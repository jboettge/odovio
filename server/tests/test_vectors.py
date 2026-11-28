"""E11 Gemeinsame Testvektoren (tests/vectors/*.json) für Fachlogik, die Server und App doppelt rechnen:
Verbrauch, km-Lücken, Jahresbericht. Die App-Tests lesen dieselben Dateien.

Neu erzeugen (nach bewusster Änderung der Fachlogik):  FZB_WRITE_VECTORS=1 pytest tests/test_vectors.py
"""
import datetime as dt
import json
import os
from pathlib import Path
from types import SimpleNamespace

import pytest

from app.stats import consumption_points, summarize
from app.trips import _sorted, km_gaps

from .conftest import T, op, sync, uid, web_headers

VECTORS = Path(__file__).parent / "vectors"
WRITE = os.environ.get("FZB_WRITE_VECTORS") == "1"


def _load(name: str) -> dict:
    return json.loads((VECTORS / f"{name}.json").read_text(encoding="utf-8"))


def _check(name: str, data: dict, case: dict, got: dict) -> None:
    if WRITE:
        case["expected"] = got
        (VECTORS / f"{name}.json").write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n",
                                              encoding="utf-8")
    assert got == case["expected"], case["name"]


def _ids(name: str) -> list[str]:
    return [c["name"] for c in _load(name)["cases"]]


def test_ios_vector_copy_matches():
    """Die App-Tests lesen eine Kopie (ios/Tests/FahrzeugbuchTests/vectors) – muss identisch sein."""
    ios = Path(__file__).resolve().parents[2] / "ios" / "Tests" / "FahrzeugbuchTests" / "vectors"
    if not ios.is_dir():
        pytest.skip("iOS-Verzeichnis nicht vorhanden")
    for f in VECTORS.glob("*.json"):
        assert (ios / f.name).read_bytes() == f.read_bytes(), f"{f.name}: iOS-Kopie veraltet"


@pytest.mark.parametrize("case_name", _ids("consumption"))
def test_consumption_vectors(case_name):
    data = _load("consumption")
    case = next(c for c in data["cases"] if c["name"] == case_name)
    entries = [SimpleNamespace(**{**f, "date": dt.date.fromisoformat(f["date"])}) for f in case["fuel"]]
    points = consumption_points(entries)
    got = {"points": [{**p, "date": p["date"].isoformat()} for p in points], "summary": summarize(points)}
    _check("consumption", data, case, got)


@pytest.mark.parametrize("case_name", _ids("gaps"))
def test_gap_vectors(case_name):
    data = _load("gaps")
    case = next(c for c in data["cases"] if c["name"] == case_name)
    trips = _sorted(SimpleNamespace(**t) for t in case["trips"])
    previous = SimpleNamespace(**case["previous"]) if case["previous"] else None
    got = {"order": [t.id for t in trips], "gaps": km_gaps(trips, previous)}
    _check("gaps", data, case, got)


@pytest.mark.parametrize("case_name", _ids("year_report"))
def test_year_report_vectors(client, monkeypatch, case_name):
    monkeypatch.delenv("TAX_CANTON", raising=False)
    data = _load("year_report")
    case = next(c for c in data["cases"] if c["name"] == case_name)
    vid = uid()
    ops = [op("vehicle", vid, case["vehicle"])]
    ops += [op("trip", uid(), {"vehicle_id": vid, **t}) for t in case["trips"]]
    ops += [op("fuel", uid(), {"vehicle_id": vid, **f}) for f in case["fuel"]]
    ops += [op("maintenance", uid(), {"vehicle_id": vid, **m}) for m in case["maintenance"]]
    ops += [op("tax_param", uid(), p) for p in case["tax_params"]]
    res = sync(client, *ops, headers=web_headers())
    assert all(r["status"] == "applied" for r in res["results"]), res
    rep = client.get(f"{T}/vehicles/{vid}/year-report?year={case['year']}").json()
    got = {k: rep[k] for k in ("trips_count", "unconfirmed", "months_used", "km", "shares_pct", "costs",
                               "warnings")}
    got["items"] = {k: {"value": v["value"], "applicable": v["applicable"]} for k, v in rep["items"].items()}
    _check("year_report", data, case, got)


@pytest.mark.parametrize("case_name", _ids("current_km"))
def test_current_km_vectors(client, case_name):
    """S18: aktueller km-Stand inkl. km-Beginn/-Ende der Fahrten (Statistik, Fälligkeit, Fahrzeugliste)."""
    data = _load("current_km")
    case = next(c for c in data["cases"] if c["name"] == case_name)
    vid = uid()
    ops = [op("vehicle", vid, case["vehicle"])]
    ops += [op(kind, uid(), {"vehicle_id": vid, **row}) for kind in ("odometer", "fuel", "maintenance")
            for row in case[kind]]
    trip_ids = [uid() for _ in case["trips"]]
    ops += [op("trip", i, {"vehicle_id": vid, **{k: v for k, v in t.items() if k != "deleted"}})
            for i, t in zip(trip_ids, case["trips"], strict=True)]
    res = sync(client, *ops, headers=web_headers())
    assert all(r["status"] == "applied" for r in res["results"]), res
    gone = [op("trip", i, action="delete", base=1) for i, t in zip(trip_ids, case["trips"], strict=True)
            if t.get("deleted")]
    if gone:
        assert all(r["status"] == "applied" for r in sync(client, *gone, headers=web_headers())["results"])
    stats = client.get(f"{T}/vehicles/{vid}/stats").json()
    listed = {v["id"]: v["current_km"] for v in client.get(f"{T}/vehicles").json()}
    assert listed[vid] == stats["current_km"]
    got = {"current_km": stats["current_km"], "driven_km": stats["driven_km"],
           "overdue": sorted(d["title"] for d in stats["due"] if d["overdue"])}
    _check("current_km", data, case, got)
