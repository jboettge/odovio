import os
from contextlib import contextmanager
from pathlib import Path

from sqlalchemy import create_engine, event
from sqlalchemy.orm import DeclarativeBase, sessionmaker

DATABASE_URL = os.environ.get("DATABASE_URL", "sqlite:///./data/fahrzeugbuch.db")

connect_args = {}
if DATABASE_URL.startswith("sqlite"):
    connect_args = {"check_same_thread": False}
    db_path = DATABASE_URL.split("///", 1)[-1]
    if db_path and db_path != ":memory:":
        Path(db_path).parent.mkdir(parents=True, exist_ok=True)

engine = create_engine(DATABASE_URL, connect_args=connect_args, pool_pre_ping=True)

if engine.dialect.name == "sqlite":
    # SQLite kennt kein SELECT … FOR UPDATE: jede Transaktion sofort mit Schreibsperre beginnen,
    # damit die Revisionskette auch bei parallelen Requests sequenziell bleibt. Ausnahme: Snapshot-
    # Sitzungen (nur lesend, BEGIN DEFERRED) – dank WAL blockieren sie Schreiber nicht.
    @event.listens_for(engine, "connect")
    def _sqlite_connect(dbapi_conn, _):
        dbapi_conn.isolation_level = None
        dbapi_conn.execute("PRAGMA busy_timeout = 30000")
        dbapi_conn.execute("PRAGMA foreign_keys = ON")
        if engine.url.database not in (None, "", ":memory:"):
            dbapi_conn.execute("PRAGMA journal_mode = WAL")

    @event.listens_for(engine, "begin")
    def _sqlite_begin(conn):
        conn.exec_driver_sql("BEGIN" if conn.get_execution_options().get("fzb_snapshot") else "BEGIN IMMEDIATE")
SessionLocal = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)

# Konsistenter, nur lesender Snapshot: PostgreSQL REPEATABLE READ READ ONLY (alle Abfragen sehen denselben
# Stand), SQLite eine Lesetransaktion (WAL-Snapshot). Für Integritätsprüfung und Berichte.
if engine.dialect.name == "postgresql":
    _snapshot_engine = engine.execution_options(isolation_level="REPEATABLE READ", postgresql_readonly=True)
else:
    _snapshot_engine = engine.execution_options(fzb_snapshot=True)
SnapshotLocal = sessionmaker(bind=_snapshot_engine, autoflush=False, expire_on_commit=False)


class Base(DeclarativeBase):
    pass


def get_session():
    with SessionLocal() as session:
        yield session


@contextmanager
def snapshot_session():
    """Nur lesen. Beim Verlassen wird die Sitzung geschlossen (Transaktion beendet); geladene Objekte
    bleiben lesbar (kein Expire)."""
    with SnapshotLocal() as session:
        yield session
