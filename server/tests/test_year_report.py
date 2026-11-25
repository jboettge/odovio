"""Jahresbericht: km je Kategorie, Kosten, Privatanteil, Kilometerentschädigung, Arbeitsweg-Abzug."""
import pytest

from app import tax

from .conftest import T, op, sync, uid, web_headers
from .test_trips import pdf_text, statuses, trip


def param(key, value, scope="tenant", year=2026, **kw):
    return op("tax_param", uid(), {"year": year, "scope": scope, "key": key, "value": value, **kw})


def seed_year(client, **vehicle):
    vid = uid()
    v = {"name": "Firmenauto", "plate": "ZG 1", **vehicle}
    mid = uid()
    res = sync(client,
               op("vehicle", vid, v),
               op("trip", uid(), trip(vid, start="2026-01-05T08:00:00+01:00", end=None, km_start=10000,
                                      km_end=10600)),
               op("trip", uid(), trip(vid, start="2026-02-05T08:00:00+01:00", end=None, km_start=10600,
                                      km_end=10900, category="private", purpose=None)),
               op("trip", uid(), trip(vid, start="2026-02-06T08:00:00+01:00", end=None, km_start=10900,
                                      km_end=11000, category="commute", purpose=None)),
               op("trip", uid(), trip(vid, start="2025-12-30T08:00:00+01:00", end=None, km_start=9000,
                                      km_end=10000)),                                    # Vorjahr
               op("fuel", uid(), {"vehicle_id": vid, "date": "2026-01-10", "km": 10300, "liters": 50,
                                  "price_total": 100}),
               op("fuel", uid(), {"vehicle_id": vid, "date": "2025-12-10", "km": 9500, "liters": 50,
                                  "price_total": 999}),
               op("maintenance", mid, {"vehicle_id": vid, "date": "2026-02-01", "km": 10700, "title": "Service"}),
               op("maintenance_material", uid(), {"maintenance_id": mid, "name": "Öl", "quantity": 4,
                                                  "unit_price": 50}))   # Materialfallback: 200
    assert all(s == "applied" for s in statuses(res)), res
    return vid


def test_business_vehicle_with_own_params(client, monkeypatch):
    monkeypatch.setenv("TAX_CANTON", "ZH")
    vid = seed_year(client, purchase_price=50_000, ownership="business", private_use_method="effective",
                    annual_fixed_costs=6000)
    deleted = uid()
    res = sync(client,
               param("private_share_pct", 1.0, source_url="https://example.test/treuhand", note="bestätigt"),
               param("commute_rate", 1.0),
               param("cap_canton", 50, scope="canton:ZH"),
               param("cap_canton", 10, scope="canton:BE"),                    # anderer Kanton: ignoriert
               param("min_private_month", 999, year=2025),                    # anderes Jahr: ignoriert
               op("tax_param", deleted, {"year": 2026, "scope": "tenant", "key": "cap_federal", "value": 1}),
               headers=web_headers())
    assert all(s == "applied" for s in statuses(res))
    sync(client, op("tax_param", deleted, action="delete"), headers=web_headers())   # storniert: ignoriert

    r = client.get(f"{T}/vehicles/{vid}/year-report?year=2026").json()
    assert r["year"] == 2026 and r["canton"] == "ZH" and r["trips_count"] == 3 and r["unconfirmed"] == 0
    assert r["km"] == {"business": 600.0, "private": 300.0, "commute": 100.0, "field": 0.0, "unknown": 0.0,
                       "total": 1000.0}
    assert r["shares_pct"]["business"] == 60.0 and r["shares_pct"]["private"] == 30.0
    assert r["months_used"] == 2
    assert r["costs"] == {"fuel": 100.0, "maintenance": 200.0, "fixed": 6000.0, "total": 6300.0}
    it = r["items"]
    assert it["private_share_flat"]["value"] == 1000.0                # max(1 % × 50'000, 150) × 2
    assert it["private_share_effective"]["value"] == 1890.0           # 6300 × 300 / 1000
    assert it["private_share_effective_incl_commute"]["value"] == 2520.0
    assert it["km_compensation"]["value"] is None and it["km_compensation"]["applicable"] is False
    assert it["commute_deduction_federal"]["value"] == 100.0          # min(100 × 1.0, 3300)
    assert it["commute_deduction_canton"]["value"] == 50.0            # min(100, 50)
    pct = {p["key"]: p for p in it["private_share_flat"]["params"]}
    assert pct["private_share_pct"]["scope"] == "tenant" and pct["private_share_pct"]["value"] == 1.0
    assert pct["private_share_pct"]["source_url"] == "https://example.test/treuhand"
    assert pct["min_private_month"]["scope"] == "default" and "[A]" in pct["min_private_month"]["note"]
    assert r["params"]["cap_canton"]["scope"] == "canton:ZH"
    assert r["params"]["cap_federal"] == {**r["params"]["cap_federal"], "value": 3300, "scope": "default"}
    assert any("Arbeitsweg mit Geschäftsfahrzeug" in w for w in r["warnings"])
    assert "Treuhand" in r["disclaimer"]

    pdf = client.get(f"{T}/vehicles/{vid}/year-report.pdf?year=2026")
    assert pdf.status_code == 200 and pdf.content.startswith(b"%PDF")
    assert "Jahresbericht_Firmenauto_2026.pdf" in pdf.headers["content-disposition"]
    txt = pdf_text(pdf.content)
    for s in ("Jahresbericht Fahrtenbuch 2026", "1'890.00", "2'520.00", "1'000.00", "6'300.00",
              "example.test/treuhand", "mit Treuhand", "Kettenkopf"):
        assert s in txt, s
    assert client.get(f"{T}/audit/verify").json()["ok"]


