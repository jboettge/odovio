from .conftest import T, new_vehicle, op, sync, uid


def fuel(vid, km, liters, price, full=True, date="2026-01-01"):
    return {"vehicle_id": vid, "date": date, "km": km, "liters": liters, "price_total": price, "full_tank": full}


def test_create_and_pull(client):
    vid = new_vehicle(client)
    fid = uid()
    res = sync(client, op("fuel", fid, fuel(vid, 10100, 40, 70)))
    assert res["results"][0] == {"op_id": res["results"][0]["op_id"], "status": "applied", "entity": "fuel",
                                 "id": fid, "version": 1, "error": None}
    ch = client.get(f"{T}/changes?since=0").json()
    assert ch["cursor"] == 2
    assert [v["id"] for v in ch["vehicles"]] == [vid]
    assert ch["fuel"][0]["liters"] == 40 and ch["fuel"][0]["version"] == 1 and ch["fuel"][0]["deleted"] is False
    # inkrementell
    assert client.get(f"{T}/changes?since=2").json()["fuel"] == []
    sync(client, op("fuel", fid, fuel(vid, 10100, 41, 70), base=1))
    ch = client.get(f"{T}/changes?since=2").json()
    assert [f["liters"] for f in ch["fuel"]] == [41] and ch["vehicles"] == []


def test_idempotent_replay(client):
    vid = new_vehicle(client)
    o = op("odometer", uid(), {"vehicle_id": vid, "date": "2026-02-01", "km": 12000})
    assert sync(client, o)["results"][0]["status"] == "applied"
    assert sync(client, o)["results"][0]["status"] == "duplicate"
    assert len(client.get(f"{T}/changes?since=0").json()["odometer"]) == 1
    assert client.get(f"{T}/audit/verify").json()["count"] == 2


def test_conflict_last_writer_wins_but_kept(client):
    vid = new_vehicle(client)
    fid = uid()
    sync(client, op("fuel", fid, fuel(vid, 10100, 40, 70)))
    sync(client, op("fuel", fid, fuel(vid, 10100, 42, 70), base=1))            # Gerät A
    res = sync(client, op("fuel", fid, fuel(vid, 10100, 45, 70), base=1))      # Gerät B, veraltet
    assert res["results"][0]["status"] == "conflict" and res["results"][0]["version"] == 3
    hist = client.get(f"{T}/history/fuel/{fid}").json()
    assert [h["data"]["liters"] for h in hist] == [40, 42, 45]
    assert [h["conflict"] for h in hist] == [False, False, True]


def test_delete_is_storno(client):
    vid = new_vehicle(client)
    fid = uid()
    sync(client, op("fuel", fid, fuel(vid, 10100, 40, 70)))
    assert sync(client, op("fuel", fid, action="delete", base=1))["results"][0]["status"] == "applied"
    assert sync(client, op("fuel", fid, action="delete", base=2))["results"][0]["status"] == "noop"
    f = client.get(f"{T}/changes?since=0").json()["fuel"][0]
    assert f["deleted"] is True and f["liters"] == 40
    assert client.get(f"{T}/vehicles/{vid}/stats").json()["total_fuel_cost"] == 0
    assert [h["action"] for h in client.get(f"{T}/history/fuel/{fid}").json()] == ["create", "delete"]


def test_rejections_do_not_block_batch(client):
    vid = new_vehicle(client)
    good = op("fuel", uid(), fuel(vid, 10100, 40, 70))
    res = sync(client,
               op("fuel", uid(), fuel(vid, 10100, -1, 70)),                    # Validierung
               op("fuel", uid(), fuel(uid(), 10100, 40, 70)),                  # Eltern fehlen
               op("fuel", uid(), action="delete"),                             # unbekannt
               good)
    assert [r["status"] for r in res["results"]] == ["rejected", "rejected", "rejected", "applied"]
    assert "liters" in res["results"][0]["error"]
    v = client.get(f"{T}/audit/verify").json()
    assert v["ok"] and v["count"] == 2 and v["problems"] == []


def test_maintenance_with_items_and_due(client):
    vid = new_vehicle(client)
    mid, i1, i2 = uid(), uid(), uid()
    sync(client,
         op("maintenance", mid, {"vehicle_id": vid, "date": "2026-01-15", "km": 10500, "title": "Service",
                                 "cost": 350, "next_due_km": 11000}),
         op("maintenance_item", i1, {"maintenance_id": mid, "label": "Motoröl", "position": 0}),
         op("maintenance_item", i2, {"maintenance_id": mid, "label": "Ölfilter", "done": True, "position": 1}))
    sync(client, op("maintenance_item", i1, {"maintenance_id": mid, "label": "Motoröl", "done": True}, base=1))
    items = client.get(f"{T}/changes?since=0").json()["maintenance_items"]
    assert all(i["done"] for i in items)
    s = client.get(f"{T}/vehicles/{vid}/stats").json()
    assert s["due"][0]["overdue"] is False and s["total_maintenance_cost"] == 350
    sync(client, op("odometer", uid(), {"vehicle_id": vid, "date": "2026-04-01", "km": 11050}))
    assert client.get(f"{T}/vehicles/{vid}/stats").json()["due"][0]["overdue"] is True


def test_consumption_full_to_full(client):
    vid = new_vehicle(client)
    sync(client,
         op("fuel", uid(), fuel(vid, 10000, 40, 70, date="2026-01-01")),
         op("fuel", uid(), fuel(vid, 10300, 10, 18, full=False, date="2026-01-10")),
         op("fuel", uid(), fuel(vid, 10600, 26, 46, date="2026-01-20")),
         op("fuel", uid(), fuel(vid, 11100, 35, 63, date="2026-02-01")))
    s = client.get(f"{T}/vehicles/{vid}/stats").json()
    assert [p["consumption"] for p in s["points"]] == [6.0, 7.0]
    assert s["avg_consumption"] == round(71 / 1100 * 100, 2)
    assert s["avg_cost_per_km"] == round(127 / 1100, 3)
    assert s["current_km"] == 11100 and s["driven_km"] == 1100


def test_report_pdf(client):
    vid = new_vehicle(client)
    fid = uid()
    mid = uid()
    sync(client,
         op("fuel", fid, fuel(vid, 10000, 40, 70, date="2026-01-01")),
         op("fuel", uid(), fuel(vid, 10600, 36, 64, date="2026-01-20")),
         op("maintenance", mid, {"vehicle_id": vid, "date": "2026-01-15", "km": 10500, "title": "Service & <Öl>"}),
         op("maintenance_item", uid(), {"maintenance_id": mid, "label": "Ölfilter", "done": True}))
    sync(client, op("fuel", fid, action="delete", base=1))
    r = client.get(f"{T}/vehicles/{vid}/report.pdf?from=2026-01-01&to=2026-12-31")
    assert r.status_code == 200 and r.headers["content-type"] == "application/pdf"
    assert r.content.startswith(b"%PDF") and len(r.content) > 2000
    assert client.get(f"{T}/vehicles/{vid}/report.pdf?from=2026-12-31&to=2026-01-01").status_code == 422
    assert client.get(f"{T}/vehicles/{uid()}/report.pdf").status_code == 404
