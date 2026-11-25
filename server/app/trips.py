"""Fahrtenbuch: km-Kette, Odometer-Abgleich, Monatsabschluss.

km je Fahrt: Tacho (km_end − km_start) ist massgebend (Konzept Entscheid 2); fehlt er, zählt die
Routen-, sonst die GPS-Distanz.

Odometer-Abgleich eines Monats: Die km-Stände aus km-Ständen/Tankvorgängen/Wartungen im Monat
spannen ein Intervall [min, max] auf (odometer_km = max − min). Fahrten mit Tacho-Werten zählen mit
ihrem Anteil innerhalb dieses Intervalls, Fahrten ohne Tacho-Werte mit ihrer Distanz, wenn sie
zwischen dem ersten und letzten Ablesedatum liegen. Abweichung > max(5 km, 2 %) → nicht ok
(fehlende Fahrten oder falsche km-Stände).

Monatszuordnung und Zeiträume nach lokaler Zeit (APP_TIMEZONE, Default Europe/Zurich), siehe timeutil.
Abschluss nur für abgelaufene Monate; blockiert bei unbestätigten Fahrten, km-Lücken und unvollständigen
Fahrten (Zweck, km-Stand, Endzeit, geschätzter km-Stand) – Lücken/Mängel nur mit `force` + Begründung.
"""
import datetime as dt
import hashlib
import hmac
import itertools
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
from .sync import ENTITIES, closed_period, entity_out, frozen_names, record
from .timeutil import TEXT_SLACK, local_date

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


def trips_between(db: Session, tenant_id: int, vehicle_id: str, date_from: dt.date, date_to: dt.date,
                  include_deleted: bool = False) -> list[models.Trip]:
    """Nicht stornierte Fahrten mit lokalem Startdatum (APP_TIMEZONE) im Zeitraum, chronologisch.
    Vorauswahl per Text (Index vehicle_id, start_at) mit Rand für beliebige Offsets, dann exakt lokal."""
    q = select(models.Trip).where(models.Trip.tenant_id == tenant_id, models.Trip.vehicle_id == vehicle_id,
                                  models.Trip.start_at >= (date_from - TEXT_SLACK).isoformat(),
                                  models.Trip.start_at < (date_to + dt.timedelta(days=1) + TEXT_SLACK).isoformat())
    if not include_deleted:
        q = q.where(models.Trip.deleted.is_(False))
    return _sorted(t for t in db.scalars(q) if date_from <= local_date(t.start_at) <= date_to)


def month_bounds(month: str) -> tuple[dt.date, dt.date]:
    y, m = map(int, month.split("-"))
    first = dt.date(y, m, 1)
    nxt = dt.date(y + (m == 12), m % 12 + 1, 1)
    return first, nxt - dt.timedelta(days=1)


def trips_in_month(db: Session, tenant_id: int, vehicle_id: str, month: str) -> list[models.Trip]:
    return trips_between(db, tenant_id, vehicle_id, *month_bounds(month))


def previous_trip(db: Session, tenant_id: int, vehicle_id: str, before: dt.date) -> models.Trip | None:
    """Letzte Fahrt mit lokalem Datum vor `before` (Textsortierung nur grob wegen Offsets →
    Feinsortierung in Python)."""
    q = _vehicle_trips(tenant_id, vehicle_id).where(models.Trip.start_at < (before + TEXT_SLACK).isoformat()) \
        .order_by(models.Trip.start_at.desc()).limit(200)
    prev = _sorted(t for t in db.scalars(q) if local_date(t.start_at) < before)
    return prev[-1] if prev else None


def km_gaps(trips: list[models.Trip], previous: models.Trip | None = None) -> list[dict]:
    """Lücke, wenn km_end(n) ≠ km_start(n+1) (negativ = Überschneidung)."""
    chain = ([previous] if previous is not None else []) + trips
    gaps = []
    for a, b in itertools.pairwise(chain):
        if a.km_end is not None and b.km_start is not None and a.km_end != b.km_start:
            gaps.append({"after_trip_id": a.id, "before_trip_id": b.id, "km_from": a.km_end, "km_to": b.km_start,
                         "km": b.km_start - a.km_end})
    return gaps


