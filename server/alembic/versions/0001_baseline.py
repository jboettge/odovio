"""Baseline: Schema inkl. Fahrtenbuch, Belege, Prüfsummen-Cache und zusammengesetzten Indizes.

Bestehende Datenbanken ohne alembic_version werden von app.migrate nachgerüstet und auf diese Revision
gestempelt; neue Datenbanken entstehen durch upgrade head.

Revision ID: 0001
Revises: –
Create Date: 2026-11-25
"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = '0001'
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table('tenants',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('slug', sa.String(length=64), nullable=False),
    sa.Column('name', sa.String(length=100), nullable=False),
    sa.Column('seq', sa.Integer(), nullable=False),
    sa.Column('head_hash', sa.String(length=64), nullable=False),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('slug')
    )
    op.create_table('anchors',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('tenant_id', sa.Integer(), nullable=False),
    sa.Column('seq', sa.Integer(), nullable=False),
    sa.Column('head_hash', sa.String(length=64), nullable=False),
    sa.Column('created_at', sa.String(length=32), nullable=False),
    sa.Column('key_id', sa.String(length=16), nullable=False),
    sa.Column('signature', sa.String(length=128), nullable=False),
    sa.ForeignKeyConstraint(['tenant_id'], ['tenants.id'], ),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index('ix_anchors_tenant_id', 'anchors', ['tenant_id'], unique=False)

    op.create_table('blob_checks',
    sa.Column('attachment_id', sa.String(length=36), nullable=False),
    sa.Column('tenant_id', sa.Integer(), nullable=False),
    sa.Column('fingerprint', sa.String(length=200), nullable=False),
    sa.Column('sha256', sa.String(length=64), nullable=False),
    sa.Column('checked_at', sa.String(length=32), nullable=False),
    sa.ForeignKeyConstraint(['tenant_id'], ['tenants.id'], ),
    sa.PrimaryKeyConstraint('attachment_id')
    )
    op.create_index('ix_blob_checks_tenant_id', 'blob_checks', ['tenant_id'], unique=False)

    op.create_table('customers',
    sa.Column('name', sa.String(length=150), nullable=False),
    sa.Column('ref', sa.String(length=50), nullable=True),
    sa.Column('note', sa.String(length=500), nullable=True),
    sa.Column('id', sa.String(length=36), nullable=False),
    sa.Column('tenant_id', sa.Integer(), nullable=False),
    sa.Column('version', sa.Integer(), nullable=False),
    sa.Column('deleted', sa.Boolean(), nullable=False),
    sa.Column('last_seq', sa.Integer(), nullable=False),
    sa.ForeignKeyConstraint(['tenant_id'], ['tenants.id'], ),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index('ix_customers_last_seq', 'customers', ['last_seq'], unique=False)
    op.create_index('ix_customers_tenant_id', 'customers', ['tenant_id'], unique=False)
    op.create_index('ix_customers_tenant_last_seq', 'customers', ['tenant_id', 'last_seq'], unique=False)

    op.create_table('revisions',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('tenant_id', sa.Integer(), nullable=False),
    sa.Column('seq', sa.Integer(), nullable=False),
    sa.Column('entity', sa.String(length=32), nullable=False),
    sa.Column('entity_id', sa.String(length=36), nullable=False),
    sa.Column('version', sa.Integer(), nullable=False),
    sa.Column('action', sa.String(length=10), nullable=False),
    sa.Column('data', sa.Text(), nullable=False),
    sa.Column('actor_sub', sa.String(length=255), nullable=False),
    sa.Column('actor_name', sa.String(length=255), nullable=True),
    sa.Column('recorded_at', sa.String(length=32), nullable=False),
    sa.Column('client_ts', sa.String(length=40), nullable=True),
    sa.Column('op_id', sa.String(length=64), nullable=True),
    sa.Column('conflict', sa.Boolean(), nullable=False),
    sa.Column('prev_hash', sa.String(length=64), nullable=False),
    sa.Column('hash', sa.String(length=64), nullable=False),
    sa.ForeignKeyConstraint(['tenant_id'], ['tenants.id'], ),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('tenant_id', 'op_id', name='uq_revision_op'),
    sa.UniqueConstraint('tenant_id', 'seq', name='uq_revision_seq')
    )
    op.create_index('ix_revisions_entity_id', 'revisions', ['entity_id'], unique=False)
    op.create_index('ix_revisions_tenant_entity', 'revisions', ['tenant_id', 'entity', 'entity_id'], unique=False)
    op.create_index('ix_revisions_tenant_id', 'revisions', ['tenant_id'], unique=False)

    op.create_table('tax_params',
    sa.Column('year', sa.Integer(), nullable=False),
    sa.Column('scope', sa.String(length=30), nullable=False),
    sa.Column('key', sa.String(length=30), nullable=False),
    sa.Column('value', sa.Float(), nullable=False),
    sa.Column('source_url', sa.String(length=300), nullable=True),
    sa.Column('note', sa.String(length=300), nullable=True),
    sa.Column('id', sa.String(length=36), nullable=False),
    sa.Column('tenant_id', sa.Integer(), nullable=False),
    sa.Column('version', sa.Integer(), nullable=False),
    sa.Column('deleted', sa.Boolean(), nullable=False),
    sa.Column('last_seq', sa.Integer(), nullable=False),
    sa.ForeignKeyConstraint(['tenant_id'], ['tenants.id'], ),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index('ix_tax_params_last_seq', 'tax_params', ['last_seq'], unique=False)
    op.create_index('ix_tax_params_tenant_id', 'tax_params', ['tenant_id'], unique=False)
    op.create_index('ix_tax_params_tenant_last_seq', 'tax_params', ['tenant_id', 'last_seq'], unique=False)

    op.create_table('vehicles',
    sa.Column('name', sa.String(length=100), nullable=False),
    sa.Column('make', sa.String(length=100), nullable=True),
    sa.Column('model', sa.String(length=100), nullable=True),
    sa.Column('plate', sa.String(length=30), nullable=True),
    sa.Column('fuel_type', sa.String(length=20), nullable=False),
    sa.Column('initial_km', sa.Integer(), nullable=False),
    sa.Column('purchase_price', sa.Float(), nullable=True),
    sa.Column('ownership', sa.String(length=20), nullable=True),
    sa.Column('private_use_method', sa.String(length=20), nullable=True),
    sa.Column('annual_fixed_costs', sa.Float(), nullable=True),
    sa.Column('id', sa.String(length=36), nullable=False),
    sa.Column('tenant_id', sa.Integer(), nullable=False),
    sa.Column('version', sa.Integer(), nullable=False),
    sa.Column('deleted', sa.Boolean(), nullable=False),
    sa.Column('last_seq', sa.Integer(), nullable=False),
    sa.ForeignKeyConstraint(['tenant_id'], ['tenants.id'], ),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index('ix_vehicles_last_seq', 'vehicles', ['last_seq'], unique=False)
    op.create_index('ix_vehicles_tenant_id', 'vehicles', ['tenant_id'], unique=False)
    op.create_index('ix_vehicles_tenant_last_seq', 'vehicles', ['tenant_id', 'last_seq'], unique=False)

    op.create_table('fuel_entries',
    sa.Column('vehicle_id', sa.String(length=36), nullable=False),
    sa.Column('date', sa.Date(), nullable=False),
    sa.Column('km', sa.Integer(), nullable=False),
    sa.Column('liters', sa.Float(), nullable=False),
    sa.Column('price_total', sa.Float(), nullable=False),
    sa.Column('full_tank', sa.Boolean(), nullable=False),
    sa.Column('station', sa.String(length=100), nullable=True),
    sa.Column('note', sa.Text(), nullable=True),
    sa.Column('id', sa.String(length=36), nullable=False),
    sa.Column('tenant_id', sa.Integer(), nullable=False),
    sa.Column('version', sa.Integer(), nullable=False),
    sa.Column('deleted', sa.Boolean(), nullable=False),
    sa.Column('last_seq', sa.Integer(), nullable=False),
    sa.ForeignKeyConstraint(['tenant_id'], ['tenants.id'], ),
    sa.ForeignKeyConstraint(['vehicle_id'], ['vehicles.id'], ),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index('ix_fuel_entries_last_seq', 'fuel_entries', ['last_seq'], unique=False)
    op.create_index('ix_fuel_entries_tenant_id', 'fuel_entries', ['tenant_id'], unique=False)
    op.create_index('ix_fuel_entries_tenant_last_seq', 'fuel_entries', ['tenant_id', 'last_seq'], unique=False)
    op.create_index('ix_fuel_entries_vehicle_id', 'fuel_entries', ['vehicle_id'], unique=False)

    op.create_table('maintenance',
    sa.Column('vehicle_id', sa.String(length=36), nullable=False),
    sa.Column('date', sa.Date(), nullable=False),
    sa.Column('km', sa.Integer(), nullable=True),
    sa.Column('title', sa.String(length=150), nullable=False),
    sa.Column('cost', sa.Float(), nullable=True),
    sa.Column('note', sa.Text(), nullable=True),
    sa.Column('next_due_km', sa.Integer(), nullable=True),
    sa.Column('next_due_date', sa.Date(), nullable=True),
    sa.Column('id', sa.String(length=36), nullable=False),
    sa.Column('tenant_id', sa.Integer(), nullable=False),
    sa.Column('version', sa.Integer(), nullable=False),
    sa.Column('deleted', sa.Boolean(), nullable=False),
    sa.Column('last_seq', sa.Integer(), nullable=False),
    sa.ForeignKeyConstraint(['tenant_id'], ['tenants.id'], ),
    sa.ForeignKeyConstraint(['vehicle_id'], ['vehicles.id'], ),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index('ix_maintenance_last_seq', 'maintenance', ['last_seq'], unique=False)
    op.create_index('ix_maintenance_tenant_id', 'maintenance', ['tenant_id'], unique=False)
    op.create_index('ix_maintenance_tenant_last_seq', 'maintenance', ['tenant_id', 'last_seq'], unique=False)
    op.create_index('ix_maintenance_vehicle_id', 'maintenance', ['vehicle_id'], unique=False)

    op.create_table('material_articles',
    sa.Column('name', sa.String(length=150), nullable=False),
    sa.Column('part_number', sa.String(length=60), nullable=True),
    sa.Column('unit', sa.String(length=20), nullable=False),
    sa.Column('unit_price', sa.Float(), nullable=True),
    sa.Column('category', sa.String(length=50), nullable=True),
    sa.Column('vehicle_id', sa.String(length=36), nullable=True),
    sa.Column('note', sa.Text(), nullable=True),
    sa.Column('id', sa.String(length=36), nullable=False),
    sa.Column('tenant_id', sa.Integer(), nullable=False),
    sa.Column('version', sa.Integer(), nullable=False),
    sa.Column('deleted', sa.Boolean(), nullable=False),
    sa.Column('last_seq', sa.Integer(), nullable=False),
    sa.ForeignKeyConstraint(['tenant_id'], ['tenants.id'], ),
    sa.ForeignKeyConstraint(['vehicle_id'], ['vehicles.id'], ),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index('ix_material_articles_last_seq', 'material_articles', ['last_seq'], unique=False)
    op.create_index('ix_material_articles_tenant_id', 'material_articles', ['tenant_id'], unique=False)
    op.create_index('ix_material_articles_tenant_last_seq', 'material_articles', ['tenant_id', 'last_seq'], unique=False)
    op.create_index('ix_material_articles_vehicle_id', 'material_articles', ['vehicle_id'], unique=False)

    op.create_table('odometer_readings',
    sa.Column('vehicle_id', sa.String(length=36), nullable=False),
    sa.Column('date', sa.Date(), nullable=False),
    sa.Column('km', sa.Integer(), nullable=False),
    sa.Column('note', sa.Text(), nullable=True),
    sa.Column('id', sa.String(length=36), nullable=False),
    sa.Column('tenant_id', sa.Integer(), nullable=False),
    sa.Column('version', sa.Integer(), nullable=False),
    sa.Column('deleted', sa.Boolean(), nullable=False),
    sa.Column('last_seq', sa.Integer(), nullable=False),
    sa.ForeignKeyConstraint(['tenant_id'], ['tenants.id'], ),
    sa.ForeignKeyConstraint(['vehicle_id'], ['vehicles.id'], ),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index('ix_odometer_readings_last_seq', 'odometer_readings', ['last_seq'], unique=False)
    op.create_index('ix_odometer_readings_tenant_id', 'odometer_readings', ['tenant_id'], unique=False)
    op.create_index('ix_odometer_readings_tenant_last_seq', 'odometer_readings', ['tenant_id', 'last_seq'], unique=False)
    op.create_index('ix_odometer_readings_vehicle_id', 'odometer_readings', ['vehicle_id'], unique=False)

    op.create_table('places',
    sa.Column('name', sa.String(length=100), nullable=False),
    sa.Column('kind', sa.String(length=20), nullable=False),
    sa.Column('lat', sa.Float(), nullable=True),
    sa.Column('lon', sa.Float(), nullable=True),
    sa.Column('radius_m', sa.Integer(), nullable=False),
    sa.Column('customer_id', sa.String(length=36), nullable=True),
    sa.Column('default_category', sa.String(length=20), nullable=True),
    sa.Column('private', sa.Boolean(), nullable=False),
    sa.Column('id', sa.String(length=36), nullable=False),
    sa.Column('tenant_id', sa.Integer(), nullable=False),
    sa.Column('version', sa.Integer(), nullable=False),
    sa.Column('deleted', sa.Boolean(), nullable=False),
    sa.Column('last_seq', sa.Integer(), nullable=False),
    sa.ForeignKeyConstraint(['customer_id'], ['customers.id'], ),
    sa.ForeignKeyConstraint(['tenant_id'], ['tenants.id'], ),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index('ix_places_customer_id', 'places', ['customer_id'], unique=False)
    op.create_index('ix_places_last_seq', 'places', ['last_seq'], unique=False)
    op.create_index('ix_places_tenant_id', 'places', ['tenant_id'], unique=False)
    op.create_index('ix_places_tenant_last_seq', 'places', ['tenant_id', 'last_seq'], unique=False)

    op.create_table('trip_periods',
    sa.Column('vehicle_id', sa.String(length=36), nullable=False),
    sa.Column('month', sa.String(length=7), nullable=False),
    sa.Column('status', sa.String(length=10), nullable=False),
    sa.Column('closed_by', sa.String(length=255), nullable=True),
    sa.Column('closed_at', sa.String(length=32), nullable=True),
    sa.Column('anchor_seq', sa.Integer(), nullable=True),
    sa.Column('km_start', sa.Integer(), nullable=True),
    sa.Column('km_end', sa.Integer(), nullable=True),
    sa.Column('trips_count', sa.Integer(), nullable=False),
    sa.Column('business_km', sa.Float(), nullable=False),
    sa.Column('private_km', sa.Float(), nullable=False),
    sa.Column('commute_km', sa.Float(), nullable=False),
    sa.Column('field_km', sa.Float(), nullable=False),
    sa.Column('note', sa.String(length=500), nullable=True),
    sa.Column('corrections', sa.Integer(), server_default='0', nullable=False),
    sa.Column('id', sa.String(length=36), nullable=False),
    sa.Column('tenant_id', sa.Integer(), nullable=False),
    sa.Column('version', sa.Integer(), nullable=False),
    sa.Column('deleted', sa.Boolean(), nullable=False),
    sa.Column('last_seq', sa.Integer(), nullable=False),
    sa.ForeignKeyConstraint(['tenant_id'], ['tenants.id'], ),
    sa.ForeignKeyConstraint(['vehicle_id'], ['vehicles.id'], ),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('vehicle_id', 'month', name='uq_trip_period_month')
    )
    op.create_index('ix_trip_periods_last_seq', 'trip_periods', ['last_seq'], unique=False)
    op.create_index('ix_trip_periods_tenant_id', 'trip_periods', ['tenant_id'], unique=False)
    op.create_index('ix_trip_periods_tenant_last_seq', 'trip_periods', ['tenant_id', 'last_seq'], unique=False)
    op.create_index('ix_trip_periods_vehicle_id', 'trip_periods', ['vehicle_id'], unique=False)

    op.create_table('attachments',
    sa.Column('fuel_id', sa.String(length=36), nullable=True),
    sa.Column('maintenance_id', sa.String(length=36), nullable=True),
    sa.Column('vehicle_id', sa.String(length=36), nullable=True),
    sa.Column('kind', sa.String(length=20), nullable=False),
    sa.Column('sha256', sa.String(length=64), nullable=False),
    sa.Column('mime', sa.String(length=40), nullable=False),
    sa.Column('size', sa.Integer(), nullable=False),
    sa.Column('taken_at', sa.String(length=40), nullable=True),
    sa.Column('note', sa.String(length=300), nullable=True),
    sa.Column('id', sa.String(length=36), nullable=False),
    sa.Column('tenant_id', sa.Integer(), nullable=False),
    sa.Column('version', sa.Integer(), nullable=False),
    sa.Column('deleted', sa.Boolean(), nullable=False),
    sa.Column('last_seq', sa.Integer(), nullable=False),
    sa.ForeignKeyConstraint(['fuel_id'], ['fuel_entries.id'], ),
    sa.ForeignKeyConstraint(['maintenance_id'], ['maintenance.id'], ),
    sa.ForeignKeyConstraint(['tenant_id'], ['tenants.id'], ),
    sa.ForeignKeyConstraint(['vehicle_id'], ['vehicles.id'], ),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index('ix_attachments_fuel_id', 'attachments', ['fuel_id'], unique=False)
    op.create_index('ix_attachments_last_seq', 'attachments', ['last_seq'], unique=False)
    op.create_index('ix_attachments_maintenance_id', 'attachments', ['maintenance_id'], unique=False)
    op.create_index('ix_attachments_tenant_id', 'attachments', ['tenant_id'], unique=False)
    op.create_index('ix_attachments_tenant_last_seq', 'attachments', ['tenant_id', 'last_seq'], unique=False)
    op.create_index('ix_attachments_vehicle_id', 'attachments', ['vehicle_id'], unique=False)

    op.create_table('maintenance_items',
    sa.Column('maintenance_id', sa.String(length=36), nullable=False),
    sa.Column('label', sa.String(length=200), nullable=False),
    sa.Column('done', sa.Boolean(), nullable=False),
    sa.Column('position', sa.Integer(), nullable=False),
    sa.Column('id', sa.String(length=36), nullable=False),
    sa.Column('tenant_id', sa.Integer(), nullable=False),
    sa.Column('version', sa.Integer(), nullable=False),
    sa.Column('deleted', sa.Boolean(), nullable=False),
    sa.Column('last_seq', sa.Integer(), nullable=False),
    sa.ForeignKeyConstraint(['maintenance_id'], ['maintenance.id'], ),
    sa.ForeignKeyConstraint(['tenant_id'], ['tenants.id'], ),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index('ix_maintenance_items_last_seq', 'maintenance_items', ['last_seq'], unique=False)
    op.create_index('ix_maintenance_items_maintenance_id', 'maintenance_items', ['maintenance_id'], unique=False)
    op.create_index('ix_maintenance_items_tenant_id', 'maintenance_items', ['tenant_id'], unique=False)
    op.create_index('ix_maintenance_items_tenant_last_seq', 'maintenance_items', ['tenant_id', 'last_seq'], unique=False)

    op.create_table('maintenance_materials',
    sa.Column('maintenance_id', sa.String(length=36), nullable=False),
    sa.Column('article_id', sa.String(length=36), nullable=True),
    sa.Column('name', sa.String(length=150), nullable=False),
    sa.Column('part_number', sa.String(length=60), nullable=True),
    sa.Column('quantity', sa.Float(), nullable=False),
    sa.Column('unit', sa.String(length=20), nullable=False),
    sa.Column('unit_price', sa.Float(), nullable=True),
    sa.Column('position', sa.Integer(), nullable=False),
    sa.Column('id', sa.String(length=36), nullable=False),
    sa.Column('tenant_id', sa.Integer(), nullable=False),
    sa.Column('version', sa.Integer(), nullable=False),
    sa.Column('deleted', sa.Boolean(), nullable=False),
    sa.Column('last_seq', sa.Integer(), nullable=False),
    sa.ForeignKeyConstraint(['maintenance_id'], ['maintenance.id'], ),
    sa.ForeignKeyConstraint(['tenant_id'], ['tenants.id'], ),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index('ix_maintenance_materials_last_seq', 'maintenance_materials', ['last_seq'], unique=False)
    op.create_index('ix_maintenance_materials_maintenance_id', 'maintenance_materials', ['maintenance_id'], unique=False)
    op.create_index('ix_maintenance_materials_tenant_id', 'maintenance_materials', ['tenant_id'], unique=False)
    op.create_index('ix_maintenance_materials_tenant_last_seq', 'maintenance_materials', ['tenant_id', 'last_seq'], unique=False)

    op.create_table('purpose_rules',
    sa.Column('priority', sa.Integer(), nullable=False),
    sa.Column('from_place_id', sa.String(length=36), nullable=True),
    sa.Column('to_place_id', sa.String(length=36), nullable=True),
    sa.Column('weekdays', sa.String(length=20), nullable=True),
    sa.Column('time_from', sa.String(length=5), nullable=True),
    sa.Column('time_to', sa.String(length=5), nullable=True),
    sa.Column('vehicle_id', sa.String(length=36), nullable=True),
    sa.Column('result_category', sa.String(length=20), nullable=False),
    sa.Column('result_purpose', sa.String(length=300), nullable=True),
    sa.Column('result_customer_id', sa.String(length=36), nullable=True),
    sa.Column('auto_confirm', sa.Boolean(), nullable=False),
    sa.Column('origin', sa.String(length=20), nullable=False),
    sa.Column('active', sa.Boolean(), nullable=False),
    sa.Column('id', sa.String(length=36), nullable=False),
    sa.Column('tenant_id', sa.Integer(), nullable=False),
    sa.Column('version', sa.Integer(), nullable=False),
    sa.Column('deleted', sa.Boolean(), nullable=False),
    sa.Column('last_seq', sa.Integer(), nullable=False),
    sa.ForeignKeyConstraint(['from_place_id'], ['places.id'], ),
    sa.ForeignKeyConstraint(['result_customer_id'], ['customers.id'], ),
    sa.ForeignKeyConstraint(['tenant_id'], ['tenants.id'], ),
    sa.ForeignKeyConstraint(['to_place_id'], ['places.id'], ),
    sa.ForeignKeyConstraint(['vehicle_id'], ['vehicles.id'], ),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index('ix_purpose_rules_last_seq', 'purpose_rules', ['last_seq'], unique=False)
    op.create_index('ix_purpose_rules_tenant_id', 'purpose_rules', ['tenant_id'], unique=False)
    op.create_index('ix_purpose_rules_tenant_last_seq', 'purpose_rules', ['tenant_id', 'last_seq'], unique=False)

    op.create_table('trips',
    sa.Column('vehicle_id', sa.String(length=36), nullable=False),
    sa.Column('driver_sub', sa.String(length=255), nullable=True),
    sa.Column('driver_name', sa.String(length=100), nullable=True),
    sa.Column('start_at', sa.String(length=40), nullable=False),
    sa.Column('end_at', sa.String(length=40), nullable=True),
    sa.Column('km_start', sa.Integer(), nullable=True),
    sa.Column('km_end', sa.Integer(), nullable=True),
    sa.Column('distance_gps', sa.Float(), nullable=True),
    sa.Column('distance_route', sa.Float(), nullable=True),
    sa.Column('start_place_id', sa.String(length=36), nullable=True),
    sa.Column('end_place_id', sa.String(length=36), nullable=True),
    sa.Column('start_label', sa.String(length=200), nullable=True),
    sa.Column('end_label', sa.String(length=200), nullable=True),
    sa.Column('category', sa.String(length=20), nullable=False),
    sa.Column('purpose', sa.String(length=300), nullable=True),
    sa.Column('customer_id', sa.String(length=36), nullable=True),
    sa.Column('customer_name', sa.String(length=150), nullable=True),
    sa.Column('status', sa.String(length=20), nullable=False),
    sa.Column('source', sa.String(length=20), nullable=False),
    sa.Column('suggestion_category', sa.String(length=20), nullable=True),
    sa.Column('suggestion_purpose', sa.String(length=300), nullable=True),
    sa.Column('suggestion_customer_id', sa.String(length=36), nullable=True),
    sa.Column('suggestion_confidence', sa.Float(), nullable=True),
    sa.Column('suggestion_reason', sa.String(length=300), nullable=True),
    sa.Column('suggestion_source', sa.String(length=20), nullable=True),
    sa.Column('track_hash', sa.String(length=64), nullable=True),
    sa.Column('split_of', sa.String(length=36), nullable=True),
    sa.Column('private_mode', sa.Boolean(), nullable=False),
    sa.Column('note', sa.Text(), nullable=True),
    sa.Column('km_estimated', sa.Boolean(), server_default=sa.false(), nullable=False),
    sa.Column('id', sa.String(length=36), nullable=False),
    sa.Column('tenant_id', sa.Integer(), nullable=False),
    sa.Column('version', sa.Integer(), nullable=False),
    sa.Column('deleted', sa.Boolean(), nullable=False),
    sa.Column('last_seq', sa.Integer(), nullable=False),
    sa.ForeignKeyConstraint(['customer_id'], ['customers.id'], ),
    sa.ForeignKeyConstraint(['end_place_id'], ['places.id'], ),
    sa.ForeignKeyConstraint(['split_of'], ['trips.id'], ),
    sa.ForeignKeyConstraint(['start_place_id'], ['places.id'], ),
    sa.ForeignKeyConstraint(['tenant_id'], ['tenants.id'], ),
    sa.ForeignKeyConstraint(['vehicle_id'], ['vehicles.id'], ),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index('ix_trips_last_seq', 'trips', ['last_seq'], unique=False)
    op.create_index('ix_trips_start_at', 'trips', ['start_at'], unique=False)
    op.create_index('ix_trips_tenant_id', 'trips', ['tenant_id'], unique=False)
    op.create_index('ix_trips_tenant_last_seq', 'trips', ['tenant_id', 'last_seq'], unique=False)
    op.create_index('ix_trips_vehicle_id', 'trips', ['vehicle_id'], unique=False)
    op.create_index('ix_trips_vehicle_start', 'trips', ['vehicle_id', 'start_at'], unique=False)



def downgrade() -> None:
    op.drop_index('ix_trips_vehicle_start', table_name='trips')
    op.drop_index('ix_trips_vehicle_id', table_name='trips')
    op.drop_index('ix_trips_tenant_last_seq', table_name='trips')
    op.drop_index('ix_trips_tenant_id', table_name='trips')
    op.drop_index('ix_trips_start_at', table_name='trips')
    op.drop_index('ix_trips_last_seq', table_name='trips')

    op.drop_table('trips')
    op.drop_index('ix_purpose_rules_tenant_last_seq', table_name='purpose_rules')
    op.drop_index('ix_purpose_rules_tenant_id', table_name='purpose_rules')
    op.drop_index('ix_purpose_rules_last_seq', table_name='purpose_rules')

    op.drop_table('purpose_rules')
    op.drop_index('ix_maintenance_materials_tenant_last_seq', table_name='maintenance_materials')
    op.drop_index('ix_maintenance_materials_tenant_id', table_name='maintenance_materials')
    op.drop_index('ix_maintenance_materials_maintenance_id', table_name='maintenance_materials')
    op.drop_index('ix_maintenance_materials_last_seq', table_name='maintenance_materials')

    op.drop_table('maintenance_materials')
    op.drop_index('ix_maintenance_items_tenant_last_seq', table_name='maintenance_items')
    op.drop_index('ix_maintenance_items_tenant_id', table_name='maintenance_items')
    op.drop_index('ix_maintenance_items_maintenance_id', table_name='maintenance_items')
    op.drop_index('ix_maintenance_items_last_seq', table_name='maintenance_items')

    op.drop_table('maintenance_items')
    op.drop_index('ix_attachments_vehicle_id', table_name='attachments')
    op.drop_index('ix_attachments_tenant_last_seq', table_name='attachments')
    op.drop_index('ix_attachments_tenant_id', table_name='attachments')
    op.drop_index('ix_attachments_maintenance_id', table_name='attachments')
    op.drop_index('ix_attachments_last_seq', table_name='attachments')
    op.drop_index('ix_attachments_fuel_id', table_name='attachments')

    op.drop_table('attachments')
    op.drop_index('ix_trip_periods_vehicle_id', table_name='trip_periods')
    op.drop_index('ix_trip_periods_tenant_last_seq', table_name='trip_periods')
    op.drop_index('ix_trip_periods_tenant_id', table_name='trip_periods')
    op.drop_index('ix_trip_periods_last_seq', table_name='trip_periods')

    op.drop_table('trip_periods')
    op.drop_index('ix_places_tenant_last_seq', table_name='places')
    op.drop_index('ix_places_tenant_id', table_name='places')
    op.drop_index('ix_places_last_seq', table_name='places')
    op.drop_index('ix_places_customer_id', table_name='places')

    op.drop_table('places')
    op.drop_index('ix_odometer_readings_vehicle_id', table_name='odometer_readings')
    op.drop_index('ix_odometer_readings_tenant_last_seq', table_name='odometer_readings')
    op.drop_index('ix_odometer_readings_tenant_id', table_name='odometer_readings')
    op.drop_index('ix_odometer_readings_last_seq', table_name='odometer_readings')

    op.drop_table('odometer_readings')
    op.drop_index('ix_material_articles_vehicle_id', table_name='material_articles')
    op.drop_index('ix_material_articles_tenant_last_seq', table_name='material_articles')
    op.drop_index('ix_material_articles_tenant_id', table_name='material_articles')
    op.drop_index('ix_material_articles_last_seq', table_name='material_articles')

    op.drop_table('material_articles')
    op.drop_index('ix_maintenance_vehicle_id', table_name='maintenance')
    op.drop_index('ix_maintenance_tenant_last_seq', table_name='maintenance')
    op.drop_index('ix_maintenance_tenant_id', table_name='maintenance')
    op.drop_index('ix_maintenance_last_seq', table_name='maintenance')

    op.drop_table('maintenance')
    op.drop_index('ix_fuel_entries_vehicle_id', table_name='fuel_entries')
    op.drop_index('ix_fuel_entries_tenant_last_seq', table_name='fuel_entries')
    op.drop_index('ix_fuel_entries_tenant_id', table_name='fuel_entries')
    op.drop_index('ix_fuel_entries_last_seq', table_name='fuel_entries')

    op.drop_table('fuel_entries')
    op.drop_index('ix_vehicles_tenant_last_seq', table_name='vehicles')
    op.drop_index('ix_vehicles_tenant_id', table_name='vehicles')
    op.drop_index('ix_vehicles_last_seq', table_name='vehicles')

    op.drop_table('vehicles')
    op.drop_index('ix_tax_params_tenant_last_seq', table_name='tax_params')
    op.drop_index('ix_tax_params_tenant_id', table_name='tax_params')
    op.drop_index('ix_tax_params_last_seq', table_name='tax_params')

    op.drop_table('tax_params')
    op.drop_index('ix_revisions_tenant_id', table_name='revisions')
    op.drop_index('ix_revisions_tenant_entity', table_name='revisions')
    op.drop_index('ix_revisions_entity_id', table_name='revisions')

    op.drop_table('revisions')
    op.drop_index('ix_customers_tenant_last_seq', table_name='customers')
    op.drop_index('ix_customers_tenant_id', table_name='customers')
    op.drop_index('ix_customers_last_seq', table_name='customers')

    op.drop_table('customers')
    op.drop_index('ix_blob_checks_tenant_id', table_name='blob_checks')

    op.drop_table('blob_checks')
    op.drop_index('ix_anchors_tenant_id', table_name='anchors')

    op.drop_table('anchors')
    op.drop_table('tenants')
