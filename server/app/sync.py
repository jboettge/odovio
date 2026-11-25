"""Offline-Sync: Push (Ops aus der App-Outbox) und Pull (Änderungen seit Cursor).

- IDs erzeugt der Client (UUID) → Anlegen offline ohne Kollision.
- Idempotent über `op_id` (Wiederholung nach Verbindungsabbruch ist harmlos).
- Konflikte (base_version ≠ aktuelle Version): letzte Änderung gewinnt, wird aber als
  `conflict` markiert; die überschriebene Version bleibt in der Revisionskette erhalten.
- Löschen = Stornieren (Soft-Delete), nie physisch.
- Entitätsspezifische Regeln (z. B. Monatsabschluss bei Fahrten) als Hook je Entität (`HOOKS`);
  serverseitig geschriebene Entitäten (`SERVER_ONLY`) werden per Sync nur geliefert, nie angenommen.
"""
import datetime as dt
import logging
from collections.abc import Callable

from pydantic import BaseModel, ValidationError
from sqlalchemy import select
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from . import models, schemas
from .attachments import blob_path
from .audit import append_revision
from .auth import User

# Verweis auf ein anderes Objekt desselben Mandanten: (Feld, Modell, Pflicht).
# Pflicht-Verweise müssen immer existieren; optionale nur, wenn der Wert nicht None ist.
# Stornierte Ziele sind zulässig (Altdaten bleiben editierbar).
Ref = tuple[str, type, bool]

# entity -> (Modell, Schema, Verweise)
ENTITIES: dict[str, tuple[type, type[BaseModel], tuple[Ref, ...]]] = {
    "vehicle": (models.Vehicle, schemas.VehicleData, ()),
    "odometer": (models.OdometerReading, schemas.OdometerData, (("vehicle_id", models.Vehicle, True),)),
    "fuel": (models.FuelEntry, schemas.FuelData, (("vehicle_id", models.Vehicle, True),)),
    "maintenance": (models.Maintenance, schemas.MaintenanceData, (("vehicle_id", models.Vehicle, True),)),
    "maintenance_item": (models.MaintenanceItem, schemas.MaintenanceItemData,
                         (("maintenance_id", models.Maintenance, True),)),
    "maintenance_material": (models.MaintenanceMaterial, schemas.MaintenanceMaterialData,
                             (("maintenance_id", models.Maintenance, True),
                              ("article_id", models.MaterialArticle, False))),
    "material_article": (models.MaterialArticle, schemas.MaterialArticleData,
                         (("vehicle_id", models.Vehicle, False),)),
    "customer": (models.Customer, schemas.CustomerData, ()),
    "place": (models.Place, schemas.PlaceData, (("customer_id", models.Customer, False),)),
    "trip": (models.Trip, schemas.TripData,
             (("vehicle_id", models.Vehicle, True),
              ("start_place_id", models.Place, False),
              ("end_place_id", models.Place, False),
              ("customer_id", models.Customer, False),
              ("split_of", models.Trip, False))),
    "purpose_rule": (models.PurposeRule, schemas.PurposeRuleData,
                     (("from_place_id", models.Place, False),
                      ("to_place_id", models.Place, False),
                      ("vehicle_id", models.Vehicle, False),
                      ("result_customer_id", models.Customer, False))),
    "tax_param": (models.TaxParam, schemas.TaxParamData, ()),
    "trip_period": (models.TripPeriod, schemas.TripPeriodData, (("vehicle_id", models.Vehicle, True),)),
    "attachment": (models.Attachment, schemas.AttachmentData,
                   (("fuel_id", models.FuelEntry, False),
                    ("maintenance_id", models.Maintenance, False),
                    ("vehicle_id", models.Vehicle, False))),
}
SERVER_ONLY = {"trip_period"}
log = logging.getLogger("fahrzeugbuch.sync")

