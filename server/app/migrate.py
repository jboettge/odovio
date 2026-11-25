"""Schema anlegen und DB-Rollen trennen (einmalig/bei jedem Deploy, als Owner).

PostgreSQL:
  MIGRATION_DATABASE_URL  Owner-Verbindung (z. B. POSTGRES_USER)  → legt Tabellen/Trigger an
  DATABASE_URL            Laufzeit-Verbindung der API (App-Rolle) → bekommt nur DML-Rechte:
                          revisions/anchors: SELECT, INSERT · übrige: SELECT, INSERT, UPDATE · kein DELETE
  APP_DB_PASSWORD         Passwort der App-Rolle (Rolle wird angelegt/aktualisiert)
Die App-Rolle ist weder Owner noch Superuser → kann Trigger nicht deaktivieren,
Revisionen nicht ändern/löschen und keine Datensätze physisch löschen.

Schema-Versionen: Alembic (server/alembic, Baseline-Revision 0001 = Schema inkl. Indizes).
  neue DB                      → alembic upgrade head
  Bestand ohne alembic_version → fehlende Spalten/Tabellen/Indizes nachrüsten, auf Baseline stempeln,
                                 dann upgrade head
  Bestand mit alembic_version  → upgrade head

Aufruf: python -m app.migrate
"""
import logging
import os
import re
import sys
from pathlib import Path

from alembic.config import Config
from sqlalchemy import Connection, Engine, create_engine, inspect, text
from sqlalchemy.engine import make_url

from alembic import command

from . import models  # noqa: F401  (Tabellen registrieren)
from .audit import IMMUTABLE_TABLES, install_triggers
from .db import Base

log = logging.getLogger("fahrzeugbuch.migrate")

# Alle Fachtabellen (inkl. Fahrtenbuch): App-Rolle darf SELECT/INSERT/UPDATE, nie DELETE.
DML_TABLES = tuple(t.name for t in Base.metadata.sorted_tables if t.name not in IMMUTABLE_TABLES)
ROLE = re.compile(r"^[a-z_][a-z0-9_]{0,62}$")


ROOT = Path(__file__).resolve().parents[1]
BASELINE = "0001"


def alembic_config(conn: Connection | None = None) -> Config:
    cfg = Config(str(ROOT / "alembic.ini"))
    cfg.set_main_option("script_location", str(ROOT / "alembic"))
    if conn is not None:
        cfg.attributes["connection"] = conn
    return cfg


def add_missing_columns(conn: Connection) -> None:
    """Idempotente Nachrüstung fehlender Spalten für ALLE Modelle (SQLite und PostgreSQL).

    `create_all` legt nur fehlende Tabellen an, ergänzt aber keine Spalten bestehender Tabellen.
    Nachgerüstet werden nullable Spalten und nicht-nullable mit Server-Default (ohne Fremdschlüssel-
    Constraint, Verweise prüft der Sync); andere nicht-nullable Spalten → Warnung."""
    insp = inspect(conn)
    tables = set(insp.get_table_names())
    ddl_compiler = conn.dialect.ddl_compiler(conn.dialect, None)
    for table in Base.metadata.sorted_tables:
        if table.name not in tables:
            continue
        present = {c["name"] for c in insp.get_columns(table.name)}
        for col in table.columns:
            if col.name in present:
                continue
            ddl = col.type.compile(dialect=conn.dialect)
            if col.primary_key or (not col.nullable and col.server_default is None):
                log.warning("Spalte %s.%s fehlt und ist nicht nullable – manuelle Migration nötig",
                            table.name, col.name)
                continue
            if not col.nullable:
                ddl += f" DEFAULT {ddl_compiler.get_column_default_string(col)} NOT NULL"
            conn.exec_driver_sql(f'ALTER TABLE {table.name} ADD COLUMN "{col.name}" {ddl}')


def add_missing_indexes(conn: Connection) -> None:
    insp = inspect(conn)
    for table in Base.metadata.sorted_tables:
        present = {i["name"] for i in insp.get_indexes(table.name)}
        for idx in table.indexes:
            if idx.name not in present:
                idx.create(conn)


def _version(conn: Connection, tables: set[str]) -> str | None:
    if "alembic_version" not in tables:
        return None
    return conn.execute(text("SELECT version_num FROM alembic_version")).scalar()


def create_schema(engine: Engine) -> None:
    with engine.begin() as conn:
        tables = set(inspect(conn).get_table_names())
        model_tables = set(Base.metadata.tables)
        version = _version(conn, tables)
        cfg = alembic_config(conn)
        if not tables & model_tables:
            if version is not None:                        # Tabellen entfernt, Versionsstand übrig
                conn.execute(text("DELETE FROM alembic_version"))
        elif version is None or model_tables - tables:
            # Bestand ohne Alembic (bzw. unvollständig): nachrüsten, dann auf die Baseline stempeln
            add_missing_columns(conn)
            Base.metadata.create_all(conn)
            add_missing_indexes(conn)
            if version is None:
                command.stamp(cfg, BASELINE)
        command.upgrade(cfg, "head")
    install_triggers(engine)


def setup_app_role(owner: Engine, role: str, password: str | None) -> None:
    if not ROLE.match(role):
        raise ValueError(f"Ungültiger Rollenname: {role}")
    from psycopg import sql

    with owner.begin() as conn:
        raw = conn.connection.driver_connection
        exists = conn.execute(text("SELECT 1 FROM pg_roles WHERE rolname = :r"), {"r": role}).scalar()
        verb = "ALTER" if exists else "CREATE"
        stmt = sql.SQL(verb + " ROLE {} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS"
                       ).format(sql.Identifier(role))
        if password:
            stmt = sql.SQL("{} PASSWORD {}").format(stmt, sql.Literal(password))
        conn.exec_driver_sql(stmt.as_string(raw))
        q = f'"{role}"'
        conn.exec_driver_sql(f"REVOKE ALL ON ALL TABLES IN SCHEMA public FROM {q}")
        conn.exec_driver_sql(f"GRANT USAGE ON SCHEMA public TO {q}")
        conn.exec_driver_sql(f"GRANT SELECT, INSERT, UPDATE ON {', '.join(DML_TABLES)} TO {q}")
        conn.exec_driver_sql(f"GRANT SELECT, INSERT ON {', '.join(IMMUTABLE_TABLES)} TO {q}")
        conn.exec_driver_sql(f"GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO {q}")


def main() -> int:
    owner_url = os.environ.get("MIGRATION_DATABASE_URL") or os.environ["DATABASE_URL"]
    owner = create_engine(owner_url)
    create_schema(owner)
    app_url = os.environ.get("DATABASE_URL")
    if owner.dialect.name == "postgresql" and app_url and app_url != owner_url:
        u = make_url(app_url)
        setup_app_role(owner, u.username, os.environ.get("APP_DB_PASSWORD") or u.password)
        print(f"Schema aktuell, App-Rolle {u.username} eingeschränkt.")
    else:
        print("Schema aktuell (keine separate App-Rolle).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
