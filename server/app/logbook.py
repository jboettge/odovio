"""Fahrtenbuch-Exporte: PDF (A4 quer), CSV (Excel CH) und Jahresbericht-PDF.

Privatsphäre: Fahrten im Privatmodus zeigen Start/Ziel/Zweck nur als „privat“. Mit `mask_private`
(Leserolle, z. B. Treuhand) gilt das für alle Privatfahrten (Konzept US6).

Abgeschlossene Monate: Start-/Zielbezeichnung und Kundenname wurden beim Abschluss in die Fahrt
geschrieben (eingefroren) – spätere Umbenennungen von Orten/Kunden ändern den Bericht nicht.
Zeiten in lokaler Zeit (APP_TIMEZONE).
"""
import csv
import datetime as dt
import io
import json
import unicodedata
from xml.sax.saxutils import escape as _esc

from reportlab.lib.pagesizes import A4, landscape
from reportlab.lib.units import mm
from reportlab.platypus import Paragraph, SimpleDocTemplate, Spacer
from sqlalchemy import select
from sqlalchemy.orm import Session

from . import models
from .report import (
    ACTIONS,
    BOLD,
    CATEGORY_NAMES,
    H2,
    SMALL,
    SOURCE_NAMES,
    STATUS_NAMES,
    STYLES,
    _day,
    _describe,
    _km,
    _num,
    _p,
    _table,
    footer,
    integrity_section,
    plain,
)
from .stats import VehicleData
from .tax import DISCLAIMER
from .timeutil import local, local_month
from .trips import km_by_category, km_gaps, month_bounds, odometer_check, previous_trip, trip_km, trips_between

OWNERSHIP_NAMES = {"private": "Privatfahrzeug", "business": "Geschäftsfahrzeug"}
METHOD_NAMES = {"flat": "Privatanteil pauschal (0.9 %/Monat)", "effective": "Privatanteil effektiv (Fahrtenbuch)"}
PRIVATE = "privat"


class Lookup:
    """Orte/Kunden des Mandanten (auch stornierte: Bezeichnung bleibt für Altfahrten lesbar)."""

    def __init__(self, db: Session, tenant_id: int):
        self.places = {p.id: p for p in db.scalars(select(models.Place).where(models.Place.tenant_id == tenant_id))}
        self.customers = {c.id: c for c in
                          db.scalars(select(models.Customer).where(models.Customer.tenant_id == tenant_id))}

    def place(self, label: str | None, pid: str | None) -> str:
        if label:
            return label
        p = self.places.get(pid) if pid else None
        return p.name if p else "–"

    def customer(self, cid: str | None, frozen: str | None = None) -> str:
        if frozen:
            return frozen
        c = self.customers.get(cid) if cid else None
        if c is None:
            return ""
        return f"{c.name} ({c.ref})" if c.ref else c.name


def masked(t: models.Trip, mask_private: bool) -> bool:
    return t.private_mode or (mask_private and t.category == "private")


def _local(ts: str | None) -> dt.datetime | None:
    return local(ts) if ts else None


def _time_range(t: models.Trip) -> str:
    s, e = _local(t.start_at), _local(t.end_at)
    if e is None:
        return f"{s:%H:%M}–?"
    return f"{s:%H:%M}–{e:%H:%M}" if e.date() == s.date() else f"{s:%H:%M}–{e:%d.%m. %H:%M}"


def _route(t: models.Trip, lk: Lookup, mask: bool) -> tuple[str, str]:
    if masked(t, mask):
        return PRIVATE, PRIVATE
    return lk.place(t.start_label, t.start_place_id), lk.place(t.end_label, t.end_place_id)


def _purpose(t: models.Trip, lk: Lookup, mask: bool) -> str:
    if masked(t, mask):
        return PRIVATE if t.category == "private" or t.private_mode else ""
    parts = [x for x in (t.purpose, lk.customer(t.customer_id, t.customer_name)) if x]
    return " · ".join(parts)


