"""S3 Monatsabschluss: Namen einfrieren (b), Blockaden (c), nur abgelaufene Monate (d), km-Stände im
abgeschlossenen Monat (e), Berichte stornierter Fahrzeuge (f), Monatszuordnung nach Zürcher Zeit (g),
geschätzte km-Stände (U3)."""
import csv
import io

from app.timeutil import current_month

from .conftest import T, new_vehicle, op, sync, uid
from .test_periods import close
from .test_trips import errors, pdf_text, statuses, trip


def _csv_rows(client, vid, frm="2026-02-01", to="2026-02-28"):
    body = client.get(f"{T}/vehicles/{vid}/trips.csv?from={frm}&to={to}").content.decode("utf-8-sig")
    return list(csv.reader(io.StringIO(body), delimiter=";"))[1:]


def test_names_frozen_at_close(client):
    vid = new_vehicle(client)
    pid, cid, priv_place, a, b = uid(), uid(), uid(), uid(), uid()
    sync(client, op("place", pid, {"name": "Büro Alt", "kind": "work"}),
         op("place", priv_place, {"name": "Arzt", "kind": "other"}),
         op("customer", cid, {"name": "Kunde Alt", "ref": "K-1"}),
         op("trip", a, trip(vid, start="2026-02-02T08:00:00+01:00", end="2026-02-02T08:30:00+01:00",
                            customer_id=cid, start_place_id=pid, end_label="Ziel", customer_name="gefälscht")),
         op("trip", b, trip(vid, start="2026-02-03T08:00:00+01:00", end="2026-02-03T08:30:00+01:00",
                            km_start=10020, km_end=10030, category="private", purpose=None,
                            start_place_id=priv_place)))
    got = {t["id"]: t for t in client.get(f"{T}/changes").json()["trips"]}
    assert got[a]["customer_name"] is None                     # Client-Wert ignoriert
    close(client, vid, month="2026-02")
    got = {t["id"]: t for t in client.get(f"{T}/changes").json()["trips"]}
    assert got[a]["customer_name"] == "Kunde Alt (K-1)" and got[a]["start_label"] == "Büro Alt"
    assert got[a]["end_label"] == "Ziel"
    assert got[b]["start_label"] is None                       # Privatfahrt: kein Ort eingefroren
    before = _csv_rows(client, vid)
    pdf_before = pdf_text(client.get(f"{T}/vehicles/{vid}/logbook.pdf?month=2026-02").content)
    sync(client, op("place", pid, {"name": "Büro NEU", "kind": "work"}, base=1),
         op("customer", cid, {"name": "Kunde NEU"}, base=1))
    assert _csv_rows(client, vid) == before
    pdf_after = pdf_text(client.get(f"{T}/vehicles/{vid}/logbook.pdf?month=2026-02").content)
    assert "NEU" not in pdf_after and "Kunde Alt" in pdf_before and "Kunde Alt" in pdf_after
    v = client.get(f"{T}/audit/verify").json()
    assert v["ok"], v["problems"]


def test_close_blocked_by_incomplete_trips(client):
    vid = new_vehicle(client)
    t1, t2, t3, t4 = uid(), uid(), uid(), uid()
    sync(client,
         op("trip", t1, trip(vid, start="2026-02-02T08:00:00+01:00", end="2026-02-02T08:30:00+01:00",
                             purpose=None, customer_id=None)),                       # geschäftlich ohne Zweck
         op("trip", t2, trip(vid, start="2026-02-03T08:00:00+01:00", end=None, km_start=10020, km_end=10030,
                             category="field", purpose="Service")),                  # ohne Endzeit
         op("trip", t3, trip(vid, start="2026-02-04T08:00:00+01:00", end="2026-02-04T09:00:00+01:00",
                             km_start=10030, km_end=None)),                          # ohne km-Ende
         op("trip", t4, trip(vid, start="2026-02-05T08:00:00+01:00", end="2026-02-05T09:00:00+01:00",
                             km_start=10030, km_end=10050, km_estimated=True)))      # geschätzt
    chk = client.get(f"{T}/vehicles/{vid}/trips/check?month=2026-02").json()
    reasons = {(m["trip_id"], m["reason"], m["blocking"]) for m in chk["mismatches"]}
    assert (t1, "Zweck fehlt (geschäftlich)", True) in reasons
    assert (t2, "Endzeit fehlt", True) in reasons
    assert (t3, "km-Stand Beginn/Ende fehlt", True) in reasons
    assert (t4, "km-Stand geschätzt (nicht abgelesen)", True) in reasons
    r = close(client, vid, month="2026-02", expect=409)["detail"]
    assert r["message"].startswith("Fahrten unvollständig")
    assert {m["trip_id"] for m in r["mismatches"]} == {t1, t2, t3, t4}
    assert "Begründung" in close(client, vid, month="2026-02", expect=409, force=True, reason="kurz")["detail"][
        "message"]
    res = close(client, vid, month="2026-02", force=True, reason="Belege fehlen, mit Treuhand abgesprochen")
    assert res["forced"] is True and len(res["mismatches"]) == 4
    assert "4 unvollständigen Angaben" in res["period"]["note"]


def test_only_past_months_can_be_closed(client):
    vid = new_vehicle(client)
    now = current_month()
    r = close(client, vid, month=now, expect=422)
    assert r["detail"] == "Nur abgelaufene Monate können abgeschlossen werden"
    close(client, vid, month="2099-12", expect=422)
    close(client, vid, month="2026-01")


