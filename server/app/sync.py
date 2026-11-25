"""Offline-Sync: Push (Ops aus der App-Outbox) und Pull (Änderungen seit Cursor).

- IDs erzeugt der Client (UUID) → Anlegen offline ohne Kollision.
- Idempotent über `op_id` (Wiederholung nach Verbindungsabbruch ist harmlos); eine wiederverwendete
  `op_id` für ein anderes Objekt wird abgelehnt.
- Konflikte (base_version ≠ aktuelle Version): letzte Änderung gewinnt, wird aber als
  `conflict` markiert; die überschriebene Version bleibt in der Revisionskette erhalten.
- Löschen = Stornieren (Soft-Delete), nie physisch.
- Abgeschlossene Monate: Stornos/Korrekturen nur mit Begründung (`reason` der Op, mind. 10 Zeichen;
  bei Fahrten genügt für Korrekturen weiterhin `note`). Die Summen des Abschlusses bleiben, der Abschluss
  zählt die Korrekturen (`trip_period.corrections`), die Begründung steht in der Revision.
- Nur Integritäts-/Datenfehler verwerfen eine einzelne Op; andere DB-Fehler (Verbindung, Serialisierung)
  brechen den ganzen Sync ab (→ 503, der Client wiederholt später).
- Entitätsspezifische Regeln (z. B. Monatsabschluss bei Fahrten) als Hook je Entität (`HOOKS`);
  serverseitig geschriebene Entitäten (`SERVER_ONLY`) werden per Sync nur geliefert, nie angenommen.
"""
import datetime as dt
import logging
from collections.abc import Callable
from dataclasses import dataclass, field

from pydantic import BaseModel, ValidationError
from sqlalchemy import select
from sqlalchemy.exc import DataError, IntegrityError
from sqlalchemy.orm import Session

from . import models, privacy, schemas
from .attachments import blob_path
from .audit import append_revision
from .auth import User
from .timeutil import local_month

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


MIN_REASON = 10
REVISION_META = ("storno_reason", "correction_reason")   # nur in Revisionen, nicht im Datensatz
PRIVATE_LABEL_MAX = 60
PRIVATE_FORBIDDEN = ("start_place_id", "end_place_id", "purpose", "customer_id", "track_hash",
                     "suggestion_purpose", "suggestion_customer_id")


def _json(v):
    return v.isoformat() if isinstance(v, (dt.date, dt.datetime)) else v


def snapshot(obj, schema: type[BaseModel]) -> dict:
    data = {k: _json(getattr(obj, k)) for k in schema.model_fields}
    data["deleted"] = obj.deleted
    return data


def entity_out(obj, schema: type[BaseModel]) -> dict:
    return {"id": obj.id, "version": obj.version, **snapshot(obj, schema)}


# ---------- entitätsspezifische Regeln ----------
@dataclass
class OpContext:
    """Kontext einer Op für die Hooks: Benutzer, Begründung, Zusatzangaben für die Revision und
    Folgeaktionen, die erst nach dem Schreiben der Revision laufen (z. B. Korrekturzähler)."""
    db: Session
    tenant: models.Tenant
    user: User
    op: schemas.SyncOp
    meta: dict = field(default_factory=dict)
    after: list[Callable[[], None]] = field(default_factory=list)

    @property
    def reason(self) -> str | None:
        r = (self.op.reason or "").strip()
        return r if len(r) >= MIN_REASON else None

    def require_reason(self, key: str, what: str) -> str:
        reason = self.reason
        if reason is None:
            raise Rejected(f"Begründung erforderlich: {what} (reason, mind. {MIN_REASON} Zeichen)")
        self.meta[key] = reason
        return reason

    def count_corrections(self, periods: list[models.TripPeriod]) -> None:
        def bump():
            for p in periods:
                p.corrections = (p.corrections or 0) + 1
                record(self.db, self.tenant, self.user, "trip_period", p, "update")
        self.after.append(bump)


# Hook(Kontext, bestehendes Objekt | None, validierte Daten | None (= Storno)) → Daten.
# Läuft nach Validierung + Verweisprüfung, vor dem Schreiben; `Rejected` verwirft nur diese Op.
Hook = Callable[[OpContext, object | None, BaseModel | None], BaseModel | None]


def closed_period(db: Session, tenant_id: int, vehicle_id: str, month: str) -> models.TripPeriod | None:
    return db.scalar(select(models.TripPeriod).where(
        models.TripPeriod.tenant_id == tenant_id, models.TripPeriod.vehicle_id == vehicle_id,
        models.TripPeriod.month == month, models.TripPeriod.status == "closed",
        models.TripPeriod.deleted.is_(False)))


def closed_periods(db: Session, tenant_id: int, touched: set[tuple[str, str]]) -> list[models.TripPeriod]:
    return [p for v, m in sorted(touched) if (p := closed_period(db, tenant_id, v, m)) is not None]


def customer_display(c: models.Customer | None) -> str | None:
    if c is None:
        return None
    return (f"{c.name} ({c.ref})" if c.ref else c.name)[:150]


