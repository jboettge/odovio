"""Aktivitäts-Feed eines Mandanten: die letzten Revisionen des Journals als deutsche Kurztexte.

Leserolle: Privatfahrten nur als „Privatfahrt · 22 km“ (auch ältere Stände einer heute privaten Fahrt),
private Orte als „Privater Ort“. Notizen und Begründungen erscheinen nie im Kurztext.
"""
import datetime as dt
import json

from sqlalchemy import select
from sqlalchemy.orm import Session

from . import models, privacy

ACTIVITY_LIMIT, ACTIVITY_MAX = 50, 200
SUMMARY_MAX = 200

ROLE_LABEL = {"admin": "Verwalten", "write": "Schreiben", "read": "Lesen"}
CATEGORY_LABEL = {"business": "geschäftlich", "private": "privat", "commute": "Arbeitsweg",
                  "field": "Aussendienst"}
ATTACHMENT_LABEL = {"receipt": "Quittung", "pump": "Zapfsäule", "odometer": "Tacho", "other": "Datei"}


def _num(v, decimals: int = 0) -> str:
    """Schweizer Schreibweise: 50'000 bzw. 43.6 (unnötige Nachkommastellen weg)."""
    if v is None:
        return "?"
    try:
        v = float(v)
    except (TypeError, ValueError):
        return "?"
    text = f"{v:,.{decimals}f}".replace(",", "'")
    if decimals:
        text = text.rstrip("0").rstrip(".")
    return text


def _date(v) -> str:
    try:
        return dt.date.fromisoformat(str(v)[:10]).strftime("%d.%m.")
    except ValueError:
        return ""


def trip_km(d: dict) -> float | None:
    if d.get("km_start") is not None and d.get("km_end") is not None:
        return max(0, d["km_end"] - d["km_start"])
    return d.get("distance_route") if d.get("distance_route") is not None else d.get("distance_gps")


def _dist(km) -> str:
    return f"{_num(km, 0 if km is None or km >= 10 else 1)} km"


def _join(*parts) -> str:
    return " · ".join(p for p in parts if p)


class Lookup:
    """Nachschlagen für eine Seite des Feeds (je Typ höchstens eine Abfrage)."""

    def __init__(self, db: Session, tenant_id: int, revs: list[tuple], mask: bool):
        self.mask = mask
        ids: dict[type, set] = {models.Place: set(), models.Maintenance: set(), models.FuelEntry: set(),
                                models.Trip: set()}
        for r, d in revs:
            if r.entity == "trip":
                ids[models.Trip].add(r.entity_id)
                ids[models.Place].update(x for x in (d.get("start_place_id"), d.get("end_place_id")) if x)
            if d.get("maintenance_id"):
                ids[models.Maintenance].add(d["maintenance_id"])
            if d.get("fuel_id"):
                ids[models.FuelEntry].add(d["fuel_id"])

        def rows(model, *cols):
            if not ids[model]:
                return []
            return db.execute(select(model.id, *cols).where(model.tenant_id == tenant_id, model.id.in_(ids[model])))

        self.places = {r.id: (r.name, r.private) for r in rows(models.Place, models.Place.name, models.Place.private)}
        self.vehicle_of = {r.id: r.vehicle_id for r in rows(models.Maintenance, models.Maintenance.vehicle_id)}
        self.vehicle_of |= {r.id: r.vehicle_id for r in rows(models.FuelEntry, models.FuelEntry.vehicle_id)}
        self.private_trips = {r.id for r in rows(models.Trip, models.Trip.category, models.Trip.private_mode)
                              if r.category == "private" or r.private_mode}

    def place(self, pid: str | None) -> str | None:
        hit = self.places.get(pid) if pid else None
        if hit is None:
            return None
        name, private = hit
        return privacy.PRIVATE_PLACE_NAME if private and self.mask else name


def _trip(r, d: dict, lk: Lookup) -> str:
    private = privacy.is_private("trip", d) or r.entity_id in lk.private_trips
    km = _dist(trip_km(d))
    if private and lk.mask:
        return _join("Privatfahrt", km)
    start = d.get("start_label") or lk.place(d.get("start_place_id"))
    end = d.get("end_label") or lk.place(d.get("end_place_id"))
    route = f"{start or '…'} → {end or '…'}" if start or end else None
    head = "Privatfahrt" if privacy.is_private("trip", d) else "Fahrt"
    return _join(f"{head} {route}" if route else head, km)


