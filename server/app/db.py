"""Datenbank-Engine und Sitzungen.

PostgreSQL-Pool je Worker (Env, Defaults in Klammern):
  DB_POOL_SIZE (5), DB_MAX_OVERFLOW (10), DB_POOL_TIMEOUT (30 s), DB_POOL_RECYCLE (1800 s), pool_pre_ping immer
  DB_STATEMENT_TIMEOUT_MS (30000)            statement_timeout je Verbindung (0 = aus)
  DB_IDLE_IN_TRANSACTION_TIMEOUT_MS (60000)  idle_in_transaction_session_timeout (0 = aus)
  DB_DISABLE_PREPARED=1                      psycopg prepare_threshold=None (PgBouncer im transaction mode
                                             ohne max_prepared_statements)
Verbindungsbedarf: WEB_CONCURRENCY × REPLICAS_HINT × (POOL + OVERFLOW) + Reserve ≤ PG_MAX_CONNECTIONS
(Startprüfung in app.runtime).
SQL-Parameter erscheinen nie in Fehlermeldungen/Logs (hide_parameters); Constraint-Fehler werden nur mit
SQLSTATE/Constraint-Namen protokolliert (PostgreSQL-DETAIL enthielte die Zeilenwerte).
"""
import os
from contextlib import contextmanager
from pathlib import Path

from sqlalchemy import create_engine, event
from sqlalchemy.orm import DeclarativeBase, sessionmaker

from .config import env_int

DATABASE_URL = os.environ.get("DATABASE_URL", "sqlite:///./data/fahrzeugbuch.db")


def pool_settings() -> dict:
    return {"pool_size": env_int("DB_POOL_SIZE", 5, minimum=1), "max_overflow": env_int("DB_MAX_OVERFLOW", 10),
            "pool_timeout": env_int("DB_POOL_TIMEOUT", 30, minimum=1),
            "pool_recycle": env_int("DB_POOL_RECYCLE", 1800, minimum=-1)}


def engine_args(url: str) -> dict:
    if url.startswith("sqlite"):
        db_path = url.split("///", 1)[-1]
        if db_path and db_path != ":memory:":
            Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        return {"connect_args": {"check_same_thread": False}, "pool_pre_ping": True, "hide_parameters": True}
    options = []
    if (st := env_int("DB_STATEMENT_TIMEOUT_MS", 30000)) > 0:
        options.append(f"-c statement_timeout={st}")
    if (it := env_int("DB_IDLE_IN_TRANSACTION_TIMEOUT_MS", 60000)) > 0:
        options.append(f"-c idle_in_transaction_session_timeout={it}")
    connect_args: dict = {"application_name": "fahrzeugbuch-api"}
    if options:
        connect_args["options"] = " ".join(options)
    if os.environ.get("DB_DISABLE_PREPARED") == "1" and url.startswith("postgresql+psycopg"):
        connect_args["prepare_threshold"] = None
    # hide_parameters: Fehlermeldungen/Logs ohne SQL-Parameter (Zweck, Orte, Notizen)
    return {"connect_args": connect_args, "pool_pre_ping": True, "hide_parameters": True, **pool_settings()}


engine = create_engine(DATABASE_URL, **engine_args(DATABASE_URL))

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


def db_error_code(e: Exception) -> str:
    """Datenbankfehler fürs Log ohne Werte: Typ, SQLSTATE und Constraint-Name (keine Meldung/DETAIL)."""
    orig = getattr(e, "orig", None)
    parts = [type(orig or e).__name__]
    if sqlstate := getattr(orig, "sqlstate", None):
        parts.append(str(sqlstate))
    if constraint := getattr(getattr(orig, "diag", None), "constraint_name", None):
        parts.append(str(constraint))
    return " ".join(parts)