def frozen_names(db: Session, t) -> dict:
    """Namen beim Abschluss einfrieren (Fahrt-Objekt oder TripData): Kundenname und leere Start-/Ziel-
    bezeichnungen aus dem Ort. Privatfahrten erhalten keine Orte."""
    private = t.category == "private" or t.private_mode
    out = {"customer_name": None if t.private_mode or not t.customer_id
           else customer_display(db.get(models.Customer, t.customer_id))}
    for side in ("start", "end"):
        label, pid = getattr(t, f"{side}_label"), getattr(t, f"{side}_place_id")
        if not label and pid and not private:
            place = db.get(models.Place, pid)
            if place is not None and not place.private:
                out[f"{side}_label"] = place.name[:200]
    return out


def _trip_rules(ctx: OpContext, obj, data):
    """Monatsabschluss: abgeschlossene Fahrten sind nur noch mit Begründung stornierbar; neue Fahrten/
    Änderungen in einem abgeschlossenen Monat nur mit Begründung (`note` oder `reason`) und sofort `locked`.
    Privatmodus: keine Orte, kein Zweck/Kunde/Track, Bezeichnungen nur kurz (Gemeinde).
    Fahrer (`driver_sub`/`driver_name`) setzt der Server beim Anlegen aus dem Token."""
    db, tenant = ctx.db, ctx.tenant
    if data is None:            # Storno
        periods = closed_periods(db, tenant.id, {(obj.vehicle_id, local_month(obj.start_at))})
        if obj.status == "locked" or periods:
            ctx.require_reason("storno_reason", "Storno im abgeschlossenen Monat")
            ctx.count_corrections(periods)
        return None
    if obj is not None and obj.status == "locked":
        raise Rejected("Monat abgeschlossen")
    if data.status == "locked":
        raise Rejected("Status locked setzt nur der Server (Monatsabschluss)")
    if data.private_mode:
        bad = [f for f in PRIVATE_FORBIDDEN if getattr(data, f) not in (None, "")]
        if bad:
            raise Rejected(f"Privatmodus: {', '.join(bad)} nicht erlaubt")
        for f in ("start_label", "end_label"):
            if len(getattr(data, f) or "") > PRIVATE_LABEL_MAX:
                raise Rejected(f"Privatmodus: {f} max. {PRIVATE_LABEL_MAX} Zeichen (nur Gemeinde)")
    name = (ctx.user.name or None) and ctx.user.name[:100]
    data = data.model_copy(update={
        "driver_sub": obj.driver_sub if obj is not None else ctx.user.sub,
        "driver_name": obj.driver_name if obj is not None else name,
        "customer_name": obj.customer_name if obj is not None else None,
    })
    touched = {(data.vehicle_id, local_month(data.start_at))}
    if obj is not None:
        touched.add((obj.vehicle_id, local_month(obj.start_at)))
    periods = closed_periods(db, tenant.id, touched)
    if periods:
        if not (data.note or "").strip() and ctx.reason is None:
            raise Rejected("Monat abgeschlossen: Korrektur nur mit Begründung (note)")
        if ctx.reason:
            ctx.meta["correction_reason"] = ctx.reason
        data = data.model_copy(update={"status": "locked"})
        data = data.model_copy(update=frozen_names(db, data))
        ctx.count_corrections(periods)
    return data


def _place_rules(ctx: OpContext, obj, data):
    if data is not None and (data.lat is not None or data.lon is not None):
        if data.kind == "home":
            raise Rejected("Wohnort-Koordinaten bleiben auf dem Gerät")
        if data.private:
            raise Rejected("Koordinaten privater Orte bleiben auf dem Gerät")
    return data


def _attachment_rules(ctx: OpContext, obj, data):
    """Belege: Ist die Datei hochgeladen, sind Prüfsumme/Typ/Grösse festgeschrieben (sonst würde die
    Integritätsprüfung die unveränderte Datei als verändert melden) → neuen Beleg anlegen.
    Ein angegebenes Fahrzeug muss zum Tankvorgang bzw. zur Wartung passen."""
    if data is None:            # Storno: Datei bleibt erhalten
        return None
    if obj is not None and (obj.sha256, obj.mime, obj.size) != (data.sha256, data.mime, data.size) \
            and blob_path(ctx.tenant.id, obj.id).is_file():
        raise Rejected("Datei bereits hochgeladen: sha256/mime/size unveränderlich (neuen Beleg anlegen)")
    if data.vehicle_id is not None:
        for fld, model in (("fuel_id", models.FuelEntry), ("maintenance_id", models.Maintenance)):
            ref_id = getattr(data, fld)
            if ref_id is not None and ctx.db.get(model, ref_id).vehicle_id != data.vehicle_id:
                raise Rejected(f"vehicle_id passt nicht zu {fld}")
    return data


