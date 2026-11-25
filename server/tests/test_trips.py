"""Fahrtenbuch-Entitäten: trip, place, customer, purpose_rule, tax_param, trip_period (Sync)."""
import base64
import re
import zlib

import pytest
from sqlalchemy import create_engine, inspect, text

from app.db import engine
from app.integrity import _same
from app.migrate import DML_TABLES, create_schema

from .conftest import T, bearer_token, new_vehicle, op, sync, uid

FIRMA = bearer_token(groups=["/fahrzeugbuch/firma"], sub="user-2")


def firma_sync(client, *ops):
    r = client.post("/api/t/firma/sync", headers=FIRMA, json={"ops": list(ops)})
    assert r.status_code == 200, r.text
    return r.json()


def trip(vid, start="2026-03-02T08:00:00+01:00", end="2026-03-02T08:30:00+01:00", km_start=10000, km_end=10020,
         category="business", status="confirmed", purpose="Kundentermin", **kw):
    return {"vehicle_id": vid, "start_at": start, "end_at": end, "km_start": km_start, "km_end": km_end,
            "category": category, "status": status, "purpose": purpose, **kw}


def statuses(res) -> list[str]:
    return [r["status"] for r in res["results"]]


def errors(res) -> list[str]:
    return [r["error"] or "" for r in res["results"]]


def pdf_text(content: bytes) -> str:
    """Text aller (Flate-komprimierten) Inhaltsströme – ohne PDF-Bibliothek."""
    out = []
    for m in re.finditer(rb"stream\r?\n(.*?)endstream", content, re.S):
        raw = m.group(1).strip()
        if raw.endswith(b"~>"):                                   # reportlab: ASCII85 + Flate
            raw = base64.a85decode(raw[:-2].replace(b"\n", b"").replace(b"\r", b""))
        try:
            out.append(zlib.decompress(raw).decode("latin-1"))
        except zlib.error:
            out.append(raw.decode("latin-1"))
    return "\n".join(out)


def test_crud_all_entities_and_changes(client):
    vid = new_vehicle(client)
    cid, pid, tid, rid, xid = uid(), uid(), uid(), uid(), uid()
    res = sync(client,
               op("customer", cid, {"name": "Muster AG", "ref": "P-17", "note": "Hauptkunde"}),
               op("place", pid, {"name": "Büro Kunde", "kind": "customer", "lat": 47.376887, "lon": 8.541694,
                                 "customer_id": cid, "default_category": "business"}),
               op("trip", tid, trip(vid, start_place_id=pid, end_place_id=pid, customer_id=cid,
                                    track_hash="AB" * 32, distance_gps=20.4)),
               op("purpose_rule", rid, {"from_place_id": pid, "to_place_id": pid, "weekdays": "5,1,3",
                                        "time_from": "07:00", "time_to": "09:30", "vehicle_id": vid,
                                        "result_category": "business", "result_customer_id": cid}),
               op("tax_param", xid, {"year": 2026, "scope": "tenant", "key": "km_rate", "value": 0.8,
                                     "source_url": "https://example.test/spesen"}))
    assert statuses(res) == ["applied"] * 5, res
    ch = client.get(f"{T}/changes?since=0").json()
    for key in ("trips", "places", "customers", "purpose_rules", "tax_params", "trip_periods"):
        assert key in ch
    t = ch["trips"][0]
    assert t["id"] == tid and t["version"] == 1 and t["deleted"] is False
    assert t["source"] == "manual" and t["private_mode"] is False and t["track_hash"] == "ab" * 32
    assert t["suggestion_category"] is None and t["split_of"] is None
    p = ch["places"][0]
    assert (p["lat"], p["lon"], p["radius_m"], p["private"]) == (47.377, 8.542, 150, False)
    r = ch["purpose_rules"][0]
    assert r["weekdays"] == "1,3,5" and r["auto_confirm"] is False and r["origin"] == "user" and r["active"]
    assert ch["customers"][0]["ref"] == "P-17" and ch["tax_params"][0]["value"] == 0.8
    assert ch["trip_periods"] == []

    # Ändern, Aufteilen (Storno + 2 neue mit split_of), Storno
    cursor = ch["cursor"]
    res = sync(client, op("trip", tid, trip(vid, purpose="Projekt X"), base=1))
    assert statuses(res) == ["applied"] and res["results"][0]["version"] == 2
    a, b = uid(), uid()
    res = sync(client, op("trip", tid, action="delete", base=2),
               op("trip", a, trip(vid, end="2026-03-02T08:15:00+01:00", km_end=10010, split_of=tid)),
               op("trip", b, trip(vid, start="2026-03-02T08:15:00+01:00", km_start=10010, category="private",
                                  purpose=None, split_of=tid)),
               op("customer", cid, action="delete"))
    assert statuses(res) == ["applied"] * 4, res
    ch = client.get(f"{T}/changes?since={cursor}").json()
    assert {x["id"] for x in ch["trips"]} == {tid, a, b}
    assert ch["customers"][0]["deleted"] is True
    hist = client.get(f"{T}/history/trip/{tid}").json()
    assert [h["action"] for h in hist] == ["create", "update", "delete"]
    assert hist[1]["data"]["purpose"] == "Projekt X"
    # Verweis auf stornierten Kunden bleibt zulässig (Altdaten editierbar)
    assert statuses(sync(client, op("trip", a, trip(vid, km_end=10010, end="2026-03-02T08:15:00+01:00",
                                                     customer_id=cid, split_of=tid), base=1))) == ["applied"]
    v = client.get(f"{T}/audit/verify").json()
    assert v["ok"] and v["problems"] == [], v