def _months(date_from: dt.date, date_to: dt.date) -> list[str]:
    out, y, m = [], date_from.year, date_from.month
    while (y, m) <= (date_to.year, date_to.month):
        out.append(f"{y:04d}-{m:02d}")
        y, m = (y + 1, 1) if m == 12 else (y, m + 1)
    return out


def _vehicle_head(tenant: models.Tenant, v: models.Vehicle) -> str:
    own = OWNERSHIP_NAMES[v.ownership or "private"]
    method = METHOD_NAMES[v.private_use_method or "flat"] if (v.ownership == "business") else "–"
    car = " ".join(x for x in [v.make, v.model] if x)
    return (f"{car + '  ·  ' if car else ''}Kennzeichen: {v.plate or '–'}  ·  Mandant: {tenant.name}  ·  "
            f"{own}  ·  Methode: {method}")


def build_logbook(db: Session, tenant: models.Tenant, data: VehicleData, date_from: dt.date, date_to: dt.date,
                  user_name: str | None, mask_private: bool = False) -> bytes:
    v = data.vehicle
    lk = Lookup(db, tenant.id)
    trips = trips_between(db, tenant.id, v.id, date_from, date_to)
    created = dt.datetime.now().strftime("%d.%m.%Y %H:%M")
    page = landscape(A4)

    story = [
        Paragraph(_esc(f"Fahrtenbuch – {v.name}"), STYLES["Title"]),
        _p(_vehicle_head(tenant, v), STYLES["Normal"]),
        _p(f"Zeitraum: {_day(date_from)} – {_day(date_to)}  ·  erstellt {created}"
           f"{' von ' + user_name if user_name else ''}", STYLES["Normal"]),
        Spacer(1, 3 * mm),
        Paragraph(f"Fahrten ({len(trips)})", H2),
    ]
    if trips:
        rows = []
        for t in trips:
            start, end = _route(t, lk, mask_private)
            purpose = _purpose(t, lk, mask_private)
            if t.note and not masked(t, mask_private):
                purpose = f"{purpose}\nNotiz: {t.note}" if purpose else f"Notiz: {t.note}"
            dist = trip_km(t)
            rows.append([
                _day(_local(t.start_at).date()), _time_range(t), _km(t.km_start), _km(t.km_end), _num(dist, 1),
                _p(f"{start} » {end}", limit=420), CATEGORY_NAMES.get(t.category, t.category),
                _p(purpose, limit=600), _p(t.driver_name or (t.driver_sub or "–")[:20], limit=100),
                STATUS_NAMES.get(t.status, t.status), SOURCE_NAMES.get(t.source, t.source),
            ])
        story.append(_table(["Datum", "Zeit", "km Beginn", "km Ende", "Distanz", "Start » Ziel", "Kategorie",
                             "Zweck / Kunde", "Fahrer", "Status", "Quelle"],
                            rows, [18, 22, 17, 17, 14, 55, 20, 52, 18, 18, 16]))
    else:
        story.append(_p("Keine Fahrten im Zeitraum."))

    # Summen je Kategorie
    kms = km_by_category(trips)
    total = sum(kms.values())
    counts = {c: sum(1 for t in trips if t.category == c) for c in kms}
    rows = [[CATEGORY_NAMES[c], counts[c], _num(kms[c], 1), _num(kms[c] / total * 100, 1) if total else "–"]
            for c in kms if counts[c] or c != "unknown"]
    rows.append([_p("Total", BOLD), _p(str(len(trips)), BOLD), _p(_num(total, 1), BOLD),
                 _p("100.0" if total else "–", BOLD)])
    story += [Paragraph("Summen je Kategorie", H2), _table(["Kategorie", "Fahrten", "km", "Anteil %"], rows,
                                                          [40, 25, 30, 25])]

    # Lücken + Odometer-Abgleich
    previous = previous_trip(db, tenant.id, v.id, date_from)
    gaps = km_gaps(trips, previous)
    by_id = {t.id: t for t in trips}
    if previous is not None:
        by_id[previous.id] = previous
    story.append(Paragraph(f"Lücken in der km-Kette ({len(gaps)})", H2))
    if gaps:
        story.append(_table(
            ["nach Fahrt", "vor Fahrt", "km von", "km bis", "Differenz km"],
            [[_day(_local(by_id[g["after_trip_id"]].start_at).date()),
              _day(_local(by_id[g["before_trip_id"]].start_at).date()),
              _km(g["km_from"]), _km(g["km_to"]), _km(g["km"])] for g in gaps],
            [35, 35, 30, 30, 30]))
    else:
        story.append(_p("Keine Lücken (km-Ende jeder Fahrt = km-Beginn der nächsten)."))
    odo_rows = []
    for month in _months(date_from, date_to):
        m_first, m_last = month_bounds(month)
        m_trips = [t for t in trips if local_month(t.start_at) == month]
        chk = odometer_check(data, m_trips, max(m_first, date_from), min(m_last, date_to))
        odo_rows.append([month, _num(chk["trip_km"], 1), _km(chk["odometer_km"]),
                         _num(chk["diff_km"], 1) if chk["diff_km"] is not None else "–",
                         {True: "ok", False: "ABWEICHUNG", None: chk["note"] or "–"}[chk["ok"]]])
    story += [Paragraph("Abgleich mit km-Ständen (Odometer, Tank, Wartung)", H2),
              _table(["Monat", "Fahrten-km", "km-Stände", "Differenz", "Ergebnis (Toleranz max. 5 km / 2 %)"],
                     odo_rows, [25, 30, 30, 25, 100])]

    # Abschlussstatus
    periods = {p.month: p for p in db.scalars(select(models.TripPeriod).where(
        models.TripPeriod.tenant_id == tenant.id, models.TripPeriod.vehicle_id == v.id,
        models.TripPeriod.deleted.is_(False)))}
    anchors = {a.seq: a for a in db.scalars(select(models.Anchor).where(models.Anchor.tenant_id == tenant.id))}
    rows = []
    for month in _months(date_from, date_to):
        p = periods.get(month)
        if p is None or p.status != "closed":
            rows.append([month, "offen", "–", "–", "Nicht abgeschlossen: Einträge können noch geändert werden."])
            continue
        a = anchors.get(p.anchor_seq) if p.anchor_seq is not None else None
        anchor = (f"Seq {a.seq}, Schlüssel {a.key_id}, Signatur {a.signature[:24]}…" if a else
                  "kein signierter Anker")
        corr = f"\nKorrekturen nach Abschluss: {p.corrections}" if p.corrections else ""
        rows.append([month, "abgeschlossen", p.closed_by or "–", (p.closed_at or "")[:19].replace("T", " "),
                     anchor + (f"\n{p.note}" if p.note else "") + corr])
    story += [Paragraph("Monatsabschluss", H2),
              _table(["Monat", "Status", "durch", "am (UTC)", "Anker / Bemerkung"], rows, [20, 25, 35, 32, 150])]

    # Änderungsprotokoll der Fahrten (Client-Änderungen, Stornos, Konflikte; Sperren beim Abschluss s. oben)
    ids = [t.id for t in trips_between(db, tenant.id, v.id, date_from, date_to, include_deleted=True)]
    revs = list(db.scalars(
        select(models.Revision).where(
            models.Revision.tenant_id == tenant.id, models.Revision.entity == "trip",
            models.Revision.entity_id.in_(ids), models.Revision.op_id.is_not(None),
            (models.Revision.action != "create") | models.Revision.conflict.is_(True))
        .order_by(models.Revision.seq))) if ids else []
    story.append(Paragraph(f"Änderungsprotokoll Fahrten ({len(revs)})", H2))
    if revs:
        rows = []
        for r in revs:
            d = json.loads(r.data)
            hide = d.get("private_mode") or (mask_private and d.get("category") == "private")
            rows.append([r.seq, r.recorded_at[:19].replace("T", " "), r.actor_name or r.actor_sub[:8],
                         ACTIONS.get(r.action, r.action) + (" (Konflikt)" if r.conflict else ""),
                         f"Fahrt v{r.version}", PRIVATE if hide else _describe("trip", d)])
        story.append(_table(["Seq", "Zeitpunkt (UTC)", "Benutzer", "Aktion", "Objekt", "Stand nach Änderung"],
                            rows, [14, 34, 30, 26, 22, 141]))
    else:
        story.append(_p("Keine nachträglichen Änderungen oder Stornierungen."))

    integrity, audit, _ = integrity_section(db, tenant)
    story += integrity
    story += [Paragraph("Hinweis", H2), _p(DISCLAIMER), _p(
        "Massgebend sind die km-Stände (Tacho); GPS-/Routendistanzen dienen nur der Kontrolle. "
        "Private Fahrten im Privatmodus enthalten keine Orte.")]

    return _build(story, page, f"Fahrtenbuch · {tenant.name} · {v.name}", audit,
                  f"Fahrtenbuch {v.name}", user_name)


