"""Fahrtenbuch: km-Kette, Odometer-Abgleich, Monatsabschluss.

km je Fahrt: Tacho (km_end − km_start) ist massgebend (Konzept Entscheid 2); fehlt er, zählt die
Routen-, sonst die GPS-Distanz.

Odometer-Abgleich eines Monats: Die km-Stände aus km-Ständen/Tankvorgängen/Wartungen im Monat
spannen ein Intervall [min, max] auf (odometer_km = max − min). Fahrten mit Tacho-Werten zählen mit
ihrem Anteil innerhalb dieses Intervalls, Fahrten ohne Tacho-Werte mit ihrer Distanz, wenn sie
zwischen dem ersten und letzten Ablesedatum liegen. Abweichung > max(5 km, 2 %) → nicht ok
(fehlende Fahrten oder falsche km-Stände).
"""
import datetime as dt
import json
import logging
import os
import urllib.request

from sqlalchemy import select
from sqlalchemy.orm import Session

from . import models
from .auth import User
from .integrity import maybe_anchor, signing_key
from .stats import VehicleData
from .sync import closed_period, entity_out, record, ENTITIES

log = logging.getLogger("fahrzeugbuch.trips")

KM_CATEGORIES = ("business", "private", "commute", "field")
TOLERANCE_KM, TOLERANCE_PCT = 5, 0.02


class PeriodError(Exception):
    """Abschluss nicht möglich (→ HTTP 409)."""

    def __init__(self, detail: dict):
        super().__init__(detail.get("message"))
        self.detail = detail


def parse_ts(v: str) -> dt.datetime:
    return dt.datetime.fromisoformat(v)


def trip_km(t: models.Trip) -> float:
    if t.km_start is not None and t.km_end is not None:
        return float(t.km_end - t.km_start)
    if t.distance_route is not None:
        return float(t.distance_route)
    return float(t.distance_gps or 0.0)


def needs_review(t: models.Trip) -> bool:
    return t.status not in ("confirmed", "locked") or t.category == "unknown"


def _sorted(trips) -> list[models.Trip]:
    return sorted(trips, key=lambda t: (parse_ts(t.start_at), t.id))


def _vehicle_trips(tenant_id: int, vehicle_id: str):
    return select(models.Trip).where(
        models.Trip.tenant_id == tenant_id, models.Trip.vehicle_id == vehicle_id, models.Trip.deleted.is_(False))


def trips_between(db: Session, tenant_id: int, vehicle_id: str, date_from: dt.date, date_to: dt.date
                  ) -> list[models.Trip]:
    """Nicht stornierte Fahrten mit lokalem Startdatum im Zeitraum, chronologisch.
    `start_at` ist normalisiertes ISO-8601 → Textvergleich mit dem Datumspräfix ist exakt."""
    upper = (date_to + dt.timedelta(days=1)).isoformat()
    q = _vehicle_trips(tenant_id, vehicle_id).where(models.Trip.start_at >= date_from.isoformat(),
                                                    models.Trip.start_at < upper)
    return _sorted(db.scalars(q))


def month_bounds(month: str) -> tuple[dt.date, dt.date]:
    y, m = map(int, month.split("-"))
    first = dt.date(y, m, 1)
    nxt = dt.date(y + (m == 12), m % 12 + 1, 1)
    return first, nxt - dt.timedelta(days=1)


def trips_in_month(db: Session, tenant_id: int, vehicle_id: str, month: str) -> list[models.Trip]:
    return trips_between(db, tenant_id, vehicle_id, *month_bounds(month))


def previous_trip(db: Session, tenant_id: int, vehicle_id: str, before: dt.date) -> models.Trip | None:
    """Letzte Fahrt vor `before` (Textsortierung nur grob wegen Offsets → Feinsortierung in Python)."""
    q = _vehicle_trips(tenant_id, vehicle_id).where(models.Trip.start_at < before.isoformat()) \
        .order_by(models.Trip.start_at.desc()).limit(20)
    prev = _sorted(db.scalars(q))
    return prev[-1] if prev else None


