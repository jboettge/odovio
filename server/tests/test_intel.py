import itertools
import json
import urllib.parse

import pytest

from app import geo, intel
from app.main import app

from .conftest import bearer_token

T = "/api/t/privat"
TRIP = {"start_at": "2026-11-24T07:42:00+01:00", "end_at": "2026-11-24T08:05:00+01:00",
        "start_label": "Wohnort", "end_label": "Bahnhofstrasse 1, 8001 Zürich",
        "start_place_name": "Wohnort", "end_place_name": "Büro", "distance_km": 18.4,
        "weekday": 2, "private_mode": False}
CUSTOMERS = [{"id": "c-1", "name": "Meier AG"}, {"id": "c-2", "name": "Muster GmbH"}]


@pytest.fixture(autouse=True)
def _router():
    """Router idempotent einbinden (falls main.py ihn noch nicht einbindet)."""
    if not any(getattr(r, "path", None) == "/api/intel/status" for r in app.routes):
        app.include_router(intel.router)
    intel.limiter.reset()
    yield
    intel.limiter.reset()


class FakeHTTP:
    def __init__(self):
        self.calls = []
        self.handlers = []   # (substring, fn(url, payload) -> dict | Exception)

    def on(self, part, fn):
        self.handlers.insert(0, (part, fn))

    def __call__(self, url, payload=None, headers=None, timeout=5.0):
        self.calls.append({"url": url, "payload": payload, "headers": headers, "timeout": timeout})
        for part, fn in self.handlers:
            if part in url:
                res = fn(url, payload)
                if isinstance(res, Exception):
                    raise res
                return res
        raise AssertionError(f"unerwarteter Aufruf {url}")


@pytest.fixture
def http(monkeypatch):
    fake = FakeHTTP()
    monkeypatch.setattr(geo, "http_json", fake)
    for k in ("OSRM_PROFILE", "VLLM_API_KEY", "VLLM_MODEL", "GEO_TIMEOUT_S", "LLM_TIMEOUT_S",
              "INTEL_RATE_SUGGEST", "INTEL_RATE_GEO", "OSRM_MAX_MATCHING_SIZE", "VLLM_VISION_URL",
              "VLLM_VISION_MODEL", "INTEL_RATE_SCAN"):
        monkeypatch.delenv(k, raising=False)
    monkeypatch.setenv("OSRM_URL", "http://osrm:5000/")
    monkeypatch.setenv("PHOTON_URL", "http://photon:2322")
    monkeypatch.setenv("VLLM_URL", "http://vllm:8000/v1")
    return fake


def _query(url) -> dict:
    return dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(url).query))


def _coords(url) -> list:
    path = urllib.parse.urlsplit(url).path
    return path.rsplit("/", 1)[1].split(";")


def _osrm_match(url, _):
    n = len(_coords(url))
    return {"code": "Ok", "matchings": [{"distance": 1000.0 * (n - 1), "duration": 60.0 * (n - 1),
                                         "confidence": 0.8}],
            "tracepoints": [{"location": [0, 0]}] * n}


def _track(n, start=1_764_000_000, step=1, acc=5.0):
    return [{"lat": 47.37 + i * 1e-4, "lon": 8.54 + i * 1e-4, "ts": start + i * step, "accuracy": acc}
            for i in range(n)]


# ---------- Auth / Status ----------
def test_auth_missing_401(client):
    del client.headers["Authorization"]
    assert client.get("/api/intel/status").status_code == 401
    assert client.post(f"{T}/trips/suggest", json={"trip": TRIP}).status_code == 401
    r = client.post("/api/geo/reverse", json={"lat": 47, "lon": 8}, headers={"Authorization": "Bearer kaputt"})
    assert r.status_code == 401


def test_status(client, http, monkeypatch):
    assert client.get("/api/intel/status").json() == {"geo_match": True, "geo_reverse": True, "llm": True,
                                                       "vision": False}
    monkeypatch.delenv("PHOTON_URL")
    monkeypatch.setenv("VLLM_URL", "file:///etc/passwd")
    r = client.get("/api/intel/status")
    assert r.json() == {"geo_match": True, "geo_reverse": False, "llm": False, "vision": False}
    assert "osrm" not in r.text
    assert http.calls == []


def test_geo_requires_tenant(client, http):
    r = client.post("/api/geo/reverse", json={"lat": 47, "lon": 8}, headers=bearer_token(groups=[]))
    assert r.status_code == 403


