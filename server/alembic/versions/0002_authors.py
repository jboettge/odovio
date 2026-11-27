"""Urheber je Datensatz: created_by/updated_by (Anzeigename aus dem Token, serverseitig gesetzt).

Nullable, ohne Default (Altbestand bleibt NULL). Idempotent: Bestände ohne alembic_version rüstet
app.migrate.add_missing_columns bereits vor dem Stempeln auf 0001 nach → vorhandene Spalten überspringen.
Nicht Teil der Revisions-Snapshots (Hash-Kette und Abgleich Datensatz ↔ Journal unverändert).

Revision ID: 0002
Revises: 0001
Create Date: 2026-11-25
"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = '0002'
down_revision: str | None = '0001'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None
# Läuft der Code der Vorgängerrevision unverändert auf diesem Stand? (nullable Spalten, nicht in den Snapshots – Code von 0001 läuft unverändert)
# → app.migrate: Readiness/Rollback eines älteren Images
compatible_with_previous = True

SYNCED_TABLES = ('vehicles', 'odometer_readings', 'fuel_entries', 'maintenance', 'maintenance_items',
                 'maintenance_materials', 'material_articles', 'attachments', 'customers', 'places', 'trips',
                 'purpose_rules', 'tax_params', 'trip_periods')
COLUMNS = ('created_by', 'updated_by')


def _present(table: str) -> set[str]:
    return {c['name'] for c in sa.inspect(op.get_bind()).get_columns(table)}


def upgrade() -> None:
    for table in SYNCED_TABLES:
        present = _present(table)
        for col in COLUMNS:
            if col not in present:
                op.add_column(table, sa.Column(col, sa.String(length=100), nullable=True))


def downgrade() -> None:
    for table in SYNCED_TABLES:
        present = _present(table)
        with op.batch_alter_table(table) as batch:
            for col in COLUMNS:
                if col in present:
                    batch.drop_column(col)