def km_gaps(trips: list[models.Trip], previous: models.Trip | None = None) -> list[dict]:
    """Lücke, wenn km_end(n) ≠ km_start(n+1) (negativ = Überschneidung)."""
    chain = ([previous] if previous is not None else []) + trips
    gaps = []
    for a, b in zip(chain, chain[1:]):
        if a.km_end is not None and b.km_start is not None and a.km_end != b.km_start:
            gaps.append({"after_trip_id": a.id, "before_trip_id": b.id, "km_from": a.km_end, "km_to": b.km_start,
                         "km": b.km_start - a.km_end})
    return gaps


def _mismatches(trips: list[models.Trip]) -> list[dict]:
    out = []
    for t in trips:
        if t.km_start is None or t.km_end is None:
            out.append({"trip_id": t.id, "reason": "km-Stand Beginn/Ende fehlt"})
        else:
            tacho = t.km_end - t.km_start
            for label, d in (("Routendistanz", t.distance_route), ("GPS-Distanz", t.distance_gps)):
                if d is not None and abs(d - tacho) > max(TOLERANCE_KM, 0.1 * tacho):
                    out.append({"trip_id": t.id, "reason": f"{label} {d:.1f} km weicht vom km-Stand ({tacho} km) ab"})
        if t.end_at is None:
            out.append({"trip_id": t.id, "reason": "Endzeit fehlt"})
        if t.category == "business" and not (t.purpose or "").strip() and not t.customer_id:
            out.append({"trip_id": t.id, "reason": "Zweck/Kunde fehlt (geschäftlich)"})
    return out


def odometer_check(data: VehicleData, trips: list[models.Trip], first: dt.date, last: dt.date) -> dict:
    readings = sorted(
        [(o.date, o.km) for o in data.odometer] + [(f.date, f.km) for f in data.fuel]
        + [(m.date, m.km) for m in data.maintenance if m.km is not None])
    readings = [(d, k) for d, k in readings if first <= d <= last]
    trip_sum = round(sum(trip_km(t) for t in trips), 1)
    if len(readings) < 2 or max(k for _, k in readings) == min(k for _, k in readings):
        return {"trip_km": trip_sum, "odometer_km": None, "diff_km": None, "ok": None,
                "readings": len(readings), "note": "Zu wenige km-Stände im Monat für den Abgleich"}
    lo, hi = min(k for _, k in readings), max(k for _, k in readings)
    d_lo, d_hi = readings[0][0].isoformat(), readings[-1][0].isoformat()
    covered = 0.0
    for t in trips:
        if t.km_start is not None and t.km_end is not None:
            covered += max(0, min(t.km_end, hi) - max(t.km_start, lo))
        elif d_lo < t.start_at[:10] < d_hi:
            covered += trip_km(t)
    odo = hi - lo
    diff = round(covered - odo, 1)
    return {"trip_km": round(covered, 1), "odometer_km": odo, "diff_km": diff,
            "ok": abs(diff) <= max(TOLERANCE_KM, TOLERANCE_PCT * odo), "readings": len(readings),
            "note": None}


def check_month(db: Session, tenant: models.Tenant, data: VehicleData, month: str) -> dict:
    first, last = month_bounds(month)
    trips = trips_in_month(db, tenant.id, data.vehicle.id, month)
    previous = previous_trip(db, tenant.id, data.vehicle.id, first)
    period = closed_period(db, tenant.id, data.vehicle.id, month)
    return {
        "month": month,
        "trips": len(trips),
        "gaps": km_gaps(trips, previous),
        "mismatches": _mismatches(trips),
        "odometer_check": odometer_check(data, trips, first, last),
        "unconfirmed": sum(1 for t in trips if needs_review(t)),
        "closed": period is not None,
    }


def km_by_category(trips: list[models.Trip]) -> dict[str, float]:
    out = {c: 0.0 for c in (*KM_CATEGORIES, "unknown")}
    for t in trips:
        out[t.category] = out.get(t.category, 0.0) + trip_km(t)
    return {c: round(v, 1) for c, v in out.items()}


