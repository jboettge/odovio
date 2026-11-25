"""Integritätsprüfung: Hash-Kette + Abgleich Fachtabellen ↔ Journal + signierte Anker + Belegdateien.

Konsistenz: Die Prüfung läuft in einem Snapshot (`db.snapshot_session`, PostgreSQL REPEATABLE READ READ
ONLY); der Mandantenstand (seq/head_hash) wird im selben Snapshot gelesen. Ein parallel committeter Sync
erzeugt so keinen Fehlalarm.

Aufwand: Die Kette wird inkrementell ab dem zuletzt bestätigten Stand (seq, hash) je Mandant geprüft
(Cache je Prozess). Vollprüfung mit `full=True` (API: ?full=1), nach VERIFY_FULL_INTERVAL_S (Default 24 h)
und immer, wenn der bestätigte Stand nicht mehr in der DB steht. Anker werden immer vollständig geprüft
(Signatur + Hash der Revision an der Anker-Seq).

Schlüsselwechsel: ANCHOR_PUBLIC_KEYS = kommagetrennte alte Ed25519-Public-Keys (Base64, raw 32 Byte);
Anker mit deren key_id bleiben gültig.
"""
import base64
import binascii
import datetime as dt
import hashlib
import json
import logging
import os
import threading
import time
from functools import lru_cache

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from sqlalchemy import and_, func, select
from sqlalchemy.orm import Session

from . import models, security
from .attachments import persist_blob_checks, verify_blobs
from .audit import canonical, verify_chain
from .db import snapshot_session
from .sync import ENTITIES, JOURNAL_ONLY, REVISION_META, snapshot

log = logging.getLogger("fahrzeugbuch.integrity")
MAX_LISTED = 20


# ---------- Signaturschlüssel ----------
@lru_cache(maxsize=4)
def _key(seed_b64: str) -> Ed25519PrivateKey:
    seed = base64.b64decode(seed_b64)
    if len(seed) != 32:
        raise ValueError("ANCHOR_SIGNING_KEY muss 32 Byte (Base64) sein")
    return Ed25519PrivateKey.from_private_bytes(seed)


def signing_key() -> Ed25519PrivateKey | None:
    seed = os.environ.get("ANCHOR_SIGNING_KEY", "").strip()
    return _key(seed) if seed else None


def _raw_public(pub: Ed25519PublicKey) -> bytes:
    return pub.public_bytes(Encoding.Raw, PublicFormat.Raw)


def public_key_b64(key: Ed25519PrivateKey) -> str:
    return base64.b64encode(_raw_public(key.public_key())).decode()


def key_id(key: Ed25519PrivateKey | Ed25519PublicKey) -> str:
    pub = key.public_key() if isinstance(key, Ed25519PrivateKey) else key
    return hashlib.sha256(_raw_public(pub)).hexdigest()[:16]


@lru_cache(maxsize=8)
def _public_keys(spec: str) -> tuple[Ed25519PublicKey, ...]:
    out = []
    for item in filter(None, (x.strip() for x in spec.split(","))):
        try:
            raw = base64.b64decode(item, validate=True)
            out.append(Ed25519PublicKey.from_public_bytes(raw))
        except (binascii.Error, ValueError):
            log.error("ANCHOR_PUBLIC_KEYS: ungültiger Schlüssel (Base64, 32 Byte erwartet) – ignoriert")
    return tuple(out)


def verification_keys() -> dict[str, Ed25519PublicKey]:
    """key_id → Public Key: aktueller Signaturschlüssel + alte Schlüssel aus ANCHOR_PUBLIC_KEYS."""
    keys = {key_id(k): k for k in _public_keys(os.environ.get("ANCHOR_PUBLIC_KEYS", ""))}
    if (key := signing_key()) is not None:
        keys[key_id(key)] = key.public_key()
    return keys


def anchor_message(slug: str, seq: int, head_hash: str, created_at: str) -> bytes:
    return f"fahrzeugbuch-anchor|{slug}|{seq}|{head_hash}|{created_at}".encode()


