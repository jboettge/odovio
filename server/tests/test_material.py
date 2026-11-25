import datetime as dt

import pytest
from sqlalchemy import text

from app.db import engine

from .conftest import T, bearer_token, new_vehicle, op, sync, uid


def maint(vid, cost=None, date="2026-03-01", title="Service"):
    return {"vehicle_id": vid, "date": date, "km": 10500, "title": title, "cost": cost}


def mat(mid, name="Motoröl 5W-30", qty=4.5, price=12.5, unit="l", part="OIL-530", position=0):
    return {"maintenance_id": mid, "name": name, "part_number": part, "quantity": qty, "unit": unit,
            "unit_price": price, "position": position}


def _setup(client, cost=None):
    vid = new_vehicle(client)
    mid = uid()
    assert sync(client, op("maintenance", mid, maint(vid, cost)))["results"][0]["status"] == "applied"
    return vid, mid


def test_create_update_storno_and_changes(client):
    _, mid = _setup(client)
    m1, m2 = uid(), uid()
    res = sync(client, op("maintenance_material", m1, mat(mid)),
               op("maintenance_material", m2, {"maintenance_id": mid, "name": "Ölfilter", "quantity": 1}))
    assert [r["status"] for r in res["results"]] == ["applied", "applied"]
    ch = client.get(f"{T}/changes?since=0").json()
    mats = {m["id"]: m for m in ch["maintenance_materials"]}
    assert mats[m1]["quantity"] == 4.5 and mats[m1]["unit"] == "l" and mats[m1]["part_number"] == "OIL-530"
    assert mats[m2]["unit"] == "Stk" and mats[m2]["unit_price"] is None and mats[m2]["position"] == 0
    assert mats[m2]["version"] == 1 and mats[m2]["deleted"] is False
    cursor = ch["cursor"]

    res = sync(client, op("maintenance_material", m1, mat(mid, qty=5), base=1))
    assert res["results"][0]["status"] == "applied" and res["results"][0]["version"] == 2
    res = sync(client, op("maintenance_material", m2, action="delete", base=1))
    assert res["results"][0]["status"] == "applied"
    ch = client.get(f"{T}/changes?since={cursor}").json()
    got = {m["id"]: m for m in ch["maintenance_materials"]}
    assert got[m1]["quantity"] == 5 and got[m2]["deleted"] is True and got[m2]["name"] == "Ölfilter"
    hist = client.get(f"{T}/history/maintenance_material/{m2}").json()
    assert [h["action"] for h in hist] == ["create", "delete"]
    v = client.get(f"{T}/audit/verify").json()
    assert v["ok"] and v["problems"] == []


def test_parent_missing_or_foreign_tenant_rejected(client):
    vid, _ = _setup(client)
    # Wartung in anderem Mandanten
    hb = bearer_token(groups=["/fahrzeugbuch/firma"], sub="user-2")
    fvid, fmid = uid(), uid()
    r = client.post("/api/t/firma/sync", headers=hb, json={"ops": [
        op("vehicle", fvid, {"name": "Firmenauto"}), op("maintenance", fmid, maint(fvid))]}).json()
    assert [x["status"] for x in r["results"]] == ["applied", "applied"]
    res = sync(client,
               op("maintenance_material", uid(), mat(uid())),
               op("maintenance_material", uid(), mat(fmid)),
               op("maintenance_material", uid(), mat(vid)))          # Fahrzeug-ID statt Wartung
    assert [r["status"] for r in res["results"]] == ["rejected"] * 3
    assert all("maintenance_id" in r["error"] for r in res["results"])
    assert client.get(f"{T}/changes?since=0").json()["maintenance_materials"] == []


