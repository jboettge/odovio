"""Integritätsprüfung: Hash-Kette + Abgleich Fachtabellen ↔ Journal + signierte Anker + Belegdateien.

Konsistenz: Die Prüfung läuft in einem Snapshot (`db.snapshot_session`, PostgreSQL REPEATABLE READ READ
ONLY); der Mandantenstand (seq/head_hash) wird im selben Snapshot gelesen. Ein parallel committeter Sync
erzeugt so keinen Fehlalarm.

Aufwand – inkrementell ab dem bestätigten Prüfstand (Tabelle `verify_checkpoints`, eine Zeile je Mandant, für
alle Worker/Replikas gemeinsam): Kette und Datenstand sind bis Seq S mit Kettenkopf H bestätigt, die letzte
Vollprüfung lief am T auf Stand F. Eine Standardprüfung (PDF-Integritätsabschnitt, /audit/verify) prüft nur
  - die Kette ab (S, H); die Revision an Seq S muss noch den Hash H haben (sonst Vollprüfung),
  - die Datensätze mit Revision oder last_seq > S gegen ihre letzte Revision,
  - die Anzahl Datensätze je Objekttyp (Stand bei S + seither neu angelegte Objekte → erkennt direkt
    eingefügte/entfernte Zeilen),
  - die signierten Anker mit Seq > S (ältere deckt H ab: ein Neuberechnen der Kette ändert H).
Erst die nächste Vollprüfung erkennt: Änderungen an bereits bestätigten Revisionen ohne Neuberechnen der
Folgehashes und an seither unveränderten Datensätzen (beides nur mit DB-Vollzugriff bzw. abgeschalteten Triggern).
Vollprüfung: `full=True` (API ?full=1, je Mandant ein Lauf gleichzeitig), ohne gültigen Prüfstand und sobald
die letzte älter als VERIFY_FULL_INTERVAL_S (Default 24 h) ist – dann übernimmt sie der Worker, der den
try-Advisory-Lock "verify_full" erhält; die übrigen prüfen so lange inkrementell weiter. Liegt die letzte
Vollprüfung mehr als FULL_OVERDUE_FACTOR × VERIFY_FULL_INTERVAL_S zurück und kann sie trotzdem nicht laufen
(Lock dauerhaft belegt – der Schlüssel ist ableitbar, wer die DB erreicht, kann ihn halten), meldet die Prüfung
«Vollprüfung überfällig» (ok=false, full_overdue, Sicherheits-Log integrity_full_overdue) statt «OK».

Absicherung des Prüfstands: mit ANCHOR_SIGNING_KEY Ed25519-signiert (Schlüssel wie bei den Ankern, liegt nicht in
der DB), inkl. failed_seq (Format v2; ältere Signaturen ohne failed_seq gelten nicht → einmalig Vollprüfung).
Fehlende/ungültige Signatur, unbekannter Schlüssel, S > Mandantenstand, geänderter Hash an S oder
Vollprüfungszeitpunkt in der Zukunft → Vollprüfung. Ohne Schlüssel ist der Prüfstand unsigniert (wer die DB
schreiben kann, könnte die Vollprüfung hinauszögern; ?full=1 prüft immer vollständig). Fortschreiben nur
monoton, in eigener kurzer Transaktion unter Advisory-Lock je Mandant: Vollprüfung mit Stand ≥ letzter
Vollprüfung, inkrementell nur auf derselben Vollprüfung mit grösserer Seq. Jeder Befund (Kette, Datenstand,
Anker) entwertet den Prüfstand; erst eine fehlerfreie Vollprüfung auf einem neueren Stand setzt ihn wieder – oder
auf demselben Stand, wenn sie nach dem Befund begonnen hat (behobener Befund ohne neue Schreibvorgänge).

Schlüsselwechsel: ANCHOR_PUBLIC_KEYS = kommagetrennte alte Ed25519-Public-Keys (Base64, raw 32 Byte);
Anker mit deren key_id bleiben gültig. Optional je Schlüssel eine Gültigkeitsgrenze (Review X8), damit ein
abgelöster (ev. kompromittierter) Schlüssel keine NEUEN Anker/Prüfstände mehr bestätigt:
  <key>@2026-11-30                  gültig für Anker/Prüfstände bis und mit diesem Tag (UTC)
  <key>@2026-11-30T12:00:00+00:00   bis zu diesem Zeitpunkt (ISO-8601, ohne Zone = UTC)
  <key>@1234                        bis und mit Seq 1234 (Seq je Mandant – nur bei einem Mandanten sinnvoll)
Ohne «@…» unbegrenzt (bisheriges Format). Massgebend ist created_at des Ankers bzw. verified_at des Prüfstands.
"""
import base64
import binascii
import datetime as dt
import hashlib
import json
import logging
import os
from collections import defaultdict
from dataclasses import dataclass
from functools import lru_cache
from itertools import batched

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from sqlalchemy import and_, func, select
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from . import jobs, models, security
from .attachments import persist_blob_checks, verify_blobs
from .audit import canonical, verify_chain
from .db import SessionLocal, snapshot_session
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


