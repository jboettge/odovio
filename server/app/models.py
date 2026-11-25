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
    # Fahrtenbuch/Steuer (nachgerüstet, nullable; None → Default in der Logik: private / flat)
    purchase_price: Mapped[float | None] = mapped_column(Float)          # Kaufpreis exkl. MWST
    ownership: Mapped[str | None] = mapped_column(String(20))            # private | business
    private_use_method: Mapped[str | None] = mapped_column(String(20))   # flat | effective
    annual_fixed_costs: Mapped[float | None] = mapped_column(Float)      # Versicherung, Steuer, Leasing, AfA


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
    # Herkunft aus dem Materialstamm (nur Referenz; Werte der Position sind eine Kopie).
    # Kein Fremdschlüssel: Prüfung im Sync, Spalte wird in migrate.create_schema nachgerüstet.
    article_id: Mapped[str | None] = mapped_column(String(36))
    name: Mapped[str] = mapped_column(String(150))
    part_number: Mapped[str | None] = mapped_column(String(60))
    quantity: Mapped[float] = mapped_column(Float)
    unit: Mapped[str] = mapped_column(String(20), default="Stk")
    unit_price: Mapped[float | None] = mapped_column(Float)
    position: Mapped[int] = mapped_column(Integer, default=0)

    @property
    def total(self) -> float | None:
        return None if self.unit_price is None else self.quantity * self.unit_price


class MaterialArticle(Synced, Base):
    """Materialstamm (mandantenweit). `vehicle_id` = None → für alle Fahrzeuge."""

    __tablename__ = "material_articles"

    name: Mapped[str] = mapped_column(String(150))
    part_number: Mapped[str | None] = mapped_column(String(60))
    unit: Mapped[str] = mapped_column(String(20), default="Stk")
    unit_price: Mapped[float | None] = mapped_column(Float)
    category: Mapped[str | None] = mapped_column(String(50))
    vehicle_id: Mapped[str | None] = mapped_column(ForeignKey("vehicles.id"), index=True)
    note: Mapped[str | None] = mapped_column(Text)


class Attachment(Synced, Base):
    """Beleg (Foto/PDF von Zapfsäule, Quittung, Tacho). Metadaten werden synchronisiert (Journal),
    die Datei liegt ausserhalb der DB (ATTACHMENT_DIR/<tenant_id>/<id>) und ist über `sha256`
    an die Revisionskette gebunden. Storno = Soft-Delete, die Datei bleibt erhalten."""

    __tablename__ = "attachments"

    fuel_id: Mapped[str | None] = mapped_column(ForeignKey("fuel_entries.id"), index=True)
    maintenance_id: Mapped[str | None] = mapped_column(ForeignKey("maintenance.id"), index=True)
    vehicle_id: Mapped[str | None] = mapped_column(ForeignKey("vehicles.id"), index=True)
    kind: Mapped[str] = mapped_column(String(20))
    sha256: Mapped[str] = mapped_column(String(64))
    mime: Mapped[str] = mapped_column(String(40))
    size: Mapped[int] = mapped_column(Integer)
    taken_at: Mapped[str | None] = mapped_column(String(40))
    note: Mapped[str | None] = mapped_column(String(300))


# ---------- Fahrtenbuch ----------
class Customer(Synced, Base):
    __tablename__ = "customers"

    name: Mapped[str] = mapped_column(String(150))
    ref: Mapped[str | None] = mapped_column(String(50))
    note: Mapped[str | None] = mapped_column(String(500))


class Place(Synced, Base):
    """Bekannter Ort. Wohnort-Koordinaten bleiben auf dem Gerät (Server lehnt sie ab)."""

    __tablename__ = "places"

    name: Mapped[str] = mapped_column(String(100))
    kind: Mapped[str] = mapped_column(String(20))
    lat: Mapped[float | None] = mapped_column(Float)
    lon: Mapped[float | None] = mapped_column(Float)
    radius_m: Mapped[int] = mapped_column(Integer, default=150)
    customer_id: Mapped[str | None] = mapped_column(ForeignKey("customers.id"), index=True)
    default_category: Mapped[str | None] = mapped_column(String(20))
    private: Mapped[bool] = mapped_column(Boolean, default=False)