# ---------- match ----------
def test_match_sorts_radiuses_and_sums(client, http):
    http.on("/match/v1/", _osrm_match)
    pts = _track(5, acc=5.0)
    pts[2]["accuracy"] = 50.0      # → 100 (Obergrenze)
    pts[3]["accuracy"] = None      # → Default
    pts[4]["accuracy"] = 1.0       # → 10 (Untergrenze)
    pts[1]["ts"] = "2025-11-24T16:00:01Z"   # 1764000001 als ISO
    r = client.post("/api/geo/match", json={"points": list(reversed(pts))})
    assert r.status_code == 200, r.text
    assert r.json() == {"distance_km": 4.0, "duration_s": 240.0, "confidence": 0.8, "matched_points": 5}
    call = http.calls[0]
    assert call["url"].startswith("http://osrm:5000/match/v1/driving/")
    q = _query(call["url"])
    assert q["timestamps"] == ";".join(str(1_764_000_000 + i) for i in range(5))
    assert q["radiuses"] == "15;15;100;30;10"
    assert q["overview"] == "false" and q["gaps"] == "split" and q["tidy"] == "true"
    assert _coords(call["url"])[0] == "8.540000,47.370000"   # lon,lat


def test_match_splits_on_gap(client, http):
    http.on("/match/v1/", _osrm_match)
    pts = _track(4) + _track(3, start=1_764_000_000 + 3 + 61)
    r = client.post("/api/geo/match", json={"points": pts})
    assert r.status_code == 200
    assert len(http.calls) == 2
    assert [len(_coords(c["url"])) for c in http.calls] == [4, 3]
    assert r.json()["distance_km"] == 5.0          # 3 + 2 Abschnitte


def test_match_thins_to_500(client, http, monkeypatch):
    monkeypatch.setenv("OSRM_MAX_MATCHING_SIZE", "1000")
    http.on("/match/v1/", _osrm_match)
    r = client.post("/api/geo/match", json={"points": _track(5000)})
    assert r.status_code == 200
    assert len(http.calls) == 1
    ts = [int(x) for x in _query(http.calls[0]["url"])["timestamps"].split(";")]
    assert len(ts) == 500 and ts[0] == 1_764_000_000 and ts[-1] == 1_764_000_000 + 4999
    gaps = {b - a for a, b in itertools.pairwise(ts)}
    assert gaps <= {10, 11}                         # gleichmässig


def test_match_chunks_and_weighted_confidence(client, http):
    def fn(url, _):
        n = len(_coords(url))
        first = int(_query(url)["timestamps"].split(";")[0])
        conf = 1.0 if first == 1_764_000_000 else 0.0
        return {"code": "Ok", "matchings": [{"distance": 100.0 * (n - 1), "duration": 1, "confidence": conf}],
                "tracepoints": [{}] * n}
    http.on("/match/v1/", fn)
    r = client.post("/api/geo/match", json={"points": _track(150)})   # Default 100 je Anfrage
    assert r.status_code == 200
    assert [len(_coords(c["url"])) for c in http.calls] == [100, 51]   # Randpunkt geteilt
    body = r.json()
    assert body["distance_km"] == 14.9 and body["matched_points"] == 150
    assert body["confidence"] == round(9900 / 14900, 3)


def test_match_validation(client, http):
    bad = _track(3)
    bad[0]["lat"] = 91
    assert client.post("/api/geo/match", json={"points": bad}).status_code == 422
    raw = '{"points":[{"lat":NaN,"lon":8,"ts":1764000000},{"lat":47,"lon":8,"ts":1764000001}]}'
    r = client.post("/api/geo/match", content=raw, headers={"Content-Type": "application/json"})
    assert r.status_code == 422 and "input" not in r.json()["detail"][0]
    assert client.post("/api/geo/match", json={"points": _track(5001)}).status_code == 422
    old = _track(2, start=100)
    assert client.post("/api/geo/match", json={"points": old}).status_code == 422
    # alle Punkte gleicher Zeitpunkt → kein Teilstück
    same = _track(3, step=0)
    assert client.post("/api/geo/match", json={"points": same}).status_code == 422
    assert http.calls == []


