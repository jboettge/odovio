"""PDF-Export je Fahrzeug und Zeitraum, inkl. Änderungsprotokoll und Integritätsvermerk."""
import datetime as dt
import io
import json
from xml.sax.saxutils import escape

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.platypus import Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle
from sqlalchemy import select
from sqlalchemy.orm import Session

from . import models
from .attachments import fuel_with_receipt
from .integrity import verify_all
from .stats import VehicleData, consumption_points, summarize

STYLES = getSampleStyleSheet()
SMALL = ParagraphStyle("small", parent=STYLES["Normal"], fontSize=8, leading=10)
BOLD = ParagraphStyle("bold", parent=SMALL, fontName="Helvetica-Bold")
H2 = ParagraphStyle("h2", parent=STYLES["Heading2"], spaceBefore=10, spaceAfter=4)
ACTIONS = {"create": "Erfasst", "update": "Geändert", "delete": "Storniert"}
ENTITY_NAMES = {
    "vehicle": "Fahrzeug", "odometer": "km-Stand", "fuel": "Tankvorgang",
    "maintenance": "Wartung", "maintenance_item": "Checkpunkt", "maintenance_material": "Material",
    "material_article": "Materialartikel", "trip": "Fahrt", "place": "Ort", "customer": "Kunde",
    "purpose_rule": "Zweckregel", "tax_param": "Steuerparameter", "trip_period": "Monatsabschluss",
    "attachment": "Beleg",
}
KIND_NAMES = {"receipt": "Quittung", "pump": "Zapfsäule", "odometer": "Tacho", "other": "Beleg"}
CATEGORY_NAMES = {"business": "geschäftlich", "private": "privat", "commute": "Arbeitsweg",
                  "field": "Aussendienst", "unknown": "unbekannt"}
STATUS_NAMES = {"draft": "Entwurf", "suggested": "vorgeschlagen", "confirmed": "bestätigt",
                "locked": "abgeschlossen"}
SOURCE_NAMES = {"auto": "automatisch", "manual": "manuell", "gap": "Lücke", "import": "Import"}


def _num(v: float | None, d: int = 2) -> str:
    if v is None:
        return "–"
    return f"{v:,.{d}f}".replace(",", "'")


def _qty(v: float | None) -> str:
    if v is None:
        return "–"
    return f"{v:,.3f}".rstrip("0").rstrip(".").replace(",", "'")


def _km(v: int | None) -> str:
    return "–" if v is None else f"{v:,}".replace(",", "'")


def _day(d: dt.date | str | None) -> str:
    if d is None:
        return "–"
    if isinstance(d, str):
        d = dt.date.fromisoformat(d[:10])
    return d.strftime("%d.%m.%Y")


def _p(text: str, style=SMALL, limit: int = 3000) -> Paragraph:
    text = text if len(text) <= limit else text[:limit] + " …"
    return Paragraph(escape(text).replace("\n", "<br/>"), style)


def _table(header: list[str], rows: list[list], widths: list[float]) -> Table:
    data = [[_p(h, BOLD) for h in header]]
    data += [[c if isinstance(c, Paragraph) else _p(str(c)) for c in r] for r in rows]
    t = Table(data, colWidths=[w * mm for w in widths], repeatRows=1, splitInRow=1)
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#e8edf3")),
        ("LINEBELOW", (0, 0), (-1, 0), 0.5, colors.grey),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#f7f7f7")]),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("TOPPADDING", (0, 0), (-1, -1), 2),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 2),
    ]))
    return t