def test_private_vehicle_km_compensation_and_priorities(client, monkeypatch):
    monkeypatch.setenv("TAX_CANTON", "ZH")
    vid = seed_year(client)                                           # ownership None → privat
    sync(client, param("km_rate", 0.8, scope="federal"), param("km_rate", 0.9),
         param("commute_rate", 0.5, scope="canton:ZH"), param("commute_rate", 0.6, scope="federal"),
         headers=web_headers())
    r = client.get(f"{T}/vehicles/{vid}/year-report?year=2026").json()
    it = r["items"]
    assert it["km_compensation"]["value"] == 540.0                    # 600 × 0.9 (Mandant vor Bund)
    assert it["commute_deduction_federal"]["value"] == 50.0           # 100 × 0.5 (Kanton vor Bund)
    assert it["commute_deduction_canton"]["value"] is None and "cap_canton" in it["commute_deduction_canton"]["reason"]
    assert it["private_share_flat"]["value"] is None and it["private_share_effective"]["value"] is None
    assert r["vehicle"]["ownership"] == "private" and r["vehicle"]["private_use_method"] == "flat"
    assert any("ownership" in w for w in r["warnings"])
    assert any("annual_fixed_costs" in w for w in r["warnings"])
    # Doppelter Mandanten-Parameter: neuster gilt
    sync(client, param("km_rate", 1.0), headers=web_headers())
    assert client.get(f"{T}/vehicles/{vid}/year-report?year=2026").json()["items"]["km_compensation"]["value"] == 600


def test_defaults_and_warnings(client, monkeypatch):
    monkeypatch.delenv("TAX_CANTON", raising=False)
    vid = seed_year(client, ownership="business")                     # Kaufpreis fehlt
    r = client.get(f"{T}/vehicles/{vid}/year-report?year=2026").json()
    assert r["canton"] is None
    assert r["items"]["private_share_flat"]["value"] is None
    assert any("purchase_price" in w for w in r["warnings"])
    assert r["items"]["private_share_effective"]["value"] == 90.0     # 300 × 300 / 1000 (ohne Fixkosten)
    assert r["items"]["commute_deduction_federal"]["value"] == 75.0   # 100 × 0.75 (Default 2026)
    r25 = client.get(f"{T}/vehicles/{vid}/year-report?year=2025").json()
    assert r25["trips_count"] == 1 and r25["costs"]["fuel"] == 999.0
    assert r25["params"]["commute_rate"]["value"] == 0.70 and r25["params"]["cap_federal"]["value"] == 3300
    r27 = client.get(f"{T}/vehicles/{vid}/year-report?year=2027").json()
    assert r27["params"]["cap_federal"]["value"] == 3300 and "2026" in r27["params"]["cap_federal"]["note"]
    assert any("Keine Fahrten" in w for w in r27["warnings"])
    assert client.get(f"{T}/vehicles/{vid}/year-report?year=1999").status_code == 422
    assert client.get(f"{T}/vehicles/{uid()}/year-report?year=2026").status_code == 404
    assert client.get(f"{T}/vehicles/{vid}/year-report.pdf?year=2027").status_code == 200


@pytest.mark.parametrize("year,key,value", [
    (2025, "km_rate", 0.75), (2025, "commute_rate", 0.70), (2025, "cap_federal", 3300),
    (2026, "commute_rate", 0.75), (2026, "cap_federal", 3300), (2026, "private_share_pct", 0.9),
    (2026, "min_private_month", 150), (2026, "vat_rate", 8.1), (2026, "km_rate", 0.75),
])
def test_default_constants(year, key, value):
    p = tax._default(year, key)
    assert p.value == value and p.scope == "default" and p.source_url.startswith("https://") and "[A]" in p.note
    assert tax._default(2026, "cap_canton") is None
