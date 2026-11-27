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
  Bestand mit alembic_version  → upgrade head (kein Nachrüsten per create_all; fehlen danach Tabellen → Log-Fehler)

Mehrere Worker/Replikas mit AUTO_MIGRATE=1: PostgreSQL-Advisory-Lock "migrate" → nacheinander, der zweite findet
den Stand head vor. Empfohlen bleibt der eigene Lauf vor dem Start (Compose-Dienst migrate, Kubernetes-Job/
Init-Container) mit AUTO_MIGRATE=0 in der API.

Schema-Kompatibilität (Readiness, Rollback): Ein Image ist bereit, wenn der DB-Stand = sein head ist ODER ein ihm
unbekannter, neuerer Stand, der als kompatibel gilt – d. h. der Code dieses Images läuft darauf unverändert
(rein additive Migration, die er nicht braucht). Kompatibel ist ein neuerer Stand, wenn
  - die neuere Migration dies selbst erklärt: Modulattribut `compatible_with_previous = True`; der Migrationslauf
    (Owner) schreibt die Liste der so kompatiblen älteren Stände als Kommentar an alembic_version (PostgreSQL,
    COMMENT ON TABLE; das ältere Image liest ihn) – damit bleiben alte Pods beim Rolling Update und nach einem
    Rollback bereit, ohne dass sie die neue Revision kennen müssen;
  - oder er in COMPATIBLE_NEWER (unten) bzw. SCHEMA_COMPATIBLE_NEWER (Env, kommagetrennt, "*" = jeder unbekannte
    neuere Stand) steht – Notbehelf des Betriebs für ältere Images/SQLite.
Unbekannter, nicht kompatibler Stand → Readiness 503 (schema_newer); der Migrationslauf eines älteren Images
ändert einen neueren Stand nie (kompatibel → Exit 0 ohne Änderung, sonst Fehler).

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
from sqlalchemy.exc import SQLAlchemyError

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
# Neuere, diesem Image unbekannte Revisionen, auf denen es nachweislich läuft (z. B. in einem Hotfix-Release
# nachgetragen); zusätzlich Env SCHEMA_COMPATIBLE_NEWER und der Kommentar an alembic_version (s. oben)
COMPATIBLE_NEWER: frozenset[str] = frozenset()
COMPAT_COMMENT = "fahrzeugbuch-schema compatible:"


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


def known_revisions() -> frozenset[str]:
    return frozenset(s.revision for s in ScriptDirectory.from_config(alembic_config()).walk_revisions())


def compatible_previous(script: ScriptDirectory | None = None) -> list[str]:
    """Ältere Stände, deren Code auf dem aktuellen head läuft: von head abwärts, solange jede Migration
    `compatible_with_previous = True` erklärt (z. B. head 0007 und 0006 kompatibel → ["0006", "0005"])."""
    script = script or ScriptDirectory.from_config(alembic_config())
    out = []
    for rev in script.walk_revisions():          # head → Baseline
        if not getattr(rev.module, "compatible_with_previous", False) or rev.down_revision is None:
            break
        out.append(str(rev.down_revision))
    return out


def _compat_comment(conn: Connection) -> list[str]:
    if conn.dialect.name != "postgresql":
        return []
    try:
        comment = conn.execute(text("SELECT obj_description('alembic_version'::regclass, 'pg_class')")).scalar()
    except SQLAlchemyError:
        return []
    if not isinstance(comment, str) or not comment.startswith(COMPAT_COMMENT):
        return []
    return comment[len(COMPAT_COMMENT):].split()


def write_compat_comment(conn: Connection, compatible: list[str] | None = None) -> None:
    """Owner: kompatible ältere Stände an alembic_version vermerken (nur PostgreSQL)."""
    if conn.dialect.name != "postgresql":
        return
    revs = compatible_previous() if compatible is None else compatible
    if any(not re.fullmatch(r"[A-Za-z0-9_]+", r) for r in revs):
        raise ValueError("Revisionsbezeichner ungültig")
    conn.exec_driver_sql(f"COMMENT ON TABLE alembic_version IS '{COMPAT_COMMENT} {' '.join(revs)}'")