def close_period(db: Session, tenant: models.Tenant, user: User, data: VehicleData, month: str,
                 force: bool, reason: str | None) -> dict:
    """Monat abschliessen. Aufrufer hält die Sperre auf der Mandantenzeile und committet."""
    vid = data.vehicle.id
    existing = db.scalar(select(models.TripPeriod).where(
        models.TripPeriod.tenant_id == tenant.id, models.TripPeriod.vehicle_id == vid,
        models.TripPeriod.month == month))
    if existing is not None and not existing.deleted and existing.status == "closed":
        raise PeriodError({"message": "Monat bereits abgeschlossen", "period": entity_out(
            existing, ENTITIES["trip_period"][1])})
    first, _ = month_bounds(month)
    trips = trips_in_month(db, tenant.id, vid, month)
    open_trips = [t for t in trips if needs_review(t)]
    if open_trips:
        raise PeriodError({"message": "Nicht alle Fahrten bestätigt", "trips": [
            {"id": t.id, "start_at": t.start_at, "status": t.status, "category": t.category} for t in open_trips]})
    gaps = km_gaps(trips, previous_trip(db, tenant.id, vid, first))
    reason = (reason or "").strip() or None
    if gaps and not force:
        raise PeriodError({"message": "km-Lücken vorhanden", "gaps": gaps})
    if gaps and (reason is None or len(reason) < 10):
        raise PeriodError({"message": "Erzwungener Abschluss braucht eine Begründung (mind. 10 Zeichen)",
                           "gaps": gaps})

    locked = 0
    for t in trips:
        if t.status != "locked":
            t.status = "locked"
            record(db, tenant, user, "trip", t, "update")
            locked += 1

    kms = km_by_category(trips)
    starts = [t.km_start for t in trips if t.km_start is not None]
    ends = [t.km_end for t in trips if t.km_end is not None]
    period = existing or models.TripPeriod(id=models.new_id(), tenant_id=tenant.id, vehicle_id=vid, month=month,
                                           version=0, deleted=False, last_seq=0)
    period.deleted = False
    period.status = "closed"
    period.closed_by = user.name or user.sub
    period.closed_at = dt.datetime.now(dt.UTC).isoformat(timespec="seconds")
    # Der erzwungene Anker folgt direkt auf die Revision des Abschlusses → seine Seq ist bekannt.
    period.anchor_seq = tenant.seq + 1 if signing_key() is not None else None
    period.km_start = min(starts) if starts else None
    period.km_end = max(ends) if ends else None
    period.trips_count = len(trips)
    for c in KM_CATEGORIES:
        setattr(period, f"{c}_km", kms[c])
    note = f"Erzwungen trotz {len(gaps)} km-Lücke(n): {reason}" if gaps else None
    period.note = note[:500] if note else None
    if existing is None:
        db.add(period)
    record(db, tenant, user, "trip_period", period, "create" if existing is None else "update")
    anchor = maybe_anchor(db, tenant, force=True)
    if period.anchor_seq is not None and (anchor is None or anchor.seq != period.anchor_seq):
        raise RuntimeError("Anker des Monatsabschlusses konnte nicht gesetzt werden")
    return {"period": entity_out(period, ENTITIES["trip_period"][1]), "locked_trips": locked,
            "gaps": gaps, "forced": bool(gaps), "cursor": tenant.seq,
            "anchor": None if anchor is None else {"seq": anchor.seq, "head_hash": anchor.head_hash,
                                                   "created_at": anchor.created_at, "key_id": anchor.key_id}}


def webhook_url() -> str | None:
    return os.environ.get("N8N_WEBHOOK_URL", "").strip() or None


def send_webhook(url: str, payload: dict) -> None:
    """Benachrichtigung (z. B. n8n → Paperless). Fehler werden nur protokolliert."""
    try:
        req = urllib.request.Request(url, data=json.dumps(payload).encode(), method="POST",
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=5) as r:
            r.read(1024)
    except Exception:  # noqa: BLE001 – Abschluss ist bereits gespeichert
        log.exception("Webhook %s fehlgeschlagen", url)
