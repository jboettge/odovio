import datetime as dt
import re
import uuid
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


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
    # Fahrtenbuch/Steuer: None = nicht erfasst (Logik nimmt ownership "private", Methode "flat")
    purchase_price: float | None = Field(default=None, ge=0, le=10_000_000)   # exkl. MWST
    ownership: Literal["private", "business"] | None = None
    private_use_method: Literal["flat", "effective"] | None = None
    annual_fixed_costs: float | None = Field(default=None, ge=0, le=1_000_000)


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


# ---------- Fahrtenbuch ----------
TripCategory = Literal["business", "private", "commute", "field", "unknown"]
RuleCategory = Literal["business", "private", "commute", "field"]
TRIP_CATEGORIES = ("business", "private", "commute", "field", "unknown")
DISTANCE_MAX = 10_000
_HHMM = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$")
_MONTH = re.compile(r"^\d{4}-(0[1-9]|1[0-2])$")


def normalize_ts(v: str | None) -> str | None:
    """ISO-8601 mit Offset → datetime.isoformat(timespec="seconds"), Offset bleibt erhalten."""
    if v is None:
        return None
    if not isinstance(v, str) or len(v) > 40:
        raise ValueError("ISO-8601-Zeitpunkt erwartet")
    try:
        t = dt.datetime.fromisoformat(v.strip())
    except ValueError as e:
        raise ValueError("ISO-8601-Zeitpunkt erwartet") from e
    if t.tzinfo is None or t.utcoffset() is None:
        raise ValueError("Zeitpunkt ohne Zeitzonen-Offset")
    if not 2000 <= t.year <= 2100:
        raise ValueError("Jahr ausserhalb 2000–2100")
    return t.isoformat(timespec="seconds")


def is_month(v: str) -> bool:
    return bool(_MONTH.match(v or ""))


class CustomerData(Payload):
    name: str = Field(min_length=1, max_length=150)
    ref: str | None = Field(default=None, max_length=50)
    note: str | None = Field(default=None, max_length=500)


class PlaceData(Payload):
    name: str = Field(min_length=1, max_length=100)
    kind: Literal["home", "work", "customer", "other"]
    lat: float | None = Field(default=None, ge=-90, le=90)
    lon: float | None = Field(default=None, ge=-180, le=180)
    radius_m: int = Field(default=150, ge=50, le=5000)
    customer_id: str | None = Field(default=None, max_length=36)
    default_category: TripCategory | None = None
    private: bool = False

    @field_validator("lat", "lon")
    @classmethod
    def _round(cls, v: float | None) -> float | None:   # ~100 m: Datensparsamkeit
        return None if v is None else round(v, 3)


class TripData(Payload):
    vehicle_id: str = Field(max_length=36)
    driver_sub: str | None = Field(default=None, max_length=255)
    driver_name: str | None = Field(default=None, max_length=100)
    start_at: str
    end_at: str | None = None
    km_start: int | None = Field(default=None, ge=0, le=MAX_KM)
    km_end: int | None = Field(default=None, ge=0, le=MAX_KM)
    distance_gps: float | None = Field(default=None, ge=0, le=DISTANCE_MAX)
    distance_route: float | None = Field(default=None, ge=0, le=DISTANCE_MAX)
    start_place_id: str | None = Field(default=None, max_length=36)
    end_place_id: str | None = Field(default=None, max_length=36)
    start_label: str | None = Field(default=None, max_length=200)
    end_label: str | None = Field(default=None, max_length=200)
    category: TripCategory = "unknown"
    purpose: str | None = Field(default=None, max_length=300)
    customer_id: str | None = Field(default=None, max_length=36)
    status: Literal["draft", "suggested", "confirmed", "locked"] = "draft"   # "locked" setzt nur der Server
    source: Literal["auto", "manual", "gap", "import"] = "manual"
    suggestion_category: TripCategory | None = None
    suggestion_purpose: str | None = Field(default=None, max_length=300)
    suggestion_customer_id: str | None = Field(default=None, max_length=36)
    suggestion_confidence: float | None = Field(default=None, ge=0, le=1)
    suggestion_reason: str | None = Field(default=None, max_length=300)
    suggestion_source: Literal["rule", "calendar", "pattern", "llm"] | None = None
    track_hash: str | None = Field(default=None, pattern=r"^[0-9a-fA-F]{64}$")
    split_of: str | None = Field(default=None, max_length=36)
    private_mode: bool = False
    note: str | None = Field(default=None, max_length=NOTE)

    @field_validator("start_at", "end_at", mode="before")
    @classmethod
    def _ts(cls, v):
        return normalize_ts(v)

    @field_validator("track_hash")
    @classmethod
    def _lower(cls, v: str | None) -> str | None:
        return None if v is None else v.lower()

    @model_validator(mode="after")
    def _order(self):
        if self.end_at is not None and \
                dt.datetime.fromisoformat(self.end_at) < dt.datetime.fromisoformat(self.start_at):
            raise ValueError("end_at liegt vor start_at")
        if self.km_start is not None and self.km_end is not None and self.km_end < self.km_start:
            raise ValueError("km_end kleiner als km_start")
        return self


