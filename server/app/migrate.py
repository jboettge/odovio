"""Schema anlegen und DB-Rollen trennen (einmalig/bei jedem Deploy, als Owner).

PostgreSQL:
  MIGRATION_DATABASE_URL  Owner-Verbindung (z. B. POSTGRES_USER)  → legt Tabellen/Trigger an
  DATABASE_URL            Laufzeit-Verbindung der API (App-Rolle) → bekommt nur DML-Rechte:
                          revisions/anchors: SELECT, INSERT · übrige: SELECT, INSERT, UPDATE · kein DELETE
  APP_DB_PASSWORD         Passwort der App-Rolle (Rolle wird angelegt/aktualisiert)
Owner ohne SUPERUSER (nur CREATEROLE, z. B. CloudNativePG) genügt: neue Rolle mit allen Einschränkungen, bestehende
nur Abweichungen (Login/Passwort); hat sie unzulässige Rechte, die sich nicht entziehen lassen → Fehler.
Die App-Rolle ist weder Owner noch Superuser → kann Trigger nicht deaktivieren,
Revisionen nicht ändern/löschen und keine Datensätze physisch löschen.

Schema-Versionen: Alembic (server/alembic, Baseline-Revision 0001 = Schema inkl. Indizes;
  0002 = created_by/updated_by aller synchronisierten Tabellen, idempotent; 0003 = Index anchors(tenant_id, seq),
  auf PostgreSQL CONCURRENTLY; 0004 = Tabelle verify_checkpoints (Prüfstand der inkrementellen Integritätsprüfung),
  idempotent; 0005 = vehicles.vin (VIN/Fahrgestellnummer, nullable), idempotent).
  neue DB                      → alembic upgrade head
  Bestand ohne alembic_version → fehlende Spalten/Tabellen/Indizes nachrüsten, auf Baseline stempeln,
                                 dann upgrade head
  Bestand mit alembic_version  → upgrade head

Mehrere Worker/Replikas mit AUTO_MIGRATE=1: PostgreSQL-Advisory-Lock "migrate" → nacheinander, der zweite findet
den Stand head vor. Empfohlen bleibt der eigene Lauf vor dem Start (Compose-Dienst migrate, Kubernetes-Job/
Init-Container) mit AUTO_MIGRATE=0 in der API.

Aufruf: python -m app.migrate            (Exit 0 = Schema aktuell, ≠ 0 = Fehler)
        python -m app.migrate --check    (Exit 0 = Stand ist head, 3 = Migration nötig; ändert nichts)
"""
import logging
import os
import re
import sys
from pathlib import Path

from alembic.config import Config
from alembic.script import ScriptDirectory
from sqlalchemy import Connection, Engine, create_engine, inspect, text
from sqlalchemy.engine import make_url

from alembic import command

from . import jobs, models  # noqa: F401  (Tabellen registrieren)
from .audit import IMMUTABLE_TABLES, install_triggers
from .db import Base

log = logging.getLogger("fahrzeugbuch.migrate")

# Alle Fachtabellen (inkl. Fahrtenbuch): App-Rolle darf SELECT/INSERT/UPDATE, nie DELETE.
DML_TABLES = tuple(t.name for t in Base.metadata.sorted_tables if t.name not in IMMUTABLE_TABLES)
ROLE = re.compile(r"^[a-z_][a-z0-9_]{0,62}$")
RESTRICTED = ("NOSUPERUSER", "NOCREATEDB", "NOCREATEROLE", "NOREPLICATION", "NOBYPASSRLS")


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


def head_revision() -> str:
    return ScriptDirectory.from_config(alembic_config()).get_current_head()


def current_revision(conn: Connection) -> str | None:
    return _version(conn, set(inspect(conn).get_table_names()))


def create_schema(engine: Engine) -> None:
    with jobs.session_lock(engine, "migrate"):
        _create_schema(engine)
        install_triggers(engine)


def _create_schema(engine: Engine) -> None:
    with engine.begin() as conn:
        tables = set(inspect(conn).get_table_names())
        model_tables = set(Base.metadata.tables)
        version = _version(conn, tables)
        if not tables & model_tables:
            if version is not None:                        # Tabellen entfernt, Versionsstand übrig
                conn.execute(text("DELETE FROM alembic_version"))
        elif version is None or model_tables - tables:
            # Bestand ohne Alembic (bzw. unvollständig): nachrüsten, dann auf die Baseline stempeln
            add_missing_columns(conn)
            Base.metadata.create_all(conn)
            add_missing_indexes(conn)
            if version is None:
                command.stamp(alembic_config(conn), BASELINE)
    # Upgrade ohne äussere Transaktion: Alembic führt sie selbst; Revisionen mit autocommit-Block
    # (CREATE INDEX CONCURRENTLY, 0003) brauchen das.
    with engine.connect() as conn:
        command.upgrade(alembic_config(conn), "head")
        conn.commit()


def setup_app_role(owner: Engine, role: str, password: str | None) -> None:
    if not ROLE.match(role):
        raise ValueError(f"Ungültiger Rollenname: {role}")
    from psycopg import sql

    with owner.begin() as conn:
        raw = conn.connection.driver_connection
        attrs = conn.execute(text("SELECT rolcanlogin, rolsuper, rolcreatedb, rolcreaterole, rolreplication, "
                                  "rolbypassrls FROM pg_roles WHERE rolname = :r"), {"r": role}).one_or_none()
        if attrs is None:
            clauses = ["LOGIN", *RESTRICTED]
        else:
            # Nur Abweichungen setzen: ein Owner ohne SUPERUSER (z. B. CloudNativePG, nur CREATEROLE) darf
            # SUPERUSER/REPLICATION/BYPASSRLS nicht einmal auf den gleichen Wert setzen. Hat die Rolle doch eines
            # dieser Rechte und lässt es sich nicht entziehen → Fehler (App-Rolle muss eingeschränkt sein).
            clauses = ([] if attrs[0] else ["LOGIN"]) + [neg for flag, neg in zip(attrs[1:], RESTRICTED,
                                                                                  strict=True) if flag]
        verb = "ALTER" if attrs is not None else "CREATE"
        if clauses or password or attrs is None:
            stmt = sql.SQL(verb + " ROLE {} " + " ".join(clauses)).format(sql.Identifier(role))
            if password:
                stmt = sql.SQL("{} PASSWORD {}").format(stmt, sql.Literal(password))
            conn.exec_driver_sql(stmt.as_string(raw))
        q = f'"{role}"'
        conn.exec_driver_sql(f"REVOKE ALL ON ALL TABLES IN SCHEMA public FROM {q}")
        conn.exec_driver_sql(f"GRANT USAGE ON SCHEMA public TO {q}")
        conn.exec_driver_sql(f"GRANT SELECT, INSERT, UPDATE ON {', '.join(DML_TABLES)} TO {q}")
        conn.exec_driver_sql(f"GRANT SELECT, INSERT ON {', '.join(IMMUTABLE_TABLES)} TO {q}")
        conn.exec_driver_sql(f"GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO {q}")
        # Readiness (/health/ready) vergleicht den Schema-Stand mit Alembic head
        conn.exec_driver_sql(f"GRANT SELECT ON alembic_version TO {q}")


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    owner_url = os.environ.get("MIGRATION_DATABASE_URL") or os.environ["DATABASE_URL"]
    owner = create_engine(owner_url)
    if "--check" in argv:
        with owner.connect() as conn:
            current, head = current_revision(conn), head_revision()
        print(f"Schema-Stand {current or '-'}, head {head}")
        return 0 if current == head else 3
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
