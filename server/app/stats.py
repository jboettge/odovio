"""Verbrauch (Voll-zu-voll), Kosten, Fälligkeiten. Stornierte Einträge zählen nicht.

Wartungskosten: `Maintenance.cost` ist der erfasste Rechnungsbetrag. Fehlt er, zählt die
Materialsumme (Σ Menge × Einzelpreis der nicht stornierten Materialien mit Preis).

Verbrauch einer Etappe = alle seit der letzten Volltankung getankten Liter
(inkl. Teilbetankungen) / gefahrene km seit der letzten Volltankung. Eine weitere Volltankung beim gleichen
km-Stand (Tank war doch nicht voll, nachgetankt) zählt zur vorigen Etappe (Review S7).

Aktueller km-Stand = höchster Wert aus Anfangs-km, km-Ständen, Tankvorgängen, Wartungen und km-Beginn/-Ende der
nicht stornierten Fahrten (Review S18; sonst verpasste die Service-Fälligkeit gefahrene km ohne Tankung).
"""
import datetime as dt
from dataclasses import dataclass, field

from sqlalchemy import func, select, union_all
from sqlalchemy.orm import Session

from . import models, timeutil


@dataclass
class VehicleData:
    vehicle: models.Vehicle
    odometer: list[models.OdometerReading]
    fuel: list[models.FuelEntry]
    maintenance: list[models.Maintenance]
    items: dict[str, list[models.MaintenanceItem]]
    materials: dict[str, list[models.MaintenanceMaterial]] = field(default_factory=dict)
    trip_km: int | None = None          # höchster km-Beginn/-Ende der Fahrten (None = keine bzw. nicht geladen)

    def material_sum(self, maintenance_id: str) -> float:
        return material_sum(self.materials.get(maintenance_id, []))

    def maintenance_cost(self, m: models.Maintenance) -> float:
        """Rechnungsbetrag, sonst Materialsumme."""
        return m.cost if m.cost is not None else self.material_sum(m.id)

    @property
    def current_km(self) -> int:
        kms = [self.vehicle.initial_km]
        kms += [o.km for o in self.odometer] + [f.km for f in self.fuel]
        kms += [m.km for m in self.maintenance if m.km is not None]
        if self.trip_km is not None:
            kms.append(self.trip_km)
        return max(kms)


def load_vehicle(db: Session, tenant_id: int, vehicle_id: str, *, allow_deleted: bool = False,
                 date_from: dt.date | None = None, date_to: dt.date | None = None,
                 children: bool = True) -> VehicleData | None:
    """Fahrzeug mit nicht stornierten km-Ständen, Tankvorgängen, Wartungen (+ Checkpunkte/Material).

    allow_deleted: auch ein storniertes Fahrzeug (Berichte über abgeschlossene Zeiträume).
    date_from/date_to: nur Einträge im Zeitraum (Monatscheck/Abschluss), children=False: ohne
    Checkpunkte/Material."""
    v = db.get(models.Vehicle, vehicle_id)
    if v is None or v.tenant_id != tenant_id or (v.deleted and not allow_deleted):
        return None

    def rows(model):
        q = select(model).where(model.vehicle_id == vehicle_id, model.deleted.is_(False))
        if date_from is not None:
            q = q.where(model.date >= date_from)
        if date_to is not None:
            q = q.where(model.date <= date_to)
        return list(db.scalars(q))

    maint = rows(models.Maintenance)

    def load_children(model) -> dict[str, list]:
        out: dict[str, list] = {m.id: [] for m in maint}
        if maint and children:
            q = select(model).where(
                model.maintenance_id.in_(list(out.keys())), model.deleted.is_(False)
            ).order_by(model.position, model.id)
            for c in db.scalars(q):
                out[c.maintenance_id].append(c)
        return out

    trip_km = None
    if date_from is None and date_to is None:       # nur für den Gesamtstand (Fälligkeiten, Statistik)
        u = union_all(*_trip_kms(tenant_id, vehicle_id)).subquery()
        trip_km = db.scalar(select(func.max(u.c.km)))
    return VehicleData(v, rows(models.OdometerReading), rows(models.FuelEntry), maint,
                       load_children(models.MaintenanceItem), load_children(models.MaintenanceMaterial),
                       trip_km=trip_km)


def _trip_kms(tenant_id: int, vehicle_id: str | None = None) -> list:
    """Abfragen (vid, km) für km-Beginn und km-Ende der nicht stornierten Fahrten (für UNION ALL), optional
    je Fahrzeug."""
    def part(col):
        q = select(models.Trip.vehicle_id.label("vid"), col.label("km")).where(
            models.Trip.tenant_id == tenant_id, models.Trip.deleted.is_(False), col.is_not(None))
        return q if vehicle_id is None else q.where(models.Trip.vehicle_id == vehicle_id)
    return [part(models.Trip.km_start), part(models.Trip.km_end)]


