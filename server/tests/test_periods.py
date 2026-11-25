"""km-Kette/Odometer-Abgleich, Monatsabschluss, Sperrregeln, Fahrtenbuch-PDF und CSV."""
import base64
import csv
import io
import json
import os

from app import trips

from .conftest import T, bearer_token, new_vehicle, op, sync, uid
from .test_trips import FIRMA, errors, firma_sync, pdf_text, statuses, trip

KEY = base64.b64encode(os.urandom(32)).decode()
MARCH = "2026-03"


def seed_march(client):
    """3 bestätigte Fahrten (lückenlos 10000–10050), 1 Entwurf mit km-Lücke davor, km-Stände 1./31.3."""
    vid = new_vehicle(client)
    ids = [uid() for _ in range(4)]
    res = sync(client,
               op("odometer", uid(), {"vehicle_id": vid, "date": "2026-03-01", "km": 10000}),
               op("trip", ids[0], trip(vid)),
               op("trip", ids[1], trip(vid, start="2026-03-05T17:00:00+01:00", end="2026-03-05T17:20:00+01:00",
                                       km_start=10020, km_end=10035, category="private", purpose=None,
                                       private_mode=True, start_label="Zuhause Geheimweg 1",
                                       end_label="Fitnessstudio")),
               op("trip", ids[2], trip(vid, start="2026-03-10T07:30:00+01:00", end="2026-03-10T07:50:00+01:00",
                                       km_start=10035, km_end=10050, category="commute", purpose=None)),
               op("trip", ids[3], trip(vid, start="2026-03-12T09:00:00+01:00", end="2026-03-12T09:20:00+01:00",
                                       km_start=10060, km_end=10070, category="unknown", status="draft",
                                       purpose=None)),
               op("odometer", uid(), {"vehicle_id": vid, "date": "2026-03-31", "km": 10070}))
    assert all(s == "applied" for s in statuses(res)), res
    return vid, ids


def close(client, vid, month=MARCH, expect=200, headers=None, tenant="privat", **body):
    r = client.post(f"/api/t/{tenant}/vehicles/{vid}/periods/{month}/close", json=body, headers=headers or {})
    assert r.status_code == expect, r.text
    return r.json()


def confirm(client, vid, tid, base, **kw):
    d = trip(vid, start="2026-03-12T09:00:00+01:00", end="2026-03-12T09:20:00+01:00", km_start=10060,
             km_end=10070, purpose="Lieferung Kunde")
    res = sync(client, op("trip", tid, {**d, **kw}, base=base))
    assert statuses(res) == ["applied"], res


def test_check_gaps_odometer_unconfirmed(client):
    vid, ids = seed_march(client)
    c = client.get(f"{T}/vehicles/{vid}/trips/check?month={MARCH}").json()
    assert c["gaps"] == [{"after_trip_id": ids[2], "before_trip_id": ids[3], "km_from": 10050, "km_to": 10060,
                          "km": 10}]
    assert c["unconfirmed"] == 1 and c["closed"] is False and c["trips"] == 4
    assert c["odometer_check"] == {"trip_km": 60.0, "odometer_km": 70, "diff_km": -10.0, "ok": False,
                                   "readings": 2, "note": None}
    assert c["mismatches"] == []
    # Lückenfahrt nachtragen → km-Kette geschlossen, Abgleich ok
    gap = uid()
    sync(client, op("trip", gap, trip(vid, start="2026-03-11T12:00:00+01:00", end="2026-03-11T12:20:00+01:00",
                                      km_start=10050, km_end=10060, category="private", purpose=None,
                                      source="gap")))
    c = client.get(f"{T}/vehicles/{vid}/trips/check?month={MARCH}").json()
    assert c["gaps"] == [] and c["odometer_check"]["ok"] is True and c["odometer_check"]["diff_km"] == 0
    # Plausibilität je Fahrt
    bad = uid()
    sync(client, op("trip", bad, trip(vid, start="2026-03-20T10:00:00+01:00", end=None, km_start=10070,
                                      km_end=10080, distance_gps=30.0, purpose=None)))
    reasons = [m["reason"] for m in client.get(f"{T}/vehicles/{vid}/trips/check?month={MARCH}").json()["mismatches"]
               if m["trip_id"] == bad]
    assert any("GPS-Distanz" in r for r in reasons) and "Endzeit fehlt" in reasons
    assert any("Zweck" in r for r in reasons)
    # Validierung
    assert client.get(f"{T}/vehicles/{vid}/trips/check?month=2026-13").status_code == 422
    assert client.get(f"{T}/vehicles/{vid}/trips/check").status_code == 422
    assert client.get(f"{T}/vehicles/{uid()}/trips/check?month={MARCH}").status_code == 404


