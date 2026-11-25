import datetime as dt

from pydantic import BaseModel, ConfigDict, Field


class ORM(BaseModel):
    model_config = ConfigDict(from_attributes=True)


class AuthConfig(BaseModel):
    issuer: str
    client_id: str
    scopes: str


# Fahrzeuge
class VehicleIn(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    make: str | None = None
    model: str | None = None
    plate: str | None = None
    fuel_type: str = "benzin"
    initial_km: int = Field(default=0, ge=0)


class VehicleOut(ORM, VehicleIn):
    id: int
    current_km: int


# Kilometerstände
class OdometerIn(BaseModel):
    date: dt.date
    km: int = Field(ge=0)
    note: str | None = None


class OdometerOut(ORM, OdometerIn):
    id: int


# Tankvorgänge
class FuelIn(BaseModel):
    date: dt.date
    km: int = Field(ge=0)
    liters: float = Field(gt=0)
    price_total: float = Field(ge=0)
    full_tank: bool = True
    station: str | None = None
    note: str | None = None


class FuelOut(ORM, FuelIn):
    id: int
    price_per_liter: float


# Wartung
class ItemIn(BaseModel):
    label: str = Field(min_length=1, max_length=200)
    done: bool = False


class ItemOut(ORM, ItemIn):
    id: int
    position: int


class ItemPatch(BaseModel):
    done: bool


class MaintenanceIn(BaseModel):
    date: dt.date
    km: int | None = Field(default=None, ge=0)
    title: str = Field(min_length=1, max_length=150)
    cost: float | None = Field(default=None, ge=0)
    note: str | None = None
    next_due_km: int | None = Field(default=None, ge=0)
    next_due_date: dt.date | None = None
    items: list[ItemIn] = []


class MaintenanceOut(ORM):
    id: int
    date: dt.date
    km: int | None
    title: str
    cost: float | None
    note: str | None
    next_due_km: int | None
    next_due_date: dt.date | None
    items: list[ItemOut]


class ChecklistTemplate(BaseModel):
    title: str
    items: list[str]


# Statistik
class ConsumptionPoint(BaseModel):
    date: dt.date
    km: int
    distance: int
    liters: float
    cost: float
    consumption: float  # L/100 km
    cost_per_km: float


class DueItem(BaseModel):
    maintenance_id: int
    title: str
    next_due_km: int | None
    next_due_date: dt.date | None
    overdue: bool


class Stats(BaseModel):
    current_km: int
    driven_km: int
    avg_consumption: float | None  # L/100 km
    avg_liters_per_km: float | None
    avg_cost_per_km: float | None
    total_liters: float
    total_fuel_cost: float
    total_maintenance_cost: float
    points: list[ConsumptionPoint]
    due: list[DueItem]
