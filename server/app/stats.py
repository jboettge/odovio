"""Verbrauchsberechnung nach Voll-zu-voll-Methode.

Verbrauch einer Etappe = alle seit der letzten Volltankung getankten Liter
(inkl. Teilbetankungen) / gefahrene km seit der letzten Volltankung.
"""
from datetime import date

from . import models


def consumption_points(entries: list[models.FuelEntry]) -> list[dict]:
    points: list[dict] = []
    prev_full: models.FuelEntry | None = None
    acc_l = acc_c = 0.0
    for e in sorted(entries, key=lambda x: (x.km, x.date, x.id or 0)):
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
            points.append(
                {
                    "date": e.date,
                    "km": e.km,
                    "distance": dist,
                    "liters": round(acc_l, 2),
                    "cost": round(acc_c, 2),
                    "consumption": round(acc_l / dist * 100, 2),
                    "cost_per_km": round(acc_c / dist, 3),
                }
            )
        acc_l = acc_c = 0.0
        prev_full = e
    return points


def due_items(vehicle: models.Vehicle, today: date | None = None) -> list[dict]:
    """Je Wartungstitel die jüngste Wartung mit gesetzter Fälligkeit."""
    today = today or date.today()
    current = vehicle.current_km
    latest: dict[str, models.Maintenance] = {}
    for m in sorted(vehicle.maintenance, key=lambda x: (x.date, x.id)):
        latest[m.title.strip().lower()] = m
    result = []
    for m in latest.values():
        if m.next_due_km is None and m.next_due_date is None:
            continue
        overdue = (m.next_due_km is not None and current >= m.next_due_km) or (
            m.next_due_date is not None and today >= m.next_due_date
        )
        result.append(
            {
                "maintenance_id": m.id,
                "title": m.title,
                "next_due_km": m.next_due_km,
                "next_due_date": m.next_due_date,
                "overdue": overdue,
            }
        )
    return sorted(result, key=lambda d: (not d["overdue"], d["next_due_date"] or date.max))


def vehicle_stats(vehicle: models.Vehicle) -> dict:
    points = consumption_points(vehicle.fuel)
    dist = sum(p["distance"] for p in points)
    liters = sum(p["liters"] for p in points)
    cost = sum(p["cost"] for p in points)
    return {
        "current_km": vehicle.current_km,
        "driven_km": vehicle.current_km - vehicle.initial_km,
        "avg_consumption": round(liters / dist * 100, 2) if dist else None,
        "avg_liters_per_km": round(liters / dist, 4) if dist else None,
        "avg_cost_per_km": round(cost / dist, 3) if dist else None,
        "total_liters": round(sum(f.liters for f in vehicle.fuel), 2),
        "total_fuel_cost": round(sum(f.price_total for f in vehicle.fuel), 2),
        "total_maintenance_cost": round(sum(m.cost or 0 for m in vehicle.maintenance), 2),
        "points": points,
        "due": due_items(vehicle),
    }