def test_match_epoch_millis(client, http):
    http.on("/match/v1/", _osrm_match)
    pts = [{**p, "ts": p["ts"] * 1000} for p in _track(3)]
    assert client.post("/api/geo/match", json={"points": pts}).status_code == 200
    assert _query(http.calls[0]["url"])["timestamps"].startswith("1764000000;")


def test_match_nomatch_422_and_errors(client, http, monkeypatch):
    http.on("/match/v1/", lambda u, p: {"code": "NoMatch"})
    assert client.post("/api/geo/match", json={"points": _track(3)}).status_code == 422
    http.on("/match/v1/", lambda u, p: {"code": "TooBig"})
    r = client.post("/api/geo/match", json={"points": _track(3)})
    assert r.status_code == 502 and "TooBig" not in r.text
    http.on("/match/v1/", lambda u, p: geo.UpstreamError("timeout http://osrm:5000"))
    r = client.post("/api/geo/match", json={"points": _track(3)})
    assert r.status_code == 502 and "osrm" not in r.text
    monkeypatch.delenv("OSRM_URL")
    r = client.post("/api/geo/match", json={"points": _track(3)})
    assert r.status_code == 503 and r.json()["detail"] == "Geo-Dienst nicht konfiguriert"


# ---------- route ----------
def test_route(client, http, monkeypatch):
    monkeypatch.setenv("OSRM_PROFILE", "car")
    http.on("/route/v1/", lambda u, p: {"code": "Ok", "routes": [{"distance": 18412.3, "duration": 1388.04}]})
    r = client.post("/api/geo/route", json={"from": {"lat": 47.1, "lon": 8.2}, "to": {"lat": 47.37, "lon": 8.54}})
    assert r.status_code == 200, r.text
    assert r.json() == {"distance_km": 18.412, "duration_s": 1388.0}
    url = http.calls[0]["url"]
    assert "/route/v1/car/8.200000,47.100000;8.540000,47.370000?" in url
    http.on("/route/v1/", lambda u, p: {"code": "NoRoute"})
    assert client.post("/api/geo/route", json={"from": {"lat": 47, "lon": 8},
                                               "to": {"lat": 47, "lon": 8}}).status_code == 422
    assert client.post("/api/geo/route", json={"from": {"lat": 47, "lon": 181},
                                               "to": {"lat": 47, "lon": 8}}).status_code == 422


# ---------- reverse ----------
def _photon(props):
    return lambda u, p: {"type": "FeatureCollection", "features": [{"properties": props}]}


def test_reverse_rounds_and_labels(client, http):
    http.on("/reverse", _photon({"osm_key": "building", "street": "Bahnhofstrasse", "housenumber": "1",
                                 "postcode": "8001", "city": "Zürich", "country": "Schweiz"}))
    r = client.post("/api/geo/reverse", json={"lat": 47.3712345, "lon": 8.5398765})
    assert r.status_code == 200
    assert r.json() == {"label": "Bahnhofstrasse 1, 8001 Zürich", "municipality": "Zürich", "country": "Schweiz"}
    q = _query(http.calls[0]["url"])
    assert http.calls[0]["url"].startswith("http://photon:2322/reverse?")
    assert q["lat"] == "47.3712" and q["lon"] == "8.5399" and q["lang"] == "de"


def test_reverse_name_and_village(client, http):
    http.on("/reverse", _photon({"osm_key": "place", "type": "village", "name": "Hütten",
                                 "postcode": "8825", "country": "Schweiz"}))
    assert client.post("/api/geo/reverse", json={"lat": 47.17, "lon": 8.66}).json() == \
        {"label": "8825 Hütten", "municipality": "Hütten", "country": "Schweiz"}
    http.on("/reverse", _photon({"osm_key": "amenity", "name": "Kantonsspital", "postcode": "6000",
                                 "city": "Luzern", "country": "Schweiz"}))
    r = client.post("/api/geo/reverse", json={"lat": 47.05, "lon": 8.3})
    assert r.json()["label"] == "Kantonsspital, 6000 Luzern"
    http.on("/reverse", lambda u, p: {"features": []})
    assert client.post("/api/geo/reverse", json={"lat": 0, "lon": 0}).json() == \
        {"label": None, "municipality": None, "country": None}