# ---------- Belege ----------
MAX_ATTACHMENT_BYTES = 8 * 1024 * 1024
AttachmentMime = Literal["image/jpeg", "image/heic", "application/pdf"]


class AttachmentData(Payload):
    """Metadaten eines Belegs. Die Datei selbst kommt per PUT …/attachments/{id}/blob."""
    fuel_id: str | None = Field(default=None, max_length=36)
    maintenance_id: str | None = Field(default=None, max_length=36)
    vehicle_id: str | None = Field(default=None, max_length=36)
    kind: Literal["receipt", "pump", "odometer", "other"]
    sha256: str = Field(pattern=r"^[0-9a-fA-F]{64}$")
    mime: AttachmentMime
    size: int = Field(ge=1, le=MAX_ATTACHMENT_BYTES)
    taken_at: str | None = None
    note: str | None = Field(default=None, max_length=300)

    @field_validator("sha256")
    @classmethod
    def _lower(cls, v: str) -> str:
        return v.lower()

    @field_validator("taken_at", mode="before")
    @classmethod
    def _ts(cls, v):
        return normalize_ts(v)

    @model_validator(mode="after")
    def _target(self):
        if self.fuel_id is None and self.maintenance_id is None and \
                not (self.kind == "odometer" and self.vehicle_id is not None):
            raise ValueError("fuel_id oder maintenance_id nötig (Tacho-Foto: kind odometer mit vehicle_id)")
        return self


class PurposeRuleData(Payload):
    priority: int = Field(default=100, ge=0, le=1000)
    from_place_id: str | None = Field(default=None, max_length=36)
    to_place_id: str | None = Field(default=None, max_length=36)
    weekdays: str | None = Field(default=None, max_length=20)   # "1,2,3,4,5" (ISO: 1 = Montag)
    time_from: str | None = None                                # "HH:MM"
    time_to: str | None = None
    vehicle_id: str | None = Field(default=None, max_length=36)
    result_category: RuleCategory
    result_purpose: str | None = Field(default=None, max_length=300)
    result_customer_id: str | None = Field(default=None, max_length=36)
    auto_confirm: bool = False
    origin: Literal["user", "learned"] = "user"
    active: bool = True

    @field_validator("weekdays")
    @classmethod
    def _weekdays(cls, v: str | None) -> str | None:
        if v is None or not v.strip():
            return None
        try:
            days = [int(x) for x in v.split(",")]
        except ValueError as e:
            raise ValueError("Format 1,2,3 (ISO-Wochentage 1–7)") from e
        if any(not 1 <= d <= 7 for d in days) or len(set(days)) != len(days):
            raise ValueError("Format 1,2,3 (ISO-Wochentage 1–7, ohne Doppel)")
        return ",".join(map(str, sorted(days)))

    @field_validator("time_from", "time_to")
    @classmethod
    def _hhmm(cls, v: str | None) -> str | None:
        if v is not None and not _HHMM.match(v):
            raise ValueError("Format HH:MM")
        return v


TAX_KEYS = ("km_rate", "commute_rate", "cap_federal", "cap_canton", "private_share_pct", "min_private_month",
            "vat_rate")


class TaxParamData(Payload):
    year: int = Field(ge=2000, le=2100)
    scope: str = Field(max_length=30, pattern=r"^(federal|canton:[A-Z]{2}|tenant)$")
    key: Literal["km_rate", "commute_rate", "cap_federal", "cap_canton", "private_share_pct",
                 "min_private_month", "vat_rate"]
    value: float = Field(ge=0, le=1_000_000)
    source_url: str | None = Field(default=None, max_length=300)
    note: str | None = Field(default=None, max_length=300)


class TripPeriodData(Payload):
    """Nur Server (Monatsabschluss); Client-Ops werden abgelehnt. Feldliste = Snapshot/`/changes`."""
    vehicle_id: str
    month: str
    status: Literal["closed"] = "closed"
    closed_by: str | None = None
    closed_at: str | None = None
    anchor_seq: int | None = None
    km_start: int | None = None
    km_end: int | None = None
    trips_count: int = 0
    business_km: float = 0
    private_km: float = 0
    commute_km: float = 0
    field_km: float = 0
    note: str | None = None


class CloseRequest(BaseModel):
    force: bool = False
    reason: str | None = Field(default=None, max_length=500)


# ---------- Sync-Protokoll ----------
class SyncOp(BaseModel):
    op_id: str = Field(min_length=8, max_length=64)
    entity: Literal["vehicle", "odometer", "fuel", "maintenance", "maintenance_item", "maintenance_material",
                    "material_article", "trip", "place", "customer", "purpose_rule", "tax_param", "trip_period",
                    "attachment"]
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
    trips: list[dict]
    places: list[dict]
    customers: list[dict]
    purpose_rules: list[dict]
    tax_params: list[dict]
    trip_periods: list[dict]
    attachments: list[dict]


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
    blobs_checked: int = 0  # Belegdateien mit geprüfter SHA-256
    blobs_missing: int = 0  # Belege ohne (hochgeladene) Datei – kein Fehler


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
