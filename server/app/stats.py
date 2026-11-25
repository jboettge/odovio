"""Verbrauch (Voll-zu-voll), Kosten, Fälligkeiten. Stornierte Einträge zählen nicht.

Verbrauch einer Etappe = alle seit der letzten Volltankung getankten Liter
(inkl. Teilbetankungen) / gefahrene km seit der letzten Volltankung.
"""
import datetime as dt
from dataclasses import dataclass

from sqlalchemy import select
from sqlalchemy.orm import Session

from . import models


@dataclass
class VehicleData:
    vehicle: models.Vehicle
    odometer: list[models.OdometerReading]
    fuel: list[models.FuelEntry]
    maintenance: list[models.Maintenance]
    items: dict[str, list[models.MaintenanceItem]]

    @property
    def current_km(self) -> int:
        kms = [self.vehicle.initial_km]
        kms += [o.km for o in self.odometer] + [f.km for f in self.fuel]
        kms += [m.km for m in self.maintenance if m.km is not None]
        return max(kms)


def load_vehicle(db: Session, tenant_id: int, vehicle_id: str) -> VehicleData | None:
    v = db.get(models.Vehicle, vehicle_id)
    if v is None or v.tenant_id != tenant_id or v.deleted:
        return None

    def rows(model):
        return list(db.scalars(select(model).where(model.vehicle_id == vehicle_id, model.deleted.is_(False))))

    maint = rows(models.Maintenance)
    items: dict[str, list[models.MaintenanceItem]] = {m.id: [] for m in maint}
    if maint:
        q = select(models.MaintenanceItem).where(
            models.MaintenanceItem.maintenance_id.in_(items.keys()), models.MaintenanceItem.deleted.is_(False)
        ).order_by(models.MaintenanceItem.position)
        for it in db.scalars(q):
            items[it.maintenance_id].append(it)
    return VehicleData(v, rows(models.OdometerReading), rows(models.FuelEntry), maint, items)


def consumption_points(entries: list[models.FuelEntry]) -> list[dict]:
    points: list[dict] = []
    prev_full = None
    acc_l = acc_c = 0.0
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
            points.append({
                "date": e.date, "km": e.km, "distance": dist,
                "liters": round(acc_l, 2), "cost": round(acc_c, 2),
                "consumption": round(acc_l / dist * 100, 2),
                "cost_per_km": round(acc_c / dist, 3),
            })
        acc_l = acc_c = 0.0
        prev_full = e
    return points


def due_items(data: VehicleData, today: dt.date | None = None) -> list[dict]:
    """Je Wartungstitel die jüngste Wartung mit gesetzter Fälligkeit."""
    today = today or dt.date.today()
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
        "total_maintenance_cost": round(sum(m.cost or 0 for m in data.maintenance), 2),
        "points": points,
        "due": due_items(data),
    }