@dataclass(frozen=True)
class KeyLimit:
    """Gültigkeitsgrenze eines alten Schlüssels: bis Seq (inkl.) bzw. bis Zeitpunkt (inkl., UTC)."""
    until_seq: int | None = None
    until: dt.datetime | None = None
    text: str = ""

    def problem(self, seq: int, at: str | None) -> str | None:
        """None = innerhalb der Gültigkeit, sonst Grund."""
        if self.until_seq is not None and seq > self.until_seq:
            return f"Schlüssel nur gültig bis Seq {self.until_seq}"
        if self.until is not None:
            try:
                when = _utc(dt.datetime.fromisoformat(at or ""))
            except ValueError:
                return f"Schlüssel nur gültig bis {self.text}, Zeitpunkt unlesbar"
            if when > self.until:
                return f"Schlüssel nur gültig bis {self.text}"
        return None


def _utc(t: dt.datetime) -> dt.datetime:
    return t.replace(tzinfo=dt.UTC) if t.tzinfo is None else t.astimezone(dt.UTC)


def _parse_limit(text: str) -> KeyLimit:
    if text.isdigit():
        return KeyLimit(until_seq=int(text), text=text)
    if len(text) == 10:                                   # Datum: bis und mit diesem Tag (UTC)
        day = dt.date.fromisoformat(text)
        return KeyLimit(until=dt.datetime.combine(day, dt.time.max, dt.UTC), text=text)
    return KeyLimit(until=_utc(dt.datetime.fromisoformat(text)), text=text)


@lru_cache(maxsize=8)
def _public_keys(spec: str) -> tuple[tuple[Ed25519PublicKey, KeyLimit | None], ...]:
    out = []
    for item in filter(None, (x.strip() for x in spec.split(","))):
        b64, _, limit = item.partition("@")
        try:
            raw = base64.b64decode(b64.strip(), validate=True)
            out.append((Ed25519PublicKey.from_public_bytes(raw), _parse_limit(limit.strip()) if limit else None))
        except (binascii.Error, ValueError):
            log.error("ANCHOR_PUBLIC_KEYS: ungültiger Eintrag (Base64, 32 Byte, optional @Datum/@Seq) – ignoriert")
    return tuple(out)


def verification_keys() -> dict[str, Ed25519PublicKey]:
    """key_id → Public Key: aktueller Signaturschlüssel + alte Schlüssel aus ANCHOR_PUBLIC_KEYS."""
    keys = {key_id(k): k for k, _ in _public_keys(os.environ.get("ANCHOR_PUBLIC_KEYS", ""))}
    if (key := signing_key()) is not None:
        keys[key_id(key)] = key.public_key()
    return keys


def key_limits() -> dict[str, KeyLimit]:
    """key_id → Gültigkeitsgrenze der alten Schlüssel (nur mit «@…»; der aktuelle Signaturschlüssel nie)."""
    out = {key_id(k): lim for k, lim in _public_keys(os.environ.get("ANCHOR_PUBLIC_KEYS", "")) if lim}
    if (key := signing_key()) is not None:
        out.pop(key_id(key), None)
    return out


def anchor_message(slug: str, seq: int, head_hash: str, created_at: str) -> bytes:
    return f"fahrzeugbuch-anchor|{slug}|{seq}|{head_hash}|{created_at}".encode()


