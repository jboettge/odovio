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