def test_check_gap_across_month_boundary_and_few_readings(client):
    vid = new_vehicle(client)
    feb, mar = uid(), uid()
    sync(client, op("trip", feb, trip(vid, start="2026-02-27T08:00:00+01:00", end="2026-02-27T08:10:00+01:00",
                                      km_start=9980, km_end=9990)),
         op("trip", mar, trip(vid)))
    c = client.get(f"{T}/vehicles/{vid}/trips/check?month={MARCH}").json()
    assert c["gaps"] == [{"after_trip_id": feb, "before_trip_id": mar, "km_from": 9990, "km_to": 10000, "km": 10}]
    assert c["odometer_check"]["ok"] is None and c["odometer_check"]["odometer_km"] is None


def test_close_workflow_locks_and_rules(client):
    vid, ids = seed_march(client)
    # 1) unbestätigte Fahrt
    r = close(client, vid, expect=409)["detail"]
    assert r["message"] == "Nicht alle Fahrten bestätigt" and [t["id"] for t in r["trips"]] == [ids[3]]
    # 2) bestätigt, aber Lücke
    confirm(client, vid, ids[3], base=1)
    r = close(client, vid, expect=409)["detail"]
    assert r["message"] == "km-Lücken vorhanden" and r["gaps"][0]["km"] == 10
    assert "Begründung" in close(client, vid, expect=409, force=True)["detail"]["message"]
    assert "Begründung" in close(client, vid, expect=409, force=True, reason=" kurz     ")["detail"]["message"]
    assert client.get(f"{T}/changes").json()["trip_periods"] == []
    # zukünftiger Monat / ungültiger Monat / Leserolle
    close(client, vid, month="2099-01", expect=422)
    close(client, vid, month="2026-3", expect=422)
    fvid = uid()
    firma_sync(client, op("vehicle", fvid, {"name": "Firmenauto"}))
    close(client, fvid, tenant="firma", expect=403)
    close(client, uid(), expect=404)

    # 3) erzwungen mit Begründung
    res = close(client, vid, force=True, reason="Fahrt zur Garage vergessen, km unbekannt")
    p = res["period"]
    assert res["locked_trips"] == 4 and res["forced"] is True and res["anchor"] is None
    assert p["month"] == MARCH and p["status"] == "closed" and p["closed_by"] == "jakob" and p["anchor_seq"] is None
    assert (p["km_start"], p["km_end"], p["trips_count"]) == (10000, 10070, 4)
    assert (p["business_km"], p["private_km"], p["commute_km"], p["field_km"]) == (30.0, 15.0, 15.0, 0.0)
    assert "Fahrt zur Garage vergessen" in p["note"] and p["version"] == 1
    ch = client.get(f"{T}/changes").json()
    assert ch["trip_periods"][0]["id"] == p["id"] and ch["cursor"] == res["cursor"]
    assert {t["status"] for t in ch["trips"]} == {"locked"}
    hist = client.get(f"{T}/history/trip/{ids[0]}").json()
    assert hist[-1]["data"]["status"] == "locked" and hist[-1]["actor_name"] == "jakob"
    assert hist[-1]["action"] == "update"
    assert client.get(f"{T}/history/trip_period/{p['id']}").json()[0]["action"] == "create"
    assert client.get(f"{T}/vehicles/{vid}/trips/check?month={MARCH}").json()["closed"] is True
    # doppelter Abschluss
    assert close(client, vid, expect=409)["detail"]["message"] == "Monat bereits abgeschlossen"

    # 4) Sperrregeln nach Abschluss
    t0 = trip(vid)
    res = sync(client,
               op("trip", ids[0], t0, base=2),                                   # Änderung gesperrt
               op("trip", ids[0], {**t0, "note": "Korrektur"}, base=2),          # auch mit Notiz
               op("trip", uid(), trip(vid, start="2026-03-25T08:00:00+01:00", end=None, km_start=10070,
                                      km_end=10080)),                            # neu im Monat ohne Notiz
               op("trip", uid(), trip(vid, start="2026-03-25T08:00:00+01:00", end=None, km_start=10070,
                                      km_end=10080, note="   ")))
    assert statuses(res) == ["rejected"] * 4
    assert errors(res)[:2] == ["Monat abgeschlossen"] * 2 and "Begründung" in errors(res)[2]
    # Storno gesperrter Fahrten nur mit Begründung (S3a)
    res = sync(client, op("trip", ids[1], action="delete", base=2),
               op("trip", ids[1], action="delete", base=2, reason="zu kurz"))
    assert statuses(res) == ["rejected"] * 2 and all(e.startswith("Begründung erforderlich") for e in errors(res))
    corr, moved = uid(), uid()
    res = sync(client,
               op("trip", ids[1], action="delete", base=2, reason="Doppelt erfasst (Fahrt 5.3.)"),
               op("trip", corr, trip(vid, start="2026-03-25T08:00:00+01:00", end=None, km_start=10070,
                                     km_end=10080, status="confirmed", note="Nachtrag: Beleg Garage")),
               op("trip", moved, trip(vid, start="2026-04-01T08:00:00+02:00", end=None, km_start=10080,
                                      km_end=10090)))                            # April offen
    assert statuses(res) == ["applied"] * 3, res
    res = sync(client, op("trip", ids[1], trip(vid, category="private", purpose=None), base=3),   # Wiederbeleben
               op("trip", corr, trip(vid, note="neu"), base=1),                                  # Korrektur locked
               op("trip", moved, trip(vid, start="2026-03-31T21:00:00+01:00", end=None, km_start=10080,
                                      km_end=10090), base=1))                    # in geschlossenen Monat schieben
    assert statuses(res) == ["rejected"] * 3
    got = {t["id"]: t for t in client.get(f"{T}/changes").json()["trips"]}
    assert got[corr]["status"] == "locked" and got[moved]["status"] == "confirmed"
    assert got[ids[1]]["deleted"] is True and got[ids[1]]["status"] == "locked"
    # Summen des Abschlusses bleiben, Korrekturen werden gezählt; Begründung in der Revision
    period = client.get(f"{T}/changes").json()["trip_periods"][0]
    assert (period["business_km"], period["private_km"], period["trips_count"]) == (30.0, 15.0, 4)
    assert period["corrections"] == 2 and period["version"] == 3       # Storno + Nachtrag
    hist = client.get(f"{T}/history/trip/{ids[1]}").json()
    assert hist[-1]["action"] == "delete" and hist[-1]["data"]["storno_reason"] == "Doppelt erfasst (Fahrt 5.3.)"
    txt = pdf_text(client.get(f"{T}/vehicles/{vid}/logbook.pdf?month={MARCH}").content)
    assert "Korrekturen nach Abschluss: 2" in txt and "Doppelt erfasst" not in txt     # Privatfahrt
    v = client.get(f"{T}/audit/verify").json()
    assert v["ok"] and v["problems"] == [], v