def test_references_foreign_tenant_rejected(client):
    vid = new_vehicle(client)
    fvid, fcid, fpid, ftid = uid(), uid(), uid(), uid()
    r = firma_sync(client, op("vehicle", fvid, {"name": "Firmenauto"}), op("customer", fcid, {"name": "Fremd"}),
                   op("place", fpid, {"name": "Fremd", "kind": "other"}), op("trip", ftid, trip(fvid)))
    assert statuses(r) == ["applied"] * 4
    res = sync(client,
               op("trip", uid(), trip(fvid)),
               op("trip", uid(), trip(vid, customer_id=fcid)),
               op("trip", uid(), trip(vid, start_place_id=fpid)),
               op("trip", uid(), trip(vid, end_place_id=uid())),
               op("trip", uid(), trip(vid, split_of=ftid)),
               op("place", uid(), {"name": "x", "kind": "customer", "customer_id": fcid}),
               op("purpose_rule", uid(), {"result_category": "business", "result_customer_id": fcid}),
               op("purpose_rule", uid(), {"result_category": "business", "from_place_id": fpid}),
               op("purpose_rule", uid(), {"result_category": "business", "vehicle_id": fvid}),
               op("trip", uid(), trip(vid, suggestion_customer_id=uid())),   # Vorschlag: kein Ref-Check
               op("trip", ftid, trip(vid)))                                   # ID-Übernahme
    assert statuses(res) == ["rejected"] * 9 + ["applied", "rejected"], res
    for err, field in zip(errors(res), ("vehicle_id", "customer_id", "start_place_id", "end_place_id", "split_of",
                                        "customer_id", "result_customer_id", "from_place_id", "vehicle_id")):
        assert field in err, (err, field)
    assert errors(res)[-1] == "ID bereits vergeben"
    assert client.get("/api/t/firma/changes", headers=FIRMA).json()["trips"][0]["vehicle_id"] == fvid
    assert all(t["vehicle_id"] == vid for t in client.get(f"{T}/changes").json()["trips"])


