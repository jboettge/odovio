"""Steuerparameter (CH) und Jahresbericht Fahrtenbuch.

Parameter sind nicht hart codiert: `tax_param`-Einträge des Mandanten gehen vor.
Auflösung je (Jahr, Schlüssel): scope "tenant" > "canton:XX" (Env TAX_CANTON) > "federal" > Default unten.
Fehlt ein Schlüssel im Jahr, gilt der jüngste Wert eines Vorjahres (Einträge des Mandanten wie Defaults, Review S8):
der neuere Jahrgang geht vor, im gleichen Jahrgang die Reihenfolge oben; übernommene Werte tragen einen Hinweis.
Defaults = Annahmen gemäss Konzept (Kap. 3.1, Stand 11/2026) **[A]** – mit Treuhand bestätigen.

Rechnungen (Konzept Kap. 4, Rechenbeispiele):
- Privatanteil pauschal (Geschäftsfahrzeug) = max(private_share_pct % × Kaufpreis, min_private_month)
  × Monate mit Nutzung
- Privatanteil effektiv = Fahrzeugkosten Jahr × privat-km ÷ total-km
  (Variante inkl. Arbeitsweg zusätzlich, da die Praxis uneinheitlich ist [P])
- Kilometerentschädigung (Privatauto) = geschäftliche km × km_rate
- Arbeitsweg-Abzug = min(Arbeitsweg-km × commute_rate, cap_federal) bzw. cap_canton
"""
import datetime as dt
import os
from dataclasses import dataclass

from sqlalchemy import select
from sqlalchemy.orm import Session

from . import models
from .schemas import TRIP_CATEGORIES
from .stats import VehicleData
from .timeutil import local_month
from .trips import trip_km, trips_between

NOTE_A = "[A] Default gemäss Konzept Fahrtenbuch, mit Treuhand bestätigen"
DISCLAIMER = ("Annahmen gemäss Konzept, mit Treuhand bestätigen. Die Berechnungen sind Hilfsgrössen und "
              "ersetzen keine Steuerberatung; massgebend sind Spesenreglement, Lohnausweis und kantonale Praxis.")

Q_ESTV_TEUERUNG = "https://www.estv.admin.ch/de/newnsb/VzaAUrhkPx2EPde4a6e3O"
Q_ESTV_FAHRKOSTEN = ("https://www.estv.admin.ch/dam/estv/de/dokumente/estv/steuersystem/steuermaeppchen/"
                     "fahrkosten-de-fr.pdf.download.pdf/fahrkosten-de-fr.pdf")
Q_BE_FAQ = ("https://www.sv.fin.be.ch/content/dam/sv_fin/dokumente/de/"
            "Frage-Antwort_GESCHÄFTSFAHRZEUG_de_rz_WEBSITE.pdf")
Q_BEXIO = "https://www.bexio.com/de-CH/blog/view/kilometergeld-schweiz"
Q_WEKA_MWST = ("https://www.weka.ch/themen/finanzen-controlling/steuern/juristische-personen/article/"
               "berechnung-privatanteil-fahrzeug-mwst-risiken-vermeiden/")

SOURCES = {
    "km_rate": Q_BEXIO, "commute_rate": Q_ESTV_TEUERUNG, "cap_federal": Q_ESTV_FAHRKOSTEN,
    "private_share_pct": Q_BE_FAQ, "min_private_month": Q_BE_FAQ, "vat_rate": Q_WEKA_MWST,
}
LABELS = {
    "km_rate": "Kilometeransatz Geschäftsfahrten (CHF/km)",
    "commute_rate": "Arbeitsweg Privatauto (CHF/km)",
    "cap_federal": "Fahrkostenabzug Obergrenze Bund (CHF)",
    "cap_canton": "Fahrkostenabzug Obergrenze Kanton (CHF)",
    "private_share_pct": "Privatanteil pauschal (% Kaufpreis pro Monat)",
    "min_private_month": "Privatanteil Minimum (CHF pro Monat)",
    "vat_rate": "MWST-Normalsatz (%)",
}

# Default (Bund) je Jahr; Jahre ohne Eintrag nehmen das nächstältere (bzw. das älteste) Jahr.
DEFAULTS: dict[int, dict[str, float]] = {
    2025: {"km_rate": 0.75, "commute_rate": 0.70, "cap_federal": 3300, "private_share_pct": 0.9,
           "min_private_month": 150, "vat_rate": 8.1},
    2026: {"km_rate": 0.75, "commute_rate": 0.75, "cap_federal": 3300, "private_share_pct": 0.9,
           "min_private_month": 150, "vat_rate": 8.1},
}


def canton() -> str | None:
    c = os.environ.get("TAX_CANTON", "").strip().upper()
    return c if len(c) == 2 and c.isalpha() else None


@dataclass
class Param:
    key: str
    value: float
    year: int
    scope: str            # tenant | canton:XX | federal | default
    source_url: str | None
    note: str | None

    def out(self) -> dict:
        return {"key": self.key, "label": LABELS.get(self.key, self.key), "value": self.value, "year": self.year,
                "scope": self.scope, "source_url": self.source_url, "note": self.note}


