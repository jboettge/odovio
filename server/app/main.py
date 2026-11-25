import json
import os
from contextlib import asynccontextmanager
from typing import Annotated

from fastapi import Depends, FastAPI, HTTPException, Response, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from . import models, schemas
from .auth import get_config, require_user
from .db import Base, engine, get_session
from .stats import vehicle_stats

DEFAULT_TEMPLATES = [
    {
        "title": "Service",
        "items": [
            "Motoröl gewechselt",
            "Ölfilter gewechselt",
            "Luftfilter geprüft/gewechselt",
            "Innenraumfilter gewechselt",
            "Bremsflüssigkeit geprüft",
            "Kühlmittel geprüft",
            "Scheibenwaschwasser aufgefüllt",
            "Beleuchtung geprüft",
            "Batterie geprüft",
            "Serviceintervall zurückgesetzt",
        ],
    },
    {
        "title": "Reifenwechsel",
        "items": [
            "Räder gewechselt",
            "Profiltiefe geprüft",
            "Reifendruck eingestellt",
            "Radschrauben nachgezogen (nach 50 km)",
            "Eingelagerte Räder gereinigt",
        ],
    },
    {
        "title": "MFK-Vorbereitung",
        "items": [
            "Beleuchtung & Blinker",
            "Bremsen (Beläge/Scheiben)",
            "Reifen (Profil, Alter)",
            "Scheibenwischer",
            "Auspuff dicht",
            "Keine Ölverluste",
            "Fahrzeugausweis dabei",
        ],
    },
]


def load_templates() -> list[dict]:
    path = os.environ.get("CHECKLIST_FILE")
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    return DEFAULT_TEMPLATES


@asynccontextmanager
async def lifespan(_: FastAPI):
    Base.metadata.create_all(engine)
    yield


app = FastAPI(title="Fahrzeugbuch", version="1.0.0", lifespan=lifespan)
DB = Annotated[Session, Depends(get_session)]
auth = [Depends(require_user)]


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/auth/config", response_model=schemas.AuthConfig)
def auth_config():
    """Öffentlich: OIDC-Parameter für die App (nur Server-URL muss konfiguriert werden)."""
    cfg = get_config()
    return {"issuer": cfg.issuer, "client_id": cfg.client_id, "scopes": "openid profile offline_access"}


@app.get("/api/me", dependencies=auth)
def me(user=Depends(require_user)):
    return {"sub": user.sub, "name": user.name}


def get_or_404(db: Session, model, obj_id: int):
    obj = db.get(model, obj_id)
    if obj is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, f"{model.__name__} {obj_id} nicht gefunden")
    return obj


# ---------- Fahrzeuge ----------
@app.get("/api/vehicles", response_model=list[schemas.VehicleOut], dependencies=auth)
def list_vehicles(db: DB):
    return db.scalars(select(models.Vehicle).order_by(models.Vehicle.name)).all()


@app.post("/api/vehicles", response_model=schemas.VehicleOut, status_code=201, dependencies=auth)
def create_vehicle(data: schemas.VehicleIn, db: DB):
    v = models.Vehicle(**data.model_dump())
    db.add(v)
    db.commit()
    return v


@app.get("/api/vehicles/{vid}", response_model=schemas.VehicleOut, dependencies=auth)
def get_vehicle(vid: int, db: DB):
    return get_or_404(db, models.Vehicle, vid)


@app.put("/api/vehicles/{vid}", response_model=schemas.VehicleOut, dependencies=auth)
def update_vehicle(vid: int, data: schemas.VehicleIn, db: DB):
    v = get_or_404(db, models.Vehicle, vid)
    for k, val in data.model_dump().items():
        setattr(v, k, val)
    db.commit()
    return v


@app.delete("/api/vehicles/{vid}", status_code=204, dependencies=auth)
def delete_vehicle(vid: int, db: DB):
    db.delete(get_or_404(db, models.Vehicle, vid))
    db.commit()
    return Response(status_code=204)


@app.get("/api/vehicles/{vid}/stats", response_model=schemas.Stats, dependencies=auth)
def get_stats(vid: int, db: DB):
    return vehicle_stats(get_or_404(db, models.Vehicle, vid))


# ---------- Kilometerstände ----------
@app.get("/api/vehicles/{vid}/odometer", response_model=list[schemas.OdometerOut], dependencies=auth)
def list_odometer(vid: int, db: DB):
    get_or_404(db, models.Vehicle, vid)
    q = select(models.OdometerReading).where(models.OdometerReading.vehicle_id == vid)
    return db.scalars(q.order_by(models.OdometerReading.date.desc(), models.OdometerReading.km.desc())).all()


