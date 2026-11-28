"""Fahrzeug-Identifizierungsnummer: vehicles.vin (VIN/Fahrgestellnummer, String(17), nullable, ohne Default).

Altbestand bleibt NULL. Idempotent: Bestände ohne alembic_version rüstet app.migrate.add_missing_columns bereits
vor dem Stempeln auf 0001 nach → vorhandene Spalte überspringen.
Teil der Revisions-Snapshots (schemas.VehicleData): Altrevisionen ohne Schlüssel `vin` gelten beim Abgleich
Datensatz ↔ Journal als gleich, solange der Datensatz vin = NULL hat (integrity._same, wie article_id und
km_estimated). Bestehende Revisionen und damit die Hash-Kette bleiben unverändert.

Downgrade wird NICHT unterstützt (Review S12): Er löscht erfasste VINs, und jede unter 0005 geschriebene
Fahrzeug-Revision enthält den Schlüssel `vin` – der Code von 0004 meldete diese Fahrzeuge danach als vom Journal
abweichend. Rollback auf ein älteres Image daher nur per Datenbank-Sicherung. Für Tests/Notfälle erzwingbar mit
ALLOW_UNSUPPORTED_DOWNGRADE=1; die Spalte wird dann per ALTER TABLE … DROP COLUMN entfernt (SQLite ≥ 3.35, ohne
Batch-Neuaufbau der Tabelle – dieser brach unter PRAGMA foreign_keys=ON ab, sobald Fahrten auf Fahrzeuge zeigen).

Revision ID: 0005
Revises: 0004
Create Date: 2026-11-27
"""
import os
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = '0005'
down_revision: str | None = '0004'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None
# Läuft der Code der Vorgängerrevision unverändert auf diesem Stand? (Code von 0004 kennt vin nicht: Bearbeiten setzt keine VIN in die Revision, die Integritätsprüfung meldete Fahrzeuge mit VIN als abweichend)
# → app.migrate: Readiness/Rollback eines älteren Images
compatible_with_previous = False

TABLE, COLUMN = 'vehicles', 'vin'


def _present() -> bool:
    return COLUMN in {c['name'] for c in sa.inspect(op.get_bind()).get_columns(TABLE)}


def upgrade() -> None:
    if not _present():
        op.add_column(TABLE, sa.Column(COLUMN, sa.String(length=17), nullable=True))


def downgrade() -> None:
    if os.environ.get("ALLOW_UNSUPPORTED_DOWNGRADE") != "1":
        raise RuntimeError("Downgrade 0005 → 0004 nicht unterstützt (VINs gingen verloren, Integritätsprüfung "
                           "meldete Fahrzeuge als abweichend) – Rollback per Datenbank-Sicherung; erzwingen nur mit "
                           "ALLOW_UNSUPPORTED_DOWNGRADE=1")
    if _present():
        op.execute(f'ALTER TABLE {TABLE} DROP COLUMN "{COLUMN}"')
