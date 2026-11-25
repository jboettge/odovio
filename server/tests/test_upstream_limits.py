"""S2 Reverse per POST + Zugriffslog ohne Query, S7 Gleichzeitigkeit/Circuit-Breaker je Upstream,
Geo-Limit, Scan-Limit vor dem Body."""
import json
import logging

from app import geo, logfilter
from app.geo import UpstreamError

from .test_intel import FakeHTTP, _llm, _photon, http  # noqa: F401  (Fixture)
from .test_scan import GOOD, JPEG, b64

PHOTON = _photon({"osm_key": "building", "street": "Bahnhofstrasse", "housenumber": "1", "postcode": "8001",
                  "city": "Zürich", "country": "Schweiz"})


def test_reverse_post_and_deprecated_get(client, http):  # noqa: F811
    http.on("/reverse", PHOTON)
    r = client.post("/api/geo/reverse", json={"lat": 47.3712345, "lon": 8.5398765})
    assert r.status_code == 200 and r.json()["label"] == "Bahnhofstrasse 1, 8001 Zürich"
    assert r.headers["cache-control"] == "no-store"
    assert client.post("/api/geo/reverse", json={"lat": 95, "lon": 8}).status_code == 422
    assert client.post("/api/geo/reverse", content=b'{"lat": NaN, "lon": 8}',
                       headers={"Content-Type": "application/json"}).status_code == 422
    r = client.get("/api/geo/reverse?lat=47&lon=8")
    assert r.status_code == 200 and r.headers["deprecation"] == "true"


def test_access_log_without_query_string(caplog):
    logfilter.install()
    logfilter.install()                                     # idempotent
    access = logging.getLogger("uvicorn.access")
    assert sum(isinstance(f, logfilter.StripQueryFilter) for f in access.filters) == 1
    with caplog.at_level(logging.INFO, logger="uvicorn.access"):
        access.info('%s - "%s %s HTTP/%s" %d', "10.0.0.1:5000", "GET", "/api/geo/reverse?lat=47.1&lon=8.2",
                    "1.1", 200)
    assert "/api/geo/reverse" in caplog.text and "47.1" not in caplog.text and "lat=" not in caplog.text


def test_geo_default_limit_30(client, http, monkeypatch):  # noqa: F811
    monkeypatch.delenv("INTEL_RATE_GEO", raising=False)
    http.on("/reverse", PHOTON)
    codes = [client.post("/api/geo/reverse", json={"lat": 47, "lon": 8}).status_code for _ in range(31)]
    assert codes[:30] == [200] * 30 and codes[30] == 429


def test_upstream_concurrency_limit_503(client, http, monkeypatch):  # noqa: F811
    monkeypatch.setenv("UPSTREAM_CONCURRENCY", "1")
    http.on("/reverse", PHOTON)
    with geo.UPSTREAMS["photon"].guard():                   # belegt den einzigen Platz
        r = client.post("/api/geo/reverse", json={"lat": 47, "lon": 8})
    assert r.status_code == 503 and r.headers["Retry-After"] == "1" and "ausgelastet" in r.json()["detail"]
    assert not http.calls                                   # Upstream nicht aufgerufen
    assert client.post("/api/geo/reverse", json={"lat": 47, "lon": 8}).status_code == 200


def test_circuit_breaker(client, http, monkeypatch):  # noqa: F811
    monkeypatch.setenv("UPSTREAM_BREAKER_OPEN_S", "30")
    http.on("/reverse", lambda u, p: UpstreamError("TimeoutError"))
    codes = [client.post("/api/geo/reverse", json={"lat": 47, "lon": 8}).status_code for _ in range(3)]
    assert codes == [502, 502, 502] and len(http.calls) == 3
    r = client.post("/api/geo/reverse", json={"lat": 47, "lon": 8})
    assert r.status_code == 503 and 1 <= int(r.headers["Retry-After"]) <= 31
    assert len(http.calls) == 3                             # gesperrt: kein weiterer Aufruf
    # andere Dienste sind nicht betroffen; nach Ablauf wieder offen
    assert geo.UPSTREAMS["osrm"].open_until == 0
    geo.UPSTREAMS["photon"].open_until = 0
    http.on("/reverse", PHOTON)
    assert client.post("/api/geo/reverse", json={"lat": 47, "lon": 8}).status_code == 200


def test_scan_limit_checked_before_body(client, monkeypatch):
    fake = FakeHTTP()
    monkeypatch.setattr(geo, "http_json", fake)
    monkeypatch.setenv("VLLM_URL", "http://vllm:8000/v1")
    monkeypatch.setenv("VLLM_VISION_MODEL", "qwen2.5-vl-7b")
    monkeypatch.setenv("INTEL_RATE_SCAN", "1")
    fake.on("/chat/completions", _llm(json.dumps(GOOD)))
    assert client.post("/api/t/privat/scan", json={"image_b64": b64(JPEG), "kind": "pump"}).status_code == 200
    # ungültiger Body: Limit greift vor dem Parsen (429 statt 422)
    r = client.post("/api/t/privat/scan", content=b"{kaputt", headers={"Content-Type": "application/json"})
    assert r.status_code == 429