def test_trip_timestamp_normalization_and_validation(client):
    vid = new_vehicle(client)
    a, b = uid(), uid()
    res = sync(client,
               op("trip", a, trip(vid, start="2026-03-02T08:00:00.123456+01:00", end="2026-03-02T08:30+01:00")),
               op("trip", b, trip(vid, start="2026-03-02T07:00:00Z", end=None)))
    assert statuses(res) == ["applied", "applied"], res
    got = {t["id"]: t for t in client.get(f"{T}/changes").json()["trips"]}
    assert got[a]["start_at"] == "2026-03-02T08:00:00+01:00" and got[a]["end_at"] == "2026-03-02T08:30:00+01:00"
    assert got[b]["start_at"] == "2026-03-02T07:00:00+00:00" and got[b]["end_at"] is None
    bad = [
        trip(vid, start="2026-03-02T08:00:00"),                                   # ohne Offset
        trip(vid, start="gestern"),
        trip(vid, start="2026-03-02T08:00:00+01:00" + " " * 30),                  # > 40 Zeichen
        trip(vid, start="1999-03-02T08:00:00+01:00"),
        trip(vid, end="2026-03-02T07:59:59+01:00"),                               # Ende vor Start
        trip(vid, end="2026-03-02T07:30:00+00:00"),                               # 07:30Z = 08:30+01:00 → ok
        trip(vid, km_start=100, km_end=99),
        trip(vid, km_start=-1),
        trip(vid, km_end=5_000_001),
        trip(vid, distance_gps=10_000.1),
        trip(vid, distance_route=-1),
        trip(vid, suggestion_confidence=1.01),
        trip(vid, category="dienstlich"),
        trip(vid, source="gps"),
        trip(vid, suggestion_source="magic"),
        trip(vid, track_hash="xyz"),
        trip(vid, purpose="x" * 301),
        trip(vid, note="x" * 2001),
        trip(vid, driver_name="x" * 101),
        {k: v for k, v in trip(vid).items() if k != "start_at"},
    ]
    res = sync(client, *[op("trip", uid(), d) for d in bad])
    st = statuses(res)
    # 07:30Z ist exakt 08:30+01:00 = nicht vor dem Start → zulässig
    assert st[5] == "applied"
    assert st[:5] + st[6:] == ["rejected"] * (len(bad) - 1), list(zip(st, errors(res)))
    assert "km_end kleiner als km_start" in errors(res)[6]
    assert "end_at liegt vor start_at" in errors(res)[4]
    assert "Offset" in errors(res)[0]


def test_place_rules(client):
    home, work = uid(), uid()
    res = sync(client,
               op("place", uid(), {"name": "Zuhause", "kind": "home", "lat": 47.1, "lon": 8.1}),
               op("place", uid(), {"name": "Zuhause", "kind": "home", "lon": 8.1}),
               op("place", home, {"name": "Zuhause", "kind": "home", "private": True}),
               op("place", work, {"name": "Büro", "kind": "work", "lat": -33.8688197, "lon": 151.2092955,
                                  "radius_m": 5000}),
               op("place", uid(), {"name": "x", "kind": "work", "lat": 90.01}),
               op("place", uid(), {"name": "x", "kind": "work", "lon": -180.5}),
               op("place", uid(), {"name": "x", "kind": "work", "radius_m": 49}),
               op("place", uid(), {"name": "x", "kind": "work", "radius_m": 5001}),
               op("place", uid(), {"name": "", "kind": "work"}),
               op("place", uid(), {"name": "x", "kind": "büro"}),
               op("place", uid(), {"name": "x", "kind": "work", "default_category": "freizeit"}))
    assert statuses(res) == ["rejected", "rejected", "applied", "applied"] + ["rejected"] * 7
    assert errors(res)[0] == "Wohnort-Koordinaten bleiben auf dem Gerät" == errors(res)[1]
    # Nachträglich Koordinaten an den Wohnort hängen → ebenfalls abgelehnt
    res = sync(client, op("place", home, {"name": "Zuhause", "kind": "home", "lat": 47.0, "lon": 8.0}, base=1))
    assert statuses(res) == ["rejected"]
    places = {p["id"]: p for p in client.get(f"{T}/changes").json()["places"]}
    assert places[home]["lat"] is None and places[home]["private"] is True
    assert (places[work]["lat"], places[work]["lon"]) == (-33.869, 151.209)