def maybe_anchor(db: Session, tenant: models.Tenant, force: bool = False) -> models.Anchor | None:
    """Neuen Anker setzen, wenn die Kette seit dem letzten Anker gewachsen ist
    (und das Intervall abgelaufen ist bzw. `force`)."""
    key = signing_key()
    if key is None or tenant.seq == 0:
        return None
    # mehrere Worker/Replikas: serialisieren VOR dem Lesen des letzten Ankers (frei beim Commit)
    jobs.xact_lock(db, "anchor", tenant.id)
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


# ---------- bestätigter Prüfstand (inkrementelle Prüfung) ----------
CLOCK_SKEW = dt.timedelta(minutes=5)
FULL_OVERDUE_FACTOR = 2      # fällige, aber nicht ausgeführte Vollprüfung → ab diesem Vielfachen «überfällig»


def full_interval() -> float:
    """VERIFY_FULL_INTERVAL_S: Vollprüfung fällig nach so vielen Sekunden (Default 24 h)."""
    try:
        return float(os.environ.get("VERIFY_FULL_INTERVAL_S") or 86400)
    except ValueError:
        return 86400.0


def _utcnow() -> str:
    return dt.datetime.now(dt.UTC).isoformat(timespec="seconds")


@dataclass(frozen=True)
class Checkpoint:
    """Bestätigter Stand: Kette + Datenstand bis `seq` (Kopf `head_hash`, `counts` Datensätze je Objekttyp);
    letzte Vollprüfung am `full_at` (UTC ISO) auf Stand `full_seq`."""
    seq: int
    head_hash: str
    counts: dict[str, int]
    full_seq: int
    full_at: str

    def full_age_s(self) -> float:
        return (dt.datetime.now(dt.UTC) - dt.datetime.fromisoformat(self.full_at)).total_seconds()

    def full_due(self) -> bool:
        return self.full_age_s() > full_interval()

    def full_overdue(self) -> bool:
        return self.full_age_s() > FULL_OVERDUE_FACTOR * full_interval()


def checkpoint_message(slug: str, row: models.VerifyCheckpoint, version: int = 2) -> bytes:
    """Signierter Inhalt des Prüfstands. v2 (aktuell) inkl. failed_seq; v1 nur noch zum Erkennen alter Zeilen."""
    fields = {"tenant": slug, "seq": row.seq, "head_hash": row.head_hash, "counts": row.counts,
              "full_seq": row.full_seq, "full_at": row.full_at, "verified_at": row.verified_at}
    if version == 1:
        return ("fahrzeugbuch-verified|" + canonical(fields)).encode()
    return ("fahrzeugbuch-verified-v2|" + canonical({**fields, "failed_seq": row.failed_seq})).encode()


def _verify_sig(pub: Ed25519PublicKey, signature: str, message: bytes) -> bool:
    try:
        pub.verify(bytes.fromhex(signature), message)
    except (InvalidSignature, ValueError):
        return False
    return True


def _signature_problem(slug: str, row: models.VerifyCheckpoint) -> str | None:
    """None = Signatur gültig (bzw. kein Schlüssel konfiguriert), sonst Grund."""
    keys = verification_keys()
    if not keys:                      # ohne Schlüssel unsigniert (s. Modul-Docstring)
        return None
    pub = keys.get(row.key_id or "")
    if pub is None or not row.signature:
        return "Signatur fehlt oder unbekannter Schlüssel"
    if (lim := key_limits().get(row.key_id or "")) and (why := lim.problem(row.seq, row.verified_at)):
        return why
    if _verify_sig(pub, row.signature, checkpoint_message(slug, row)):
        return None
    if _verify_sig(pub, row.signature, checkpoint_message(slug, row, version=1)):
        return "Signatur im alten Format (ohne failed_seq)"
    return "Signatur ungültig"


