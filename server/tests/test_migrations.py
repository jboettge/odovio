"""E8 Alembic: neue DB → upgrade head; Bestand ohne alembic_version → nachrüsten + auf Baseline stempeln;
Schema entspricht danach exakt den Modellen (inkl. zusammengesetzter Indizes). SQLite und PostgreSQL."""
from alembic.autogenerate import compare_metadata
from alembic.migration import MigrationContext
from alembic.script import ScriptDirectory
from sqlalchemy import inspect, text

from app.db import Base, engine
from app.migrate import BASELINE, alembic_config, create_schema

from .conftest import reset_db

NEW_INDEXES = ("ix_trips_tenant_last_seq", "ix_vehicles_tenant_last_seq", "ix_trip_periods_tenant_last_seq",
               "ix_revisions_tenant_entity", "ix_trips_vehicle_start", "ix_anchors_tenant_seq")


def _head() -> str:
    return ScriptDirectory.from_config(alembic_config()).get_current_head()


def _diff() -> list:
    with engine.connect() as conn:
        return compare_metadata(MigrationContext.configure(conn, opts={"compare_type": True}), Base.metadata)


def _version() -> str:
    with engine.connect() as conn:
        return conn.execute(text("SELECT version_num FROM alembic_version")).scalar()


def test_fresh_database_upgrade_head():
    reset_db()
    try:
        create_schema(engine)
        create_schema(engine)                                   # idempotent
        assert _version() == _head()
        assert _diff() == []
        indexes = {i["name"] for t in ("trips", "vehicles", "trip_periods", "revisions", "anchors")
                   for i in inspect(engine).get_indexes(t)}
        assert set(NEW_INDEXES) <= indexes
    finally:
        reset_db()


def test_legacy_database_is_stamped_and_upgraded():
    """Stand vor Alembic: Tabellen ohne neue Spalten/Indizes/Tabelle blob_checks, ohne alembic_version."""
    reset_db()
    try:
        Base.metadata.create_all(engine)
        with engine.begin() as conn:
            for name in NEW_INDEXES:
                conn.exec_driver_sql(f"DROP INDEX {name}")
            conn.exec_driver_sql("DROP TABLE blob_checks")
            for table, col in (("trips", "customer_name"), ("trips", "km_estimated"),
                               ("trip_periods", "corrections"), ("vehicles", "created_by"),
                               ("vehicles", "updated_by"), ("trips", "updated_by"), ("vehicles", "vin")):
                conn.exec_driver_sql(f"ALTER TABLE {table} DROP COLUMN {col}")
            conn.exec_driver_sql("INSERT INTO tenants (id, slug, name, seq, head_hash) VALUES (1, 't', 't', 0, 'x')")
            conn.exec_driver_sql("INSERT INTO vehicles (id, tenant_id, version, deleted, last_seq, name, fuel_type, "
                                 "initial_km) VALUES ('v1', 1, 1, false, 1, 'Golf', 'benzin', 0)")
            conn.exec_driver_sql("INSERT INTO trips (id, tenant_id, version, deleted, last_seq, vehicle_id, start_at, "
                                 "category, status, source, private_mode) VALUES ('t1', 1, 1, false, 2, 'v1', "
                                 "'2026-01-01T08:00:00+01:00', 'business', 'confirmed', 'manual', false)")
        assert "alembic_version" not in inspect(engine).get_table_names()
        create_schema(engine)
        assert _version() == _head() == "0005" and BASELINE == "0001"
        assert _diff() == []
        with engine.connect() as conn:
            row = conn.execute(text("SELECT km_estimated, customer_name FROM trips WHERE id = 't1'")).one()
            assert conn.execute(text("SELECT vin FROM vehicles WHERE id = 'v1'")).scalar() is None
        assert (bool(row[0]), row[1]) == (False, None)
        create_schema(engine)                                   # danach normaler Upgrade-Pfad
        assert _version() == _head()
    finally:
        reset_db()


