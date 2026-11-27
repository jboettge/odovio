"""E6 Paging von /changes, E7 vorübergehende DB-Fehler → 503, S6 Rate-Limit Vollabgleich,
S9 Cache-Control für /api/*."""
import pytest
from sqlalchemy.exc import IntegrityError, OperationalError

from app import sync as sync_module

from .conftest import T, new_vehicle, op, sync, uid


def test_changes_paging_has_more_and_cursor(client):
    vid = new_vehicle(client)
    ids = {vid}
    for i in range(3):
        cid, pid = uid(), uid()
        sync(client, op("customer", cid, {"name": f"K{i}"}), op("place", pid, {"name": f"P{i}", "kind": "work"}))
        ids |= {cid, pid}
    sync(client, op("vehicle", vid, {"name": "Golf neu"}, base=1))          # Fahrzeug erneut geändert
    full = client.get(f"{T}/changes").json()
    assert full["has_more"] is False and full["cursor"] == 8

    seen, since, pages = [], 0, 0
    while True:
        page = client.get(f"{T}/changes?since={since}&limit=3").json()
        pages += 1
        rows = [r for key in ("vehicles", "customers", "places") for r in page[key]]
        assert len(rows) <= 3
        seen += [r["id"] for r in rows]
        assert page["cursor"] >= since
        since = page["cursor"]
        if not page["has_more"]:
            break
    assert pages == 3 and since == 8
    assert sorted(seen) == sorted(ids) and len(seen) == len(set(seen))   # vollständig, ohne Doppel
    # Seite 1 endet exakt an der höchsten gelieferten last_seq
    p1 = client.get(f"{T}/changes?since=0&limit=3").json()
    assert p1["has_more"] and p1["cursor"] == 4                          # Seq 1 (Fzg.) überholt, 2–4
    assert client.get(f"{T}/changes?limit=5001").status_code == 422
    assert client.get(f"{T}/changes?limit=0").status_code == 422


def test_transient_db_error_aborts_whole_sync_with_503(client, monkeypatch):
    real = sync_module._apply

    def flaky(db, tenant, user, o):
        name = (o.data or {}).get("name")
        if name == "verbindung-weg":
            raise OperationalError("SELECT 1", {}, Exception("server closed the connection"))
        if name == "constraint":
            raise IntegrityError("INSERT", {}, Exception("unique violation"))
        return real(db, tenant, user, o)

    monkeypatch.setattr(sync_module, "_apply", flaky)
    ok1, ok2 = uid(), uid()
    r = client.post(f"{T}/sync", json={"ops": [op("customer", ok1, {"name": "A"}),
                                               op("customer", uid(), {"name": "verbindung-weg"})]})
    assert r.status_code == 503 and r.headers["Retry-After"] == "30"
    assert client.get(f"{T}/changes").json()["customers"] == []           # nichts übernommen
    res = sync(client, op("customer", ok1, {"name": "A"}), op("customer", uid(), {"name": "constraint"}),
               op("customer", ok2, {"name": "B"}))
    assert [x["status"] for x in res["results"]] == ["applied", "rejected", "applied"]
    assert res["results"][1]["error"] == "Datenbankfehler"
    assert client.get(f"{T}/audit/verify").json()["ok"]


def test_db_errors_logged_without_values(client, monkeypatch, caplog):
    """X10/S14: weder SQL-Parameter noch PostgreSQL-DETAIL (Zeilenwerte) im Log."""
    from sqlalchemy import text

    from app.db import engine
    assert engine.hide_parameters
    with pytest.raises(IntegrityError) as e, engine.begin() as conn:
        conn.execute(text("INSERT INTO tenants (id, slug, name, seq, head_hash) VALUES (:a, :b, :b, 0, 'x')"),
                     [{"a": 900001, "b": "geheimer-zweck"}, {"a": 900001, "b": "geheimer-zweck"}])
    assert "geheimer-zweck" not in str(e.value) and "hidden" in str(e.value)

    def boom(db, tenant, user, o):
        raise IntegrityError("INSERT INTO trips …", {"purpose": "Arzt Dr. Geheim"},
                             Exception('Failing row contains (Arzt Dr. Geheim, Bahnhofstrasse 1)'))
    monkeypatch.setattr(sync_module, "_apply", boom)
    caplog.set_level("INFO")
    res = sync(client, op("customer", uid(), {"name": "x"}))
    assert res["results"][0]["error"] == "Datenbankfehler"
    assert "Sync-Op" in caplog.text and "Geheim" not in caplog.text and "Bahnhofstrasse" not in caplog.text


@pytest.mark.parametrize("path", ["/api/me", f"{T}/changes", "/api/checklist-templates"])
def test_api_responses_not_cacheable(client, path):
    r = client.get(path)
    assert r.status_code == 200 and r.headers["cache-control"] == "no-store"
    assert "no-store" not in client.get("/health").headers.get("cache-control", "")
    r = client.get(path, headers={"Authorization": ""})
    assert r.status_code == 401 and r.headers["cache-control"] == "no-store"


def test_full_sync_rate_limited(client, monkeypatch):
    monkeypatch.setenv("RATE_FULL_SYNC", "2")
    new_vehicle(client)
    assert client.get(f"{T}/changes").status_code == 200
    assert client.get(f"{T}/changes?since=0").status_code == 200
    r = client.get(f"{T}/changes")
    assert r.status_code == 429 and int(r.headers["Retry-After"]) >= 1
    assert client.get(f"{T}/changes?since=1").status_code == 200        # inkrementell unbegrenzt


def test_list_vehicles_current_km_aggregated(client):
    a = new_vehicle(client, name="A", initial_km=1000)
    b = new_vehicle(client, name="B", initial_km=5000)
    dead = uid()
    sync(client, op("odometer", uid(), {"vehicle_id": a, "date": "2026-01-01", "km": 1500}),
         op("fuel", uid(), {"vehicle_id": a, "date": "2026-01-02", "km": 1700, "liters": 30, "price_total": 50}),
         op("maintenance", uid(), {"vehicle_id": a, "date": "2026-01-03", "km": 1600, "title": "Service"}),
         op("maintenance", uid(), {"vehicle_id": a, "date": "2026-01-04", "title": "ohne km"}),
         op("odometer", dead, {"vehicle_id": a, "date": "2026-01-05", "km": 9999}))
    sync(client, op("odometer", dead, action="delete"))
    got = {v["name"]: v["current_km"] for v in client.get(f"{T}/vehicles").json()}
    assert got == {"A": 1700, "B": 5000}
    stats = client.get(f"{T}/vehicles/{a}/stats").json()
    assert stats["current_km"] == 1700 and b