def _describe(entity: str, data: dict) -> str:
    match entity:
        case "fuel":
            return f"{_day(data.get('date'))}, {_km(data.get('km'))} km, {_num(data.get('liters'))} l, CHF {_num(data.get('price_total'))}"
        case "odometer":
            return f"{_day(data.get('date'))}, {_km(data.get('km'))} km"
        case "maintenance":
            return f"{_day(data.get('date'))}, {data.get('title')}, CHF {_num(data.get('cost'))}"
        case "maintenance_item":
            return f"{data.get('label')}: {'erledigt' if data.get('done') else 'offen'}"
        case "maintenance_material":
            pn = f" ({data['part_number']})" if data.get("part_number") else ""
            return (f"{data.get('name')}{pn}, {_qty(data.get('quantity'))} {data.get('unit') or ''}, "
                    f"CHF {_num(data.get('unit_price'))}")
        case "vehicle":
            return f"{data.get('name')} {data.get('plate') or ''}".strip()
        case "trip":
            km = (f"{_km(data.get('km_start'))}–{_km(data.get('km_end'))} km"
                  if data.get("km_start") is not None or data.get("km_end") is not None else "")
            parts = [_day(data.get("start_at")), km, CATEGORY_NAMES.get(data.get("category"), ""),
                     STATUS_NAMES.get(data.get("status"), "")]
            if data.get("note"):
                parts.append(f"Notiz: {data['note']}")
            return ", ".join(x for x in parts if x)
        case "attachment":
            size = data.get("size")
            parts = [KIND_NAMES.get(data.get("kind"), str(data.get("kind") or "")), str(data.get("mime") or ""),
                     f"{_num(size / 1024, 0)} KB" if isinstance(size, int) else "",
                     f"SHA-256 {str(data.get('sha256') or '')[:16]}…"]
            if data.get("note"):
                parts.append(f"Notiz: {data['note']}")
            return ", ".join(x for x in parts if x)
        case "trip_period":
            return f"{data.get('month')}: {data.get('status')} ({data.get('closed_by') or '–'})"
    return ""


def integrity_section(db: Session, tenant: models.Tenant) -> tuple[list, dict, models.Anchor | None]:
    """Integritätsvermerk (Kette, Datenstand, Anker) für alle Berichte."""
    audit = verify_all(db, tenant)
    anchor = db.scalar(select(models.Anchor).where(models.Anchor.tenant_id == tenant.id)
                       .order_by(models.Anchor.seq.desc()).limit(1))
    if audit["ok"]:
        status = "OK"
    elif not audit["chain_ok"]:
        status = f"FEHLER ab Seq {audit['broken_at']}: {audit['reason']}"
    else:
        status = "FEHLER: " + "; ".join(audit["problems"][:3])
    story = [
        Paragraph("Integrität", H2),
        _p(f"Geprüft: Hash-Kette, Abgleich der Einträge mit dem Journal, signierte Anker – {status}. "
           f"Revisionen: {audit['count']}."),
        _p(f"Kettenkopf (SHA-256): {audit['head_hash']}"),
        _p(f"Signierter Anker: Seq {anchor.seq}, {anchor.created_at}, Schlüssel {anchor.key_id}, "
           f"Signatur {anchor.signature[:32]}…" if anchor else
           "Kein signierter Anker (ANCHOR_SIGNING_KEY nicht konfiguriert)."),
        _p("Jede Erfassung, Änderung und Stornierung wird unveränderlich protokolliert und über eine "
           "Hash-Kette gesichert. Der Kettenkopf-Hash dieses Berichts erlaubt den späteren Nachweis, "
           "dass keine Einträge nachträglich verändert wurden."),
    ]
    return story, audit, anchor


def footer(title: str, audit: dict, page_width: float):
    text = f"{title} · Integrität: {'OK' if audit['ok'] else 'FEHLER'} · Kette {audit['head_hash'][:12]}…"

    def on_page(canvas, doc):
        canvas.saveState()
        canvas.setFont("Helvetica", 7)
        canvas.setFillColor(colors.grey)
        canvas.drawString(15 * mm, 10 * mm, text[:180])
        canvas.drawRightString(page_width - 15 * mm, 10 * mm, f"Seite {doc.page}")
        canvas.restoreState()
    return on_page