def _build(story: list, page, footer_title: str, audit: dict, title: str, user_name: str | None) -> bytes:
    on_page = footer(footer_title, audit, page[0])
    buf = io.BytesIO()
    doc = SimpleDocTemplate(buf, pagesize=page, leftMargin=15 * mm, rightMargin=15 * mm,
                            topMargin=15 * mm, bottomMargin=18 * mm, title=plain(title),
                            author=plain(user_name or "Fahrzeugbuch"))
    doc.build(story, onFirstPage=on_page, onLaterPages=on_page)
    return buf.getvalue()


# ---------- CSV ----------
FORMULA_START = frozenset("=+-@")
_LEADING_SPACE = " \u00a0\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a\u202f\u3000\ufeff"


def _cell(v) -> str:
    """Keine Formel-/DDE-Injektion in Excel/LibreOffice: Text, der (nach Leerraum) mit = + - @ beginnt – auch
    in Unicode-Varianten wie ＝ ＋ － ＠ ﹦ (NFKC) –, oder mit Tab/CR/LF, bekommt ein führendes Apostroph."""
    if v is None:
        return ""
    s = str(v)
    if s[:1] in ("\t", "\r", "\n"):
        return "'" + s
    first = unicodedata.normalize("NFKC", s.lstrip(_LEADING_SPACE)[:1])[:1]
    return "'" + s if first in FORMULA_START else s