CHANGE_KEYS = {
    "vehicle": "vehicles", "odometer": "odometer", "fuel": "fuel",
    "maintenance": "maintenance", "maintenance_item": "maintenance_items",
    "maintenance_material": "maintenance_materials", "material_article": "material_articles",
    "customer": "customers", "place": "places", "trip": "trips", "purpose_rule": "purpose_rules",
    "tax_param": "tax_params", "trip_period": "trip_periods", "attachment": "attachments",
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


# ---------- entitätsspezifische Regeln ----------
# Hook(db, tenant, bestehendes Objekt | None, validierte Daten | None (= Storno)) → Daten.
# Läuft nach Validierung + Verweisprüfung, vor dem Schreiben; `Rejected` verwirft nur diese Op.
Hook = Callable[[Session, models.Tenant, object | None, BaseModel | None], BaseModel | None]


def closed_period(db: Session, tenant_id: int, vehicle_id: str, month: str) -> models.TripPeriod | None:
    return db.scalar(select(models.TripPeriod).where(
        models.TripPeriod.tenant_id == tenant_id, models.TripPeriod.vehicle_id == vehicle_id,
        models.TripPeriod.month == month, models.TripPeriod.status == "closed",
        models.TripPeriod.deleted.is_(False)))


def _trip_rules(db: Session, tenant: models.Tenant, obj, data):
    """Monatsabschluss: abgeschlossene Fahrten sind nur noch stornierbar; neue Fahrten/Änderungen in
    einem abgeschlossenen Monat nur mit Begründung (`note`) und werden sofort `locked`."""
    if data is None:            # Storno ist immer erlaubt (auch locked)
        return None
    if obj is not None and obj.status == "locked":
        raise Rejected("Monat abgeschlossen")
    if data.status == "locked":
        raise Rejected("Status locked setzt nur der Server (Monatsabschluss)")
    touched = {(data.vehicle_id, data.start_at[:7])}
    if obj is not None:
        touched.add((obj.vehicle_id, obj.start_at[:7]))
    if any(closed_period(db, tenant.id, v, m) for v, m in touched):
        if not (data.note or "").strip():
            raise Rejected("Monat abgeschlossen: Korrektur nur mit Begründung (note)")
        data = data.model_copy(update={"status": "locked"})
    return data


def _place_rules(db: Session, tenant: models.Tenant, obj, data):
    if data is not None and data.kind == "home" and (data.lat is not None or data.lon is not None):
        raise Rejected("Wohnort-Koordinaten bleiben auf dem Gerät")
    return data


def _attachment_rules(db: Session, tenant: models.Tenant, obj, data):
    """Belege: Ist die Datei hochgeladen, sind Prüfsumme/Typ/Grösse festgeschrieben (sonst würde die
    Integritätsprüfung die unveränderte Datei als verändert melden) → neuen Beleg anlegen.
    Ein angegebenes Fahrzeug muss zum Tankvorgang bzw. zur Wartung passen."""
    if data is None:            # Storno: Datei bleibt erhalten
        return None
    if obj is not None and (obj.sha256, obj.mime, obj.size) != (data.sha256, data.mime, data.size) \
            and blob_path(tenant.id, obj.id).is_file():
        raise Rejected("Datei bereits hochgeladen: sha256/mime/size unveränderlich (neuen Beleg anlegen)")
    if data.vehicle_id is not None:
        for field, model in (("fuel_id", models.FuelEntry), ("maintenance_id", models.Maintenance)):
            ref_id = getattr(data, field)
            if ref_id is not None and db.get(model, ref_id).vehicle_id != data.vehicle_id:
                raise Rejected(f"vehicle_id passt nicht zu {field}")
    return data


HOOKS: dict[str, Hook] = {"trip": _trip_rules, "place": _place_rules, "attachment": _attachment_rules}


def _apply(db: Session, tenant: models.Tenant, user: User, op: schemas.SyncOp) -> dict:
    model, schema, refs = ENTITIES[op.entity]
    base = {"op_id": op.op_id, "entity": op.entity, "id": op.id}
    if op.entity in SERVER_ONLY:
        raise Rejected(f"{op.entity} wird nur vom Server geschrieben")
    hook = HOOKS.get(op.entity)

    dup = db.scalar(
        select(models.Revision).where(models.Revision.tenant_id == tenant.id, models.Revision.op_id == op.op_id)
    )
    if dup is not None:
        obj = db.get(model, op.id)
        same = obj is not None and obj.tenant_id == tenant.id
        return {**base, "status": "duplicate", "version": obj.version if same else dup.version}

    obj = db.get(model, op.id)
    if obj is not None and obj.tenant_id != tenant.id:
        raise Rejected("ID bereits vergeben")
    conflict = obj is not None and op.base_version is not None and op.base_version != obj.version

    if op.action == "delete":
        if obj is None:
            raise Rejected("Objekt nicht gefunden")
        if obj.deleted:
            return {**base, "status": "noop", "version": obj.version}
        if hook:
            hook(db, tenant, obj, None)
        obj.deleted = True
        action = "delete"
    else:
        try:
            data = schema.model_validate(op.data)
        except ValidationError as e:
            raise Rejected("; ".join(f"{'.'.join(map(str, x['loc']))}: {x['msg']}" for x in e.errors())) from e
        for field, ref_model, required in refs:
            ref_id = getattr(data, field)
            if ref_id is None and not required:
                continue
            p = db.get(ref_model, ref_id)
            if p is None or p.tenant_id != tenant.id:
                raise Rejected(f"{'Übergeordnetes' if required else 'Referenziertes'} Objekt ({field}) fehlt")
        if hook:
            data = hook(db, tenant, obj, data)
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
        except SQLAlchemyError:
            # z. B. Wertebereich/Constraint: nur diese Op verwerfen, nicht den ganzen Batch
            sp.rollback()
            log.exception("Sync-Op %s verworfen", op.op_id)
            results.append({"op_id": op.op_id, "entity": op.entity, "id": op.id, "status": "rejected",
                            "error": "Datenbankfehler"})
    return results


def changes_since(db: Session, tenant: models.Tenant, since: int) -> dict:
    out: dict = {"cursor": tenant.seq}
    for entity, (model, schema, _) in ENTITIES.items():
        rows = db.scalars(
            select(model).where(model.tenant_id == tenant.id, model.last_seq > since).order_by(model.last_seq)
        )
        out[CHANGE_KEYS[entity]] = [entity_out(r, schema) for r in rows]
    return out


def record(db: Session, tenant: models.Tenant, user: User, entity: str, obj, action: str) -> models.Revision:
    """Serverseitige Änderung (z. B. Monatsabschluss) wie eine Sync-Op ins Journal schreiben.
    Aufrufer hält die Sperre auf der Mandantenzeile."""
    _, schema, _ = ENTITIES[entity]
    obj.version = (obj.version or 0) + 1
    rev = append_revision(db, tenant, entity=entity, entity_id=obj.id, version=obj.version, action=action,
                          data=snapshot(obj, schema), user=user)
    obj.last_seq = rev.seq
    db.flush()
    return rev
