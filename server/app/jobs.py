"""Koordination mehrerer Worker/Replikas über PostgreSQL-Advisory-Locks (SQLite: ein Schreiber, BEGIN IMMEDIATE).

Was nur einmal laufen darf und wie es koordiniert ist:
  Schema-Migration (AUTO_MIGRATE=1)  session-Lock "migrate" (blockierend) um Alembic + Trigger → mehrere
                                     startende Worker migrieren nacheinander, der zweite findet "head" vor
  Anker-Erzeugung (maybe_anchor)      xact-Lock ("anchor", Mandant) VOR dem Lesen des letzten Ankers → kein
                                     doppelter Anker, auch ohne Sperre der Mandantenzeile; frei beim Commit
  Vollprüfung (?full=1)               try-xact-Lock ("verify_full", Mandant) im Snapshot; belegt → 409 mit
                                     Retry-After (die Prüfung eines anderen Workers läuft bereits)
  fällige Vollprüfung (PDF/Verify)    derselbe try-Lock; belegt → dieser Worker prüft inkrementell weiter
  Prüfstand fortschreiben             xact-Lock ("verify_checkpoint", Mandant) in eigener kurzer Transaktion;
                                     nur monoton (integrity._advances), Befund entwertet ihn
  Webhook-Zustellung                 BackgroundTask genau des Workers, der die Anfrage bearbeitet hat (je
                                     Ereignis genau einmal angestossen; keine periodischen Jobs/Scheduler)
  Aufräumen flüchtiger Zustände       per TTL im State-Backend (kein Job nötig)
Periodische Hintergrundjobs gibt es nicht; `singleton()` steht für künftige bereit (Session-Lock auf eigener
Verbindung, nicht blockierend, wird beim Verlassen bzw. Verbindungsende – auch SIGTERM/Absturz – frei).
"""
import hashlib
import time
from collections.abc import Iterator
from contextlib import contextmanager

from sqlalchemy import Connection, Engine, text
from sqlalchemy.orm import Session


def lock_key(name: str, *parts) -> int:
    """Stabiler signierter 64-Bit-Schlüssel (pg_advisory_lock(bigint))."""
    raw = "|".join(["fahrzeugbuch", name, *map(str, parts)]).encode()
    return int.from_bytes(hashlib.sha256(raw).digest()[:8], "big", signed=True)


def _is_pg(bind) -> bool:
    return bind.dialect.name == "postgresql"


def xact_lock(db: Session | Connection, name: str, *parts, wait: bool = True) -> bool:
    """Transaktions-Lock (frei bei Commit/Rollback). wait=False → False, wenn belegt. SQLite: immer True."""
    bind = db.get_bind() if isinstance(db, Session) else db
    if not _is_pg(bind):
        return True
    key = lock_key(name, *parts)
    if wait:
        db.execute(text("SELECT pg_advisory_xact_lock(:k)"), {"k": key})
        return True
    return bool(db.execute(text("SELECT pg_try_advisory_xact_lock(:k)"), {"k": key}).scalar())


@contextmanager
def session_lock(engine: Engine, name: str, *parts, wait: bool = True,
                 timeout: float = 900.0) -> Iterator[Connection | None]:
    """Session-Lock auf eigener Verbindung (AUTOCOMMIT) für die Dauer des Blocks. Liefert die Verbindung bzw.
    None, wenn wait=False und belegt. Gewartet wird per pg_try_advisory_lock in kurzen Abständen OHNE offene
    Transaktion – sonst würde z. B. CREATE INDEX CONCURRENTLY des Lock-Inhabers auf den Wartenden warten.
    SQLite: Verbindung ohne Lock."""
    with engine.connect() as conn:
        if not _is_pg(conn):
            yield conn
            return
        conn = conn.execution_options(isolation_level="AUTOCOMMIT")
        key = lock_key(name, *parts)
        deadline = time.monotonic() + timeout
        while True:
            got = bool(conn.execute(text("SELECT pg_try_advisory_lock(:k)"), {"k": key}).scalar())
            if got or not wait:
                break
            if time.monotonic() > deadline:
                raise TimeoutError(f"Advisory-Lock {name} nicht erhalten")
            time.sleep(0.5)
        if not got:
            yield None
            return
        try:
            yield conn
        finally:
            try:
                conn.execute(text("SELECT pg_advisory_unlock(:k)"), {"k": key})
            except Exception:  # noqa: BLE001 – Verbindung weg → Lock ist ohnehin frei
                conn.invalidate()


@contextmanager
def singleton(engine: Engine, name: str) -> Iterator[bool]:
    """Periodischer Job nur in einem Prozess: True → dieser Prozess führt aus, False → anderer läuft."""
    with session_lock(engine, name, wait=False) as conn:
        yield conn is not None