def load_checkpoint(db: Session, tenant: models.Tenant) -> Checkpoint | None:
    """Gültiger Prüfstand des Mandanten im Snapshot `db` oder None (→ Vollprüfung)."""
    row = db.get(models.VerifyCheckpoint, tenant.id)
    if row is None or row.full_at is None:
        return None
    reason = None
    try:
        full_at = dt.datetime.fromisoformat(row.full_at)
        counts = {str(k): int(v) for k, v in json.loads(row.counts).items()}
    except (TypeError, ValueError, AttributeError):
        full_at, counts, reason = None, {}, "unlesbar"
    if reason is None and (sig := _signature_problem(tenant.slug, row)) is not None:
        reason = sig
    elif reason is None and (full_at.tzinfo is None or full_at > dt.datetime.now(dt.UTC) + CLOCK_SKEW):
        reason = "Vollprüfungszeitpunkt ungültig"
    elif reason is None and row.seq > tenant.seq:
        reason = "neuer als der Mandantenstand"
    elif reason is None and ENTITIES.keys() - counts.keys():
        reason = "ohne Zählstand für neue Objekttypen"
    elif reason is None:
        stored = models.GENESIS if row.seq == 0 else db.scalar(select(models.Revision.hash).where(
            models.Revision.tenant_id == tenant.id, models.Revision.seq == row.seq))
        if stored != row.head_hash:
            reason = f"Revision {row.seq} hat nicht mehr den bestätigten Hash"
    if reason:
        log.warning("Prüfstand Mandant %s verworfen (%s) – Vollprüfung", tenant.slug, reason)
        return None
    return Checkpoint(row.seq, row.head_hash, counts, row.full_seq, row.full_at)


def _clears_failure(row: models.VerifyCheckpoint, new: Checkpoint) -> bool:
    """Hebt die fehlerfreie Vollprüfung `new` den letzten Befund auf? Auf neuerem Stand immer; auf demselben Stand
    (Befund behoben, ohne neue Schreibvorgänge – z. B. Belegdatei zurückgespielt), wenn sie nach dem Erfassen des
    Befunds begonnen hat (`full_at` = Start > `verified_at` = Zeitpunkt des Befunds, Review S10): ihr Snapshot
    ist dann jünger als der des Befunds. Sonst bliebe jede Prüfung bis zur nächsten Änderung eine Vollprüfung."""
    if row.failed_seq is None or new.seq > row.failed_seq:
        return True
    return new.seq == row.failed_seq and row.verified_at is not None and new.full_at > row.verified_at


def _advances(row: models.VerifyCheckpoint, new: Checkpoint, full: bool) -> bool:
    if full:      # Vollprüfung: nicht älter als die gespeicherte, nach einem Befund nur auf neuerem Stand
        return new.seq >= row.full_seq and _clears_failure(row, new)
    return (row.full_at == new.full_at and row.full_seq == new.full_seq and row.failed_seq is None
            and new.seq > row.seq)


def _persist_checkpoint(tenant: models.Tenant, new: Checkpoint | None, full: bool, seq: int) -> None:
    """Prüfstand fortschreiben (`new`) bzw. nach einem Befund auf Stand `seq` entwerten (`new` None).
    Eigene, kurze Transaktion (Snapshot ist nur lesend); Fehler sind unkritisch (nächste Prüfung voll)."""
    try:
        with SessionLocal() as db:
            jobs.xact_lock(db, "verify_checkpoint", tenant.id)
            row = db.get(models.VerifyCheckpoint, tenant.id)
            fresh = row is None
            if fresh:
                row = models.VerifyCheckpoint(tenant_id=tenant.id, seq=0, head_hash=models.GENESIS, counts="{}",
                                              full_seq=0)
                db.add(row)
            if new is None:      # Befund: verified_at = Zeitpunkt des (letzten) Befunds (s. _clears_failure)
                row.full_at = row.key_id = row.signature = None
                row.failed_seq = max(row.failed_seq or 0, seq)
                row.verified_at = _utcnow()
            else:
                if not fresh and not _advances(row, new, full):
                    return
                row.seq, row.head_hash, row.counts = new.seq, new.head_hash, canonical(new.counts)
                row.full_seq, row.full_at, row.verified_at = new.full_seq, new.full_at, _utcnow()
                if full:
                    row.failed_seq = None
                key = signing_key()
                row.key_id = key_id(key) if key else None
                row.signature = key.sign(checkpoint_message(tenant.slug, row)).hex() if key else None
            db.commit()
    except SQLAlchemyError as e:
        log.warning("Prüfstand Mandant %s nicht gespeichert (%s)", tenant.slug, type(e).__name__)


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


