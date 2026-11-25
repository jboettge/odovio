"""Integritätsprüfung: Hash-Kette + Abgleich Fachtabellen ↔ Journal + signierte Anker + Belegdateien."""
import base64
import datetime as dt
import hashlib
import json
import os
from functools import lru_cache

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from sqlalchemy import select
from sqlalchemy.orm import Session

from . import models
from .attachments import verify_blobs
from .audit import canonical, verify_chain
from .sync import ENTITIES, snapshot

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


def public_key_b64(key: Ed25519PrivateKey) -> str:
    return base64.b64encode(key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)).decode()


def key_id(key: Ed25519PrivateKey) -> str:
    return hashlib.sha256(key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)).hexdigest()[:16]


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


# ---------- Prüfungen ----------
def _same(recorded: dict, current: dict) -> bool:
    """Später ergänzte optionale Felder (z. B. maintenance_material.article_id) fehlen in
    Altrevisionen; solange sie im Datensatz None sind, entspricht das dem Stand der Revision."""
    added = current.keys() - recorded.keys()
    if any(current[k] is not None for k in added):
        return False
    return recorded == {k: v for k, v in current.items() if k not in added}


def verify_state(db: Session, tenant: models.Tenant) -> list[str]:
    """Jeder Datensatz muss exakt dem Stand seiner letzten Revision entsprechen."""
    latest: dict[tuple[str, str], models.Revision] = {}
    for rev in db.scalars(select(models.Revision).where(models.Revision.tenant_id == tenant.id)
                          .order_by(models.Revision.seq)):
        latest[(rev.entity, rev.entity_id)] = rev
    problems, seen = [], set()
    for entity, (model, schema, _) in ENTITIES.items():
        for obj in db.scalars(select(model).where(model.tenant_id == tenant.id)):
            key = (entity, obj.id)
            seen.add(key)
            rev = latest.get(key)
            if rev is None:
                problems.append(f"{entity} {obj.id}: Datensatz ohne Revision")
            elif rev.version != obj.version or not _same(json.loads(rev.data),
                                                         json.loads(canonical(snapshot(obj, schema)))):
                problems.append(f"{entity} {obj.id}: weicht von Revision {rev.seq} ab")
    problems += [f"{e} {i}: Revision ohne Datensatz" for (e, i) in latest if (e, i) not in seen]
    return problems


def verify_anchors(db: Session, tenant: models.Tenant) -> dict:
    key = signing_key()
    anchors = list(db.scalars(select(models.Anchor).where(models.Anchor.tenant_id == tenant.id)
                              .order_by(models.Anchor.seq)))
    result = {"signed": key is not None, "anchors": len(anchors), "anchor_problems": []}
    if key is None:
        return result
    pub, kid = key.public_key(), key_id(key)
    hashes = dict(db.execute(select(models.Revision.seq, models.Revision.hash)
                             .where(models.Revision.tenant_id == tenant.id,
                                    models.Revision.seq.in_([a.seq for a in anchors]))).all()) if anchors else {}
    for a in anchors:
        if a.key_id != kid:
            result["anchor_problems"].append(f"Anker Seq {a.seq}: anderer Schlüssel ({a.key_id})")
            continue
        try:
            pub.verify(bytes.fromhex(a.signature), anchor_message(tenant.slug, a.seq, a.head_hash, a.created_at))
        except (InvalidSignature, ValueError):
            result["anchor_problems"].append(f"Anker Seq {a.seq}: Signatur ungültig")
            continue
        if hashes.get(a.seq) != a.head_hash:
            result["anchor_problems"].append(f"Anker Seq {a.seq}: Kette wurde nachträglich verändert")
    return result


def verify_all(db: Session, tenant: models.Tenant) -> dict:
    chain = verify_chain(db, tenant)
    state = verify_state(db, tenant)
    anchors = verify_anchors(db, tenant)
    blobs = verify_blobs(db, tenant)
    return {
        **chain,
        "ok": chain["ok"] and not state and not anchors["anchor_problems"] and not blobs["problems"],
        "chain_ok": chain["ok"],
        "state_ok": not state,
        "problems": state[:MAX_LISTED] + anchors["anchor_problems"][:MAX_LISTED] + blobs["problems"][:MAX_LISTED],
        **{k: anchors[k] for k in ("signed", "anchors")},
        "blobs_checked": blobs["checked"],
        "blobs_missing": blobs["missing"],
    }
