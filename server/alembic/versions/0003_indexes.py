"""Indizes für vertikale Skalierung (gemessen mit loadtest.seed + loadtest.explain, 1 Mio. Revisionen).

ix_anchors_tenant_seq (tenant_id, seq): letzter Anker je Mandant (maybe_anchor bei jedem Sync, unter der
  Mandantensperre) und Anker der Monatsabschlüsse – ohne Index Bitmap-Scan über alle Anker des Mandanten
  (10 000 Anker: 4.2 ms → 0.03 ms).
Alle übrigen Hot-Queries (/changes je Tabelle, Kette je Mandant/Seq, Aktivität before_seq, Fahrten je Fahrzeug +
Zeitraum, Tank/Wartung je Fahrzeug, Belege je Tankvorgang/Wartung, Historie) nutzen bereits passende Indizes.

PostgreSQL: CREATE INDEX CONCURRENTLY (keine Schreibsperre) im autocommit-Block, ohne statement_timeout; ein
ungültiger Rest eines abgebrochenen Laufs wird zuvor entfernt. SQLite: normal. Idempotent (IF NOT EXISTS).
Keine Änderung an Triggern, Journal oder Rechten der App-Rolle.

Revision ID: 0003
Revises: 0002
Create Date: 2026-11-25
"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = '0003'
down_revision: str | None = '0002'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

INDEXES = (('ix_anchors_tenant_seq', 'anchors', ('tenant_id', 'seq')),)


def _pg_upgrade() -> None:
    with op.get_context().autocommit_block():
        bind = op.get_bind()
        bind.exec_driver_sql('SET statement_timeout = 0')
        try:
            for name, table, cols in INDEXES:
                invalid = bind.execute(sa.text(
                    'SELECT 1 FROM pg_class c JOIN pg_index i ON i.indexrelid = c.oid '
                    'WHERE c.relname = :n AND NOT i.indisvalid'), {'n': name}).scalar()
                if invalid:
                    bind.exec_driver_sql(f'DROP INDEX CONCURRENTLY IF EXISTS {name}')
                bind.exec_driver_sql(f'CREATE INDEX CONCURRENTLY IF NOT EXISTS {name} ON {table} ({", ".join(cols)})')
        finally:
            bind.exec_driver_sql('RESET statement_timeout')


def upgrade() -> None:
    if op.get_bind().dialect.name == 'postgresql':
        _pg_upgrade()
        return
    for name, table, cols in INDEXES:
        op.execute(f'CREATE INDEX IF NOT EXISTS {name} ON {table} ({", ".join(cols)})')


def downgrade() -> None:
    for name, _, _ in INDEXES:
        if op.get_bind().dialect.name == 'postgresql':
            with op.get_context().autocommit_block():
                op.get_bind().exec_driver_sql(f'DROP INDEX CONCURRENTLY IF EXISTS {name}')
        else:
            op.execute(f'DROP INDEX IF EXISTS {name}')