STATE_BATCH = 1000
MAX_PROBLEMS = 1000


def _latest_revisions(db: Session, tenant_id: int, entity: str, ids: list[str]):
    """Letzte Revision je Objekt (nur für `ids`) per SQL (GROUP BY über den Index tenant_id, entity, entity_id)."""
    last = select(models.Revision.entity_id, func.max(models.Revision.seq).label("seq")).where(
        models.Revision.tenant_id == tenant_id, models.Revision.entity == entity,
        models.Revision.entity_id.in_(ids)).group_by(models.Revision.entity_id).subquery()
    q = select(models.Revision.entity_id, models.Revision.seq, models.Revision.version, models.Revision.data) \
        .join(last, and_(models.Revision.tenant_id == tenant_id, models.Revision.seq == last.c.seq))
    return db.execute(q)


def _orphan_revisions(db: Session, tenant_id: int, entity: str, model, limit: int):
    """Objekt-IDs mit Revision, aber ohne Datensatz (Anti-Join in SQL, begrenzt)."""
    exists = select(model.id).where(model.tenant_id == tenant_id, model.id == models.Revision.entity_id).exists()
    return db.scalars(select(models.Revision.entity_id).distinct().where(
        models.Revision.tenant_id == tenant_id, models.Revision.entity == entity, ~exists).limit(limit))


def _columns(model, schema) -> list:
    return [model.id, model.version, model.deleted, *(getattr(model, k) for k in schema.model_fields)]


def _compare(entity: str, schema, defaults: dict, rows, latest: dict, problems: list[str]) -> None:
    for row in rows:
        rev = latest.get(row.id)
        if rev is None:
            problems.append(f"{entity} {row.id}: Datensatz ohne Revision")
        elif rev.version != row.version or not _same(json.loads(rev.data),
                                                     json.loads(canonical(snapshot(row, schema))), defaults):
            problems.append(f"{entity} {row.id}: weicht von Revision {rev.seq} ab")


def verify_state(db: Session, tenant: models.Tenant, counts: dict[str, int] | None = None) -> list[str]:
    """Jeder Datensatz muss exakt dem Stand seiner letzten Revision entsprechen.
    Konstanter Speicher: Datensätze werden gestreamt und in Blöcken von STATE_BATCH mit ihren letzten Revisionen
    verglichen; Revisionen ohne Datensatz per Anti-Join. Höchstens MAX_PROBLEMS Befunde werden gesammelt.
    `counts` (optional) erhält die Anzahl Datensätze je Objekttyp (für den Prüfstand)."""
    problems: list[str] = []
    seen_entities = set()
    for entity, (model, schema, _) in ENTITIES.items():
        seen_entities.add(entity)
        defaults = {k: f.default for k, f in schema.model_fields.items()}
        q = select(*_columns(model, schema)).where(model.tenant_id == tenant.id)
        n = 0
        for part in db.execute(q.execution_options(yield_per=STATE_BATCH)).partitions():
            n += len(part)
            latest = {r.entity_id: r for r in _latest_revisions(db, tenant.id, entity, [row.id for row in part])}
            _compare(entity, schema, defaults, part, latest, problems)
            if len(problems) >= MAX_PROBLEMS:
                return problems[:MAX_PROBLEMS]
        if counts is not None:
            counts[entity] = n
        problems += [f"{entity} {i}: Revision ohne Datensatz"
                     for i in _orphan_revisions(db, tenant.id, entity, model, MAX_PROBLEMS)]
    # Revisionen unbekannter Objekttypen (reine Journal-Einträge wie Mitgliederänderungen sind bekannt;
    # sie sind über die Hash-Kette geschützt, haben aber keinen Datensatz zum Abgleich)
    seen_entities |= JOURNAL_ONLY
    others = db.scalars(select(models.Revision.entity).distinct().where(
        models.Revision.tenant_id == tenant.id, models.Revision.entity.not_in(seen_entities)))
    problems += [f"{e}: unbekannter Objekttyp im Journal" for e in others]
    return problems[:MAX_PROBLEMS]