def test_upgrade_0001_to_0002_keeps_data(monkeypatch):
    """Bestand mit alembic_version = 0001 (vor created_by/updated_by) → upgrade head ergänzt die Spalten."""
    from alembic import command
    monkeypatch.setenv("ALLOW_UNSUPPORTED_DOWNGRADE", "1")
    reset_db()
    try:
        with engine.begin() as conn:
            command.upgrade(alembic_config(conn), BASELINE)
            assert "created_by" not in {c["name"] for c in inspect(conn).get_columns("vehicles")}
            conn.exec_driver_sql("INSERT INTO tenants (id, slug, name, seq, head_hash) VALUES (1, 't', 't', 0, 'x')")
            conn.exec_driver_sql("INSERT INTO vehicles (id, tenant_id, version, deleted, last_seq, name, fuel_type, "
                                 "initial_km) VALUES ('v1', 1, 1, false, 1, 'Golf', 'benzin', 0)")
        create_schema(engine)
        assert _version() == _head() == "0005"
        assert _diff() == []
        with engine.connect() as conn:
            row = conn.execute(text("SELECT name, created_by, updated_by FROM vehicles WHERE id = 'v1'")).one()
        assert tuple(row) == ("Golf", None, None)
        with engine.connect() as conn:                          # Downgrade/erneutes Upgrade idempotent
            command.downgrade(alembic_config(conn), BASELINE)
            conn.commit()
            assert "updated_by" not in {c["name"] for c in inspect(conn).get_columns("trips")}
        create_schema(engine)
        assert _diff() == []
    finally:
        reset_db()


def test_upgrade_0004_to_0005_adds_vin(monkeypatch):
    """Bestand auf 0004 (vor vehicles.vin) → upgrade head ergänzt die Spalte (NULL); Downgrade entfernt sie,
    erneutes Upgrade idempotent (auch wenn die Spalte schon besteht)."""
    from alembic import command
    monkeypatch.setenv("ALLOW_UNSUPPORTED_DOWNGRADE", "1")
    reset_db()
    try:
        # Upgrade ohne äussere Transaktion (wie create_schema): 0003 braucht unter PostgreSQL einen autocommit-Block
        with engine.connect() as conn:
            command.upgrade(alembic_config(conn), "0004")
            conn.commit()
        with engine.begin() as conn:
            assert "vin" not in {c["name"] for c in inspect(conn).get_columns("vehicles")}
            conn.exec_driver_sql("INSERT INTO tenants (id, slug, name, seq, head_hash) VALUES (1, 't', 't', 0, 'x')")
            conn.exec_driver_sql("INSERT INTO vehicles (id, tenant_id, version, deleted, last_seq, name, fuel_type, "
                                 "initial_km) VALUES ('v1', 1, 1, false, 1, 'Golf', 'benzin', 0)")
        create_schema(engine)
        assert _version() == _head() == "0005" and _diff() == []
        with engine.connect() as conn:
            assert conn.execute(text("SELECT name, vin FROM vehicles WHERE id = 'v1'")).one() == ("Golf", None)
            col = {c["name"]: c for c in inspect(conn).get_columns("vehicles")}["vin"]
            assert col["nullable"]
        with engine.begin() as conn:
            command.downgrade(alembic_config(conn), "0004")
            assert "vin" not in {c["name"] for c in inspect(conn).get_columns("vehicles")}
            command.upgrade(alembic_config(conn), "0005")
            command.downgrade(alembic_config(conn), "0004")
            conn.exec_driver_sql("ALTER TABLE vehicles ADD COLUMN vin VARCHAR(17)")     # Spalte schon vorhanden
            command.upgrade(alembic_config(conn), "0005")
        assert _version() == "0005" and _diff() == []
    finally:
        reset_db()


def test_existing_version_never_runs_legacy_backfill(caplog):
    """S5: Mit alembic_version läuft nur `upgrade head` – fehlende Tabellen legt die zuständige Migration an
    (hier 0004 verify_checkpoints); eine Tabelle, die keine Migration mehr anlegt, bleibt fehlend (Log-Fehler),
    statt per create_all künftigen Migrationen vorzugreifen."""
    from alembic import command
    reset_db()
    try:
        with engine.connect() as conn:
            command.upgrade(alembic_config(conn), "0003")
            conn.commit()
        with engine.begin() as conn:
            conn.exec_driver_sql("DROP TABLE blob_checks")
            assert "verify_checkpoints" not in inspect(conn).get_table_names()
        with caplog.at_level("ERROR", logger="fahrzeugbuch.migrate"):
            create_schema(engine)
        tables = set(inspect(engine).get_table_names())
        assert _version() == _head()
        assert "verify_checkpoints" in tables and "blob_checks" not in tables
        assert any("blob_checks" in r.getMessage() for r in caplog.records)
    finally:
        reset_db()


