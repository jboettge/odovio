import base64
import json
import logging

import pytest

from app import geo, intel

from .conftest import bearer_token
from .test_intel import FakeHTTP, _llm

T = "/api/t/privat"
JPEG = b"\xff\xd8\xff\xe0" + b"\x10JFIF" + bytes(range(256)) * 8
PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 300
GOOD = {"liters": 40.12, "amount": 72.18, "price_per_liter": 1.799, "km": None, "date": "2026-11-24",
        "station": "Migrol Zürich", "confidence": 0.9, "reason": "Anzeige Zapfsäule gut lesbar"}


@pytest.fixture(autouse=True)
def _reset():
    intel.limiter.reset()
    yield
    intel.limiter.reset()


@pytest.fixture
def http(monkeypatch):
    fake = FakeHTTP()
    monkeypatch.setattr(geo, "http_json", fake)
    for k in ("VLLM_API_KEY", "VLLM_MODEL", "LLM_TIMEOUT_S", "INTEL_RATE_SCAN", "VLLM_VISION_URL",
              "OSRM_URL", "PHOTON_URL"):
        monkeypatch.delenv(k, raising=False)
    monkeypatch.setenv("VLLM_URL", "http://vllm:8000/v1")
    monkeypatch.setenv("VLLM_VISION_MODEL", "qwen2.5-vl-7b")
    return fake


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode()


def scan(client, image=JPEG, kind="pump", **kw):
    return client.post(f"{T}/scan", json={"image_b64": b64(image) if isinstance(image, bytes) else image,
                                          "kind": kind}, **kw)


def test_scan_ok_and_request_shape(client, http, monkeypatch, caplog):
    monkeypatch.setenv("VLLM_API_KEY", "geheim")
    monkeypatch.setenv("LLM_TIMEOUT_S", "20")
    monkeypatch.setenv("VLLM_VISION_URL", "http://vision:8001/v1/")
    http.on("/chat/completions", _llm(json.dumps(GOOD)))
    caplog.set_level(logging.DEBUG)
    r = scan(client)
    assert r.status_code == 200, r.text
    assert r.json() == GOOD
    call = http.calls[0]
    assert call["url"] == "http://vision:8001/v1/chat/completions"
    assert call["headers"] == {"Authorization": "Bearer geheim"} and call["timeout"] == 20
    p = call["payload"]
    assert p["model"] == "qwen2.5-vl-7b" and p["temperature"] == 0
    system, user = p["messages"]
    assert system["role"] == "system" and "Erfinde nichts" in system["content"]
    text_part, image_part = user["content"]
    assert text_part["type"] == "text" and "Zapfsäule" in text_part["text"]
    assert image_part == {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + b64(JPEG)}}
    rf = p["response_format"]
    assert rf["type"] == "json_schema" and rf["json_schema"]["strict"] is True
    schema = rf["json_schema"]["schema"]
    assert p["guided_json"] == schema and schema["additionalProperties"] is False
    assert set(schema["required"]) == set(GOOD)
    props = schema["properties"]
    assert props["liters"] == {"type": ["number", "null"], "minimum": 0, "maximum": 5000}
    assert props["amount"] == {"type": ["number", "null"], "minimum": 0, "maximum": 100_000}
    assert props["price_per_liter"] == {"type": ["number", "null"], "minimum": 0.3, "maximum": 10}
    assert props["km"] == {"type": ["integer", "null"], "minimum": 0, "maximum": 5_000_000}
    assert props["confidence"] == {"type": "number", "minimum": 0, "maximum": 1}
    # Bild wird nicht protokolliert
    assert b64(JPEG)[:40] not in caplog.text


def test_scan_png_odometer_and_vision_url_default(client, http):
    http.on("/chat/completions", _llm(json.dumps(
        {**dict.fromkeys(GOOD), "km": 123456, "confidence": 0.8, "reason": "Tacho"})))
    r = scan(client, PNG, kind="odometer")
    assert r.status_code == 200, r.text
    assert r.json()["km"] == 123456 and r.json()["liters"] is None
    call = http.calls[0]
    assert call["url"] == "http://vllm:8000/v1/chat/completions" and call["headers"] is None
    text_part, image_part = call["payload"]["messages"][1]["content"]
    assert "Gesamtkilometerstand" in text_part["text"]
    assert image_part["image_url"]["url"].startswith("data:image/png;base64,")
    # data:-URL wird akzeptiert
    assert scan(client, "data:image/png;base64," + b64(PNG), kind="receipt").status_code == 200


