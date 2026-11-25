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
               "ix_revisions_tenant_entity", "ix_trips_vehicle_start")


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
        indexes = {i["name"] for t in ("trips", "vehicles", "trip_periods", "revisions")
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
                               ("trip_periods", "corrections")):
                conn.exec_driver_sql(f"ALTER TABLE {table} DROP COLUMN {col}")
            conn.exec_driver_sql("INSERT INTO tenants (id, slug, name, seq, head_hash) VALUES (1, 't', 't', 0, 'x')")
            conn.exec_driver_sql("INSERT INTO vehicles (id, tenant_id, version, deleted, last_seq, name, fuel_type, "
                                 "initial_km) VALUES ('v1', 1, 1, false, 1, 'Golf', 'benzin', 0)")
            conn.exec_driver_sql("INSERT INTO trips (id, tenant_id, version, deleted, last_seq, vehicle_id, start_at, "
                                 "category, status, source, private_mode) VALUES ('t1', 1, 1, false, 2, 'v1', "
                                 "'2026-01-01T08:00:00+01:00', 'business', 'confirmed', 'manual', false)")
        assert "alembic_version" not in inspect(engine).get_table_names()
        create_schema(engine)
        assert _version() == _head() == BASELINE
        assert _diff() == []
        with engine.connect() as conn:
            row = conn.execute(text("SELECT km_estimated, customer_name FROM trips WHERE id = 't1'")).one()
        assert (bool(row[0]), row[1]) == (False, None)
        create_schema(engine)                                   # danach normaler Upgrade-Pfad
        assert _version() == _head()
    finally:
        reset_db()