def _default(year: int, key: str) -> Param | None:
    years = sorted(DEFAULTS)
    use = max((y for y in years if y <= year), default=years[0])
    if key not in DEFAULTS[use]:
        return None
    note = NOTE_A if use == year else f"{NOTE_A}; Wert von {use} übernommen"
    return Param(key, DEFAULTS[use][key], use, "default", SOURCES.get(key), note)


KEYS = ("km_rate", "commute_rate", "cap_federal", "cap_canton", "private_share_pct", "min_private_month",
        "vat_rate")


def resolve_params(db: Session, tenant_id: int, year: int) -> dict[str, Param]:
    """Alle Schlüssel für ein Jahr auflösen: jüngster Jahrgang ≤ `year`, darin tenant > canton:XX > federal >
    Default (s. Modul-Docstring). Werte aus einem Vorjahr erhalten in `note` den Hinweis «Wert von … übernommen»."""
    kt = canton()
    rank = {"tenant": 0, **({f"canton:{kt}": 1} if kt else {}), "federal": 2}
    rows = db.scalars(select(models.TaxParam).where(
        models.TaxParam.tenant_id == tenant_id, models.TaxParam.year <= year, models.TaxParam.deleted.is_(False)))
    best: dict[str, tuple[tuple[int, int, int], models.TaxParam]] = {}
    for r in rows:
        if r.scope not in rank:
            continue                      # anderer Kanton
        prio = (-r.year, rank[r.scope], -r.last_seq)  # jüngster Jahrgang, dann Scope; bei Doppeln der neuste
        if r.key not in best or prio < best[r.key][0]:
            best[r.key] = (prio, r)
    out: dict[str, Param] = {}
    for key in KEYS:
        d = _default(year, key)
        if key in best and (d is None or best[key][1].year >= d.year):
            r = best[key][1]
            note = r.note
            if r.year != year:
                hint = f"Wert von {r.year} übernommen – für {year} prüfen bzw. erfassen"
                note = f"{note}; {hint}" if note else hint
            out[key] = Param(key, r.value, r.year, r.scope, r.source_url, note)
        elif d is not None:
            out[key] = d
    return out


CAT_KM = {"private": "Privat-km", "commute": "Arbeitsweg-km"}


def _r(v: float | None, d: int = 2) -> float | None:
    return None if v is None else round(v, d)