def build_report(
    db: Session, tenant: models.Tenant, data: VehicleData, date_from: dt.date, date_to: dt.date, user_name: str | None
) -> bytes:
    v = data.vehicle

    def in_period(d: dt.date) -> bool:
        return date_from <= d <= date_to

    fuel = sorted((f for f in data.fuel if in_period(f.date)), key=lambda f: (f.date, f.km))
    odo = sorted((o for o in data.odometer if in_period(o.date)), key=lambda o: (o.date, o.km))
    maint = sorted((m for m in data.maintenance if in_period(m.date)), key=lambda m: (m.date, m.id))
    points = [p for p in consumption_points(data.fuel) if in_period(p["date"])]
    per_km = {p["km"]: p for p in points}

    def kms(until: dt.date, strict: bool) -> list[int]:
        def ok(d):
            return d < until if strict else d <= until
        return ([o.km for o in data.odometer if ok(o.date)] + [f.km for f in data.fuel if ok(f.date)]
                + [m.km for m in data.maintenance if m.km is not None and ok(m.date)])

    km_start = max([v.initial_km, *kms(date_from, strict=True)])
    km_end = max([km_start, *kms(date_to, strict=False)])
    summary = summarize(points)
    fuel_cost = sum(f.price_total for f in fuel)
    maint_cost = sum(data.maintenance_cost(m) for m in maint)

    integrity, audit, _ = integrity_section(db, tenant)
    created = dt.datetime.now().strftime("%d.%m.%Y %H:%M")

    story = [
        Paragraph(escape(f"Fahrzeugbuch – {v.name}"), STYLES["Title"]),
        _p(f"{' '.join(x for x in [v.make, v.model] if x)}  ·  Kennzeichen: {v.plate or '–'}  ·  "
           f"Mandant: {tenant.name}", STYLES["Normal"]),
        _p(f"Zeitraum: {_day(date_from)} – {_day(date_to)}  ·  erstellt {created}"
           f"{' von ' + user_name if user_name else ''}", STYLES["Normal"]),
        Spacer(1, 4 * mm),
        Paragraph("Übersicht", H2),
        _table(["Kennzahl", "Wert"], [
            ["km-Stand Beginn / Ende", f"{_km(km_start)} / {_km(km_end)} km"],
            ["Gefahren im Zeitraum", f"{_km(km_end - km_start)} km"],
            ["Ø Verbrauch", f"{_num(summary['avg_consumption'])} l/100 km  ({_num(summary['avg_liters_per_km'], 3)} l/km)"],
            ["Ø Treibstoffkosten", f"CHF {_num(summary['avg_cost_per_km'], 3)} / km"],
            ["Treibstoff", f"CHF {_num(fuel_cost)}  ({_num(sum(f.liters for f in fuel))} l)"],
            ["Wartung", f"CHF {_num(maint_cost)}"],
            ["Total", f"CHF {_num(fuel_cost + maint_cost)}"],
        ], [60, 110]),
    ]

    receipts = fuel_with_receipt(db, tenant.id, [f.id for f in fuel])
    story += [Paragraph(f"Tankvorgänge ({len(fuel)})", H2)]
    story += [_table(
        ["Datum", "km-Stand", "Liter", "Betrag CHF", "CHF/l", "Voll", "l/100 km", "Tankstelle", "Beleg"],
        [[_day(f.date), _km(f.km), _num(f.liters), _num(f.price_total), _num(f.price_per_liter, 3),
          "ja" if f.full_tank else "nein",
          _num(per_km[f.km]["consumption"]) if f.full_tank and f.km in per_km else "",
          f.station or "", "ja" if f.id in receipts else ""] for f in fuel],
        [20, 20, 16, 20, 15, 11, 18, 38, 12],
    )] if fuel else [_p("Keine Tankvorgänge im Zeitraum.")]

    story += [Paragraph(f"Wartungen ({len(maint)})", H2)]
    if maint:
        rows = []
        for m in maint:
            checklist = ", ".join(f"{i.label} [{'x' if i.done else ' '}]" for i in data.items.get(m.id, []))
            due = " / ".join(x for x in [
                f"{_km(m.next_due_km)} km" if m.next_due_km else "",
                _day(m.next_due_date) if m.next_due_date else "",
            ] if x)
            if m.cost is not None:
                cost = _num(m.cost)
            elif any(x.unit_price is not None for x in data.materials.get(m.id, [])):
                cost = f"{_num(data.material_sum(m.id))} (Material)"
            else:
                cost = "–"
            rows.append([_day(m.date), _km(m.km), m.title, cost, due or "–",
                         checklist + (f"\nNotiz: {m.note}" if m.note else "")])
        story.append(_table(["Datum", "km-Stand", "Titel", "Kosten CHF", "Nächste", "Checkliste [x] erledigt"],
                            rows, [20, 18, 28, 18, 22, 64]))
    else:
        story.append(_p("Keine Wartungen im Zeitraum."))

    # Material je Wartung (eine Zeile je Position, Materialsumme je Wartung)
    with_mat = [m for m in maint if data.materials.get(m.id)]
    if with_mat:
        rows, total_all = [], 0.0
        for m in with_mat:
            mats = data.materials[m.id]
            for n, x in enumerate(mats):
                rows.append([f"{_day(m.date)}\n{m.title}" if n == 0 else "", x.name, x.part_number or "",
                             f"{_qty(x.quantity)} {x.unit}", _num(x.unit_price), _num(x.total)])
            priced = any(x.unit_price is not None for x in mats)
            msum = data.material_sum(m.id)
            total_all += msum
            rows.append(["", _p("Materialsumme", BOLD), "", "", "", _p(_num(msum if priced else None), BOLD)])
        if len(with_mat) > 1:
            rows.append([_p("Total Material", BOLD), "", "", "", "", _p(_num(total_all), BOLD)])
        story += [Paragraph(f"Material ({sum(len(data.materials[m.id]) for m in with_mat)})", H2),
                  _table(["Wartung", "Material", "Art.-Nr.", "Menge", "Einzelpreis CHF", "Total CHF"],
                         rows, [30, 54, 26, 20, 20, 20])]

    story += [Paragraph(f"Kilometerstände ({len(odo)})", H2)]
    story += [_table(["Datum", "km-Stand", "Notiz"], [[_day(o.date), _km(o.km), o.note or ""] for o in odo],
                     [25, 25, 120])] if odo else [_p("Keine separaten Kilometerstände im Zeitraum.")]

    # Änderungsprotokoll: Änderungen/Stornos an Einträgen dieses Fahrzeugs (auch stornierte)
    ids = {v.id}
    for model in (models.OdometerReading, models.FuelEntry, models.Maintenance):
        q = select(model.id, model.date).where(model.vehicle_id == v.id)
        ids |= {i for i, d in db.execute(q) if in_period(d)}
    parents = list(ids)
    for child in (models.MaintenanceItem, models.MaintenanceMaterial):
        ids |= set(db.scalars(select(child.id).where(child.maintenance_id.in_(parents))))
    ids |= set(db.scalars(select(models.Attachment.id).where(     # Belege (auch stornierte)
        models.Attachment.tenant_id == tenant.id,
        models.Attachment.fuel_id.in_(parents) | models.Attachment.maintenance_id.in_(parents))))
    revs = list(db.scalars(
        select(models.Revision)
        .where(models.Revision.tenant_id == tenant.id, models.Revision.entity_id.in_(ids),
               (models.Revision.action != "create") | models.Revision.conflict.is_(True))
        .order_by(models.Revision.seq)
    ))
    story += [Paragraph(f"Änderungsprotokoll ({len(revs)})", H2)]
    if revs:
        story.append(_table(
            ["Seq", "Zeitpunkt (UTC)", "Benutzer", "Aktion", "Objekt", "Stand nach Änderung"],
            [[r.seq, r.recorded_at[:19].replace("T", " "), r.actor_name or r.actor_sub[:8],
              ACTIONS.get(r.action, r.action) + (" (Konflikt)" if r.conflict else ""),
              f"{ENTITY_NAMES.get(r.entity, r.entity)} v{r.version}",
              _describe(r.entity, json.loads(r.data))] for r in revs],
            [12, 30, 22, 22, 26, 58],
        ))
    else:
        story.append(_p("Keine nachträglichen Änderungen oder Stornierungen."))

    story += integrity
    on_page = footer(f"Fahrzeugbuch · {tenant.name} · {v.name}", audit, A4[0])

    buf = io.BytesIO()
    doc = SimpleDocTemplate(buf, pagesize=A4, leftMargin=15 * mm, rightMargin=15 * mm,
                            topMargin=15 * mm, bottomMargin=18 * mm,
                            title=f"Fahrzeugbuch {v.name}", author=user_name or "Fahrzeugbuch")
    doc.build(story, onFirstPage=on_page, onLaterPages=on_page)
    return buf.getvalue()