def trips_csv(db: Session, tenant: models.Tenant, data: VehicleData, date_from: dt.date, date_to: dt.date,
              mask_private: bool = False) -> bytes:
    lk = Lookup(db, tenant.id)
    v = data.vehicle
    buf = io.StringIO()
    w = csv.writer(buf, delimiter=";", lineterminator="\r\n")
    w.writerow(["Datum", "Start", "Ende", "km Beginn", "km Ende", "Distanz km", "Startort", "Zielort", "Kategorie",
                "Zweck", "Kunde", "Fahrer", "Status", "Quelle", "Notiz", "Fahrzeug", "Kennzeichen", "ID"])
    for t in trips_between(db, tenant.id, v.id, date_from, date_to):
        hide = masked(t, mask_private)
        start, end = _route(t, lk, mask_private)
        s, e = _local(t.start_at), _local(t.end_at)
        w.writerow([
            f"{s:%d.%m.%Y}", f"{s:%H:%M}", f"{e:%d.%m.%Y %H:%M}" if e and e.date() != s.date() else
            (f"{e:%H:%M}" if e else ""),
            "" if t.km_start is None else t.km_start, "" if t.km_end is None else t.km_end, f"{trip_km(t):.1f}",
            _cell(start), _cell(end), CATEGORY_NAMES.get(t.category, t.category),
            PRIVATE if hide else _cell(t.purpose), "" if hide else _cell(lk.customer(t.customer_id, t.customer_name)),
            _cell(t.driver_name or t.driver_sub), STATUS_NAMES.get(t.status, t.status),
            SOURCE_NAMES.get(t.source, t.source), "" if hide else _cell(t.note), _cell(v.name), _cell(v.plate),
            t.id,
        ])
    return ("﻿" + buf.getvalue()).encode("utf-8")


