"""Materialstamm (material_article) und Verweis maintenance_material.article_id."""
from sqlalchemy import create_engine, inspect, text

from app.db import Base, engine
from app.integrity import _same
from app.migrate import create_schema

from .conftest import T, bearer_token, new_vehicle, op, sync, uid


def article(name="Motoröl 5W-30", **kw):
    return {"name": name, "part_number": "OIL-530", "unit": "l", "unit_price": 12.5, "category": "Öle",
            "vehicle_id": None, "note": "Hausmarke", **kw}


def maint(vid):
    return {"vehicle_id": vid, "date": "2026-03-01", "km": 10500, "title": "Service"}


def mat(mid, article_id=None, **kw):
    return {"maintenance_id": mid, "article_id": article_id, "name": "Motoröl 5W-30", "part_number": "OIL-530",
            "quantity": 4.5, "unit": "l", "unit_price": 12.5, **kw}


FIRMA = bearer_token(groups=["/fahrzeugbuch/firma"], sub="user-2")


def firma_sync(client, *ops):
    r = client.post("/api/t/firma/sync", headers=FIRMA, json={"ops": list(ops)})
    assert r.status_code == 200, r.text
    return r.json()


def test_create_update_storno_changes_history(client):
    vid = new_vehicle(client)
    a1, a2 = uid(), uid()
    res = sync(client, op("material_article", a1, article()),
               op("material_article", a2, {"name": "Scheibenwischer", "vehicle_id": vid}))
    assert [r["status"] for r in res["results"]] == ["applied", "applied"]
    ch = client.get(f"{T}/changes?since=0").json()
    arts = {a["id"]: a for a in ch["material_articles"]}
    assert arts[a1] == {"id": a1, "version": 1, "deleted": False, **article(),
                        "created_by": "jakob", "updated_by": "jakob"}
    assert arts[a2]["unit"] == "Stk" and arts[a2]["unit_price"] is None and arts[a2]["vehicle_id"] == vid
    assert arts[a2]["part_number"] is None and arts[a2]["category"] is None and arts[a2]["note"] is None
    cursor = ch["cursor"]

    res = sync(client, op("material_article", a1, article(unit_price=13.9), base=1))
    assert res["results"][0]["status"] == "applied" and res["results"][0]["version"] == 2
    res = sync(client, op("material_article", a2, action="delete", base=1))
    assert res["results"][0]["status"] == "applied"
    ch = client.get(f"{T}/changes?since={cursor}").json()
    got = {a["id"]: a for a in ch["material_articles"]}
    assert set(got) == {a1, a2}
    assert got[a1]["unit_price"] == 13.9 and got[a1]["version"] == 2
    assert got[a2]["deleted"] is True and got[a2]["name"] == "Scheibenwischer"
    assert client.get(f"{T}/changes?since={ch['cursor']}").json()["material_articles"] == []

    hist = client.get(f"{T}/history/material_article/{a1}").json()
    assert [(h["action"], h["version"], h["data"]["unit_price"]) for h in hist] == [
        ("create", 1, 12.5), ("update", 2, 13.9)]
    assert [h["action"] for h in client.get(f"{T}/history/material_article/{a2}").json()] == ["create", "delete"]
    # Storno erneut → noop; Konflikt bei veralteter base_version
    assert sync(client, op("material_article", a2, action="delete"))["results"][0]["status"] == "noop"
    assert sync(client, op("material_article", a1, article(), base=1))["results"][0]["status"] == "conflict"
    v = client.get(f"{T}/audit/verify").json()
    assert v["ok"] and v["problems"] == []


def test_validation_bounds_and_inf_nan(client):
    bad = [
        {"name": ""}, {"name": "x" * 151}, {"part_number": "x" * 61}, {"unit": ""}, {"unit": "x" * 21},
        {"unit_price": -0.01}, {"unit_price": 100_000.01}, {"category": "x" * 51}, {"vehicle_id": "x" * 37},
        {"note": "x" * 501},
    ]
    res = sync(client, *[op("material_article", uid(), article(**b)) for b in bad],
               op("material_article", uid(), {"unit": "l"}),                         # name fehlt
               op("material_article", uid(), article(name="x" * 150, part_number="p" * 60, unit="u" * 20,
                                                     unit_price=100_000, category="c" * 50, note="n" * 500)),
               op("material_article", uid(), article(unit_price=0)))
    assert [r["status"] for r in res["results"]] == ["rejected"] * (len(bad) + 1) + ["applied", "applied"]
    for val in ("Infinity", "-Infinity", "NaN", "1e309"):
        body = (f'{{"ops":[{{"op_id":"{uid()}","entity":"material_article","id":"{uid()}",'
                f'"action":"upsert","data":{{"name":"a","unit_price":{val}}}}}]}}')
        r = client.post(f"{T}/sync", content=body, headers={"Content-Type": "application/json"}).json()
        assert r["results"][0]["status"] == "rejected", (val, r)
    assert len(client.get(f"{T}/changes").json()["material_articles"]) == 2
    assert client.get(f"{T}/audit/verify").json()["ok"]


