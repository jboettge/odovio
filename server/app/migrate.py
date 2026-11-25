"""Schema anlegen und DB-Rollen trennen (einmalig/bei jedem Deploy, als Owner).

PostgreSQL:
  MIGRATION_DATABASE_URL  Owner-Verbindung (z. B. POSTGRES_USER)  → legt Tabellen/Trigger an
  DATABASE_URL            Laufzeit-Verbindung der API (App-Rolle) → bekommt nur DML-Rechte:
                          revisions/anchors: SELECT, INSERT · übrige: SELECT, INSERT, UPDATE · kein DELETE
  APP_DB_PASSWORD         Passwort der App-Rolle (Rolle wird angelegt/aktualisiert)
Die App-Rolle ist weder Owner noch Superuser → kann Trigger nicht deaktivieren,
Revisionen nicht ändern/löschen und keine Datensätze physisch löschen.

Aufruf: python -m app.migrate
"""
import os
import re
import sys

from sqlalchemy import Engine, create_engine, inspect, text
from sqlalchemy.engine import make_url

from . import models  # noqa: F401  (Tabellen registrieren)
from .audit import IMMUTABLE_TABLES, install_triggers
from .db import Base

DML_TABLES = ("tenants", "vehicles", "odometer_readings", "fuel_entries", "maintenance", "maintenance_items",
              "maintenance_materials", "material_articles")
ROLE = re.compile(r"^[a-z_][a-z0-9_]{0,62}$")


# Spalten, die nach dem ersten Deploy ergänzt wurden (create_all ergänzt keine Spalten in
# bestehenden Tabellen): (Tabelle, Spalte, DDL-Typ). Nur nullable, ohne Fremdschlüssel.
ADDED_COLUMNS = (
    ("maintenance_materials", "article_id", "VARCHAR(36)"),
)


def add_missing_columns(engine: Engine) -> None:
    """Idempotente Nachrüstung fehlender Spalten (SQLite und PostgreSQL)."""
    with engine.begin() as conn:
        insp = inspect(conn)
        tables = set(insp.get_table_names())
        for table, column, ddl in ADDED_COLUMNS:
            if table in tables and column not in {c["name"] for c in insp.get_columns(table)}:
                conn.exec_driver_sql(f"ALTER TABLE {table} ADD COLUMN {column} {ddl}")


def create_schema(engine: Engine) -> None:
    add_missing_columns(engine)
    Base.metadata.create_all(engine)
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