def year_report(db: Session, tenant: models.Tenant, data: VehicleData, year: int) -> dict:
    v = data.vehicle
    ownership = v.ownership or "private"
    method = v.private_use_method or "flat"
    params = resolve_params(db, tenant.id, year)
    warnings: list[str] = []

    trips = trips_between(db, tenant.id, v.id, dt.date(year, 1, 1), dt.date(year, 12, 31))
    km = {c: 0.0 for c in TRIP_CATEGORIES}
    for t in trips:
        km[t.category] += trip_km(t)
    total = sum(km.values())
    shares = {c: _r(km[c] / total * 100, 1) if total else None for c in TRIP_CATEGORIES}
    unconfirmed = sum(1 for t in trips if t.status not in ("confirmed", "locked") or t.category == "unknown")

    months = {local_month(t.start_at) for t in trips}
    months |= {f"{e.date:%Y-%m}" for e in [*data.fuel, *data.odometer] if e.date.year == year}
    months_used = len(months)

    fuel = sum(f.price_total for f in data.fuel if f.date.year == year)
    maint = sum(data.maintenance_cost(m) for m in data.maintenance if m.date.year == year)
    fixed = v.annual_fixed_costs or 0.0
    costs = {"fuel": _r(fuel), "maintenance": _r(maint), "fixed": _r(fixed), "total": _r(fuel + maint + fixed)}
    cost_total = fuel + maint + fixed

    def p(*keys: str) -> list[dict]:
        return [params[k].out() for k in keys if k in params]

    items: dict[str, dict] = {}
    business = ownership == "business"

    # Privatanteil pauschal
    pct, minimum = params["private_share_pct"].value, params["min_private_month"].value
    if not business:
        flat = None
        why = "nur für Geschäftsfahrzeuge (Halter «Geschäftsfahrzeug»)"
    elif v.purchase_price is None:
        flat = None
        why = "Kaufpreis fehlt"
    else:
        monthly = max(pct / 100 * v.purchase_price, minimum)
        flat = monthly * months_used
        why = None
    items["private_share_flat"] = {
        "label": "Privatanteil pauschal", "value": _r(flat), "applicable": business,
        "formula": f"max({pct} % × Kaufpreis, CHF {minimum}) × {months_used} Monate mit Nutzung",
        "inputs": {"purchase_price": v.purchase_price, "months_used": months_used},
        "params": p("private_share_pct", "min_private_month"), "reason": why,
    }

    # Privatanteil effektiv (zwei Varianten wegen ungeklärter Arbeitsweg-Behandlung)
    for key, label, cats in (("private_share_effective", "Privatanteil effektiv", ("private",)),
                             ("private_share_effective_incl_commute", "Privatanteil effektiv inkl. Arbeitsweg",
                              ("private", "commute"))):
        part = sum(km[c] for c in cats)
        val = cost_total * part / total if business and total else None
        items[key] = {
            "label": label, "value": _r(val), "applicable": business,
            "formula": f"Kosten Jahr × {' + '.join(CAT_KM[c] for c in cats)} ÷ Total-km",
            "inputs": {"costs_total": _r(cost_total), "km_part": _r(part, 1), "km_total": _r(total, 1)},
            "params": [], "reason": None if business else "nur für Geschäftsfahrzeuge (Halter «Geschäftsfahrzeug»)",
        }

    # Kilometerentschädigung (Geschäftsfahrten mit Privatauto)
    rate = params["km_rate"].value
    items["km_compensation"] = {
        "label": "Kilometerentschädigung", "value": _r(km["business"] * rate) if not business else None,
        "applicable": not business, "formula": f"geschäftliche km × CHF {rate}/km",
        "inputs": {"business_km": _r(km["business"], 1)}, "params": p("km_rate"),
        "reason": "nur für Privatfahrzeuge (Halter «Privatfahrzeug»)" if business else None,
    }

    # Arbeitsweg-Abzug Bund / Kanton
    crate = params["commute_rate"].value
    raw = km["commute"] * crate
    cap_f = params["cap_federal"].value
    items["commute_deduction_federal"] = {
        "label": "Arbeitsweg-Abzug Bund", "value": _r(min(raw, cap_f)), "applicable": True,
        "formula": f"min(Arbeitsweg-km × CHF {crate}/km, CHF {cap_f})",
        "inputs": {"commute_km": _r(km["commute"], 1), "uncapped": _r(raw)},
        "params": p("commute_rate", "cap_federal"), "reason": None,
    }
    cap_c = params.get("cap_canton")
    items["commute_deduction_canton"] = {
        "label": "Arbeitsweg-Abzug Kanton", "value": _r(min(raw, cap_c.value)) if cap_c else None,
        "applicable": cap_c is not None,
        "formula": f"min(Arbeitsweg-km × CHF {crate}/km, CHF {cap_c.value if cap_c else '–'})",
        "inputs": {"commute_km": _r(km["commute"], 1), "uncapped": _r(raw)},
        "params": p("commute_rate", "cap_canton"),
        "reason": None if cap_c else ("Obergrenze Kanton nicht erfasst (Steuerparameter für den Kanton oder den "
                                      "Mandanten)"),
    }

    # Warnungen
    if not trips:
        warnings.append("Keine Fahrten im Jahr erfasst.")
    if unconfirmed:
        warnings.append(f"{unconfirmed} Fahrt(en) nicht bestätigt bzw. ohne Kategorie – Zahlen vorläufig.")
    if business and v.purchase_price is None:
        warnings.append("Kaufpreis (purchase_price) fehlt – Privatanteil pauschal nicht berechenbar.")
    if v.ownership is None:
        warnings.append("Eigentum (ownership) nicht erfasst – als Privatfahrzeug gerechnet.")
    if business and v.private_use_method is None:
        warnings.append("Methode Privatanteil nicht erfasst – Pauschale angenommen.")
    if v.annual_fixed_costs is None:
        warnings.append("Fixkosten (annual_fixed_costs) fehlen – effektive Kosten unvollständig.")
    if business and total and method == "flat" and (km["business"] + km["field"]) / total < 0.5:
        warnings.append("Geschäftlicher Anteil unter 50 % – Pauschale gemäss Fachquellen ev. nicht zulässig [P].")
    if business and km["commute"]:
        warnings.append("Arbeitsweg mit Geschäftsfahrzeug: bei der Pauschale abgegolten (Art. 5a BKV); "
                        "Behandlung bei effektiver Methode ungeklärt [P].")
    if not business and km["field"]:
        warnings.append("Aussendienst-km sind nicht in der Kilometerentschädigung enthalten – mit Treuhand klären.")
    if carried := sorted(f"{LABELS.get(k, k)} {x.year}" for k, x in params.items()
                         if x.scope != "default" and x.year != year):
        warnings.append(f"Steuerparameter aus Vorjahren übernommen ({', '.join(carried)}) – für {year} prüfen "
                        "bzw. erfassen.")
    if any(x.scope == "default" for x in params.values()):
        warnings.append("Teilweise Default-Parameter verwendet [A] – eigene tax_params erfassen/bestätigen.")

    return {
        "vehicle": {"id": v.id, "name": v.name, "plate": v.plate, "vin": v.vin, "ownership": ownership,
                    "private_use_method": method, "purchase_price": v.purchase_price,
                    "annual_fixed_costs": v.annual_fixed_costs},
        "year": year,
        "canton": canton(),
        "trips_count": len(trips),
        "unconfirmed": unconfirmed,
        "months_used": months_used,
        "km": {**{c: _r(km[c], 1) for c in TRIP_CATEGORIES}, "total": _r(total, 1)},
        "shares_pct": shares,
        "costs": costs,
        "items": items,
        "params": {k: x.out() for k, x in params.items()},
        "warnings": warnings,
        "disclaimer": DISCLAIMER,
    }