def test_scan_plausibility(client, http):
    bad = {**GOOD, "amount": 80.00}                                     # 40.12 × 1.799 = 72.18
    http.on("/chat/completions", _llm(json.dumps(bad)))
    r = scan(client).json()
    assert r["confidence"] == 0.45 and "Unplausibel" in r["reason"] and r["reason"].startswith(GOOD["reason"])
    # innerhalb der Toleranz (1 % bzw. 0.05)
    http.on("/chat/completions", _llm(json.dumps({**GOOD, "amount": 72.80})))
    r = scan(client).json()
    assert r["confidence"] == 0.9 and r["reason"] == GOOD["reason"]
    # nur zwei der drei Werte → keine Prüfung
    http.on("/chat/completions", _llm(json.dumps({**GOOD, "price_per_liter": None, "amount": 999})))
    assert scan(client).json()["confidence"] == 0.9


def test_scan_normalises_date_and_station(client, http):
    http.on("/chat/completions", _llm("```json\n" + json.dumps(
        {**GOOD, "date": "24.11.2026", "station": "   "}) + "\n```"))
    r = scan(client).json()
    assert r["date"] == "2026-11-24" and r["station"] is None
    http.on("/chat/completions", _llm(json.dumps({**GOOD, "date": "gestern"})))
    assert scan(client).json()["date"] is None


@pytest.mark.parametrize("content", [
    json.dumps({**dict.fromkeys(GOOD), "confidence": 0.1, "reason": "unlesbar"}),   # nichts erkannt
    "kein json",
    json.dumps({**GOOD, "liters": 99999}),                                          # ausserhalb Grenzen
    json.dumps({**GOOD, "confidence": 2}),
    None,
])
def test_scan_no_result_204(client, http, content):
    http.on("/chat/completions", _llm(content))
    r = scan(client)
    assert r.status_code == 204 and r.content == b""


def test_scan_not_configured_503(client, http, monkeypatch):
    monkeypatch.setenv("VLLM_VISION_MODEL", "")
    r = scan(client)
    assert r.status_code == 503 and r.json()["detail"] == "Bildauswertung nicht konfiguriert"
    assert client.get("/api/intel/status").json()["vision"] is False
    monkeypatch.setenv("VLLM_VISION_MODEL", "m")
    assert client.get("/api/intel/status").json()["vision"] is True
    monkeypatch.delenv("VLLM_URL")
    assert scan(client).status_code == 503
    monkeypatch.setenv("VLLM_VISION_URL", "file:///etc/passwd")
    assert scan(client).status_code == 503
    assert http.calls == []


def test_scan_upstream_errors_502(client, http):
    http.on("/chat/completions", lambda u, p: geo.UpstreamError("TimeoutError"))
    r = scan(client)
    assert r.status_code == 502 and "Timeout" not in r.text
    http.on("/chat/completions", lambda u, p: {"unexpected": True})
    assert scan(client).status_code == 502


def test_scan_rate_limit_429(client, http, monkeypatch):
    monkeypatch.setenv("INTEL_RATE_SCAN", "2")
    http.on("/chat/completions", _llm(json.dumps(GOOD)))
    assert scan(client).status_code == 200
    assert scan(client).status_code == 200
    r = scan(client)
    assert r.status_code == 429 and int(r.headers["Retry-After"]) >= 1
    assert scan(client, headers=bearer_token(sub="user-2")).status_code == 200


def test_scan_access(client, http):
    assert client.post("/api/t/firma/scan", json={"image_b64": b64(JPEG), "kind": "pump"}).status_code == 403
    assert client.post("/api/t/fremd/scan", json={"image_b64": b64(JPEG), "kind": "pump"}).status_code == 403
    del client.headers["Authorization"]
    assert scan(client).status_code == 401
    assert http.calls == []


def test_scan_invalid_input_422_without_echo(client, http):
    http.on("/chat/completions", _llm(json.dumps(GOOD)))
    too_big = b"\xff\xd8\xff" + b"\x00" * (2 * 1024 * 1024)               # 2 MiB + 3 Byte
    r = scan(client, too_big)
    assert r.status_code == 422 and "zu gross" in r.text
    r = scan(client, b"GIF89a" + b"\x00" * 100)
    assert r.status_code == 422 and r.json()["detail"] == "Nur JPEG oder PNG"
    r = scan(client, "nicht-base64!!")
    assert r.status_code == 422 and "nicht-base64" not in r.text
    r = scan(client, kind="selfie")
    assert r.status_code == 422 and b64(JPEG)[:40] not in r.text and "input" not in r.text
    r = client.post(f"{T}/scan", json={"image_b64": "A" * (4 * 1024 * 1024), "kind": "pump"})
    assert r.status_code == 413                                          # weit über Scan-Limit
    assert http.calls == []
    # gerade noch erlaubt (2 MiB)
    assert scan(client, b"\xff\xd8\xff" + b"\x00" * (2 * 1024 * 1024 - 3)).status_code == 200