def maybe_anchor(db: Session, tenant: models.Tenant, force: bool = False) -> models.Anchor | None:
    """Neuen Anker setzen, wenn die Kette seit dem letzten Anker gewachsen ist
    (und das Intervall abgelaufen ist bzw. `force`)."""
    key = signing_key()
    if key is None or tenant.seq == 0:
        return None
    last = db.scalar(select(models.Anchor).where(models.Anchor.tenant_id == tenant.id)
                     .order_by(models.Anchor.seq.desc()).limit(1))
    if last is not None and last.seq >= tenant.seq:
        return None
    interval = dt.timedelta(minutes=int(os.environ.get("ANCHOR_INTERVAL_MIN", "60")))
    now = dt.datetime.now(dt.UTC)
    if not force and last is not None and now - dt.datetime.fromisoformat(last.created_at) < interval:
        return None
    created = now.isoformat(timespec="seconds")
    sig = key.sign(anchor_message(tenant.slug, tenant.seq, tenant.head_hash, created))
    a = models.Anchor(tenant_id=tenant.id, seq=tenant.seq, head_hash=tenant.head_hash, created_at=created,
                      key_id=key_id(key), signature=sig.hex())
    db.add(a)
    return a


# ---------- bestätigter Kettenstand (inkrementelle Prüfung) ----------
_verified: dict[tuple[str, int], tuple[int, str, float]] = {}   # (DB, Mandant) → (seq, hash, Vollprüfung)
_verified_lock = threading.Lock()


def _full_interval() -> float:
    try:
        return float(os.environ.get("VERIFY_FULL_INTERVAL_S") or 86400)
    except ValueError:
        return 86400.0


def _cache_key(db: Session, tenant_id: int) -> tuple[str, int]:
    return str(db.get_bind().url), tenant_id


def clear_verify_cache() -> None:
    with _verified_lock:
        _verified.clear()


def _start_point(db: Session, tenant: models.Tenant) -> tuple[tuple[int, str] | None, float]:
    """Bestätigter Stand, sofern noch gültig: Revision an der Seq hat noch denselben Hash und die letzte
    Vollprüfung ist nicht älter als VERIFY_FULL_INTERVAL_S."""
    with _verified_lock:
        hit = _verified.get(_cache_key(db, tenant.id))
    if hit is None:
        return None, time.monotonic()
    seq, head, full_at = hit
    if time.monotonic() - full_at > _full_interval() or seq > tenant.seq:
        return None, time.monotonic()
    stored = db.scalar(select(models.Revision.hash).where(models.Revision.tenant_id == tenant.id,
                                                           models.Revision.seq == seq))
    if stored != head:
        return None, time.monotonic()
    return (seq, head), full_at


def verify_chain_cached(db: Session, tenant: models.Tenant, full: bool = False) -> dict:
    start, full_at = (None, time.monotonic()) if full else _start_point(db, tenant)
    chain = verify_chain(db, tenant, start)
    key = _cache_key(db, tenant.id)
    with _verified_lock:
        if chain["ok"]:
            _verified[key] = (chain["count"], chain["head_hash"], full_at)
        else:
            _verified.pop(key, None)
    return {**chain, "incremental_from": start[0] if start else None}


# ---------- Prüfungen ----------
def _same(recorded: dict, current: dict, defaults: dict | None = None) -> bool:
    """Später ergänzte optionale Felder (z. B. maintenance_material.article_id, trip.km_estimated) fehlen in
    Altrevisionen; solange sie im Datensatz None bzw. ihr Default sind, entspricht das dem Stand der
    Revision. Begründungen (storno_reason …) stehen nur in der Revision."""
    defaults = defaults or {}
    recorded = {k: v for k, v in recorded.items() if k not in REVISION_META}
    added = current.keys() - recorded.keys()
    if any(current[k] is not None and current[k] != defaults.get(k) for k in added):
        return False
    return recorded == {k: v for k, v in current.items() if k not in added}


def _latest_revisions(db: Session, tenant_id: int, entity: str):
    """Letzte Revision je Objekt per SQL (GROUP BY über den Index tenant_id, entity, entity_id)."""
    last = select(models.Revision.entity_id, func.max(models.Revision.seq).label("seq")).where(
        models.Revision.tenant_id == tenant_id, models.Revision.entity == entity
    ).group_by(models.Revision.entity_id).subquery()
    q = select(models.Revision.entity_id, models.Revision.seq, models.Revision.version, models.Revision.data) \
        .join(last, and_(models.Revision.tenant_id == tenant_id, models.Revision.seq == last.c.seq))
    return db.execute(q.execution_options(yield_per=2000))