def test_close_clean_month_forces_signed_anchor(client, monkeypatch):
    monkeypatch.setenv("ANCHOR_SIGNING_KEY", KEY)
    monkeypatch.setenv("ANCHOR_INTERVAL_MIN", "600")
    vid, ids = seed_march(client)
    sync(client, op("trip", ids[3], action="delete"))
    before = client.get(f"{T}/audit/anchors").json()["anchors"]
    res = close(client, vid)
    assert res["forced"] is False and res["locked_trips"] == 3
    seq = res["period"]["anchor_seq"]
    assert seq is not None and res["anchor"]["seq"] == seq == res["cursor"]
    hist = client.get(f"{T}/history/trip_period/{res['period']['id']}").json()
    assert hist[0]["seq"] == seq and hist[0]["data"]["anchor_seq"] == seq
    anchors = client.get(f"{T}/audit/anchors").json()["anchors"]
    assert len(anchors) == len(before) + 1 and anchors[-1]["seq"] == seq
    v = client.get(f"{T}/audit/verify").json()
    assert v["ok"], v["problems"]
    pdf = client.get(f"{T}/vehicles/{vid}/logbook.pdf?month={MARCH}")
    assert pdf.status_code == 200 and f"Seq {seq}" in pdf_text(pdf.content)


def test_close_empty_month(client):
    vid = new_vehicle(client)
    res = close(client, vid, month="2026-01")
    assert res["period"]["trips_count"] == 0 and res["period"]["km_start"] is None and res["locked_trips"] == 0