def test_vehicle_reference(client):
    vid = new_vehicle(client)
    fvid = uid()
    assert firma_sync(client, op("vehicle", fvid, {"name": "Firmenauto"}))["results"][0]["status"] == "applied"
    res = sync(client,
               op("material_article", uid(), article(vehicle_id=fvid)),      # Fahrzeug fremder Mandant
               op("material_article", uid(), article(vehicle_id=uid())),     # unbekannt
               op("material_article", uid(), article(vehicle_id=None)),      # für alle Fahrzeuge
               op("material_article", uid(), article(vehicle_id=vid)))
    assert [r["status"] for r in res["results"]] == ["rejected", "rejected", "applied", "applied"]
    assert all("vehicle_id" in r["error"] for r in res["results"][:2])
    # Ändern auf fremdes Fahrzeug ebenfalls abgelehnt
    a = res["results"][3]["id"]
    assert sync(client, op("material_article", a, article(vehicle_id=fvid), base=1))["results"][0]["status"] \
        == "rejected"


def test_maintenance_material_article_reference(client):
    vid = new_vehicle(client)
    mid, a_ok, a_del = uid(), uid(), uid()
    res = sync(client, op("maintenance", mid, maint(vid)),
               op("material_article", a_ok, article()), op("material_article", a_del, article(name="Alt")))
    assert all(r["status"] == "applied" for r in res["results"])
    assert sync(client, op("material_article", a_del, action="delete"))["results"][0]["status"] == "applied"

    fvid, fmid, fa = uid(), uid(), uid()
    r = firma_sync(client, op("vehicle", fvid, {"name": "Firmenauto"}), op("maintenance", fmid, maint(fvid)),
                   op("material_article", fa, article()))
    assert [x["status"] for x in r["results"]] == ["applied"] * 3

    m_ok, m_del, m_none = uid(), uid(), uid()
    res = sync(client,
               op("maintenance_material", m_ok, mat(mid, a_ok)),
               op("maintenance_material", uid(), mat(mid, uid())),          # unbekannter Artikel
               op("maintenance_material", uid(), mat(mid, fa)),             # Artikel fremder Mandant
               op("maintenance_material", uid(), mat(mid, vid)),            # Fahrzeug-ID statt Artikel
               op("maintenance_material", m_del, mat(mid, a_del)),          # stornierter Artikel ok
               op("maintenance_material", m_none, {"maintenance_id": mid, "name": "Kleinteile", "quantity": 1}),
               op("maintenance_material", uid(), mat(mid, "x" * 37)))
    assert [r["status"] for r in res["results"]] == [
        "applied", "rejected", "rejected", "rejected", "applied", "applied", "rejected"]
    assert all("article_id" in r["error"] for r in res["results"][1:4])
    # fremde Wartung bleibt trotz gültigem Artikel abgelehnt
    res = sync(client, op("maintenance_material", uid(), mat(fmid, a_ok)))
    assert res["results"][0]["status"] == "rejected" and "maintenance_id" in res["results"][0]["error"]

    mats = {m["id"]: m for m in client.get(f"{T}/changes?since=0").json()["maintenance_materials"]}
    assert set(mats) == {m_ok, m_del, m_none}
    assert mats[m_ok]["article_id"] == a_ok and mats[m_del]["article_id"] == a_del
    assert mats[m_none]["article_id"] is None

    # Position ist eine Kopie: Stammänderung wirkt nicht auf bestehende Positionen
    sync(client, op("material_article", a_ok, article(name="Neu", unit_price=99), base=1))
    m = {m["id"]: m for m in client.get(f"{T}/changes?since=0").json()["maintenance_materials"]}[m_ok]
    assert m["name"] == "Motoröl 5W-30" and m["unit_price"] == 12.5 and m["version"] == 1
    # Position mit storniertem Artikel bleibt editierbar; Verweis entfernen geht auch
    assert sync(client, op("maintenance_material", m_del, mat(mid, a_del, quantity=2), base=1)
                )["results"][0]["status"] == "applied"
    assert sync(client, op("maintenance_material", m_ok, mat(mid, None), base=1))["results"][0]["status"] == "applied"
    assert client.get(f"{T}/history/maintenance_material/{m_del}").json()[-1]["data"]["article_id"] == a_del
    assert client.get(f"{T}/vehicles/{vid}/report.pdf").content.startswith(b"%PDF")
    assert client.get(f"{T}/audit/verify").json()["ok"]
    assert client.get("/api/t/firma/audit/verify", headers=FIRMA).json()["ok"]