def test_reverse_errors(client, http, monkeypatch):
    assert client.post("/api/geo/reverse", json={"lat": 95, "lon": 8}).status_code == 422
    assert client.post("/api/geo/reverse", content=b'{"lat": NaN, "lon": 8}',
                       headers={"Content-Type": "application/json"}).status_code == 422
    http.on("/reverse", lambda u, p: {"unexpected": 1})
    assert client.post("/api/geo/reverse", json={"lat": 47, "lon": 8}).status_code == 502
    monkeypatch.delenv("PHOTON_URL")
    assert client.post("/api/geo/reverse", json={"lat": 47, "lon": 8}).status_code == 503


# ---------- suggest ----------
def _llm(content):
    return lambda u, p: {"choices": [{"message": {"role": "assistant", "content": content}}]}


GOOD = {"category": "business", "purpose": "Offerte besprechen", "customer_id": "c-1",
        "confidence": 0.72, "reason": "Ziel ist Büro, Muster aus letzten Fahrten"}


def _suggest(client, **kw):
    body = {"trip": TRIP, "customers": CUSTOMERS,
            "recent": [{"start_label": "Wohnort", "end_label": "Büro", "category": "commute", "purpose": None}]}
    body.update(kw)
    return client.post(f"{T}/trips/suggest", json=body)


def test_suggest_ok_and_request_shape(client, http, monkeypatch):
    monkeypatch.setenv("VLLM_API_KEY", "geheim")
    monkeypatch.setenv("LLM_TIMEOUT_S", "7")
    http.on("/chat/completions", _llm(json.dumps(GOOD)))
    r = _suggest(client)
    assert r.status_code == 200, r.text
    assert r.json() == {**GOOD, "source": "llm"}
    call = http.calls[0]
    assert call["url"] == "http://vllm:8000/v1/chat/completions"
    assert call["headers"] == {"Authorization": "Bearer geheim"} and call["timeout"] == 7
    p = call["payload"]
    assert p["model"] == "qwen3.5-9b" and p["temperature"] == 0
    rf = p["response_format"]
    assert rf["type"] == "json_schema"
    assert rf["json_schema"]["name"] == "trip_suggestion" and rf["json_schema"]["strict"] is True
    schema = rf["json_schema"]["schema"]
    assert p["guided_json"] == schema
    assert schema["additionalProperties"] is False
    assert set(schema["required"]) == {"category", "purpose", "customer_id", "confidence", "reason"}
    props = schema["properties"]
    assert props["category"]["enum"] == ["business", "private", "commute", "field"]
    assert props["customer_id"]["enum"] == ["c-1", "c-2", None]
    assert props["purpose"]["maxLength"] == 120 and props["reason"]["maxLength"] == 200
    assert props["confidence"] == {"type": "number", "minimum": 0, "maximum": 1}
    system, user = p["messages"]
    assert system["role"] == "system" and "Schweizer Fahrtenbuch" in system["content"]
    assert "Erfinde keine" in system["content"]
    data = json.loads(user["content"])
    assert data["fahrt"]["wochentag"] == "Dienstag"
    assert data["fahrt"]["start_uhrzeit"] == "07:42" and data["fahrt"]["dauer_min"] == 23
    assert data["fahrt"]["ziel"] == "Büro" and data["kunden"][0] == {"id": "c-1", "name": "Meier AG"}
    assert "2026-11-24" not in user["content"]


def test_suggest_never_sends_coordinates(client, http):
    http.on("/chat/completions", _llm(json.dumps(GOOD)))
    r = _suggest(client, trip={**TRIP, "start_lat": 47.37, "start_lon": 8.54})
    assert r.status_code == 422          # Koordinaten sind im Vertrag nicht erlaubt
    assert http.calls == []
    _suggest(client)
    assert "47." not in http.calls[0]["payload"]["messages"][1]["content"]


def test_suggest_no_customers_schema(client, http):
    http.on("/chat/completions", _llm(json.dumps({**GOOD, "customer_id": None})))
    r = _suggest(client, customers=[])
    assert r.status_code == 200 and r.json()["customer_id"] is None
    assert http.calls[0]["payload"]["guided_json"]["properties"]["customer_id"] == {"type": "null"}


def test_suggest_unknown_customer_becomes_none(client, http):
    http.on("/chat/completions", _llm(json.dumps({**GOOD, "customer_id": "erfunden"})))
    r = _suggest(client)
    assert r.status_code == 200 and r.json()["customer_id"] is None