def test_validation_bounds_and_inf_nan(client):
    vid, mid = _setup(client)
    bad = [
        {"quantity": 0}, {"quantity": -1}, {"quantity": 100_001}, {"unit_price": -0.01},
        {"unit_price": 100_001}, {"name": ""}, {"name": "x" * 151}, {"part_number": "x" * 61},
        {"unit": ""}, {"unit": "x" * 21}, {"position": -1}, {"position": 10_001},
    ]
    res = sync(client, *[op("maintenance_material", uid(), {**mat(mid), **b}) for b in bad],
               op("maintenance_material", uid(), {"maintenance_id": "x" * 37, "name": "a", "quantity": 1}),
               op("maintenance_material", uid(), {"maintenance_id": mid, "name": "a"}),   # quantity fehlt
               op("maintenance_material", uid(), {**mat(mid), "quantity": 100_000, "unit_price": 100_000,
                                                  "position": 10_000}))
    assert [r["status"] for r in res["results"]] == ["rejected"] * (len(bad) + 2) + ["applied"]
    for val in ("Infinity", "-Infinity", "NaN", "1e309"):
        for fld in ("quantity", "unit_price"):
            body = (f'{{"ops":[{{"op_id":"{uid()}","entity":"maintenance_material","id":"{uid()}",'
                    f'"action":"upsert","data":{{"maintenance_id":"{mid}","name":"a","quantity":1,"{fld}":{val}}}}}]}}')
            r = client.post(f"{T}/sync", content=body, headers={"Content-Type": "application/json"}).json()
            assert r["results"][0]["status"] == "rejected", (fld, val, r)
    assert client.get(f"{T}/changes").status_code == 200
    assert client.get(f"{T}/vehicles/{vid}/stats").status_code == 200
    assert client.get(f"{T}/audit/verify").json()["ok"]


def test_stats_cost_fallback_to_material_sum(client):
    vid, mid = _setup(client, cost=None)
    m1, m2 = uid(), uid()
    sync(client,
         op("maintenance_material", m1, mat(mid, qty=4, price=12.5)),            # 50
         op("maintenance_material", m2, mat(mid, name="Filter", qty=2, price=9.9, position=1)),  # 19.8
         op("maintenance_material", uid(), mat(mid, name="Kleinteile", qty=1, price=None)))      # ohne Preis
    assert client.get(f"{T}/vehicles/{vid}/stats").json()["total_maintenance_cost"] == 69.8
    sync(client, op("maintenance_material", m2, action="delete", base=1))          # storniert zählt nicht
    assert client.get(f"{T}/vehicles/{vid}/stats").json()["total_maintenance_cost"] == 50

    # Rechnungsbetrag gesetzt → gilt statt Materialsumme
    sync(client, op("maintenance", mid, maint(vid, cost=300), base=1))
    assert client.get(f"{T}/vehicles/{vid}/stats").json()["total_maintenance_cost"] == 300
    # cost = 0 ist ein gesetzter Betrag (kein Fallback)
    sync(client, op("maintenance", mid, maint(vid, cost=0), base=2))
    assert client.get(f"{T}/vehicles/{vid}/stats").json()["total_maintenance_cost"] == 0

    # zweite Wartung ohne cost, ohne Material → 0; stornierte Wartung zählt nicht
    mid2 = uid()
    sync(client, op("maintenance", mid2, maint(vid, title="Reifen")),
         op("maintenance_material", uid(), mat(mid2, qty=4, price=100)))
    assert client.get(f"{T}/vehicles/{vid}/stats").json()["total_maintenance_cost"] == 400
    sync(client, op("maintenance", mid2, action="delete", base=1))
    assert client.get(f"{T}/vehicles/{vid}/stats").json()["total_maintenance_cost"] == 0


def test_report_pdf_with_materials(client):
    vid, mid = _setup(client)
    mid2 = uid()
    m1 = uid()
    sync(client,
         op("maintenance", mid2, maint(vid, cost=250, date="2026-04-01", title="Bremsen <vorne> & hinten")),
         op("maintenance_material", m1, mat(mid)),
         op("maintenance_material", uid(), mat(mid, name="Kleinteile", price=None, part=None, position=1)),
         *[op("maintenance_material", uid(),
              mat(mid2, name=f"Teil {i} " + "y" * 140, part="P" * 60, qty=1.25, price=99999.99, position=i))
           for i in range(60)])
    sync(client, op("maintenance_material", m1, mat(mid, qty=5), base=1))
    sync(client, op("maintenance_material", m1, action="delete", base=2))
    r = client.get(f"{T}/vehicles/{vid}/report.pdf?from=2026-01-01&to=2026-12-31")
    assert r.status_code == 200, r.text
    assert r.content.startswith(b"%PDF") and len(r.content) > 5000