def current_km_by_vehicle(db: Session, tenant_id: int) -> dict[str, int]:
    """Höchster km-Stand je Fahrzeug (km-Stände, Tankvorgänge, Wartungen, Fahrten) in einer Abfrage."""
    parts = [select(m.vehicle_id.label("vid"), m.km.label("km")).where(
        m.tenant_id == tenant_id, m.deleted.is_(False), m.km.is_not(None))
        for m in (models.OdometerReading, models.FuelEntry, models.Maintenance)]
    u = union_all(*parts, *_trip_kms(tenant_id)).subquery()
    return {vid: km for vid, km in db.execute(select(u.c.vid, func.max(u.c.km)).group_by(u.c.vid))}


def material_sum(materials: list[models.MaintenanceMaterial]) -> float:
    return sum(t for mat in materials if not mat.deleted and (t := mat.total) is not None)


def _point(date: dt.date, km: int, dist: int, liters: float, cost: float) -> dict:
    return {"date": date, "km": km, "distance": dist, "liters": round(liters, 2), "cost": round(cost, 2),
            "consumption": round(liters / dist * 100, 2), "cost_per_km": round(cost / dist, 3)}


def consumption_points(entries: list[models.FuelEntry]) -> list[dict]:
    points: list[dict] = []
    prev_full = None
    acc_l = acc_c = 0.0
    last_l = last_c = 0.0          # ungerundete Summen der letzten Etappe (Nachtanken beim gleichen km)
    for e in sorted(entries, key=lambda x: (x.km, x.date, x.id)):
        if prev_full is None:
            if e.full_tank:
                prev_full = e
            continue
        acc_l += e.liters
        acc_c += e.price_total
        if not e.full_tank:
            continue
        dist = e.km - prev_full.km
        if dist > 0:
            last_l, last_c = acc_l, acc_c
            points.append(_point(e.date, e.km, dist, last_l, last_c))
        elif points and points[-1]["km"] == e.km:
            # erneute Volltankung beim gleichen km: der Tank war nicht voll → Liter gehören zur vorigen Etappe
            last_l, last_c = last_l + acc_l, last_c + acc_c
            prev = points[-1]
            points[-1] = _point(prev["date"], e.km, prev["distance"], last_l, last_c)
        acc_l = acc_c = 0.0
        prev_full = e
    return points


def due_items(data: VehicleData, today: dt.date | None = None) -> list[dict]:
    """Je Wartungstitel die jüngste Wartung mit gesetzter Fälligkeit."""
    today = today or timeutil.today()        # APP_TIMEZONE (S9)
    current = data.current_km
    latest: dict[str, models.Maintenance] = {}
    for m in sorted(data.maintenance, key=lambda x: (x.date, x.id)):
        latest[m.title.strip().lower()] = m
    result = []
    for m in latest.values():
        if m.next_due_km is None and m.next_due_date is None:
            continue
        overdue = (m.next_due_km is not None and current >= m.next_due_km) or (
            m.next_due_date is not None and today >= m.next_due_date
        )
        result.append({
            "maintenance_id": m.id, "title": m.title, "next_due_km": m.next_due_km,
            "next_due_date": m.next_due_date, "overdue": overdue,
        })
    return sorted(result, key=lambda d: (not d["overdue"], d["next_due_date"] or dt.date.max))


def summarize(points: list[dict]) -> dict:
    dist = sum(p["distance"] for p in points)
    liters = sum(p["liters"] for p in points)
    cost = sum(p["cost"] for p in points)
    return {
        "avg_consumption": round(liters / dist * 100, 2) if dist else None,
        "avg_liters_per_km": round(liters / dist, 4) if dist else None,
        "avg_cost_per_km": round(cost / dist, 3) if dist else None,
    }


def vehicle_stats(data: VehicleData) -> dict:
    points = consumption_points(data.fuel)
    return {
        "current_km": data.current_km,
        "driven_km": data.current_km - data.vehicle.initial_km,
        **summarize(points),
        "total_liters": round(sum(f.liters for f in data.fuel), 2),
        "total_fuel_cost": round(sum(f.price_total for f in data.fuel), 2),
        "total_maintenance_cost": round(sum(data.maintenance_cost(m) for m in data.maintenance), 2),
        "points": points,
        "due": due_items(data),
    }