def _mismatches(trips: list[models.Trip]) -> list[dict]:
    """Plausibilität je Fahrt. `blocking` = verhindert den Abschluss (ausser force + Begründung)."""
    out = []

    def add(t, reason, blocking=True):
        out.append({"trip_id": t.id, "reason": reason, "blocking": blocking})

    for t in trips:
        if t.km_start is None or t.km_end is None:
            add(t, "km-Stand Beginn/Ende fehlt")
        else:
            tacho = t.km_end - t.km_start
            for label, d in (("Routendistanz", t.distance_route), ("GPS-Distanz", t.distance_gps)):
                if d is not None and abs(d - tacho) > max(TOLERANCE_KM, 0.1 * tacho):
                    add(t, f"{label} {d:.1f} km weicht vom km-Stand ({tacho} km) ab", blocking=False)
            if t.km_estimated:
                add(t, "km-Stand geschätzt (nicht abgelesen)")
        if t.end_at is None:
            add(t, "Endzeit fehlt")
        if t.category in ("business", "field") and not (t.purpose or "").strip():
            add(t, f"Zweck fehlt ({'geschäftlich' if t.category == 'business' else 'Aussendienst'})")
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
        elif d_lo < local_date(t.start_at).isoformat() < d_hi:
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
        "corrections": period.corrections if period is not None else 0,
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
    blocking = [m for m in _mismatches(trips) if m["blocking"]]
    reason = (reason or "").strip() or None
    problems = {"gaps": gaps, "mismatches": blocking}
    if (gaps or blocking) and not force:
        msg = "Fahrten unvollständig (Zweck, km-Stand oder Endzeit)" if blocking else "km-Lücken vorhanden"
        raise PeriodError({"message": msg, **problems})
    if (gaps or blocking) and (reason is None or len(reason) < 10):
        raise PeriodError({"message": "Erzwungener Abschluss braucht eine Begründung (mind. 10 Zeichen)",
                           **problems})

    locked = 0
    for t in trips:
        # Namen einfrieren: spätere Umbenennungen von Orten/Kunden ändern den Bericht nicht mehr
        changes = {k: v for k, v in frozen_names(db, t).items() if getattr(t, k) != v}
        if t.status != "locked" or changes:
            locked += t.status != "locked"
            t.status = "locked"
            for k, v in changes.items():
                setattr(t, k, v)
            record(db, tenant, user, "trip", t, "update")

    kms = km_by_category(trips)
    starts = [t.km_start for t in trips if t.km_start is not None]
    ends = [t.km_end for t in trips if t.km_end is not None]
    period = existing or models.TripPeriod(id=models.new_id(), tenant_id=tenant.id, vehicle_id=vid, month=month,
                                           version=0, deleted=False, last_seq=0, corrections=0)
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
    forced = bool(gaps or blocking)
    note = (f"Erzwungen trotz {len(gaps)} km-Lücke(n) und {len(blocking)} unvollständigen Angaben: {reason}"
            if forced else None)
    period.note = note[:500] if note else None
    if existing is None:
        db.add(period)
    record(db, tenant, user, "trip_period", period, "create" if existing is None else "update")
    anchor = maybe_anchor(db, tenant, force=True)
    if period.anchor_seq is not None and (anchor is None or anchor.seq != period.anchor_seq):
        raise RuntimeError("Anker des Monatsabschlusses konnte nicht gesetzt werden")
    return {"period": entity_out(period, ENTITIES["trip_period"][1]), "locked_trips": locked,
            "gaps": gaps, "mismatches": blocking, "forced": forced, "cursor": tenant.seq,
            "anchor": None if anchor is None else {"seq": anchor.seq, "head_hash": anchor.head_hash,
                                                   "created_at": anchor.created_at, "key_id": anchor.key_id}}


def webhook_url() -> str | None:
    return os.environ.get("N8N_WEBHOOK_URL", "").strip() or None


SIGNATURE_HEADER = "X-Fahrzeugbuch-Signature"


def webhook_signature(secret: str, body: bytes) -> str:
    """HMAC-SHA256 über den exakten Body: `sha256=<hex>` (Prüfung in n8n mit N8N_WEBHOOK_SECRET)."""
    return "sha256=" + hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def _open(req: urllib.request.Request, timeout: float):
    """Ohne Weiterleitungen (eine 3xx-Antwort ist ein Fehler)."""
    return urllib.request.build_opener(_NoRedirect()).open(req, timeout=timeout)


def send_webhook(url: str, payload: dict) -> None:
    """Benachrichtigung (z. B. n8n → Paperless), signiert mit N8N_WEBHOOK_SECRET. Fehler werden nur
    protokolliert – ohne URL (kann ein Token enthalten)."""
    body = json.dumps(payload).encode()
    headers = {"Content-Type": "application/json"}
    if secret := os.environ.get("N8N_WEBHOOK_SECRET", "").strip():
        headers[SIGNATURE_HEADER] = webhook_signature(secret, body)
    try:
        req = urllib.request.Request(url, data=body, method="POST", headers=headers)
        with _open(req, timeout=5) as r:
            r.read(1024)
    except Exception as e:  # noqa: BLE001 – Abschluss ist bereits gespeichert
        log.warning("Webhook fehlgeschlagen (%s)", type(e).__name__)
