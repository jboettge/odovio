"""VIN (Fahrgestellnummer) am Fahrzeug: Normalisierung/Validierung, Integritätsprüfung mit Altrevisionen ohne `vin`
(Alembic 0005) und Anzeige in PDF/CSV/Jahresbericht."""
import csv
import io
import json

import pytest
from pydantic import ValidationError
from sqlalchemy import select, text

from app import models
from app import sync as sync_mod
from app.db import SessionLocal, engine
from app.integrity import _same
from app.schemas import VehicleData, normalize_vin

from .conftest import T, op, sync, uid
from .test_trips import errors, pdf_text, statuses, trip

VIN = "WVWZZZ1KZ6W000001"


@pytest.mark.parametrize(("raw", "expected"), [
    (VIN, VIN),
    ("wvwzzz1kz6w000001", VIN),
    ("  WVW ZZZ 1KZ-6W0-00001 ", VIN),
    ("WVW\tZZZ1KZ6W000001", VIN),
    ("1M8GDM9AXKP042788", "1M8GDM9AXKP042788"),          # Prüfziffer korrekt (nordamerikanisch)
    ("1M8GDM9A1KP042788", "1M8GDM9A1KP042788"),          # Prüfziffer falsch: nicht erzwungen
    ("", None), ("   ", None), (" - ", None), (None, None),
])
def test_normalize_vin(raw, expected):
    assert normalize_vin(raw) == expected
    assert VehicleData(name="Golf", vin=raw).vin == expected


@pytest.mark.parametrize("raw", [
    "WVWZZZ1KZ6W00000",          # 16 Zeichen
    "WVWZZZ1KZ6W0000012",        # 18 Zeichen
    "WVWZZZ1KZ6W00000I",         # I
    "WVWZZZ1KZ6W00000O",         # O
    "WVWZZZ1KZ6W00000Q",         # Q
    "WVWZZZ1KZ6W00000_",
    "WVWZZZ1KZ6W00000Ä",
    "X" * 41,                     # Rohwert zu lang
])
def test_invalid_vin_rejected(raw):
    with pytest.raises(ValidationError, match="VIN ungültig|at most 40"):
        VehicleData(name="Golf", vin=raw)


def test_sync_normalizes_and_rejects_vin(client):
    vid, bad = uid(), uid()
    res = sync(client, op("vehicle", vid, {"name": "Golf", "vin": "wvw zzz 1kz 6w0 00001"}),
               op("vehicle", bad, {"name": "Polo", "vin": "WVWZZZ1KZ6W00000O"}))
    assert statuses(res) == ["applied", "rejected"]
    assert "VIN ungültig" in errors(res)[1] and "17 Zeichen" in errors(res)[1]
    vehicles = {v["id"]: v for v in client.get(f"{T}/changes?since=0").json()["vehicles"]}
    assert vehicles[vid]["vin"] == VIN and bad not in vehicles
    hist = client.get(f"{T}/history/vehicle/{vid}").json()
    assert hist[-1]["data"]["vin"] == VIN
    res = sync(client, op("vehicle", vid, {"name": "Golf", "vin": ""}, base=1))
    assert statuses(res) == ["applied"]
    assert client.get(f"{T}/history/vehicle/{vid}").json()[-1]["data"]["vin"] is None


def test_legacy_revision_without_vin_field_matches():
    old = {"name": "Golf", "plate": "ZH 1", "deleted": False}
    defaults = {k: f.default for k, f in VehicleData.model_fields.items()}
    assert _same(old, {**old, "vin": None}, defaults)
    assert not _same(old, {**old, "vin": VIN}, defaults)
    assert not _same({**old, "vin": None}, old, defaults)       # Feld entfernt → Abweichung


def _legacy_vehicle(client, monkeypatch) -> str:
    """Fahrzeug, dessen Revision wie vor Alembic 0005 keinen Schlüssel `vin` enthält."""
    original = sync_mod.snapshot

    def without_vin(obj, schema):
        data = original(obj, schema)
        if schema is VehicleData:
            data.pop("vin", None)
        return data

    vid = uid()
    with monkeypatch.context() as m:
        m.setattr(sync_mod, "snapshot", without_vin)
        assert statuses(sync(client, op("vehicle", vid, {"name": "Golf", "plate": "ZH 1"}))) == ["applied"]
    data = json.loads(_last_revision(vid).data)
    assert "vin" not in data and data["name"] == "Golf"
    return vid