class _Resp(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def test_close_webhook(client, monkeypatch):
    calls = []

    def fake_urlopen(req, timeout=None):
        calls.append((req.full_url, req.get_method(), json.loads(req.data), timeout,
                      req.get_header("Content-type")))
        return _Resp(b"ok")

    monkeypatch.setenv("N8N_WEBHOOK_URL", "https://n8n.example.test/webhook/fahrtenbuch")
    monkeypatch.setattr(trips, "_open", fake_urlopen)
    vid = new_vehicle(client)
    res = close(client, vid, month="2026-01")
    assert len(calls) == 1
    url, method, body, timeout, ctype = calls[0]
    assert url == "https://n8n.example.test/webhook/fahrtenbuch" and method == "POST" and timeout == 5
    assert ctype == "application/json"
    assert body == {"tenant": "privat", "vehicle_id": vid, "month": "2026-01", "period": res["period"],
                    "logbook_pdf_url": f"/api/t/privat/vehicles/{vid}/logbook.pdf?month=2026-01"}

    def broken(req, timeout=None):
        raise OSError("n8n down")

    monkeypatch.setattr(trips, "_open", broken)
    res = close(client, vid, month="2026-02")                 # Fehler nur geloggt
    assert res["period"]["month"] == "2026-02"
    monkeypatch.delenv("N8N_WEBHOOK_URL")
    monkeypatch.setattr(trips, "_open", fake_urlopen)
    close(client, vid, month="2026-03")
    assert len(calls) == 1                                     # ohne URL kein Aufruf


def test_logbook_pdf(client):
    vid, ids = seed_march(client)
    cid = uid()
    sync(client, op("customer", cid, {"name": "Muster AG", "ref": "P-17"}),
         op("trip", ids[0], trip(vid, customer_id=cid, start_label="Werkstatt", end_label="Kundensitz"), base=1))
    confirm(client, vid, ids[3], base=1)
    close(client, vid, force=True, reason="Fahrt zur Garage vergessen, km unbekannt")
    r = client.get(f"{T}/vehicles/{vid}/logbook.pdf?month={MARCH}")
    assert r.status_code == 200 and r.headers["content-type"] == "application/pdf"
    assert "Fahrtenbuch_Golf_2026-03.pdf" in r.headers["content-disposition"]
    assert b"/MediaBox [ 0 0 841.8898 595.2756 ]" in r.content                  # A4 quer
    txt = pdf_text(r.content)
    for s in ("Kundentermin", "Muster AG", "P-17", "Werkstatt", "Kundensitz", "10'000", "10'070", "privat",
              "Arbeitsweg", "abgeschlossen", "Summen je Kategorie", "Garage vergessen", "Lieferung Kunde",
              "mit Treuhand", "Kettenkopf", "Integrit"):
        assert s in txt, s
    assert "Zuhause" not in txt and "Fitnessstudio" not in txt              # Privatmodus
    # Zeitraum statt Monat, Default, Validierung
    assert client.get(f"{T}/vehicles/{vid}/logbook.pdf?from=2026-01-01&to=2026-06-30").status_code == 200
    assert client.get(f"{T}/vehicles/{vid}/logbook.pdf").status_code == 200
    assert client.get(f"{T}/vehicles/{vid}/logbook.pdf?month=2026-00").status_code == 422
    assert client.get(f"{T}/vehicles/{vid}/logbook.pdf?from=2026-06-01&to=2026-01-01").status_code == 422
    assert client.get(f"{T}/vehicles/{uid()}/logbook.pdf?month={MARCH}").status_code == 404


def test_logbook_pdf_robust_long_content(client):
    vid = new_vehicle(client)
    ops = []
    for i in range(60):
        ops.append(op("trip", uid(), trip(
            vid, start=f"2026-05-{1 + i % 28:02d}T{6 + i % 12:02d}:00:00+02:00", end=None,
            km_start=20000 + i * 10, km_end=20000 + i * 10 + 10, purpose="Zweck <b>&" + "x" * 290,
            start_label="S" * 200, end_label="Z\n" * 100, note="Notiz " * 330, driver_name="D" * 100,
            category=["business", "private", "commute", "field", "unknown"][i % 5])))
    assert all(s == "applied" for s in statuses(sync(client, *ops)))
    r = client.get(f"{T}/vehicles/{vid}/logbook.pdf?month=2026-05")
    assert r.status_code == 200 and r.content.startswith(b"%PDF")
    assert client.get(f"{T}/vehicles/{vid}/trips.csv?from=2026-05-01&to=2026-05-31").status_code == 200


def test_trips_csv(client):
    vid, ids = seed_march(client)
    sync(client, op("trip", ids[0], trip(vid, purpose="=HYPERLINK(\"http://x\")"), base=1))
    r = client.get(f"{T}/vehicles/{vid}/trips.csv?from=2026-03-01&to=2026-03-31")
    assert r.status_code == 200 and r.headers["content-type"].startswith("text/csv")
    assert "Fahrten_Golf_2026-03-01_2026-03-31.csv" in r.headers["content-disposition"]
    assert r.content.startswith(b"\xef\xbb\xbf")
    body = r.content.decode("utf-8-sig")
    assert body.startswith("Datum;Start;Ende;km Beginn;km Ende;Distanz km;Startort;Zielort;Kategorie;Zweck")
    rows = list(csv.reader(io.StringIO(body), delimiter=";"))[1:]
    assert len(rows) == 4
    assert rows[0][:6] == ["02.03.2026", "08:00", "08:30", "10000", "10020", "20.0"]
    assert rows[0][9].startswith("'=HYPERLINK")
    assert rows[1][6:8] == ["privat", "privat"] and "Zuhause" not in r.text
    assert rows[2][8] == "Arbeitsweg" and rows[3][12] == "Entwurf"
    assert client.get(f"{T}/vehicles/{vid}/trips.csv?from=2026-04-01&to=2026-03-01").status_code == 422


def test_reader_sees_private_trips_only_aggregated(client):
    fvid = uid()
    firma_sync(client, op("vehicle", fvid, {"name": "Firmenauto"}),
               op("trip", uid(), trip(fvid, category="private", purpose="Coiffeur Meier",
                                      start_label="Bahnhofstrasse 5", end_label="Seeweg 9")),
               op("trip", uid(), trip(fvid, start="2026-03-03T08:00:00+01:00", end=None, km_start=10020,
                                      km_end=10040, purpose="Offerte Kunde", end_label="Kunde Zug")))
    base = f"/api/t/firma/vehicles/{fvid}"
    # Schreibrolle sieht alles
    w = client.get(f"{base}/trips.csv?from=2026-03-01&to=2026-03-31", headers=FIRMA).text
    assert "Coiffeur Meier" in w and "Seeweg 9" in w
    # Leserolle (Treuhand): private Fahrten nur als km
    csv_r = client.get(f"{base}/trips.csv?from=2026-03-01&to=2026-03-31").text
    assert "Coiffeur" not in csv_r and "Seeweg" not in csv_r and "Bahnhofstrasse" not in csv_r
    assert "Offerte Kunde" in csv_r and "Kunde Zug" in csv_r and ";20.0;" in csv_r
    pdf = pdf_text(client.get(f"{base}/logbook.pdf?month={MARCH}").content)
    assert "Coiffeur" not in pdf and "Seeweg" not in pdf and "Offerte Kunde" in pdf
    assert client.get(f"{base}/trips/check?month={MARCH}").status_code == 200
    assert client.get(f"{base}/year-report?year=2026").status_code == 200
    # Sync bleibt für Leser gesperrt
    assert client.post("/api/t/firma/sync", json={"ops": [op("trip", uid(), trip(fvid))]}).status_code == 403
    assert client.get("/api/t/firma/audit/verify", headers=bearer_token(groups=["/fahrzeugbuch/firma"])
                      ).json()["ok"]
