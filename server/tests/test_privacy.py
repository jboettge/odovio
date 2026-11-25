"""S1 Maskierung für die Leserolle (/changes, /history), S4 Privatmodus/Wohnort serverseitig,
S15 Fahrer aus dem Token, S20 wiederverwendete op_id."""
from app.privacy import PRIVATE_PLACE_NAME, TRIP_MASKED

from .conftest import T, bearer_token, op, sync, uid
from .test_trips import FIRMA, errors, firma_sync, statuses, trip

F = "/api/t/firma"


def _seed_firma(client):
    vid, cid, home, office = uid(), uid(), uid(), uid()
    biz, priv, pmode, later = uid(), uid(), uid(), uid()
    res = firma_sync(
        client,
        op("vehicle", vid, {"name": "Firmenauto"}),
        op("customer", cid, {"name": "Onkologie Zentrum"}),
        op("place", home, {"name": "Praxis Dr. Muster", "kind": "other", "private": True}),
        op("place", office, {"name": "Büro", "kind": "work", "lat": 47.37, "lon": 8.54}),
        op("trip", biz, trip(vid, purpose="Offerte Kunde", end_label="Kunde Zug", end_place_id=office)),
        op("trip", priv, trip(vid, start="2026-03-03T08:00:00+01:00", end=None, km_start=10020, km_end=10040,
                              category="private", purpose="Arzt Dr. Muster", start_label="Praxis Onkologie",
                              end_label="Zuhause Musterweg 1", start_place_id=home, customer_id=cid,
                              note="Kontrolle", track_hash="ab" * 32, distance_gps=20.4,
                              suggestion_purpose="Arzt", suggestion_category="private")),
        op("trip", pmode, trip(vid, start="2026-03-04T08:00:00+01:00", end=None, km_start=10040, km_end=10050,
                               category="private", private_mode=True, purpose=None, start_label="Zürich",
                               end_label="Winterthur")),
        op("trip", later, trip(vid, start="2026-03-05T08:00:00+01:00", end=None, km_start=10050, km_end=10060,
                               purpose="Arzt (eigentlich privat)", end_label="Praxis")),
    )
    assert statuses(res) == ["applied"] * 8, res
    # nachträglich als privat umgestuft → auch ältere Revisionen werden maskiert
    res = firma_sync(client, op("trip", later, trip(vid, start="2026-03-05T08:00:00+01:00", end=None,
                                                    km_start=10050, km_end=10060, category="private",
                                                    purpose=None, end_label="Praxis"), base=1))
    assert statuses(res) == ["applied"]
    return vid, home, office, biz, priv, pmode, later


def test_reader_changes_and_history_masked(client):
    vid, home, office, biz, priv, pmode, later = _seed_firma(client)
    ch = client.get(f"{F}/changes").json()           # Standard-Token: /fahrzeugbuch/firma/lesen
    trips = {t["id"]: t for t in ch["trips"]}
    for tid in (priv, pmode, later):
        t = trips[tid]
        assert all(t[k] is None for k in TRIP_MASKED if k in t), t
        assert t["category"] == "private" and t["km_start"] is not None
    assert trips[priv]["distance_gps"] == 20.4 and trips[priv]["start_at"] == "2026-03-03T08:00:00+01:00"
    assert trips[biz]["purpose"] == "Offerte Kunde" and trips[biz]["end_place_id"] == office
    places = {p["id"]: p for p in ch["places"]}
    assert places[home]["name"] == PRIVATE_PLACE_NAME and places[home]["lat"] is None
    assert places[office]["name"] == "Büro" and places[office]["lat"] == 47.37
    text = client.get(f"{F}/changes").text
    for secret in ("Arzt", "Praxis Onkologie", "Musterweg", "Praxis Dr. Muster", "Kontrolle"):
        assert secret not in text, secret
    # Verlauf: alle Stände maskiert, auch der ursprünglich geschäftliche Stand von `later`
    for tid in (priv, later):
        hist = client.get(f"{F}/history/trip/{tid}").json()
        assert hist and all(h["data"]["purpose"] is None and h["data"]["end_label"] is None for h in hist)
    assert client.get(f"{F}/history/place/{home}").json()[0]["data"]["name"] == PRIVATE_PLACE_NAME
    assert client.get(f"{F}/history/trip/{biz}").json()[0]["data"]["purpose"] == "Offerte Kunde"
    # Schreibrolle sieht alles
    w = {t["id"]: t for t in client.get(f"{F}/changes", headers=FIRMA).json()["trips"]}
    assert w[priv]["purpose"] == "Arzt Dr. Muster" and w[priv]["track_hash"] == "ab" * 32
    assert client.get(f"{F}/history/trip/{later}", headers=FIRMA).json()[0]["data"]["purpose"] \
        == "Arzt (eigentlich privat)"