def test_customer_rule_taxparam_validation(client):
    res = sync(client,
               op("customer", uid(), {"name": ""}), op("customer", uid(), {"name": "x" * 151}),
               op("customer", uid(), {"name": "x", "ref": "r" * 51}), op("customer", uid(), {"name": "x" * 150}),
               op("purpose_rule", uid(), {"result_category": "unknown"}),
               op("purpose_rule", uid(), {"result_category": "business", "weekdays": "0,1"}),
               op("purpose_rule", uid(), {"result_category": "business", "weekdays": "1,1"}),
               op("purpose_rule", uid(), {"result_category": "business", "weekdays": "Mo,Di"}),
               op("purpose_rule", uid(), {"result_category": "business", "time_from": "24:00"}),
               op("purpose_rule", uid(), {"result_category": "business", "time_to": "7:00"}),
               op("purpose_rule", uid(), {"result_category": "business", "priority": 1001}),
               op("purpose_rule", uid(), {"result_category": "commute", "weekdays": "7, 6", "origin": "learned",
                                          "auto_confirm": True, "priority": 0}),
               op("tax_param", uid(), {"year": 2026, "scope": "canton:zh", "key": "cap_canton", "value": 1}),
               op("tax_param", uid(), {"year": 2026, "scope": "kanton", "key": "cap_canton", "value": 1}),
               op("tax_param", uid(), {"year": 2026, "scope": "tenant", "key": "zins", "value": 1}),
               op("tax_param", uid(), {"year": 1999, "scope": "tenant", "key": "km_rate", "value": 1}),
               op("tax_param", uid(), {"year": 2026, "scope": "tenant", "key": "km_rate", "value": -1}),
               op("tax_param", uid(), {"year": 2026, "scope": "canton:ZH", "key": "cap_canton", "value": 6000}))
    assert statuses(res) == (["rejected"] * 3 + ["applied"] + ["rejected"] * 7 + ["applied"]
                             + ["rejected"] * 5 + ["applied"]), list(zip(statuses(res), errors(res)))
    rule = client.get(f"{T}/changes").json()["purpose_rules"][0]
    assert rule["weekdays"] == "6,7" and rule["auto_confirm"] is True


def test_trip_period_is_server_only(client):
    vid = new_vehicle(client)
    pid = uid()
    res = sync(client, op("trip_period", pid, {"vehicle_id": vid, "month": "2026-03", "status": "closed"}),
               op("trip_period", pid, action="delete"))
    assert statuses(res) == ["rejected", "rejected"]
    assert all("nur vom Server" in e for e in errors(res))
    assert client.get(f"{T}/changes").json()["trip_periods"] == []


def test_client_cannot_set_locked(client):
    vid = new_vehicle(client)
    res = sync(client, op("trip", uid(), trip(vid, status="locked")))
    assert statuses(res) == ["rejected"] and "nur der Server" in errors(res)[0]


def test_vehicle_tax_fields(client):
    vid = uid()
    old = uid()
    res = sync(client,
               op("vehicle", old, {"name": "Alt"}),
               op("vehicle", vid, {"name": "Firmenauto", "purchase_price": 48_000, "ownership": "business",
                                   "private_use_method": "effective", "annual_fixed_costs": 5400}),
               op("vehicle", uid(), {"name": "x", "ownership": "leasing"}),
               op("vehicle", uid(), {"name": "x", "private_use_method": "pauschal"}),
               op("vehicle", uid(), {"name": "x", "purchase_price": 10_000_001}),
               op("vehicle", uid(), {"name": "x", "annual_fixed_costs": -1}))
    assert statuses(res) == ["applied", "applied"] + ["rejected"] * 4
    got = {v["id"]: v for v in client.get(f"{T}/changes").json()["vehicles"]}
    assert got[old]["ownership"] is None and got[old]["purchase_price"] is None
    assert got[old]["private_use_method"] is None and got[old]["annual_fixed_costs"] is None
    assert got[vid]["ownership"] == "business" and got[vid]["purchase_price"] == 48_000
    # Altrevision ohne neue Felder entspricht Datensatz mit None
    legacy = {"name": "Alt", "make": None, "deleted": False}
    assert _same(legacy, {**legacy, "purchase_price": None, "ownership": None, "private_use_method": None,
                          "annual_fixed_costs": None})
    assert not _same(legacy, {**legacy, "ownership": "business"})
    assert client.get(f"{T}/audit/verify").json()["ok"]