def _membership(r, d: dict) -> str:
    who, role = d.get("username") or "?", ROLE_LABEL.get(d.get("role"), d.get("role") or "?")
    if r.action == "create":
        return f"Mitglied {who} hinzugefügt ({role})"
    if r.action == "delete":
        return f"Mitglied {who} entfernt"
    return f"Rolle von {who}: {role}"


def summary(r, d: dict, lk: Lookup) -> str:
    e = r.entity
    if e == "trip":
        text = _trip(r, d, lk)
    elif e == "fuel":
        text = _join(f"Tankvorgang {_date(d.get('date'))}".strip(), f"{_num(d.get('liters'), 2)} l",
                     f"CHF {float(d.get('price_total') or 0):.2f}")
    elif e == "maintenance":
        text = f"Wartung {d.get('title') or ''}".strip()
    elif e == "maintenance_item":
        text = f"Checkliste: {d.get('label') or ''}" + (" (erledigt)" if d.get("done") else "")
    elif e == "maintenance_material":
        text = _join(f"Material {d.get('name') or ''}".strip(),
                     f"{_num(d.get('quantity'), 2)} {d.get('unit') or ''}".strip())
    elif e == "material_article":
        text = f"Artikel {d.get('name') or ''}".strip()
    elif e == "odometer":
        text = _join(f"Kilometerstand {_date(d.get('date'))}".strip(), f"{_num(d.get('km'))} km")
    elif e == "vehicle":
        text = f"Fahrzeug {d.get('name') or ''}".strip() + (f" ({d['plate']})" if d.get("plate") else "")
    elif e == "customer":
        text = f"Kunde {d.get('name') or ''}".strip()
    elif e == "place":
        name = privacy.PRIVATE_PLACE_NAME if lk.mask and privacy.is_private("place", d) else d.get("name")
        text = f"Ort {name or ''}".strip()
    elif e == "purpose_rule":
        text = _join("Zweckregel", CATEGORY_LABEL.get(d.get("result_category")), d.get("result_purpose"))
    elif e == "tax_param":
        text = _join(f"Steuerparameter {d.get('year') or ''}".strip(), f"{d.get('key')} = {d.get('value')}")
    elif e == "trip_period":
        month = str(d.get("month") or "")
        text = f"Monatsabschluss {month[5:7]}.{month[:4]}" if len(month) == 7 else "Monatsabschluss"
    elif e == "attachment":
        text = f"Beleg {ATTACHMENT_LABEL.get(d.get('kind'), 'Datei')}"
    elif e == "membership":
        text = _membership(r, d)
    else:
        text = e
    return text[:SUMMARY_MAX]


def vehicle_id(r, d: dict, lk: Lookup) -> str | None:
    if r.entity == "vehicle":
        return r.entity_id
    if d.get("vehicle_id"):
        return d["vehicle_id"]
    for key in ("maintenance_id", "fuel_id"):
        if d.get(key) and d[key] in lk.vehicle_of:
            return lk.vehicle_of[d[key]]
    return None


def activity(db: Session, tenant_id: int, limit: int, before_seq: int | None, mask: bool) -> dict:
    limit = max(1, min(limit, ACTIVITY_MAX))
    q = select(models.Revision).where(models.Revision.tenant_id == tenant_id)
    if before_seq is not None:
        q = q.where(models.Revision.seq < before_seq)
    revs = list(db.scalars(q.order_by(models.Revision.seq.desc()).limit(limit + 1)))
    more = len(revs) > limit
    revs = revs[:limit]
    pairs = [(r, _parse(r.data)) for r in revs]
    lk = Lookup(db, tenant_id, pairs, mask)
    items = [{
        "seq": r.seq, "at": r.recorded_at, "actor_name": r.actor_name,
        "action": r.action if r.action in ("create", "update", "delete") else "update",
        "entity": r.entity, "entity_id": r.entity_id, "vehicle_id": vehicle_id(r, d, lk),
        "summary": summary(r, d, lk),
    } for r, d in pairs]
    return {"items": items, "next_before_seq": revs[-1].seq if more and revs else None}


def _parse(raw: str) -> dict:
    try:
        data = json.loads(raw)
    except ValueError:
        return {}
    return data if isinstance(data, dict) else {}