def verify_state_since(db: Session, tenant: models.Tenant, since: int,
                       counts_before: dict[str, int]) -> tuple[list[str], dict[str, int]]:
    """Inkrementeller Abgleich ab dem bestätigten Stand `since`: nur Objekte mit Revision oder last_seq > since
    gegen ihre letzte Revision, dazu die Anzahl Datensätze je Objekttyp (Stand bei `since` + seither neu
    angelegte Objekte). Liefert (Befunde, Anzahl je Objekttyp jetzt)."""
    touched: dict[str, set[str]] = defaultdict(set)
    for entity, eid in db.execute(select(models.Revision.entity, models.Revision.entity_id).where(
            models.Revision.tenant_id == tenant.id, models.Revision.seq > since)):
        touched[entity].add(eid)
    problems = [f"{e}: unbekannter Objekttyp im Journal" for e in sorted(touched)
                if e not in ENTITIES and e not in JOURNAL_ONLY]
    counts: dict[str, int] = {}
    for entity, (model, schema, _) in ENTITIES.items():
        ids = touched.get(entity, set())
        ids |= set(db.scalars(select(model.id).where(model.tenant_id == tenant.id, model.last_seq > since)))
        defaults = {k: f.default for k, f in schema.model_fields.items()}
        created = 0
        for chunk in batched(sorted(ids), STATE_BATCH, strict=False):
            rows = db.execute(select(*_columns(model, schema)).where(model.tenant_id == tenant.id,
                                                                    model.id.in_(chunk))).all()
            latest = {r.entity_id: r for r in _latest_revisions(db, tenant.id, entity, list(chunk))}
            _compare(entity, schema, defaults, rows, latest, problems)
            present = {r.id for r in rows}
            problems += [f"{entity} {i}: Revision ohne Datensatz" for i in chunk if i in latest and i not in present]
            created += len(db.scalars(select(models.Revision.entity_id).where(
                models.Revision.tenant_id == tenant.id, models.Revision.entity == entity,
                models.Revision.entity_id.in_(chunk)).group_by(models.Revision.entity_id)
                .having(func.min(models.Revision.seq) > since)).all())
        counts[entity] = db.scalar(select(func.count()).select_from(model).where(model.tenant_id == tenant.id))
        expected = counts_before.get(entity, 0) + created
        if counts[entity] != expected:
            problems.append(f"{entity}: {counts[entity]} Datensätze statt {expected} laut Journal "
                            "(ohne Revision eingefügt oder entfernt)")
        if len(problems) >= MAX_PROBLEMS:
            break
    return problems[:MAX_PROBLEMS], counts