def test_verify_state_detects_trip_tampering(client):
    vid = new_vehicle(client)
    tid = uid()
    sync(client, op("trip", tid, trip(vid)))
    assert client.get(f"{T}/audit/verify").json()["ok"]
    with engine.begin() as conn:
        conn.execute(text("UPDATE trips SET category = 'private' WHERE id = :i"), {"i": tid})
    v = client.get(f"{T}/audit/verify").json()
    assert v["chain_ok"] and not v["state_ok"] and any(tid in p and "trip" in p for p in v["problems"])
    with engine.begin() as conn:
        conn.execute(text("UPDATE trips SET category = 'business', start_at = '2026-03-02T09:00:00+01:00' "
                          "WHERE id = :i"), {"i": tid})
    assert not client.get(f"{T}/audit/verify").json()["state_ok"]
    with engine.begin() as conn:
        conn.execute(text("UPDATE trips SET start_at = '2026-03-02T08:00:00+01:00' WHERE id = :i"), {"i": tid})
    assert client.get(f"{T}/audit/verify").json()["ok"]


def test_dml_tables_cover_new_tables():
    for t in ("trips", "places", "customers", "purpose_rules", "tax_params", "trip_periods", "vehicles"):
        assert t in DML_TABLES
    assert "revisions" not in DML_TABLES and "anchors" not in DML_TABLES


LEGACY_VEHICLES = """CREATE TABLE vehicles (
    id VARCHAR(36) PRIMARY KEY, tenant_id INTEGER NOT NULL, version INTEGER NOT NULL, deleted BOOLEAN NOT NULL,
    last_seq INTEGER NOT NULL, name VARCHAR(100) NOT NULL, make VARCHAR(100), model VARCHAR(100),
    plate VARCHAR(30), fuel_type VARCHAR(20) NOT NULL, initial_km INTEGER NOT NULL)"""


def test_retrofit_vehicle_columns_generic(tmp_path):
    eng = create_engine(f"sqlite:///{tmp_path / 'legacy.db'}")
    try:
        with eng.begin() as conn:
            conn.exec_driver_sql(LEGACY_VEHICLES)
            conn.exec_driver_sql("INSERT INTO vehicles VALUES ('v1', 1, 1, false, 1, 'Golf', NULL, NULL, NULL, "
                                 "'benzin', 0)")
        create_schema(eng)
        create_schema(eng)
        cols = {c["name"]: c for c in inspect(eng).get_columns("vehicles")}
        for c in ("purchase_price", "ownership", "private_use_method", "annual_fixed_costs"):
            assert c in cols and cols[c]["nullable"]
        assert {"trips", "places", "trip_periods"} <= set(inspect(eng).get_table_names())
        with eng.begin() as conn:
            assert conn.execute(text("SELECT ownership, purchase_price FROM vehicles")).one() == (None, None)
    finally:
        eng.dispose()


@pytest.mark.skipif(engine.dialect.name != "postgresql", reason="nur PostgreSQL")
def test_app_role_on_trip_tables(client):
    from sqlalchemy.exc import DBAPIError

    from app.migrate import setup_app_role

    vid = new_vehicle(client)
    sync(client, op("trip", uid(), trip(vid)))
    setup_app_role(engine, "fzb_app_trips", "pw-test")
    app_engine = create_engine(engine.url.set(username="fzb_app_trips", password="pw-test"))
    try:
        with app_engine.begin() as conn:                        # erlaubte DML
            conn.exec_driver_sql("UPDATE trips SET note = note")
            conn.exec_driver_sql("SELECT count(*) FROM trip_periods, places, customers, purpose_rules, tax_params")
        for stmt in ("DELETE FROM trips", "DELETE FROM trip_periods", "TRUNCATE places"):
            with pytest.raises(DBAPIError):
                with app_engine.begin() as conn:
                    conn.exec_driver_sql(stmt)
    finally:
        app_engine.dispose()
