import json

from .conftest import T, new_vehicle, op, sync, uid


def _raw_sync(client, body: str):
    return client.post(f"{T}/sync", content=body, headers={"Content-Type": "application/json"})


def test_inf_nan_rejected_and_tenant_stays_healthy(client):
    vid = new_vehicle(client)
    for bad in ("Infinity", "NaN", "1e309"):
        body = '{"ops":[{"op_id":"%s","entity":"fuel","id":"%s","action":"upsert","data":' \
               '{"vehicle_id":"%s","date":"2026-01-01","km":1,"liters":%s,"price_total":1}}]}' \
               % (uid(), uid(), vid, bad)
        res = _raw_sync(client, body).json()
        assert res["results"][0]["status"] == "rejected", (bad, res)
    assert client.get(f"{T}/vehicles/{vid}/stats").status_code == 200
    assert client.get(f"{T}/changes").status_code == 200


def test_upper_bounds(client):
    vid = new_vehicle(client)
    res = sync(client,
               op("fuel", uid(), {"vehicle_id": vid, "date": "2026-01-01", "km": 2**31, "liters": 1, "price_total": 1}),
               op("odometer", uid(), {"vehicle_id": vid, "date": "2026-01-01", "km": 1, "note": "x" * 2001}),
               op("maintenance_item", uid(), {"maintenance_id": uid(), "label": "a", "position": 10**9}),
               op("odometer", uid(), {"vehicle_id": vid, "date": "2026-01-01", "km": 12000}))
    assert [r["status"] for r in res["results"]] == ["rejected", "rejected", "rejected", "applied"]


def test_pdf_with_unicode_name_and_long_content(client):
    vid = uid()
    sync(client, op("vehicle", vid, {"name": 'Škoda "Octavia"; ü'}))
    mid = uid()
    sync(client,
         op("maintenance", mid, {"vehicle_id": vid, "date": "2026-02-01", "title": "Service", "note": "lang " * 400}),
         *[op("maintenance_item", uid(), {"maintenance_id": mid, "label": f"Punkt {i} " + "x" * 150, "position": i})
           for i in range(80)],
         op("odometer", uid(), {"vehicle_id": vid, "date": "2026-02-01", "km": 1, "note": "Zeile\n" * 300}))
    r = client.get(f"{T}/vehicles/{vid}/report.pdf?from=2026-01-01&to=2026-12-31")
    assert r.status_code == 200, r.text
    cd = r.headers["content-disposition"]
    assert 'filename="Fahrzeugbuch_Skoda__Octavia___u_' in cd and "filename*=UTF-8''Fahrzeugbuch_%C5%A0koda" in cd
    assert '"Octavia"' not in cd


def test_duplicate_op_from_other_tenant_leaks_nothing(client):
    from .conftest import bearer_token
    vid = new_vehicle(client)
    hb = bearer_token(groups=["/fahrzeugbuch/firma"], sub="user-2")
    o = op("vehicle", vid, {"name": "x"})
    r = client.post("/api/t/firma/sync", headers=hb, json={"ops": [o]}).json()["results"][0]
    assert r["status"] == "rejected" and r["error"] == "ID bereits vergeben"
    assert json.dumps(r).count("Golf") == 0


def test_validation_error_with_nan_is_422_without_echo(client):
    body = '{"ops":[{"op_id":"%s","entity":"fuel","id":"%s","action":"upsert","base_version":Infinity}]}' \
        % (uid(), uid())
    r = client.post(f"{T}/sync", content=body, headers={"Content-Type": "application/json"})
    assert r.status_code == 422
    assert "input" not in r.text and "Infinity" not in r.text