@app.post("/api/vehicles/{vid}/odometer", response_model=schemas.OdometerOut, status_code=201, dependencies=auth)
def create_odometer(vid: int, data: schemas.OdometerIn, db: DB):
    get_or_404(db, models.Vehicle, vid)
    o = models.OdometerReading(vehicle_id=vid, **data.model_dump())
    db.add(o)
    db.commit()
    return o


@app.put("/api/odometer/{oid}", response_model=schemas.OdometerOut, dependencies=auth)
def update_odometer(oid: int, data: schemas.OdometerIn, db: DB):
    o = get_or_404(db, models.OdometerReading, oid)
    for k, val in data.model_dump().items():
        setattr(o, k, val)
    db.commit()
    return o


@app.delete("/api/odometer/{oid}", status_code=204, dependencies=auth)
def delete_odometer(oid: int, db: DB):
    db.delete(get_or_404(db, models.OdometerReading, oid))
    db.commit()
    return Response(status_code=204)


# ---------- Tankvorgänge ----------
@app.get("/api/vehicles/{vid}/fuel", response_model=list[schemas.FuelOut], dependencies=auth)
def list_fuel(vid: int, db: DB):
    get_or_404(db, models.Vehicle, vid)
    q = select(models.FuelEntry).where(models.FuelEntry.vehicle_id == vid)
    return db.scalars(q.order_by(models.FuelEntry.km.desc(), models.FuelEntry.date.desc())).all()


@app.post("/api/vehicles/{vid}/fuel", response_model=schemas.FuelOut, status_code=201, dependencies=auth)
def create_fuel(vid: int, data: schemas.FuelIn, db: DB):
    get_or_404(db, models.Vehicle, vid)
    f = models.FuelEntry(vehicle_id=vid, **data.model_dump())
    db.add(f)
    db.commit()
    return f


@app.put("/api/fuel/{fid}", response_model=schemas.FuelOut, dependencies=auth)
def update_fuel(fid: int, data: schemas.FuelIn, db: DB):
    f = get_or_404(db, models.FuelEntry, fid)
    for k, val in data.model_dump().items():
        setattr(f, k, val)
    db.commit()
    return f


@app.delete("/api/fuel/{fid}", status_code=204, dependencies=auth)
def delete_fuel(fid: int, db: DB):
    db.delete(get_or_404(db, models.FuelEntry, fid))
    db.commit()
    return Response(status_code=204)


# ---------- Wartung ----------
@app.get("/api/checklist-templates", response_model=list[schemas.ChecklistTemplate], dependencies=auth)
def checklist_templates():
    return load_templates()


@app.get("/api/vehicles/{vid}/maintenance", response_model=list[schemas.MaintenanceOut], dependencies=auth)
def list_maintenance(vid: int, db: DB):
    get_or_404(db, models.Vehicle, vid)
    q = select(models.Maintenance).where(models.Maintenance.vehicle_id == vid)
    return db.scalars(q.order_by(models.Maintenance.date.desc(), models.Maintenance.id.desc())).all()


def _apply_maintenance(m: models.Maintenance, data: schemas.MaintenanceIn) -> None:
    for k, val in data.model_dump(exclude={"items"}).items():
        setattr(m, k, val)
    m.items = [models.MaintenanceItem(label=i.label, done=i.done, position=n) for n, i in enumerate(data.items)]


@app.post(
    "/api/vehicles/{vid}/maintenance", response_model=schemas.MaintenanceOut, status_code=201, dependencies=auth
)
def create_maintenance(vid: int, data: schemas.MaintenanceIn, db: DB):
    get_or_404(db, models.Vehicle, vid)
    m = models.Maintenance(vehicle_id=vid)
    _apply_maintenance(m, data)
    db.add(m)
    db.commit()
    return m


@app.get("/api/maintenance/{mid}", response_model=schemas.MaintenanceOut, dependencies=auth)
def get_maintenance(mid: int, db: DB):
    return get_or_404(db, models.Maintenance, mid)


@app.put("/api/maintenance/{mid}", response_model=schemas.MaintenanceOut, dependencies=auth)
def update_maintenance(mid: int, data: schemas.MaintenanceIn, db: DB):
    m = get_or_404(db, models.Maintenance, mid)
    _apply_maintenance(m, data)
    db.commit()
    return m


@app.delete("/api/maintenance/{mid}", status_code=204, dependencies=auth)
def delete_maintenance(mid: int, db: DB):
    db.delete(get_or_404(db, models.Maintenance, mid))
    db.commit()
    return Response(status_code=204)


@app.patch("/api/maintenance-items/{iid}", response_model=schemas.ItemOut, dependencies=auth)
def toggle_item(iid: int, data: schemas.ItemPatch, db: DB):
    item = get_or_404(db, models.MaintenanceItem, iid)
    item.done = data.done
    db.commit()
    return item