def test_private_mode_enforced_on_server(client):
    vid, home, office, *_ = _seed_firma(client)
    base = trip(vid, start="2026-03-10T08:00:00+01:00", end=None, km_start=10100, km_end=10110,
                category="private", private_mode=True, purpose=None)
    res = firma_sync(client,
                     op("trip", uid(), {**base, "start_place_id": office}),
                     op("trip", uid(), {**base, "end_place_id": office}),
                     op("trip", uid(), {**base, "purpose": "Geheim"}),
                     op("trip", uid(), {**base, "track_hash": "cd" * 32}),
                     op("trip", uid(), {**base, "suggestion_purpose": "x"}),
                     op("trip", uid(), {**base, "start_label": "Geheimadresse 5, 8000 Zürich, " + "x" * 40}),
                     op("trip", uid(), {**base, "start_label": "Zürich", "end_label": "Bern"}))
    assert statuses(res) == ["rejected"] * 6 + ["applied"], res
    assert all(e.startswith("Privatmodus:") for e in errors(res)[:6])
    # Orte: private Orte und Wohnort ohne Koordinaten
    res = firma_sync(client,
                     op("place", uid(), {"name": "Zuhause", "kind": "other", "private": True, "lat": 47.3,
                                         "lon": 8.5}),
                     op("place", uid(), {"name": "Zuhause", "kind": "home", "lat": 47.3}),
                     op("place", uid(), {"name": "Kunde", "kind": "other", "lat": 47.3, "lon": 8.5}))
    assert statuses(res) == ["rejected", "rejected", "applied"]


def test_driver_set_from_token(client):
    vid, tid = uid(), uid()
    firma_sync(client, op("vehicle", vid, {"name": "Firmenauto"}),
               op("trip", tid, trip(vid, driver_sub="gefälscht", driver_name="Chef")))
    t = client.get(f"{F}/changes", headers=FIRMA).json()["trips"][0]
    assert (t["driver_sub"], t["driver_name"]) == ("user-2", "jakob")
    other = bearer_token(groups=["/fahrzeugbuch/firma"], sub="user-9", preferred_username="anna")
    r = client.post(f"{F}/sync", headers=other, json={"ops": [
        op("trip", tid, trip(vid, purpose="Korrektur", driver_sub="user-9", driver_name="anna"), base=1)]})
    assert r.json()["results"][0]["status"] == "applied"
    t = client.get(f"{F}/changes", headers=FIRMA).json()["trips"][0]
    assert (t["driver_sub"], t["driver_name"], t["purpose"]) == ("user-2", "jakob", "Korrektur")


def test_reused_op_id_for_other_object_rejected(client):
    a, b, oid = uid(), uid(), uid()
    assert statuses(sync(client, op("customer", a, {"name": "A"}, op_id=oid))) == ["applied"]
    assert statuses(sync(client, op("customer", a, {"name": "A"}, op_id=oid))) == ["duplicate"]
    res = sync(client, op("customer", b, {"name": "B"}, op_id=oid), op("place", a, {"name": "P", "kind": "work"},
                                                                       op_id=oid))
    assert statuses(res) == ["rejected", "rejected"]
    assert all("op_id bereits verwendet" in e for e in errors(res))
    assert [c["id"] for c in client.get(f"{T}/changes").json()["customers"]] == [a]