def test_report_change_log_contains_material_revisions(client, monkeypatch):
    from app import models, report
    from app.db import SessionLocal
    from app.stats import load_vehicle

    vid, mid = _setup(client)
    m1 = uid()
    sync(client, op("maintenance_material", m1, mat(mid)))
    sync(client, op("maintenance_material", m1, mat(mid, qty=6), base=1))
    assert report._describe("maintenance_material", {"name": "Öl", "part_number": "A1", "quantity": 4.5,
                                                     "unit": "l", "unit_price": 12.5}) == "Öl (A1), 4.5 l, CHF 12.50"
    captured = {}
    orig = report._table

    def spy(header, rows, widths):
        captured[tuple(header)] = rows
        return orig(header, rows, widths)

    monkeypatch.setattr(report, "_table", spy)
    with SessionLocal() as db:
        tenant = db.query(models.Tenant).filter_by(slug="privat").one()
        report.build_report(db, tenant, load_vehicle(db, tenant.id, vid), dt.date(2026, 1, 1),
                            dt.date(2026, 12, 31), "jakob")
    log = next(v for k, v in captured.items() if k[0] == "Seq")
    assert any(row[4] == "Material v2" and "6 l" in row[5] for row in log)
    material = next(v for k, v in captured.items() if k[0] == "Wartung")
    assert material[0][1] == "Motoröl 5W-30" and material[0][3] == "6 l" and material[0][5] == "75.00"
    maint_rows = next(v for k, v in captured.items() if k[0] == "Datum" and "Titel" in k)
    assert maint_rows[0][3] == "75.00 (Material)"


def test_verify_state_detects_material_tampering(client):
    _, mid = _setup(client)
    m1 = uid()
    sync(client, op("maintenance_material", m1, mat(mid)))
    assert client.get(f"{T}/audit/verify").json()["ok"]
    with engine.begin() as conn:
        conn.execute(text("UPDATE maintenance_materials SET unit_price = 1 WHERE id = :i"), {"i": m1})
    v = client.get(f"{T}/audit/verify").json()
    assert v["chain_ok"] is True and v["state_ok"] is False and v["ok"] is False
    assert any(m1 in p and "maintenance_material" in p for p in v["problems"])


def test_material_row_without_revision_detected(client):
    _, mid = _setup(client)
    with engine.begin() as conn:
        tid = conn.execute(text("SELECT id FROM tenants WHERE slug='privat'")).scalar()
        conn.execute(text("INSERT INTO maintenance_materials (id, tenant_id, version, deleted, last_seq, "
                          "maintenance_id, name, quantity, unit, position) "
                          "VALUES (:i, :t, 1, false, 0, :m, 'x', 1, 'Stk', 0)"),
                     {"i": uid(), "t": tid, "m": mid})
    v = client.get(f"{T}/audit/verify").json()
    assert not v["ok"] and any("ohne Revision" in p for p in v["problems"])


@pytest.mark.skipif(engine.dialect.name != "postgresql", reason="nur PostgreSQL")
def test_app_role_dml_on_materials(client):
    from sqlalchemy import create_engine
    from sqlalchemy.exc import DBAPIError

    from app.migrate import setup_app_role

    _, mid = _setup(client)
    sync(client, op("maintenance_material", uid(), mat(mid)))
    setup_app_role(engine, "fzb_app_test", "pw-test")
    app_engine = create_engine(engine.url.set(username="fzb_app_test", password="pw-test"))
    try:
        with app_engine.begin() as conn:
            assert conn.execute(text("SELECT count(*) FROM maintenance_materials")).scalar() == 1
            conn.exec_driver_sql("UPDATE maintenance_materials SET name = name")
        with pytest.raises(DBAPIError), app_engine.begin() as conn:
            conn.exec_driver_sql("DELETE FROM maintenance_materials")
    finally:
        app_engine.dispose()
