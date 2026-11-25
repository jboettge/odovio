"""Revisionssicherheit: Append-only-Journal mit SHA-256-Hash-Kette je Mandant.

hash_n = SHA256(hash_{n-1} + "\\n" + kanonisches JSON der Revisionsfelder)
Jede Manipulation (Ändern, Löschen, Einfügen, Umordnen) bricht die Kette ab der
betroffenen Revision. UPDATE/DELETE/TRUNCATE auf `revisions` sperrt ein DB-Trigger.
"""
import datetime as dt
import hashlib
import json

from sqlalchemy import Engine, select, text
from sqlalchemy.orm import Session

from .auth import User
from .models import GENESIS, Revision, Tenant

IMMUTABLE_TABLES = ("revisions", "anchors")

HASHED_FIELDS = (
    "tenant_id", "seq", "entity", "entity_id", "version", "action", "data",
    "actor_sub", "actor_name", "recorded_at", "client_ts", "op_id", "conflict",
)


def canonical(obj) -> str:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False, default=str)


def compute_hash(prev_hash: str, rev: Revision) -> str:
    payload = canonical({f: getattr(rev, f) for f in HASHED_FIELDS})
    return hashlib.sha256(f"{prev_hash}\n{payload}".encode()).hexdigest()


def append_revision(
    db: Session,
    tenant: Tenant,
    *,
    entity: str,
    entity_id: str,
    version: int,
    action: str,
    data: dict,
    user: User,
    client_ts: str | None = None,
    op_id: str | None = None,
    conflict: bool = False,
) -> Revision:
    """Hängt eine Revision an. Aufrufer muss die Tenant-Zeile gesperrt haben (SELECT … FOR UPDATE)."""
    tenant.seq += 1
    rev = Revision(
        tenant_id=tenant.id,
        seq=tenant.seq,
        entity=entity,
        entity_id=entity_id,
        version=version,
        action=action,
        data=canonical(data),
        actor_sub=user.sub,
        actor_name=user.name,
        recorded_at=dt.datetime.now(dt.UTC).isoformat(timespec="milliseconds"),
        client_ts=client_ts,
        op_id=op_id,
        conflict=conflict,
        prev_hash=tenant.head_hash,
    )
    rev.hash = compute_hash(rev.prev_hash, rev)
    tenant.head_hash = rev.hash
    db.add(rev)
    return rev


CHAIN_COLUMNS = tuple(getattr(Revision, f) for f in (*HASHED_FIELDS, "prev_hash", "hash"))


def verify_chain(db: Session, tenant: Tenant, start: tuple[int, str] | None = None) -> dict:
    """Hash-Kette prüfen – vollständig oder ab einem bereits bestätigten Stand `start` = (seq, hash).
    Liest nur die gehashten Spalten, in Blöcken (kein vollständiges Laden als ORM-Objekte)."""
    prev, expected_seq, count = GENESIS, 1, 0
    if start is not None:
        count, prev = start
        expected_seq = count + 1
    q = select(*CHAIN_COLUMNS).where(Revision.tenant_id == tenant.id, Revision.seq > count).order_by(Revision.seq)
    for rev in db.execute(q.execution_options(yield_per=2000)):
        reason, at = None, rev.seq
        if rev.seq != expected_seq:
            reason, at = f"Lücke: Seq {expected_seq} fehlt", expected_seq
        elif rev.prev_hash != prev:
            reason = "Verkettung (prev_hash) gebrochen"
        elif compute_hash(prev, rev) != rev.hash:
            reason = "Inhalt verändert (Hash stimmt nicht)"
        if reason:
            return {"ok": False, "count": count, "head_hash": prev, "broken_at": at, "reason": reason}
        prev, expected_seq, count = rev.hash, expected_seq + 1, count + 1
    if count != tenant.seq or prev != tenant.head_hash:
        return {"ok": False, "count": count, "head_hash": prev, "broken_at": count + 1,
                "reason": "Kettenende stimmt nicht mit Mandantenstand überein (Revisionen entfernt?)"}
    return {"ok": True, "count": count, "head_hash": prev, "broken_at": None, "reason": None}


def install_triggers(engine: Engine) -> None:
    with engine.begin() as conn:
        if engine.dialect.name == "postgresql":
            conn.execute(text("""
                CREATE OR REPLACE FUNCTION fzb_revisions_immutable() RETURNS trigger AS $$
                BEGIN RAISE EXCEPTION 'revisions sind unveränderlich (revisionssicher)'; END;
                $$ LANGUAGE plpgsql"""))
            for table in IMMUTABLE_TABLES:
                conn.execute(text(f"DROP TRIGGER IF EXISTS fzb_{table}_no_change ON {table}"))
                conn.execute(text(f"""CREATE TRIGGER fzb_{table}_no_change BEFORE UPDATE OR DELETE ON {table}
                    FOR EACH ROW EXECUTE FUNCTION fzb_revisions_immutable()"""))
                conn.execute(text(f"DROP TRIGGER IF EXISTS fzb_{table}_no_truncate ON {table}"))
                conn.execute(text(f"""CREATE TRIGGER fzb_{table}_no_truncate BEFORE TRUNCATE ON {table}
                    FOR EACH STATEMENT EXECUTE FUNCTION fzb_revisions_immutable()"""))
        elif engine.dialect.name == "sqlite":
            for table in IMMUTABLE_TABLES:
                for op in ("UPDATE", "DELETE"):
                    conn.execute(text(f"""CREATE TRIGGER IF NOT EXISTS fzb_{table}_no_{op.lower()}
                        BEFORE {op} ON {table} BEGIN
                        SELECT RAISE(ABORT, '{table} sind unveränderlich (revisionssicher)'); END"""))