class Trip(Synced, Base):
    """Fahrt. Zeitpunkte als ISO-8601-Text (mit Offset) → Snapshots hash-stabil."""

    __tablename__ = "trips"

    vehicle_id: Mapped[str] = mapped_column(ForeignKey("vehicles.id"), index=True)
    driver_sub: Mapped[str | None] = mapped_column(String(255))
    driver_name: Mapped[str | None] = mapped_column(String(100))
    start_at: Mapped[str] = mapped_column(String(40), index=True)
    end_at: Mapped[str | None] = mapped_column(String(40))
    km_start: Mapped[int | None] = mapped_column(Integer)
    km_end: Mapped[int | None] = mapped_column(Integer)
    distance_gps: Mapped[float | None] = mapped_column(Float)
    distance_route: Mapped[float | None] = mapped_column(Float)
    start_place_id: Mapped[str | None] = mapped_column(ForeignKey("places.id"))
    end_place_id: Mapped[str | None] = mapped_column(ForeignKey("places.id"))
    start_label: Mapped[str | None] = mapped_column(String(200))
    end_label: Mapped[str | None] = mapped_column(String(200))
    category: Mapped[str] = mapped_column(String(20), default="unknown")
    purpose: Mapped[str | None] = mapped_column(String(300))
    customer_id: Mapped[str | None] = mapped_column(ForeignKey("customers.id"))
    status: Mapped[str] = mapped_column(String(20), default="draft")
    source: Mapped[str] = mapped_column(String(20), default="manual")
    suggestion_category: Mapped[str | None] = mapped_column(String(20))
    suggestion_purpose: Mapped[str | None] = mapped_column(String(300))
    suggestion_customer_id: Mapped[str | None] = mapped_column(String(36))
    suggestion_confidence: Mapped[float | None] = mapped_column(Float)
    suggestion_reason: Mapped[str | None] = mapped_column(String(300))
    suggestion_source: Mapped[str | None] = mapped_column(String(20))
    track_hash: Mapped[str | None] = mapped_column(String(64))
    split_of: Mapped[str | None] = mapped_column(ForeignKey("trips.id"))
    private_mode: Mapped[bool] = mapped_column(Boolean, default=False)
    note: Mapped[str | None] = mapped_column(Text)


class PurposeRule(Synced, Base):
    __tablename__ = "purpose_rules"

    priority: Mapped[int] = mapped_column(Integer, default=100)
    from_place_id: Mapped[str | None] = mapped_column(ForeignKey("places.id"))
    to_place_id: Mapped[str | None] = mapped_column(ForeignKey("places.id"))
    weekdays: Mapped[str | None] = mapped_column(String(20))
    time_from: Mapped[str | None] = mapped_column(String(5))
    time_to: Mapped[str | None] = mapped_column(String(5))
    vehicle_id: Mapped[str | None] = mapped_column(ForeignKey("vehicles.id"))
    result_category: Mapped[str] = mapped_column(String(20))
    result_purpose: Mapped[str | None] = mapped_column(String(300))
    result_customer_id: Mapped[str | None] = mapped_column(ForeignKey("customers.id"))
    auto_confirm: Mapped[bool] = mapped_column(Boolean, default=False)
    origin: Mapped[str] = mapped_column(String(20), default="user")
    active: Mapped[bool] = mapped_column(Boolean, default=True)


class TaxParam(Synced, Base):
    __tablename__ = "tax_params"

    year: Mapped[int] = mapped_column(Integer)
    scope: Mapped[str] = mapped_column(String(30))
    key: Mapped[str] = mapped_column(String(30))
    value: Mapped[float] = mapped_column(Float)
    source_url: Mapped[str | None] = mapped_column(String(300))
    note: Mapped[str | None] = mapped_column(String(300))


class TripPeriod(Synced, Base):
    """Monatsabschluss je Fahrzeug. Nur serverseitig geschrieben (Journal wie alle Entitäten)."""

    __tablename__ = "trip_periods"
    __table_args__ = (UniqueConstraint("vehicle_id", "month", name="uq_trip_period_month"),)

    vehicle_id: Mapped[str] = mapped_column(ForeignKey("vehicles.id"), index=True)
    month: Mapped[str] = mapped_column(String(7))
    status: Mapped[str] = mapped_column(String(10), default="closed")
    closed_by: Mapped[str | None] = mapped_column(String(255))
    closed_at: Mapped[str | None] = mapped_column(String(32))
    anchor_seq: Mapped[int | None] = mapped_column(Integer)
    km_start: Mapped[int | None] = mapped_column(Integer)
    km_end: Mapped[int | None] = mapped_column(Integer)
    trips_count: Mapped[int] = mapped_column(Integer, default=0)
    business_km: Mapped[float] = mapped_column(Float, default=0)
    private_km: Mapped[float] = mapped_column(Float, default=0)
    commute_km: Mapped[float] = mapped_column(Float, default=0)
    field_km: Mapped[float] = mapped_column(Float, default=0)
    note: Mapped[str | None] = mapped_column(String(500))   # Begründung bei erzwungenem Abschluss


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