def verify_state(db: Session, tenant: models.Tenant) -> list[str]:
    """Jeder Datensatz muss exakt dem Stand seiner letzten Revision entsprechen."""
    problems: list[str] = []
    seen_entities = set()
    for entity, (model, schema, _) in ENTITIES.items():
        seen_entities.add(entity)
        latest = {r.entity_id: r for r in _latest_revisions(db, tenant.id, entity)}
        defaults = {k: f.default for k, f in schema.model_fields.items()}
        cols = [model.id, model.version, model.deleted, *(getattr(model, k) for k in schema.model_fields)]
        q = select(*cols).where(model.tenant_id == tenant.id)
        for row in db.execute(q.execution_options(yield_per=2000)):
            rev = latest.pop(row.id, None)
            if rev is None:
                problems.append(f"{entity} {row.id}: Datensatz ohne Revision")
            elif rev.version != row.version or not _same(json.loads(rev.data),
                                                         json.loads(canonical(snapshot(row, schema))), defaults):
                problems.append(f"{entity} {row.id}: weicht von Revision {rev.seq} ab")
        problems += [f"{entity} {i}: Revision ohne Datensatz" for i in latest]
    # Revisionen unbekannter Objekttypen (reine Journal-Einträge wie Mitgliederänderungen sind bekannt;
    # sie sind über die Hash-Kette geschützt, haben aber keinen Datensatz zum Abgleich)
    seen_entities |= JOURNAL_ONLY
    others = db.scalars(select(models.Revision.entity).distinct().where(
        models.Revision.tenant_id == tenant.id, models.Revision.entity.not_in(seen_entities)))
    problems += [f"{e}: unbekannter Objekttyp im Journal" for e in others]
    return problems


def verify_anchors(db: Session, tenant: models.Tenant) -> dict:
    keys = verification_keys()
    anchors = list(db.scalars(select(models.Anchor).where(models.Anchor.tenant_id == tenant.id)
                              .order_by(models.Anchor.seq)))
    result = {"signed": signing_key() is not None, "anchors": len(anchors), "anchor_problems": []}
    if not keys:
        return result
    hashes = dict(db.execute(select(models.Revision.seq, models.Revision.hash)
                             .where(models.Revision.tenant_id == tenant.id,
                                    models.Revision.seq.in_([a.seq for a in anchors]))).all()) if anchors else {}
    for a in anchors:
        pub = keys.get(a.key_id)
        if pub is None:
            result["anchor_problems"].append(f"Anker Seq {a.seq}: unbekannter Schlüssel ({a.key_id})")
            continue
        try:
            pub.verify(bytes.fromhex(a.signature), anchor_message(tenant.slug, a.seq, a.head_hash, a.created_at))
        except (InvalidSignature, ValueError):
            result["anchor_problems"].append(f"Anker Seq {a.seq}: Signatur ungültig")
            continue
        if hashes.get(a.seq) != a.head_hash:
            result["anchor_problems"].append(f"Anker Seq {a.seq}: Kette wurde nachträglich verändert")
    return result


def verify_all(db: Session, tenant: models.Tenant, full: bool = False) -> dict:
    """Alle Prüfungen in der Sitzung `db` (sollte ein Snapshot sein). Der Mandantenstand wird in
    derselben Sitzung frisch gelesen – ein veraltetes Tenant-Objekt des Aufrufers spielt keine Rolle."""
    tenant = db.get(models.Tenant, tenant.id, populate_existing=True)
    chain = verify_chain_cached(db, tenant, full)
    state = verify_state(db, tenant)
    anchors = verify_anchors(db, tenant)
    blobs = verify_blobs(db, tenant, use_cache=not full)
    if blobs["updates"]:
        persist_blob_checks(tenant.id, blobs["updates"])
    ok = chain["ok"] and not state and not anchors["anchor_problems"] and not blobs["problems"]
    if not ok:
        first = (chain.get("reason") if not chain["ok"] else None) or \
            next(iter(state + anchors["anchor_problems"] + blobs["problems"]), "")
        security.event("integrity_failed", tenant=tenant.slug, reason=first, broken_at=chain.get("broken_at"),
                       throttle=300)
    return {
        **chain,
        "ok": ok,
        "chain_ok": chain["ok"],
        "state_ok": not state,
        "problems": state[:MAX_LISTED] + anchors["anchor_problems"][:MAX_LISTED] + blobs["problems"][:MAX_LISTED],
        **{k: anchors[k] for k in ("signed", "anchors")},
        "blobs_checked": blobs["checked"],
        "blobs_missing": blobs["missing"],
    }


def verify_tenant(tenant_id: int, full: bool = False) -> dict:
    """Prüfung in einem eigenen, konsistenten Snapshot (ohne Sperren)."""
    with snapshot_session() as db:
        return verify_all(db, db.get(models.Tenant, tenant_id), full)
