"""Tabelle verify_checkpoints: zuletzt bestätigter Prüfstand je Mandant (inkrementelle Integritätsprüfung).

PDF-Berichte und /audit/verify prüfen nur noch die Revisionen ab diesem Stand (Kette + geänderte Datensätze);
die Vollprüfung (?full=1 bzw. nach VERIFY_FULL_INTERVAL_S) setzt ihn neu. Eine Zeile je Mandant, veränderlich
(kein Journal, keine Trigger); App-Rolle: SELECT, INSERT, UPDATE wie alle Fachtabellen (app.migrate.DML_TABLES).
Idempotent: Bestände ohne alembic_version legen die Tabelle bereits per create_all an → dann überspringen.
Leere Tabelle = erster Bericht je Mandant prüft vollständig (wie bisher).

Revision ID: 0004
Revises: 0003
Create Date: 2026-11-25
"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = '0004'
down_revision: str | None = '0003'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

TABLE = 'verify_checkpoints'


def upgrade() -> None:
    if TABLE in sa.inspect(op.get_bind()).get_table_names():
        return
    op.create_table(TABLE,
    sa.Column('tenant_id', sa.Integer(), nullable=False),
    sa.Column('seq', sa.Integer(), nullable=False),
    sa.Column('head_hash', sa.String(length=64), nullable=False),
    sa.Column('counts', sa.Text(), nullable=False),
    sa.Column('full_seq', sa.Integer(), nullable=False),
    sa.Column('full_at', sa.String(length=32), nullable=True),
    sa.Column('verified_at', sa.String(length=32), nullable=True),
    sa.Column('failed_seq', sa.Integer(), nullable=True),
    sa.Column('key_id', sa.String(length=16), nullable=True),
    sa.Column('signature', sa.String(length=128), nullable=True),
    sa.ForeignKeyConstraint(['tenant_id'], ['tenants.id'], ),
    sa.PrimaryKeyConstraint('tenant_id')
    )


def downgrade() -> None:
    if TABLE in sa.inspect(op.get_bind()).get_table_names():
        op.drop_table(TABLE)