@pytest.mark.parametrize("content", [
    "kein json",
    json.dumps({**GOOD, "category": "urlaub"}),
    json.dumps({**GOOD, "confidence": 1.5}),
    json.dumps({**GOOD, "purpose": "x" * 121}),
    json.dumps({k: v for k, v in GOOD.items() if k != "reason"}),
    None,
])
def test_suggest_invalid_answer_204(client, http, content):
    http.on("/chat/completions", _llm(content))
    r = _suggest(client)
    assert r.status_code == 204 and r.content == b""


def test_suggest_think_and_fence_stripped(client, http):
    http.on("/chat/completions", _llm("<think>hmm</think>\n```json\n" + json.dumps(GOOD) + "\n```"))
    assert _suggest(client).status_code == 200


def test_suggest_private_mode_422(client, http):
    http.on("/chat/completions", _llm(json.dumps(GOOD)))
    r = _suggest(client, trip={**TRIP, "private_mode": True})
    assert r.status_code == 422 and r.json()["detail"] == "Privatfahrten werden nicht an das LLM gesendet"
    assert http.calls == []


def test_suggest_read_role_403(client, http):
    http.on("/chat/completions", _llm(json.dumps(GOOD)))
    r = client.post("/api/t/firma/trips/suggest", json={"trip": TRIP})
    assert r.status_code == 403
    assert client.post("/api/t/fremd/trips/suggest", json={"trip": TRIP}).status_code == 403
    assert http.calls == []


def test_suggest_not_configured_503(client, http, monkeypatch):
    monkeypatch.delenv("VLLM_URL")
    r = _suggest(client)
    assert r.status_code == 503 and r.json()["detail"] == "LLM nicht konfiguriert"


def test_suggest_timeout_502(client, http):
    http.on("/chat/completions", lambda u, p: geo.UpstreamError("TimeoutError"))
    r = _suggest(client)
    assert r.status_code == 502 and "Timeout" not in r.text
    http.on("/chat/completions", lambda u, p: {"object": "error", "message": "bad", "code": 400})
    assert _suggest(client).status_code == 502


def test_suggest_limits(client, http):
    many = [{"id": f"c{i}", "name": f"K{i}"} for i in range(201)]
    assert _suggest(client, customers=many).status_code == 422
    assert _suggest(client, recent=[{"start_label": "a"}] * 21).status_code == 422
    assert http.calls == []


def test_rate_limit_429(client, http, monkeypatch):
    monkeypatch.setenv("INTEL_RATE_SUGGEST", "2")
    http.on("/chat/completions", _llm(json.dumps(GOOD)))
    assert _suggest(client).status_code == 200
    assert _suggest(client).status_code == 200
    r = _suggest(client)
    assert r.status_code == 429 and int(r.headers["Retry-After"]) >= 1
    # anderer Benutzer nicht betroffen
    other = client.post(f"{T}/trips/suggest", json={"trip": TRIP}, headers=bearer_token(sub="user-2"))
    assert other.status_code == 200
    monkeypatch.setenv("INTEL_RATE_GEO", "1")
    http.on("/reverse", lambda u, p: {"features": []})
    assert client.post("/api/geo/reverse", json={"lat": 47, "lon": 8}).status_code == 200
    assert client.post("/api/geo/reverse", json={"lat": 47, "lon": 8}).status_code == 429


# ---------- HTTP-Helfer ----------
def test_http_json_timeout_and_scheme(monkeypatch):
    def boom(req, timeout):
        raise TimeoutError("timed out")
    monkeypatch.setattr(geo._opener, "open", boom)
    with pytest.raises(geo.UpstreamError):
        geo.http_json("http://osrm:5000/x", timeout=0.1)
    with pytest.raises(geo.UpstreamError):
        geo.http_json("file:///etc/passwd")


def test_http_json_parses_and_posts(monkeypatch):
    seen = {}

    class Resp:
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def read(self, n):
            return b'{"ok": true}'

    def fake_open(req, timeout):
        seen.update(method=req.get_method(), body=req.data, timeout=timeout,
                    auth=req.get_header("Authorization"))
        return Resp()
    monkeypatch.setattr(geo._opener, "open", fake_open)
    assert geo.http_json("http://vllm/v1/x", {"a": 1}, {"Authorization": "Bearer k"}, 3) == {"ok": True}
    assert seen == {"method": "POST", "body": b'{"a": 1}', "timeout": 3, "auth": "Bearer k"}