def compatible_env() -> set[str]:
    return {x.strip() for x in (os.environ.get("SCHEMA_COMPATIBLE_NEWER") or "").split(",") if x.strip()}


def schema_state(conn: Connection, current: str | None, head: str | None = None,
                 known: frozenset[str] | None = None) -> str:
    """ok | compatible_newer | migration_pending (älter bzw. leer) | schema_newer (unbekannt, nicht kompatibel)."""
    head = head or head_revision()
    if current == head:
        return "ok"
    known = known if known is not None else known_revisions()
    if current is None or current in known:
        return "migration_pending"
    allowed = compatible_env()
    if "*" in allowed or current in allowed or current in COMPATIBLE_NEWER or head in _compat_comment(conn):
        return "compatible_newer"
    return "schema_newer"


def current_revision(conn: Connection) -> str | None:
    return _version(conn, set(inspect(conn).get_table_names()))


class SchemaNewer(RuntimeError):
    """DB-Stand ist neuer als dieses Image und nicht als kompatibel markiert."""


def create_schema(engine: Engine) -> bool:
    """Migration auf head. False = DB ist auf einem neueren, kompatiblen Stand (nichts geändert)."""
    with jobs.session_lock(engine, "migrate"):
        if not _create_schema(engine):
            return False
        install_triggers(engine)
    return True


def _create_schema(engine: Engine) -> bool:
    with engine.begin() as conn:
        tables = set(inspect(conn).get_table_names())
        model_tables = set(Base.metadata.tables)
        version = _version(conn, tables)
        if version is not None and version not in known_revisions():
            if schema_state(conn, version) != "compatible_newer":
                raise SchemaNewer(f"Schema-Stand {version} ist neuer als dieses Image (head {head_revision()}) und "
                                  "nicht als kompatibel markiert – neueres Image verwenden oder "
                                  "SCHEMA_COMPATIBLE_NEWER setzen")
            log.warning("Schema-Stand %s neuer als head %s, aber kompatibel – keine Migration", version,
                        head_revision())
            return False
        if not tables & model_tables:
            if version is not None:                        # Tabellen entfernt, Versionsstand übrig
                conn.execute(text("DELETE FROM alembic_version"))
        elif version is None:
            # Bestand ohne Alembic: nachrüsten, dann auf die Baseline stempeln. Mit alembic_version nie –
            # fehlende Tabellen legt dann die zuständige Migration an (create_all würde den Stand künftiger
            # Migrationen vorwegnehmen, Review S5).
            add_missing_columns(conn)
            Base.metadata.create_all(conn)
            add_missing_indexes(conn)
            command.stamp(alembic_config(conn), BASELINE)
    # Upgrade ohne äussere Transaktion: Alembic führt sie selbst; Revisionen mit autocommit-Block
    # (CREATE INDEX CONCURRENTLY, 0003) brauchen das.
    with engine.connect() as conn:
        command.upgrade(alembic_config(conn), "head")
        conn.commit()
    with engine.begin() as conn:
        write_compat_comment(conn)
        missing = model_tables - set(inspect(conn).get_table_names())
    if missing:
        log.error("Schema-Stand %s, aber Tabellen fehlen: %s – manuell prüfen (keine automatische Nachrüstung "
                  "bei vorhandener alembic_version)", head_revision(), ", ".join(sorted(missing)))
    return True


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
    owner = create_engine(owner_url, hide_parameters=True)
    if "--check" in argv:
        with owner.connect() as conn:
            current, head = current_revision(conn), head_revision()
            state = schema_state(conn, current, head)
        print(f"Schema-Stand {current or '-'}, head {head} ({state})")
        return 0 if state in ("ok", "compatible_newer") else 3
    if not create_schema(owner):
        print("Schema neuer als dieses Image, aber kompatibel – nichts geändert.")
        return 0
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