# ---------- Jahresbericht ----------
ITEM_ORDER = ("private_share_flat", "private_share_effective", "private_share_effective_incl_commute",
              "km_compensation", "commute_deduction_federal", "commute_deduction_canton")
SCOPE_NAMES = {"tenant": "Mandant", "federal": "Bund", "default": "Default [A]"}


def build_year_report(db: Session, tenant: models.Tenant, rep: dict, user_name: str | None) -> bytes:
    v = rep["vehicle"]
    vehicle = db.get(models.Vehicle, v["id"])
    created = dt.datetime.now().strftime("%d.%m.%Y %H:%M")
    story = [
        Paragraph(_esc(f"Jahresbericht Fahrtenbuch {rep['year']} – {v['name']}"), STYLES["Title"]),
        _p(_vehicle_head(tenant, vehicle), STYLES["Normal"]),
        _p(f"Kanton: {rep['canton'] or '– (TAX_CANTON nicht gesetzt)'}  ·  Fahrten: {rep['trips_count']}  ·  "
           f"Monate mit Nutzung: {rep['months_used']}  ·  erstellt {created}"
           f"{' von ' + user_name if user_name else ''}", STYLES["Normal"]),
        Paragraph("Kilometer je Kategorie", H2),
        _table(["Kategorie", "km", "Anteil %"],
               [[CATEGORY_NAMES[c], _num(rep["km"][c], 1), _num(rep["shares_pct"][c], 1)]
                for c in CATEGORY_NAMES] + [[_p("Total", BOLD), _p(_num(rep["km"]["total"], 1), BOLD), ""]],
               [50, 35, 30]),
        Paragraph("Fahrzeugkosten", H2),
        _table(["Position", "CHF"], [
            ["Treibstoff", _num(rep["costs"]["fuel"])],
            ["Wartung (Rechnung, sonst Material)", _num(rep["costs"]["maintenance"])],
            ["Fixkosten (Versicherung, Steuer, Leasing, Abschreibung)", _num(rep["costs"]["fixed"])],
            [_p("Total", BOLD), _p(_num(rep["costs"]["total"]), BOLD)],
        ], [110, 40]),
        Paragraph("Berechnungen", H2),
    ]
    rows = []
    for key in ITEM_ORDER:
        it = rep["items"][key]
        params = "\n".join(f"{p['label']}: {p['value']} ({SCOPE_NAMES.get(p['scope'], p['scope'])} "
                           f"{p['year']})" for p in it["params"])
        value = _num(it["value"]) if it["value"] is not None else f"– ({it['reason'] or 'n/a'})"
        rows.append([_p(it["label"], BOLD), _p(value, limit=200), _p(it["formula"], limit=300),
                     _p(params or "–", limit=600)])
    story.append(_table(["Position", "CHF", "Formel", "Parameter"], rows, [42, 34, 52, 52]))

    story.append(Paragraph("Verwendete Parameter", H2))
    story.append(_table(["Parameter", "Wert", "Jahr", "Herkunft", "Quelle / Notiz"],
                        [[p["label"], p["value"], p["year"], SCOPE_NAMES.get(p["scope"], p["scope"]),
                          _p(" · ".join(x for x in (p["source_url"], p["note"]) if x) or "–", limit=500)]
                         for p in rep["params"].values()],
                        [48, 16, 12, 22, 82]))
    story.append(Paragraph(f"Warnungen ({len(rep['warnings'])})", H2))
    story += [_p("• " + w) for w in rep["warnings"]] or [_p("Keine.")]

    integrity, audit, _ = integrity_section(db, tenant)
    story += integrity
    story += [Paragraph("Hinweis", H2), _p(rep["disclaimer"], SMALL)]
    return _build(story, A4, f"Jahresbericht {rep['year']} · {tenant.name} · {v['name']}", audit,
                  f"Jahresbericht {rep['year']} {v['name']}", user_name)