def test_readings_in_closed_month_need_reason(client):
    vid = new_vehicle(client)
    odo, fuel, maint, maint_nokm = uid(), uid(), uid(), uid()
    sync(client, op("odometer", odo, {"vehicle_id": vid, "date": "2026-02-01", "km": 10000}),
         op("fuel", fuel, {"vehicle_id": vid, "date": "2026-02-10", "km": 10200, "liters": 40, "price_total": 70}),
         op("maintenance", maint, {"vehicle_id": vid, "date": "2026-02-12", "km": 10300, "title": "Service"}),
         op("maintenance", maint_nokm, {"vehicle_id": vid, "date": "2026-02-12", "title": "Wäsche"}))
    close(client, vid, month="2026-02")
    reason = "Ablesefehler korrigiert (Foto)"
    res = sync(client,
               op("odometer", odo, {"vehicle_id": vid, "date": "2026-02-01", "km": 10010}, base=1),
               op("fuel", fuel, action="delete"),
               op("fuel", uid(), {"vehicle_id": vid, "date": "2026-02-20", "km": 10400, "liters": 1,
                                  "price_total": 2}),
               op("maintenance", maint, {"vehicle_id": vid, "date": "2026-02-12", "km": 10310, "title": "Service"},
                  base=1),
               op("odometer", odo, {"vehicle_id": vid, "date": "2026-03-01", "km": 10010}, base=1),  # verschieben
               op("maintenance", maint_nokm, {"vehicle_id": vid, "date": "2026-02-12", "title": "Wäsche innen"},
                  base=1),                                                                     # ohne km: frei
               op("odometer", uid(), {"vehicle_id": vid, "date": "2026-03-02", "km": 10500}))   # März offen
    assert statuses(res) == ["rejected"] * 5 + ["applied"] * 2, res
    assert all(e.startswith("Begründung erforderlich") for e in errors(res)[:5])
    res = sync(client,
               op("odometer", odo, {"vehicle_id": vid, "date": "2026-02-01", "km": 10010}, base=1, reason=reason),
               op("fuel", fuel, action="delete", reason=reason))
    assert statuses(res) == ["applied", "applied"]
    period = client.get(f"{T}/changes").json()["trip_periods"][0]
    assert period["corrections"] == 2
    hist = client.get(f"{T}/history/odometer/{odo}").json()
    assert hist[-1]["data"]["correction_reason"] == reason
    assert client.get(f"{T}/history/fuel/{fuel}").json()[-1]["data"]["storno_reason"] == reason
    pdf = pdf_text(client.get(f"{T}/vehicles/{vid}/report.pdf?from=2026-02-01&to=2026-02-28").content)
    assert "Ablesefehler" in pdf
    assert client.get(f"{T}/audit/verify").json()["ok"]


def test_reports_for_deleted_vehicle(client):
    vid = new_vehicle(client)
    sync(client, op("trip", uid(), trip(vid, start="2026-02-02T08:00:00+01:00", end="2026-02-02T08:30:00+01:00")))
    close(client, vid, month="2026-02")
    assert statuses(sync(client, op("vehicle", vid, action="delete"))) == ["applied"]
    for url in ("logbook.pdf?month=2026-02", "trips.csv?from=2026-02-01&to=2026-02-28",
                "report.pdf?from=2026-02-01&to=2026-02-28", "year-report?year=2026", "year-report.pdf?year=2026",
                "stats", "trips/check?month=2026-02"):
        assert client.get(f"{T}/vehicles/{vid}/{url}").status_code == 200, url
        assert client.get(f"{T}/vehicles/{uid()}/{url}").status_code == 404, url
    assert vid not in [v["id"] for v in client.get(f"{T}/vehicles").json()]
    close(client, vid, month="2026-01", expect=404)            # kein neuer Abschluss
    # fremder Mandant → wie nicht vorhanden
    assert client.get(f"/api/t/firma/vehicles/{vid}/logbook.pdf?month=2026-02").status_code == 404


def test_month_assignment_uses_zurich_time(client):
    vid = new_vehicle(client)
    oct_ = uid()
    sync(client, op("trip", oct_, trip(vid, start="2026-10-30T08:00:00+01:00", end="2026-10-30T08:30:00+01:00")))
    close(client, vid, month="2026-10")
    # 01.11. 12:30 +14:00 = 31.10. 23:30 in Zürich → Oktober (abgeschlossen)
    trick = trip(vid, start="2026-11-01T12:30:00+14:00", end=None, km_start=10020, km_end=10030)
    res = sync(client, op("trip", uid(), trick))
    assert statuses(res) == ["rejected"] and "Monat abgeschlossen" in errors(res)[0]
    # 31.10. 23:30 −10:00 = 01.11. 10:30 in Zürich → November (offen)
    nov = uid()
    res = sync(client, op("trip", nov, trip(vid, start="2026-10-31T23:30:00-10:00", end=None, km_start=10020,
                                            km_end=10030)))
    assert statuses(res) == ["applied"]
    assert client.get(f"{T}/vehicles/{vid}/trips/check?month=2026-10").json()["trips"] == 1
    assert client.get(f"{T}/vehicles/{vid}/trips/check?month=2026-11").json()["trips"] == 1
    rows = _csv_rows(client, vid, "2026-11-01", "2026-11-30")
    assert len(rows) == 1 and rows[0][:2] == ["01.11.2026", "10:30"]


def test_legacy_revisions_without_new_defaults_still_match():
    from app.integrity import _same
    defaults = {"corrections": 0, "km_estimated": False, "customer_name": None}
    old = {"month": "2026-01", "deleted": False}
    assert _same(old, {**old, "corrections": 0}, defaults)
    assert not _same(old, {**old, "corrections": 1}, defaults)
    assert _same(old, {**old, "km_estimated": False, "customer_name": None}, defaults)
    assert not _same(old, {**old, "km_estimated": True}, defaults)
    assert _same({**old, "storno_reason": "Doppelt erfasst"}, old, defaults)       # nur in der Revision
