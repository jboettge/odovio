import datetime as dt
import uuid
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator


class AuthConfig(BaseModel):
    issuer: str
    client_id: str
    scopes: str


class TenantInfo(BaseModel):
    slug: str
    role: Literal["write", "read"]


class Me(BaseModel):
    sub: str
    name: str | None
    tenants: list[TenantInfo]


# ---------- Nutzdaten je Objekttyp (Sync) ----------
# Obergrenzen schützen Statistik/PDF/DB (int4) und die App vor unsinnigen Werten;
# inf/NaN würden JSON-Ausgaben (null) und damit den Sync aller Geräte brechen.
MAX_KM = 5_000_000
NOTE = 2000


class Payload(BaseModel):
    model_config = ConfigDict(allow_inf_nan=False)


class VehicleData(Payload):
    name: str = Field(min_length=1, max_length=100)
    make: str | None = Field(default=None, max_length=100)
    model: str | None = Field(default=None, max_length=100)
    plate: str | None = Field(default=None, max_length=30)
    fuel_type: str = Field(default="benzin", max_length=20)
    initial_km: int = Field(default=0, ge=0, le=MAX_KM)


class OdometerData(Payload):
    vehicle_id: str = Field(max_length=36)
    date: dt.date
    km: int = Field(ge=0, le=MAX_KM)
    note: str | None = Field(default=None, max_length=NOTE)


class FuelData(Payload):
    vehicle_id: str = Field(max_length=36)
    date: dt.date
    km: int = Field(ge=0, le=MAX_KM)
    liters: float = Field(gt=0, le=5000)
    price_total: float = Field(ge=0, le=100_000)
    full_tank: bool = True
    station: str | None = Field(default=None, max_length=100)
    note: str | None = Field(default=None, max_length=NOTE)


class MaintenanceData(Payload):
    vehicle_id: str = Field(max_length=36)
    date: dt.date
    km: int | None = Field(default=None, ge=0, le=MAX_KM)
    title: str = Field(min_length=1, max_length=150)
    cost: float | None = Field(default=None, ge=0, le=1_000_000)
    note: str | None = Field(default=None, max_length=NOTE)
    next_due_km: int | None = Field(default=None, ge=0, le=MAX_KM)
    next_due_date: dt.date | None = None


class MaintenanceItemData(Payload):
    maintenance_id: str = Field(max_length=36)
    label: str = Field(min_length=1, max_length=200)
    done: bool = False
    position: int = Field(default=0, ge=0, le=10_000)


class MaintenanceMaterialData(Payload):
    maintenance_id: str = Field(max_length=36)
    article_id: str | None = Field(default=None, max_length=36)  # Herkunft aus dem Materialstamm
    name: str = Field(min_length=1, max_length=150)
    part_number: str | None = Field(default=None, max_length=60)
    quantity: float = Field(gt=0, le=100_000)
    unit: str = Field(default="Stk", min_length=1, max_length=20)
    unit_price: float | None = Field(default=None, ge=0, le=100_000)
    position: int = Field(default=0, ge=0, le=10_000)


class MaterialArticleData(Payload):
    name: str = Field(min_length=1, max_length=150)
    part_number: str | None = Field(default=None, max_length=60)
    unit: str = Field(default="Stk", min_length=1, max_length=20)
    unit_price: float | None = Field(default=None, ge=0, le=100_000)
    category: str | None = Field(default=None, max_length=50)
    vehicle_id: str | None = Field(default=None, max_length=36)  # None = für alle Fahrzeuge
    note: str | None = Field(default=None, max_length=500)


# ---------- Sync-Protokoll ----------
class SyncOp(BaseModel):
    op_id: str = Field(min_length=8, max_length=64)
    entity: Literal["vehicle", "odometer", "fuel", "maintenance", "maintenance_item", "maintenance_material",
                    "material_article"]
    id: str
    action: Literal["upsert", "delete"]
    base_version: int | None = Field(default=None, ge=0, le=2_000_000_000)  # None = neu
    data: dict = {}
    client_ts: str | None = Field(default=None, max_length=40)  # Erfassungszeitpunkt auf dem Gerät

    @field_validator("id")
    @classmethod
    def _uuid(cls, v: str) -> str:
        return str(uuid.UUID(v))


class SyncRequest(BaseModel):
    ops: list[SyncOp] = Field(max_length=500)


class OpResult(BaseModel):
    op_id: str
    status: Literal["applied", "conflict", "duplicate", "noop", "rejected"]
    entity: str
    id: str
    version: int | None = None
    error: str | None = None


class SyncResponse(BaseModel):
    results: list[OpResult]
    cursor: int


class Changes(BaseModel):
    cursor: int
    vehicles: list[dict]
    odometer: list[dict]
    fuel: list[dict]
    maintenance: list[dict]
    maintenance_items: list[dict]
    maintenance_materials: list[dict]
    material_articles: list[dict]


class ChecklistTemplate(BaseModel):
    title: str
    items: list[str]


class RevisionOut(BaseModel):
    seq: int
    entity: str
    entity_id: str
    version: int
    action: str
    data: dict
    actor_name: str | None
    recorded_at: str
    client_ts: str | None
    conflict: bool
    hash: str


class AuditResult(BaseModel):
    ok: bool                # Kette + Datenstand + Anker
    chain_ok: bool
    state_ok: bool
    count: int
    head_hash: str
    broken_at: int | None
    reason: str | None
    problems: list[str]
    signed: bool            # Anker-Signaturschlüssel konfiguriert
    anchors: int


class AnchorOut(BaseModel):
    seq: int
    head_hash: str
    created_at: str
    key_id: str
    signature: str


class AnchorList(BaseModel):
    tenant: str
    public_key: str | None   # Ed25519, Base64 (raw)
    key_id: str | None
    message_format: str
    anchors: list[AnchorOut]


# ---------- Statistik ----------
class ConsumptionPoint(BaseModel):
    date: dt.date
    km: int
    distance: int
    liters: float
    cost: float
    consumption: float  # L/100 km
    cost_per_km: float


class DueItem(BaseModel):
    maintenance_id: str
    title: str
    next_due_km: int | None
    next_due_date: dt.date | None
    overdue: bool


class Stats(BaseModel):
    current_km: int
    driven_km: int
    avg_consumption: float | None
    avg_liters_per_km: float | None
    avg_cost_per_km: float | None
    total_liters: float
    total_fuel_cost: float
    total_maintenance_cost: float
    points: list[ConsumptionPoint]
    due: list[DueItem]