def test_downgrade_0005_not_supported_without_override(monkeypatch):
    """S12: Downgrade 0005 ist ohne ALLOW_UNSUPPORTED_DOWNGRADE=1 gesperrt; erzwungen bricht er auch unter SQLite
    mit foreign_keys=ON und Fahrten, die auf das Fahrzeug zeigen, nicht ab (kein Batch-Neuaufbau)."""
    import pytest

    from alembic import command
    monkeypatch.delenv("ALLOW_UNSUPPORTED_DOWNGRADE", raising=False)
    reset_db()
    try:
        create_schema(engine)
        with engine.begin() as conn:
            conn.exec_driver_sql("INSERT INTO tenants (id, slug, name, seq, head_hash) VALUES (1, 't', 't', 0, 'x')")
            conn.exec_driver_sql("INSERT INTO vehicles (id, tenant_id, version, deleted, last_seq, name, fuel_type, "
                                 "initial_km, vin) VALUES ('v1', 1, 1, false, 1, 'Golf', 'benzin', 0, "
                                 "'WVWZZZ1KZAW000001')")
            conn.exec_driver_sql("INSERT INTO trips (id, tenant_id, version, deleted, last_seq, vehicle_id, start_at, "
                                 "category, status, source, private_mode) VALUES ('t1', 1, 1, false, 2, 'v1', "
                                 "'2026-01-01T08:00:00+01:00', 'business', 'confirmed', 'manual', false)")
        with engine.connect() as conn, pytest.raises(RuntimeError, match="nicht unterstützt"):
            command.downgrade(alembic_config(conn), "0004")
        assert _version() == "0005"
        monkeypatch.setenv("ALLOW_UNSUPPORTED_DOWNGRADE", "1")
        with engine.connect() as conn:
            command.downgrade(alembic_config(conn), "0001")
            conn.commit()
        assert _version() == "0001"
        with engine.connect() as conn:
            assert conn.execute(text("SELECT count(*) FROM trips WHERE vehicle_id = 'v1'")).scalar() == 1
            assert "vin" not in {c["name"] for c in inspect(conn).get_columns("vehicles")}
    finally:
        reset_db()


def test_migrate_with_non_superuser_owner(monkeypatch):
    """Owner nur mit CREATEROLE (z. B. CloudNativePG): Rolle anlegen, erneuter Lauf (ALTER nur Passwort),
    App-Rolle liest alembic_version (Readiness), darf aber Revisionen nicht löschen."""
    import uuid

    import pytest
    from sqlalchemy import create_engine
    from sqlalchemy.exc import ProgrammingError

    from app import migrate
    if engine.dialect.name != "postgresql":
        pytest.skip("nur PostgreSQL")
    sfx = uuid.uuid4().hex[:8]
    owner, app_role, db = f"fzbo_{sfx}", f"fzba_{sfx}", f"fzbdb_{sfx}"
    admin = engine.execution_options(isolation_level="AUTOCOMMIT")
    url = engine.url
    with admin.connect() as c:
        c.exec_driver_sql(f"CREATE ROLE {owner} LOGIN CREATEROLE PASSWORD 'ownerpw'")
        c.exec_driver_sql(f"CREATE DATABASE {db} OWNER {owner}")
    try:
        base = url.set(database=db)
        monkeypatch.setenv("MIGRATION_DATABASE_URL",
                           base.set(username=owner, password="ownerpw").render_as_string(hide_password=False))
        monkeypatch.setenv("DATABASE_URL", base.set(username=app_role, password="apppw1")
                           .render_as_string(hide_password=False))
        assert migrate.main([]) == 0
        monkeypatch.setenv("DATABASE_URL", base.set(username=app_role, password="apppw2")
                           .render_as_string(hide_password=False))
        assert migrate.main([]) == 0                               # bestehende Rolle: nur Passwort
        assert migrate.main(["--check"]) == 0
        app_engine = create_engine(base.set(username=app_role, password="apppw2"))
        with app_engine.connect() as c:
            assert c.exec_driver_sql("SELECT version_num FROM alembic_version").scalar() == migrate.head_revision()
            roles = c.exec_driver_sql("SELECT rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls "
                                      f"FROM pg_roles WHERE rolname = '{app_role}'").one()
            assert not any(roles)
            with pytest.raises(ProgrammingError):
                c.exec_driver_sql("DELETE FROM revisions")
        app_engine.dispose()
    finally:
        with admin.connect() as c:
            c.exec_driver_sql(f"DROP DATABASE IF EXISTS {db} WITH (FORCE)")
            c.exec_driver_sql(f"DROP ROLE IF EXISTS {app_role}")
            c.exec_driver_sql(f"DROP ROLE IF EXISTS {owner}")
