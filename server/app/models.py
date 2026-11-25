import datetime as dt
import uuid

from sqlalchemy import Boolean, Date, Float, ForeignKey, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from .db import Base

GENESIS = "0" * 64


def new_id() -> str:
    return str(uuid.uuid4())


class Tenant(Base):
    """Mandant. `seq`/`head_hash` = Stand der Revisionskette."""

    __tablename__ = "tenants"

    id: Mapped[int] = mapped_column(primary_key=True)
    slug: Mapped[str] = mapped_column(String(64), unique=True)
    name: Mapped[str] = mapped_column(String(100))
    seq: Mapped[int] = mapped_column(Integer, default=0)
    head_hash: Mapped[str] = mapped_column(String(64), default=GENESIS)


class Synced:
    """Gemeinsame Spalten aller synchronisierten Objekte (IDs vom Client, UUID)."""

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    tenant_id: Mapped[int] = mapped_column(ForeignKey("tenants.id"), index=True)
    version: Mapped[int] = mapped_column(Integer, default=0)
    deleted: Mapped[bool] = mapped_column(Boolean, default=False)
    last_seq: Mapped[int] = mapped_column(Integer, default=0, index=True)


class Vehicle(Synced, Base):
    __tablename__ = "vehicles"

    name: Mapped[str] = mapped_column(String(100))
    make: Mapped[str | None] = mapped_column(String(100))
    model: Mapped[str | None] = mapped_column(String(100))
    plate: Mapped[str | None] = mapped_column(String(30))
    fuel_type: Mapped[str] = mapped_column(String(20), default="benzin")
    initial_km: Mapped[int] = mapped_column(Integer, default=0)


class OdometerReading(Synced, Base):
    __tablename__ = "odometer_readings"

    vehicle_id: Mapped[str] = mapped_column(ForeignKey("vehicles.id"), index=True)
    date: Mapped[dt.date] = mapped_column(Date)
    km: Mapped[int] = mapped_column(Integer)
    note: Mapped[str | None] = mapped_column(Text)


class FuelEntry(Synced, Base):
    __tablename__ = "fuel_entries"

    vehicle_id: Mapped[str] = mapped_column(ForeignKey("vehicles.id"), index=True)
    date: Mapped[dt.date] = mapped_column(Date)
    km: Mapped[int] = mapped_column(Integer)
    liters: Mapped[float] = mapped_column(Float)
    price_total: Mapped[float] = mapped_column(Float)
    full_tank: Mapped[bool] = mapped_column(Boolean, default=True)
    station: Mapped[str | None] = mapped_column(String(100))
    note: Mapped[str | None] = mapped_column(Text)

    @property
    def price_per_liter(self) -> float:
        return round(self.price_total / self.liters, 3) if self.liters else 0.0


class Maintenance(Synced, Base):
    __tablename__ = "maintenance"

    vehicle_id: Mapped[str] = mapped_column(ForeignKey("vehicles.id"), index=True)
    date: Mapped[dt.date] = mapped_column(Date)
    km: Mapped[int | None] = mapped_column(Integer)
    title: Mapped[str] = mapped_column(String(150))
    cost: Mapped[float | None] = mapped_column(Float)
    note: Mapped[str | None] = mapped_column(Text)
    next_due_km: Mapped[int | None] = mapped_column(Integer)
    next_due_date: Mapped[dt.date | None] = mapped_column(Date)


class MaintenanceItem(Synced, Base):
    __tablename__ = "maintenance_items"

    maintenance_id: Mapped[str] = mapped_column(ForeignKey("maintenance.id"), index=True)
    label: Mapped[str] = mapped_column(String(200))
    done: Mapped[bool] = mapped_column(Boolean, default=False)
    position: Mapped[int] = mapped_column(Integer, default=0)


class MaintenanceMaterial(Synced, Base):
    """Verbautes Material/Ersatzteil einer Wartung."""

    __tablename__ = "maintenance_materials"

    maintenance_id: Mapped[str] = mapped_column(ForeignKey("maintenance.id"), index=True)
    name: Mapped[str] = mapped_column(String(150))
    part_number: Mapped[str | None] = mapped_column(String(60))
    quantity: Mapped[float] = mapped_column(Float)
    unit: Mapped[str] = mapped_column(String(20), default="Stk")
    unit_price: Mapped[float | None] = mapped_column(Float)
    position: Mapped[int] = mapped_column(Integer, default=0)

    @property
    def total(self) -> float | None:
        return None if self.unit_price is None else self.quantity * self.unit_price


class Revision(Base):
    """Append-only Journal (Hash-Kette je Mandant). UPDATE/DELETE per DB-Trigger gesperrt."""

    __tablename__ = "revisions"
    __table_args__ = (
        UniqueConstraint("tenant_id", "seq", name="uq_revision_seq"),
        UniqueConstraint("tenant_id", "op_id", name="uq_revision_op"),
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    tenant_id: Mapped[int] = mapped_column(ForeignKey("tenants.id"), index=True)
    seq: Mapped[int] = mapped_column(Integer)
    entity: Mapped[str] = mapped_column(String(32))
    entity_id: Mapped[str] = mapped_column(String(36), index=True)
    version: Mapped[int] = mapped_column(Integer)
    action: Mapped[str] = mapped_column(String(10))  # create | update | delete
    data: Mapped[str] = mapped_column(Text)  # kanonisches JSON, exakt so gehasht
    actor_sub: Mapped[str] = mapped_column(String(255))
    actor_name: Mapped[str | None] = mapped_column(String(255))
    recorded_at: Mapped[str] = mapped_column(String(32))  # UTC ISO-8601 (Text → hash-stabil)
    client_ts: Mapped[str | None] = mapped_column(String(40))
    op_id: Mapped[str | None] = mapped_column(String(64))
    conflict: Mapped[bool] = mapped_column(Boolean, default=False)
    prev_hash: Mapped[str] = mapped_column(String(64))
    hash: Mapped[str] = mapped_column(String(64))


class Anchor(Base):
    """Signierter Kettenkopf (Ed25519). Macht ein komplettes Neuberechnen der Kette erkennbar,
    solange der Signaturschlüssel nicht in der DB liegt. Append-only wie `revisions`."""

    __tablename__ = "anchors"

    id: Mapped[int] = mapped_column(primary_key=True)
    tenant_id: Mapped[int] = mapped_column(ForeignKey("tenants.id"), index=True)
    seq: Mapped[int] = mapped_column(Integer)
    head_hash: Mapped[str] = mapped_column(String(64))
    created_at: Mapped[str] = mapped_column(String(32))
    key_id: Mapped[str] = mapped_column(String(16))
    signature: Mapped[str] = mapped_column(String(128))