def test_tenant_isolation(client):
    a = uid()
    assert sync(client, op("material_article", a, article()))["results"][0]["status"] == "applied"
    assert client.get("/api/t/firma/changes", headers=FIRMA).json()["material_articles"] == []
    assert client.get("/api/t/firma/changes").json()["material_articles"] == []          # Leser von firma
    assert client.get(f"/api/t/firma/history/material_article/{a}", headers=FIRMA).json() == []
    # ID-Übernahme/Löschen aus fremdem Mandanten → abgelehnt
    r = firma_sync(client, op("material_article", a, article(name="gekapert")),
                   op("material_article", a, action="delete"))
    assert [x["status"] for x in r["results"]] == ["rejected", "rejected"]
    # Lesezugriff darf nicht schreiben
    sync(client, op("material_article", uid(), article()), tenant="firma", expect=403)
    assert client.get(f"{T}/changes").json()["material_articles"][0]["name"] == "Motoröl 5W-30"
    assert client.get("/api/t/firma/audit/verify", headers=FIRMA).json()["count"] == 0


def test_verify_state_detects_article_tampering(client):
    a = uid()
    sync(client, op("material_article", a, article()))
    assert client.get(f"{T}/audit/verify").json()["ok"]
    with engine.begin() as conn:
        conn.execute(text("UPDATE material_articles SET unit_price = 1 WHERE id = :i"), {"i": a})
    v = client.get(f"{T}/audit/verify?full=1").json()
    assert v["chain_ok"] is True and v["state_ok"] is False and v["ok"] is False
    assert any(a in p and "material_article" in p for p in v["problems"])

    # Datensatz ohne Revision
    with engine.begin() as conn:
        tid = conn.execute(text("SELECT id FROM tenants WHERE slug='privat'")).scalar()
        conn.execute(text("INSERT INTO material_articles (id, tenant_id, version, deleted, last_seq, name, unit) "
                          "VALUES (:i, :t, 1, false, 0, 'x', 'Stk')"), {"i": uid(), "t": tid})
    v = client.get(f"{T}/audit/verify").json()
    assert any("material_article" in p and "ohne Revision" in p for p in v["problems"])


def test_verify_state_detects_article_id_tampering(client):
    vid = new_vehicle(client)
    mid, a, m = uid(), uid(), uid()
    sync(client, op("maintenance", mid, maint(vid)), op("material_article", a, article()),
         op("maintenance_material", m, mat(mid)))
    with engine.begin() as conn:
        conn.execute(text("UPDATE maintenance_materials SET article_id = :a WHERE id = :i"), {"a": a, "i": m})
    v = client.get(f"{T}/audit/verify").json()
    assert not v["state_ok"] and any(m in p for p in v["problems"])


def test_legacy_revisions_without_new_field_still_match():
    old = {"name": "Öl", "quantity": 1, "deleted": False}
    assert _same(old, {**old, "article_id": None})
    assert not _same(old, {**old, "article_id": "a"})
    assert not _same(old, {**old, "quantity": 2, "article_id": None})
    assert not _same({**old, "article_id": None}, old)        # Feld entfernt → Abweichung


LEGACY_DDL = """CREATE TABLE maintenance_materials (
    id VARCHAR(36) PRIMARY KEY, tenant_id INTEGER NOT NULL, version INTEGER NOT NULL, deleted BOOLEAN NOT NULL,
    last_seq INTEGER NOT NULL, maintenance_id VARCHAR(36) NOT NULL, name VARCHAR(150) NOT NULL,
    part_number VARCHAR(60), quantity FLOAT NOT NULL, unit VARCHAR(20) NOT NULL, unit_price FLOAT,
    position INTEGER NOT NULL)"""


def _check_retrofit(eng):
    with eng.begin() as conn:
        conn.exec_driver_sql(LEGACY_DDL)
        conn.exec_driver_sql("INSERT INTO maintenance_materials VALUES "
                             "('m1', 1, 1, false, 1, 'w1', 'Öl', NULL, 1, 'Stk', NULL, 0)")
    assert "article_id" not in {c["name"] for c in inspect(eng).get_columns("maintenance_materials")}
    create_schema(eng)
    create_schema(eng)                                     # idempotent
    cols = {c["name"]: c for c in inspect(eng).get_columns("maintenance_materials")}
    assert "article_id" in cols and cols["article_id"]["nullable"]
    assert "material_articles" in inspect(eng).get_table_names()
    with eng.begin() as conn:
        assert conn.execute(text("SELECT article_id FROM maintenance_materials WHERE id='m1'")).one() == (None,)


def test_retrofit_article_id_sqlite(tmp_path):
    eng = create_engine(f"sqlite:///{tmp_path / 'legacy.db'}")
    try:
        _check_retrofit(eng)
    finally:
        eng.dispose()


def test_retrofit_article_id_test_db():
    """Gleiche Nachrüstung auf der Test-DB (PostgreSQL, wenn FZB_TEST_DATABASE_URL gesetzt). Altbestand = ohne
    alembic_version (mit Versionsstand rüstet create_schema nichts per create_all nach, Review S5)."""
    Base.metadata.drop_all(engine)
    with engine.begin() as conn:
        conn.exec_driver_sql("DROP TABLE IF EXISTS alembic_version")
    try:
        _check_retrofit(engine)
    finally:
        Base.metadata.drop_all(engine)
