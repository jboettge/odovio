"""Offline-Sync: Push (Ops aus der App-Outbox) und Pull (Änderungen seit Cursor).

- IDs erzeugt der Client (UUID) → Anlegen offline ohne Kollision.
- Idempotent über `op_id` (Wiederholung nach Verbindungsabbruch ist harmlos).
- Konflikte (base_version ≠ aktuelle Version): letzte Änderung gewinnt, wird aber als
  `conflict` markiert; die überschriebene Version bleibt in der Revisionskette erhalten.
- Löschen = Stornieren (Soft-Delete), nie physisch.
"""
import datetime as dt

from pydantic import BaseModel, ValidationError
from sqlalchemy import select
from sqlalchemy.orm import Session

from . import models, schemas
from .audit import append_revision
from .auth import User

# entity -> (Modell, Schema, (Eltern-Feld, Eltern-Modell) | None)
ENTITIES: dict[str, tuple[type, type[BaseModel], tuple[str, type] | None]] = {
    "vehicle": (models.Vehicle, schemas.VehicleData, None),
    "odometer": (models.OdometerReading, schemas.OdometerData, ("vehicle_id", models.Vehicle)),
    "fuel": (models.FuelEntry, schemas.FuelData, ("vehicle_id", models.Vehicle)),
    "maintenance": (models.Maintenance, schemas.MaintenanceData, ("vehicle_id", models.Vehicle)),
    "maintenance_item": (models.MaintenanceItem, schemas.MaintenanceItemData, ("maintenance_id", models.Maintenance)),
}
CHANGE_KEYS = {
    "vehicle": "vehicles", "odometer": "odometer", "fuel": "fuel",
    "maintenance": "maintenance", "maintenance_item": "maintenance_items",
}


class Rejected(Exception):
    pass


def _json(v):
    return v.isoformat() if isinstance(v, (dt.date, dt.datetime)) else v


def snapshot(obj, schema: type[BaseModel]) -> dict:
    data = {k: _json(getattr(obj, k)) for k in schema.model_fields}
    data["deleted"] = obj.deleted
    return data


def entity_out(obj, schema: type[BaseModel]) -> dict:
    return {"id": obj.id, "version": obj.version, **snapshot(obj, schema)}


def _apply(db: Session, tenant: models.Tenant, user: User, op: schemas.SyncOp) -> dict:
    model, schema, parent = ENTITIES[op.entity]
    base = {"op_id": op.op_id, "entity": op.entity, "id": op.id}

    dup = db.scalar(
        select(models.Revision).where(models.Revision.tenant_id == tenant.id, models.Revision.op_id == op.op_id)
    )
    if dup is not None:
        obj = db.get(model, op.id)
        return {**base, "status": "duplicate", "version": obj.version if obj else dup.version}

    obj = db.get(model, op.id)
    if obj is not None and obj.tenant_id != tenant.id:
        raise Rejected("ID gehört zu einem anderen Mandanten")
    conflict = obj is not None and op.base_version is not None and op.base_version != obj.version

    if op.action == "delete":
        if obj is None:
            raise Rejected("Objekt nicht gefunden")
        if obj.deleted:
            return {**base, "status": "noop", "version": obj.version}
        obj.deleted = True
        action = "delete"
    else:
        try:
            data = schema.model_validate(op.data)
        except ValidationError as e:
            raise Rejected("; ".join(f"{'.'.join(map(str, x['loc']))}: {x['msg']}" for x in e.errors())) from e
        if parent is not None:
            field, parent_model = parent
            p = db.get(parent_model, getattr(data, field))
            if p is None or p.tenant_id != tenant.id:
                raise Rejected(f"Übergeordnetes Objekt ({field}) fehlt")
        if obj is None:
            obj = model(id=op.id, tenant_id=tenant.id, version=0, deleted=False, last_seq=0)
            db.add(obj)
            action = "create"
        else:
            action = "update"
            obj.deleted = False
        for k, v in data.model_dump().items():
            setattr(obj, k, v)

    obj.version += 1
    rev = append_revision(
        db, tenant,
        entity=op.entity, entity_id=obj.id, version=obj.version, action=action,
        data=snapshot(obj, schema), user=user, client_ts=op.client_ts, op_id=op.op_id, conflict=conflict,
    )
    obj.last_seq = rev.seq
    db.flush()
    return {**base, "status": "conflict" if conflict else "applied", "version": obj.version}


def apply_ops(db: Session, tenant: models.Tenant, user: User, ops: list[schemas.SyncOp]) -> list[dict]:
    results = []
    for op in ops:
        sp = db.begin_nested()
        try:
            results.append(_apply(db, tenant, user, op))
            sp.commit()
        except Rejected as e:
            sp.rollback()
            results.append({"op_id": op.op_id, "entity": op.entity, "id": op.id, "status": "rejected",
                            "error": str(e)})
    return results


def changes_since(db: Session, tenant: models.Tenant, since: int) -> dict:
    out: dict = {"cursor": tenant.seq}
    for entity, (model, schema, _) in ENTITIES.items():
        rows = db.scalars(
            select(model).where(model.tenant_id == tenant.id, model.last_seq > since).order_by(model.last_seq)
        )
        out[CHANGE_KEYS[entity]] = [entity_out(r, schema) for r in rows]
    return out