def verify_anchors(db: Session, tenant: models.Tenant, since: int | None = None) -> dict:
    """Signatur + Hash der Revision an der Anker-Seq; mit `since` nur Anker mit Seq > since (ältere sind über
    den bestätigten Kettenkopf abgedeckt). `anchors` zählt immer alle."""
    keys, limits = verification_keys(), key_limits()
    q = select(models.Anchor).where(models.Anchor.tenant_id == tenant.id)
    if since is not None:
        q = q.where(models.Anchor.seq > since)
    anchors = list(db.scalars(q.order_by(models.Anchor.seq)))
    total = len(anchors) if since is None else db.scalar(
        select(func.count()).select_from(models.Anchor).where(models.Anchor.tenant_id == tenant.id))
    result = {"signed": signing_key() is not None, "anchors": total, "anchors_checked": len(anchors),
              "anchor_problems": []}
    if not keys:
        result["anchors_checked"] = 0
        return result
    hashes = dict(db.execute(select(models.Revision.seq, models.Revision.hash)
                             .where(models.Revision.tenant_id == tenant.id,
                                    models.Revision.seq.in_([a.seq for a in anchors]))).all()) if anchors else {}
    for a in anchors:
        pub = keys.get(a.key_id)
        if pub is None:
            result["anchor_problems"].append(f"Anker Seq {a.seq}: unbekannter Schlüssel ({a.key_id})")
            continue
        if (lim := limits.get(a.key_id)) and (why := lim.problem(a.seq, a.created_at)):
            result["anchor_problems"].append(f"Anker Seq {a.seq}: {why} ({a.key_id})")
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
    derselben Sitzung frisch gelesen – ein veraltetes Tenant-Objekt des Aufrufers spielt keine Rolle.
    Inkrementell ab dem bestätigten Prüfstand, sonst bzw. mit `full` vollständig (s. Modul-Docstring)."""
    tenant = db.get(models.Tenant, tenant.id, populate_existing=True)
    started = _utcnow()
    cp = None if full else load_checkpoint(db, tenant)
    overdue = False
    if cp is not None and cp.full_due():
        if jobs.xact_lock(db, "verify_full", tenant.id, wait=False):
            cp = None         # Vollprüfung fällig – dieser Worker übernimmt sie (übrige: weiter inkrementell)
        else:                 # läuft woanders – oder der Lock wird festgehalten: ab 2× Intervall kein «OK» mehr
            overdue = cp.full_overdue()
    counts: dict[str, int] = {}
    if cp is None:
        chain = verify_chain(db, tenant)
        state = verify_state(db, tenant, counts)
        anchors = verify_anchors(db, tenant)
    else:
        chain = verify_chain(db, tenant, (cp.seq, cp.head_hash))
        state, counts = verify_state_since(db, tenant, cp.seq, cp.counts)
        anchors = verify_anchors(db, tenant, since=cp.seq)
    full_seq, full_at = (chain["count"], started) if cp is None else (cp.full_seq, cp.full_at)
    if chain["ok"] and not state and not anchors["anchor_problems"]:
        if cp is None or chain["count"] > cp.seq:
            _persist_checkpoint(tenant, Checkpoint(chain["count"], chain["head_hash"], counts, full_seq, full_at),
                                full=cp is None, seq=chain["count"])
    else:
        _persist_checkpoint(tenant, None, full=cp is None, seq=tenant.seq)
    blobs = verify_blobs(db, tenant, use_cache=not full)
    if blobs["updates"]:
        persist_blob_checks(tenant.id, blobs["updates"])
    clean = chain["ok"] and not state and not anchors["anchor_problems"] and not blobs["problems"]
    if not clean:
        first = (chain.get("reason") if not chain["ok"] else None) or \
            next(iter(state + anchors["anchor_problems"] + blobs["problems"]), "")
        security.event("integrity_failed", tenant=tenant.slug, reason=first, broken_at=chain.get("broken_at"),
                       throttle=300)
    overdue_note = []
    if overdue:
        overdue_note = [overdue_message(cp.full_at)]
        security.event("integrity_full_overdue", tenant=tenant.slug, reason=overdue_note[0],
                       full_at=cp.full_at, age_h=round(cp.full_age_s() / 3600, 1), throttle=300)
    return {
        **chain,
        "ok": clean and not overdue,
        "chain_ok": chain["ok"],
        "state_ok": not state,
        "full_overdue": overdue,
        "problems": state[:MAX_LISTED] + anchors["anchor_problems"][:MAX_LISTED] + blobs["problems"][:MAX_LISTED]
        + overdue_note,
        **{k: anchors[k] for k in ("signed", "anchors", "anchors_checked")},
        "blobs_checked": blobs["checked"],
        "blobs_missing": blobs["missing"],
        "incremental_from": cp.seq if cp else None,
        "full_seq": full_seq,
        "full_at": full_at,
    }


def overdue_message(full_at: str) -> str:
    return (f"Vollprüfung überfällig: letzte vollständige Prüfung {full_at} (UTC), fällig alle "
            f"{full_interval() / 3600:g} h – konnte nicht ausgeführt werden (Sperre «verify_full» belegt); "
            "Ergebnis nur inkrementell, nicht bestätigt")


class VerifyBusy(Exception):
    """Vollprüfung dieses Mandanten läuft bereits (anderer Worker/Replika)."""


def verify_tenant(tenant_id: int, full: bool = False) -> dict:
    """Prüfung in einem eigenen, konsistenten Snapshot (ohne Zeilensperren). Vollprüfung je Mandant höchstens
    einmal gleichzeitig (Advisory-Lock, PostgreSQL)."""
    with snapshot_session() as db:
        if full and not jobs.xact_lock(db, "verify_full", tenant_id, wait=False):
            raise VerifyBusy
        return verify_all(db, db.get(models.Tenant, tenant_id), full)
