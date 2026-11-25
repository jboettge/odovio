def make_vehicle(client, **kw):
    r = client.post("/api/vehicles", json={"name": "Golf", "plate": "ZH 123456", "initial_km": 10000, **kw})
    assert r.status_code == 201, r.text
    return r.json()



def test_vehicle_crud(client):
    v = make_vehicle(client)
    assert v["current_km"] == 10000
    r = client.put(f"/api/vehicles/{v['id']}", json={"name": "Golf GTI", "initial_km": 10000})
    assert r.json()["name"] == "Golf GTI"
    assert len(client.get("/api/vehicles").json()) == 1
    assert client.delete(f"/api/vehicles/{v['id']}").status_code == 204
    assert client.get(f"/api/vehicles/{v['id']}").status_code == 404


def test_consumption_full_to_full(client):
    v = make_vehicle(client)
    vid = v["id"]
    fuel = [
        ("2026-01-01", 10000, 40.0, 70.0, True),   # Start (zählt nicht)
        ("2026-01-10", 10300, 10.0, 18.0, False),  # Teilbetankung
        ("2026-01-20", 10600, 26.0, 46.0, True),   # 36 L / 600 km = 6.0
        ("2026-02-01", 11100, 35.0, 63.0, True),   # 35 L / 500 km = 7.0
    ]
    for d, km, l, p, full in fuel:
        r = client.post(f"/api/vehicles/{vid}/fuel",
                        json={"date": d, "km": km, "liters": l, "price_total": p, "full_tank": full})
        assert r.status_code == 201, r.text
    s = client.get(f"/api/vehicles/{vid}/stats").json()
    assert [p["consumption"] for p in s["points"]] == [6.0, 7.0]
    assert s["avg_consumption"] == round(71 / 1100 * 100, 2)
    assert s["avg_liters_per_km"] == round(71 / 1100, 4)
    assert s["avg_cost_per_km"] == round(127 / 1100, 3)
    assert s["current_km"] == 11100
    assert s["driven_km"] == 1100
    assert s["total_fuel_cost"] == 197.0


def test_no_consumption_without_two_full_tanks(client):
    vid = make_vehicle(client)["id"]
    client.post(f"/api/vehicles/{vid}/fuel", json={"date": "2026-01-01", "km": 10100, "liters": 30, "price_total": 50})
    s = client.get(f"/api/vehicles/{vid}/stats").json()
    assert s["avg_consumption"] is None and s["points"] == []


def test_odometer(client):
    vid = make_vehicle(client)["id"]
    r = client.post(f"/api/vehicles/{vid}/odometer", json={"date": "2026-03-01", "km": 12345})
    assert r.status_code == 201
    assert client.get(f"/api/vehicles/{vid}").json()["current_km"] == 12345
    assert client.post(f"/api/vehicles/{vid}/odometer", json={"date": "2026-03-01", "km": -1}).status_code == 422


def test_maintenance_checklist_and_due(client):
    vid = make_vehicle(client)["id"]
    templates = client.get("/api/checklist-templates").json()
    assert templates[0]["title"] == "Service"
    r = client.post(f"/api/vehicles/{vid}/maintenance", json={
        "date": "2026-01-15", "km": 10500, "title": "Service", "cost": 350,
        "next_due_km": 11000,
        "items": [{"label": "Motoröl"}, {"label": "Ölfilter", "done": True}],
    })
    assert r.status_code == 201, r.text
    m = r.json()
    assert [i["done"] for i in m["items"]] == [False, True]
    item_id = m["items"][0]["id"]
    assert client.patch(f"/api/maintenance-items/{item_id}", json={"done": True}).json()["done"] is True
    assert all(i["done"] for i in client.get(f"/api/maintenance/{m['id']}").json()["items"])

    s = client.get(f"/api/vehicles/{vid}/stats").json()
    assert s["due"][0]["overdue"] is False
    assert s["total_maintenance_cost"] == 350
    client.post(f"/api/vehicles/{vid}/odometer", json={"date": "2026-04-01", "km": 11050})
    assert client.get(f"/api/vehicles/{vid}/stats").json()["due"][0]["overdue"] is True

    # Update ersetzt Checkliste
    r = client.put(f"/api/maintenance/{m['id']}", json={
        "date": "2026-01-15", "km": 10500, "title": "Service", "items": [{"label": "Nur eins"}]})
    assert [i["label"] for i in r.json()["items"]] == ["Nur eins"]


def test_delete_vehicle_cascades(client):
    vid = make_vehicle(client)["id"]
    client.post(f"/api/vehicles/{vid}/fuel", json={"date": "2026-01-01", "km": 10100, "liters": 30, "price_total": 50})
    client.post(f"/api/vehicles/{vid}/maintenance", json={"date": "2026-01-01", "title": "X", "items": [{"label": "a"}]})
    assert client.delete(f"/api/vehicles/{vid}").status_code == 204
    assert client.get(f"/api/vehicles/{vid}/fuel").status_code == 404