def _reading_rules(ctx: OpContext, obj, data):
    """km-Stände, Tankvorgänge und Wartungen mit km-Stand gehören zum Odometer-Abgleich eines Monats:
    in einem abgeschlossenen Monat nur mit Begründung (`reason`) erfassen, ändern oder stornieren."""
    def month_of(x) -> set[tuple[str, str]]:
        if x is None or getattr(x, "km", None) is None:   # Wartung ohne km-Stand zählt nicht
            return set()
        return {(x.vehicle_id, f"{x.date:%Y-%m}")}

    periods = closed_periods(ctx.db, ctx.tenant.id, month_of(obj) | month_of(data))
    if periods:
        if data is None:
            ctx.require_reason("storno_reason", "Storno im abgeschlossenen Monat")
        else:
            ctx.require_reason("correction_reason", "Änderung im abgeschlossenen Monat")
        ctx.count_corrections(periods)
    return data


HOOKS: dict[str, Hook] = {"trip": _trip_rules, "place": _place_rules, "attachment": _attachment_rules,
                          "odometer": _reading_rules, "fuel": _reading_rules, "maintenance": _reading_rules}


def _apply(db: Session, tenant: models.Tenant, user: User, op: schemas.SyncOp) -> dict:
    model, schema, refs = ENTITIES[op.entity]
    base = {"op_id": op.op_id, "entity": op.entity, "id": op.id}
    if op.entity in SERVER_ONLY:
        raise Rejected(f"{op.entity} wird nur vom Server geschrieben")
    hook = HOOKS.get(op.entity)
    ctx = OpContext(db, tenant, user, op)

    dup = db.scalar(
        select(models.Revision).where(models.Revision.tenant_id == tenant.id, models.Revision.op_id == op.op_id)
    )
    if dup is not None:
        if (dup.entity, dup.entity_id) != (op.entity, op.id):
            raise Rejected("op_id bereits verwendet (anderes Objekt)")
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
            hook(ctx, obj, None)
        obj.deleted = True
        action = "delete"
    else:
        try:
            data = schema.model_validate(op.data)
        except ValidationError as e:
            raise Rejected("; ".join(f"{'.'.join(map(str, x['loc']))}: {x['msg']}" for x in e.errors())) from e
        for fld, ref_model, required in refs:
            ref_id = getattr(data, fld)
            if ref_id is None and not required:
                continue
            p = db.get(ref_model, ref_id)
            if p is None or p.tenant_id != tenant.id:
                raise Rejected(f"{'Übergeordnetes' if required else 'Referenziertes'} Objekt ({fld}) fehlt")
        if hook:
            data = hook(ctx, obj, data)
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
        data={**snapshot(obj, schema), **ctx.meta}, user=user, client_ts=op.client_ts, op_id=op.op_id,
        conflict=conflict,
    )
    obj.last_seq = rev.seq
    db.flush()
    for fn in ctx.after:
        fn()
    return {**base, "status": "conflict" if conflict else "applied", "version": obj.version}


def apply_ops(db: Session, tenant: models.Tenant, user: User, ops: list[schemas.SyncOp]) -> list[dict]:
    """Andere SQLAlchemy-Fehler als Integritäts-/Datenfehler (Verbindung, Serialisierung, Sperre) werden
    nicht abgefangen: der Aufrufer rollt die ganze Anfrage zurück (→ 503, Client wiederholt)."""
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
        except (IntegrityError, DataError):
            # Wertebereich/Constraint: nur diese Op verwerfen, nicht den ganzen Batch
            sp.rollback()
            log.exception("Sync-Op %s verworfen", op.op_id)
            results.append({"op_id": op.op_id, "entity": op.entity, "id": op.id, "status": "rejected",
                            "error": "Datenbankfehler"})
    return results


CHANGES_LIMIT, CHANGES_MAX = 2000, 5000


def changes_since(db: Session, tenant: models.Tenant, since: int, limit: int = CHANGES_LIMIT,
                  mask_private: bool = False) -> dict:
    """Änderungen mit last_seq > since, höchstens `limit` Zeilen über alle Typen.

    Jede Revision betrifft genau ein Objekt → last_seq ist je Mandant eindeutig. Je Tabelle werden die
    ersten limit+1 Zeilen gelesen; die global ersten `limit` liegen sicher darunter. Ist mehr da, ist
    cursor = höchste gelieferte last_seq (alles ≤ cursor ist vollständig geliefert) und has_more = True."""
    limit = max(1, min(limit, CHANGES_MAX))
    rows: list[tuple[int, str, object]] = []
    for entity, (model, _, _) in ENTITIES.items():
        q = select(model).where(model.tenant_id == tenant.id, model.last_seq > since) \
            .order_by(model.last_seq).limit(limit + 1)
        rows += [(r.last_seq, entity, r) for r in db.scalars(q)]
    rows.sort(key=lambda x: x[0])
    has_more = len(rows) > limit
    rows = rows[:limit]
    out: dict = {"cursor": rows[-1][0] if has_more else tenant.seq, "has_more": has_more}
    for entity in ENTITIES:
        out[CHANGE_KEYS[entity]] = []
    for _, entity, r in rows:
        data = entity_out(r, ENTITIES[entity][1])
        out[CHANGE_KEYS[entity]].append(privacy.mask(entity, data) if mask_private else data)
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