def _last_revision(vid: str) -> models.Revision:
    with SessionLocal() as db:
        return db.scalars(select(models.Revision).where(models.Revision.entity == "vehicle",
                                                        models.Revision.entity_id == vid)
                          .order_by(models.Revision.seq.desc())).first()


def _verify(client, full: bool) -> dict:
    return client.get(f"{T}/audit/verify" + ("?full=1" if full else "")).json()


def test_integrity_legacy_revision_without_vin(client, monkeypatch):
    vid = _legacy_vehicle(client, monkeypatch)
    # Altrevision ohne vin + Datensatz vin = NULL → kein Befund (voll und inkrementell)
    for full in (True, False):
        v = _verify(client, full)
        assert v["ok"] and v["state_ok"] and v["problems"] == [], v

    # VIN über die API setzen → neue Revision mit vin → ok
    res = sync(client, op("vehicle", vid, {"name": "Golf", "plate": "ZH 1", "vin": VIN}, base=1))
    assert statuses(res) == ["applied"]
    assert json.loads(_last_revision(vid).data)["vin"] == VIN
    for full in (False, True):
        v = _verify(client, full)
        assert v["ok"] and v["problems"] == [], v

    # VIN direkt in der DB manipuliert → Befund
    with engine.begin() as conn:
        conn.execute(text("UPDATE vehicles SET vin = 'WVWZZZ1KZ6W999999' WHERE id = :i"), {"i": vid})
    v = _verify(client, True)
    assert not v["ok"] and not v["state_ok"] and any(vid in p and "weicht" in p for p in v["problems"]), v


def test_integrity_detects_vin_injected_into_legacy_record(client, monkeypatch):
    """Altrevision ohne vin, Datensatz bekommt direkt in der DB eine VIN → Befund."""
    vid = _legacy_vehicle(client, monkeypatch)
    assert _verify(client, True)["ok"]
    with engine.begin() as conn:
        conn.execute(text("UPDATE vehicles SET vin = :v WHERE id = :i"), {"v": VIN, "i": vid})
    v = _verify(client, True)
    assert not v["state_ok"] and any(vid in p for p in v["problems"]), v


def _vehicle_with_trip(client, vin: str | None) -> str:
    vid = uid()
    data = {"name": "Golf", "make": "VW", "model": "Golf", "plate": "ZH 123", "initial_km": 10000}
    if vin:
        data["vin"] = vin
    res = sync(client, op("vehicle", vid, data), op("trip", uid(), trip(vid)))
    assert statuses(res) == ["applied", "applied"], res
    return vid


def test_reports_show_vin(client):
    vid = _vehicle_with_trip(client, VIN)
    report = pdf_text(client.get(f"{T}/vehicles/{vid}/report.pdf?from=2026-03-01&to=2026-03-31").content)
    assert f"VIN: {VIN}" in report
    logbook = pdf_text(client.get(f"{T}/vehicles/{vid}/logbook.pdf?month=2026-03").content)
    assert f"VIN: {VIN}" in logbook
    year = pdf_text(client.get(f"{T}/vehicles/{vid}/year-report.pdf?year=2026").content)
    assert f"VIN: {VIN}" in year
    assert client.get(f"{T}/vehicles/{vid}/year-report?year=2026").json()["vehicle"]["vin"] == VIN

    body = client.get(f"{T}/vehicles/{vid}/trips.csv?from=2026-03-01&to=2026-03-31").content.decode("utf-8-sig")
    rows = list(csv.reader(io.StringIO(body), delimiter=";"))
    assert rows[0][-3:] == ["Kennzeichen", "VIN", "ID"]
    assert rows[1][-3:-1] == ["ZH 123", VIN]


def test_reports_without_vin(client):
    vid = _vehicle_with_trip(client, None)
    report = pdf_text(client.get(f"{T}/vehicles/{vid}/report.pdf?from=2026-03-01&to=2026-03-31").content)
    assert "VIN" not in report and "Kennzeichen: ZH 123" in report
    body = client.get(f"{T}/vehicles/{vid}/trips.csv?from=2026-03-01&to=2026-03-31").content.decode("utf-8-sig")
    rows = list(csv.reader(io.StringIO(body), delimiter=";"))
    assert rows[1][-2] == ""
