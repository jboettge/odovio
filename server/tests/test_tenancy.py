from .conftest import bearer_token, new_vehicle, op, sync, uid


def test_no_access_to_foreign_tenant(client):
    assert client.get("/api/t/fremd/changes").status_code == 403
    assert client.post("/api/t/fremd/sync", json={"ops": []}).status_code == 403


def test_reader_can_pull_but_not_push(client):
    assert client.get("/api/t/firma/changes").status_code == 200
    sync(client, op("vehicle", uid(), {"name": "X"}), tenant="firma", expect=403)


def test_isolation(client, monkeypatch):
    vid = new_vehicle(client)
    # Benutzer B mit Schreibrecht nur auf "firma"
    hb = bearer_token(groups=["/fahrzeugbuch/firma"], sub="user-2")
    assert client.get("/api/t/firma/changes", headers=hb).json()["vehicles"] == []
    assert client.get(f"/api/t/firma/vehicles/{vid}/stats", headers=hb).status_code == 404
    # fremde Fahrzeug-ID als Eltern oder ID-Übernahme → abgelehnt
    r = client.post("/api/t/firma/sync", headers=hb, json={"ops": [
        op("fuel", uid(), {"vehicle_id": vid, "date": "2026-01-01", "km": 1, "liters": 1, "price_total": 1}),
        op("vehicle", vid, {"name": "gekapert"}),
    ]}).json()
    assert [x["status"] for x in r["results"]] == ["rejected", "rejected"]
    assert client.get("/api/t/privat/changes").json()["vehicles"][0]["name"] == "Golf"
    # getrennte Revisionsketten
    assert client.get("/api/t/firma/audit/verify", headers=hb).json()["count"] == 0
    assert client.get("/api/t/privat/audit/verify").json()["count"] == 1
