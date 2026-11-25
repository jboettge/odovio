"""Querschnitts-Härtung (app/security.py, auth.py, Middlewares): Rate-Limits, Brute-Force-Sperre, Proxy-IP,
CORS/CSRF, Host, HSTS/Header, Request-ID, JSON-Struktur, Text-Normalisierung, Pfadparameter, Token-Zeiten,
Sicherheits-Log (Log-Injection), Startprüfung, CSV-Formeln, Keycloak-Pfadsegmente."""
import json
import logging
import time

import pytest
from fastapi.testclient import TestClient

from app import auth, members, security
from app.geo import UpstreamError
from app.logbook import _cell
from app.main import app, content_disposition

from .conftest import T, bearer_token, make_token, new_vehicle, op, sync, uid
from .test_collab import admin_ios, admin_web, kc  # noqa: F401 – Fixture kc (Keycloak-Admin-API gemockt)


@pytest.fixture
def events():
    """Sicherheits-Ereignisse (JSON-Felder) mitschreiben."""
    out: list[dict] = []

    class H(logging.Handler):
        def emit(self, record):
            out.append(record.security)

    h = H()
    security.log.addHandler(h)
    yield out
    security.log.removeHandler(h)


def other(ip: str, **kw) -> TestClient:
    c = TestClient(app, client=(ip, 40000), **kw)
    c.headers["Authorization"] = f"Bearer {make_token()}"
    return c


def names(evts):
    return [e["event"] for e in evts]


# ---------- Rate-Limits ----------
def test_rate_limit_per_ip_429_with_retry_after(client, monkeypatch, events):
    monkeypatch.setenv("RATE_IP_PER_MIN", "3")
    monkeypatch.setenv("RATE_IP_BURST", "3")
    c = other("203.0.113.10")
    assert [c.get("/api/me").status_code for _ in range(3)] == [200, 200, 200]
    r = c.get("/api/me?echo=<script>")
    assert r.status_code == 429 and r.json() == {"detail": "Zu viele Anfragen"}
    assert int(r.headers["retry-after"]) >= 1 and "script" not in r.text
    assert other("203.0.113.11").get("/api/me").status_code == 200         # andere IP: eigener Bucket
    ev = [e for e in events if e["event"] == "rate_limited"][0]
    assert ev["ip"] == "203.0.113.10" and ev["reason"] == "ip" and ev["path"] == "/api/me"


def test_rate_limit_public_stricter_and_web_separate(client, monkeypatch, tmp_path):
    monkeypatch.setenv("RATE_PUBLIC_PER_MIN", "2")
    monkeypatch.setenv("RATE_PUBLIC_BURST", "2")
    (tmp_path / "index.html").write_text("<!doctype html><title>FZB</title>")
    monkeypatch.setenv("WEB_DIST", str(tmp_path))
    c = other("203.0.113.20")
    assert [c.get("/health").status_code for _ in range(2)] == [200, 200]
    assert c.get("/auth/config").status_code == 429                         # gemeinsamer Public-Bucket
    assert c.get("/api/me").status_code == 200                              # API: eigener Bucket
    assert all(c.get("/").status_code == 200 for _ in range(5))             # Web: grosszügig


def test_rate_limit_per_user_across_ips(client, monkeypatch, events):
    monkeypatch.setenv("RATE_USER_PER_MIN", "2")
    monkeypatch.setenv("RATE_USER_BURST", "2")
    assert other("203.0.113.30").get("/api/me").status_code == 200
    assert other("203.0.113.31").get("/api/me").status_code == 200
    r = other("203.0.113.32").get("/api/me")
    assert r.status_code == 429 and r.headers["retry-after"]
    assert client.get("/api/me", headers=bearer_token(sub="user-2")).status_code == 200
    assert any(e["event"] == "rate_limited" and e["reason"] == "user" and e["sub"] == "user-1" for e in events)


def test_existing_specific_limits_kept(client, monkeypatch):
    monkeypatch.setenv("RATE_ACTIVITY", "1")
    assert client.get(f"{T}/activity").status_code == 200
    assert client.get(f"{T}/activity").status_code == 429


def test_buckets_bounded_and_refill():
    b = security.Buckets(max_keys=3)
    for i in range(10):
        b.take(f"k{i}", 60, 1)
    assert len(b.data) == 3 and "k9" in b.data and "k0" not in b.data
    assert b.take("x", 60, 1) == 0 and b.take("x", 60, 1) >= 1
    b.data["x"][1] -= 2             # 2 s später: 2 Token nachgefüllt (max. Burst 1)
    assert b.take("x", 60, 1) == 0


# ---------- Client-IP hinter Proxy ----------
def _scope(peer, xff=None, proto=None):
    headers = []
    if xff is not None:
        headers.append((b"x-forwarded-for", xff.encode()))
    if proto is not None:
        headers.append((b"x-forwarded-proto", proto.encode()))
    return {"type": "http", "client": (peer, 1), "headers": headers, "scheme": "http"}


def test_client_ip_trusts_xff_only_from_trusted_proxy(monkeypatch):
    monkeypatch.setenv("FORWARDED_ALLOW_IPS", "10.0.0.0/8, 127.0.0.1")
    assert security.client_ip(_scope("10.0.0.5", "198.51.100.7")) == "198.51.100.7"
    # rechtester nicht vertrauenswürdiger Eintrag (Client kann links beliebig fälschen)
    assert security.client_ip(_scope("10.0.0.5", "1.1.1.1, 198.51.100.7, 10.0.0.9")) == "198.51.100.7"
    assert security.client_ip(_scope("203.0.113.9", "198.51.100.7")) == "203.0.113.9"   # Peer nicht vertraut
    assert security.client_ip(_scope("10.0.0.5", "kein-ip")) == "10.0.0.5"
    assert security.client_ip(_scope("10.0.0.5", "[2001:db8::1]:443")) == "2001:db8::1"
    assert security.client_ip(_scope("10.0.0.5")) == "10.0.0.5"
    assert security.is_https(_scope("10.0.0.5", proto="https"))
    assert not security.is_https(_scope("203.0.113.9", proto="https"))


def test_rate_limit_keyed_by_forwarded_ip(client, monkeypatch):
    monkeypatch.setenv("RATE_IP_PER_MIN", "1")
    monkeypatch.setenv("RATE_IP_BURST", "1")
    h = {"X-Forwarded-For": "198.51.100.1"}
    # Peer "testclient" nicht vertraut → X-Forwarded-For ignoriert, gleicher Bucket
    assert client.get("/api/me", headers=h).status_code == 200
    assert client.get("/api/me", headers={"X-Forwarded-For": "198.51.100.2"}).status_code == 429
    security.reset()
    monkeypatch.setenv("FORWARDED_ALLOW_IPS", "testclient")
    assert client.get("/api/me", headers={"X-Forwarded-For": "198.51.100.3"}).status_code == 200
    assert client.get("/api/me", headers={"X-Forwarded-For": "198.51.100.4"}).status_code == 200
    assert client.get("/api/me", headers={"X-Forwarded-For": "198.51.100.4"}).status_code == 429


# ---------- Brute-Force ----------
def _bad(c, n, **claims):
    for _ in range(n):
        assert c.get("/api/me", headers=bearer_token(**claims) if claims else
                     {"Authorization": "Bearer kaputt"}).status_code == 401


def test_brute_force_401_blocks_ip_with_backoff(client, monkeypatch, events):
    monkeypatch.setenv("BRUTE_401_THRESHOLD", "3")
    c = other("203.0.113.40")
    _bad(c, 3)
    r = c.get("/api/me")                         # auch mit gültigem Token gesperrt
    assert r.status_code == 429 and r.json() == {"detail": "Zu viele fehlgeschlagene Anfragen"}
    assert 290 <= int(r.headers["retry-after"]) <= 301
    assert other("203.0.113.41").get("/api/me").status_code == 200
    blocks = [e for e in events if e["event"] == "brute_force_block"]
    assert blocks[0]["ip"] == "203.0.113.40" and blocks[0]["retry_after"] == 300 and blocks[0]["level"] == 1
    auth_failed = [e for e in events if e["event"] == "auth_failed"]
    assert len(auth_failed) == 3 and auth_failed[0]["reason"] == "malformed" and auth_failed[0]["status"] == 401
    # Sperre abgelaufen → nächste Sperre 15 min, dann 60 min
    for expected in (900, 3600, 3600):
        until, level, since = security.guard.blocks["203.0.113.40"]
        security.guard.blocks["203.0.113.40"] = (time.monotonic() - 1, level, since)
        assert c.get("/api/me").status_code == 200
        _bad(c, 3)
        assert expected - 10 <= int(c.get("/api/me").headers["retry-after"]) <= expected + 1


def test_brute_force_allowlist(client, monkeypatch):
    monkeypatch.setenv("BRUTE_401_THRESHOLD", "2")
    monkeypatch.setenv("SECURITY_ALLOWLIST", "203.0.113.0/28")
    c = other("203.0.113.5")
    _bad(c, 5)
    assert c.get("/api/me").status_code == 200


def test_success_resets_401_series_of_same_sub_only(client, monkeypatch):
    monkeypatch.setenv("BRUTE_401_THRESHOLD", "3")
    c = other("203.0.113.50")
    expired = {"exp": int(time.time()) - 120, "iat": int(time.time()) - 400}
    _bad(c, 2, **expired)                          # abgelaufenes Token desselben Benutzers (vor dem Refresh)
    assert c.get("/api/me").status_code == 200     # Anmeldung ok → diese Serie vergessen
    _bad(c, 2, **expired)
    assert c.get("/api/me").status_code == 200
    # anonyme Fehlversuche (kaputtes Token) bleiben trotz Erfolg bestehen
    d = other("203.0.113.51")
    _bad(d, 2)
    assert d.get("/api/me").status_code == 200
    _bad(d, 1)
    assert d.get("/api/me").status_code == 429


def test_brute_force_tenant_probing_and_foreign_ids(client, monkeypatch, events):
    monkeypatch.setenv("BRUTE_403_THRESHOLD", "3")
    c = other("203.0.113.60")
    for t in ("a", "b", "c"):
        assert c.get(f"/api/t/{t}/vehicles").status_code == 403
    assert c.get(f"{T}/vehicles").status_code == 429
    ev = [e for e in events if e["event"] == "forbidden_tenant"]
    assert [e["tenant"] for e in ev] == ["a", "b", "c"] and ev[0]["sub"] == "user-1"
    assert [e for e in events if e["event"] == "brute_force_block"][0]["reason"] == "forbidden_tenant"
    d = other("203.0.113.61")
    for _ in range(3):
        assert d.get(f"{T}/vehicles/{uid()}/stats").status_code == 404
    assert d.get(f"{T}/vehicles").status_code == 429


def test_read_only_403_not_counted_as_probing(client, monkeypatch):
    monkeypatch.setenv("BRUTE_403_THRESHOLD", "2")
    for _ in range(4):
        sync(client, op("vehicle", uid(), {"name": "x"}), tenant="firma", expect=403)   # Leserolle
    assert client.get("/api/me").status_code == 200


# ---------- CORS / CSRF ----------
def test_cors_default_no_cross_origin(client):
    r = client.get("/api/me", headers={"Origin": "https://evil.example"})
    assert r.status_code == 200 and "access-control-allow-origin" not in r.headers
    r = client.options(f"{T}/sync", headers={"Origin": "https://evil.example",
                                             "Access-Control-Request-Method": "POST"})
    assert r.status_code == 403 and "access-control-allow-origin" not in r.headers


def test_cors_allowlist(client, monkeypatch):
    monkeypatch.setenv("CORS_ORIGINS", "https://app.example.test, *")
    r = client.options(f"{T}/sync", headers={"Origin": "https://app.example.test",
                                             "Access-Control-Request-Method": "POST",
                                             "Access-Control-Request-Headers": "authorization,content-type"})
    assert r.status_code == 204
    assert r.headers["access-control-allow-origin"] == "https://app.example.test"
    assert "POST" in r.headers["access-control-allow-methods"] and "*" not in r.headers["access-control-allow-methods"]
    assert "Authorization" in r.headers["access-control-allow-headers"]
    assert "access-control-allow-credentials" not in r.headers and r.headers["vary"] == "Origin"
    r = client.get("/api/me", headers={"Origin": "https://app.example.test"})
    assert r.headers["access-control-allow-origin"] == "https://app.example.test"
    # "*" wird ignoriert: andere Origins bleiben ohne Freigabe
    r = client.get("/api/me", headers={"Origin": "https://evil.example"})
    assert "access-control-allow-origin" not in r.headers
    assert client.options("/api/me", headers={"Origin": "https://evil.example",
                                              "Access-Control-Request-Method": "GET"}).status_code == 403
    assert client.post(f"{T}/sync", json={"ops": []}, headers={"Origin": "https://app.example.test"}).status_code == 200


def test_csrf_origin_check_for_state_changing_requests(client, monkeypatch, events):
    body = {"ops": []}
    assert client.post(f"{T}/sync", json=body).status_code == 200                       # App: kein Origin
    assert client.post(f"{T}/sync", json=body, headers={"Origin": "http://testserver"}).status_code == 200
    assert client.post(f"{T}/sync", json=body, headers={"Origin": "https://testserver"}).status_code == 200
    for bad in ("https://evil.example", "null", "http://testserver.evil.example", "http://testserver:8443"):
        r = client.post(f"{T}/sync", json=body, headers={"Origin": bad})
        assert r.status_code == 403 and r.json() == {"detail": "Ungültige Origin"}, bad
    assert client.get("/api/me", headers={"Origin": "https://evil.example"}).status_code == 200   # GET: nur CORS
    monkeypatch.setenv("ALLOWED_HOSTS", "fahrzeugbuch.j-mb.net")
    r = client.post(f"{T}/sync", json=body, headers={"Origin": "https://fahrzeugbuch.j-mb.net",
                                                     "Host": "fahrzeugbuch.j-mb.net"})
    assert r.status_code == 200
    assert "cors_rejected" in names(events)


# ---------- Host / Header / HSTS / Request-ID ----------
def test_trusted_host(client, monkeypatch, events):
    monkeypatch.setenv("ALLOWED_HOSTS", "fahrzeugbuch.j-mb.net, *.intern.test")
    r = client.get("/auth/config")
    assert r.status_code == 400 and r.json() == {"detail": "Ungültiger Host"}
    assert client.get("/auth/config", headers={"Host": "fahrzeugbuch.j-mb.net"}).status_code == 200
    assert client.get("/auth/config", headers={"Host": "fahrzeugbuch.j-mb.net:443"}).status_code == 200
    assert client.get("/auth/config", headers={"Host": "api.intern.test"}).status_code == 200
    assert client.get("/auth/config", headers={"Host": "127.0.0.1:8000"}).status_code == 200     # Healthcheck
    assert client.get("/auth/config", headers={"Host": "evil.example"}).status_code == 400
    assert client.get("/auth/config", headers={"Host": "fahrzeugbuch.j-mb.net.evil.example"}).status_code == 400
    # Probes/Prometheus (Host = Pod-IP): /health* und /metrics ohne Host-Prüfung
    for path in ("/health", "/health/live", "/health/ready"):
        assert client.get(path, headers={"Host": "10.42.0.17:8000"}).status_code == 200
    assert client.get("/metrics", headers={"Host": "10.42.0.17:8000"}).status_code == 404     # ohne Token
    assert client.get("/api/me", headers={"Host": "10.42.0.17:8000"}).status_code == 400
    assert "host_rejected" in names(events)


def test_security_headers_everywhere(client):
    for path, kw in (("/api/me", {}), ("/health", {}), ("/api/t/privat/x", {}), ("/api/me", {"headers": {
            "Authorization": ""}})):
        r = client.get(path, **kw)
        assert r.headers["x-content-type-options"] == "nosniff", path
        assert r.headers["referrer-policy"] == "no-referrer"
        assert r.headers["cross-origin-resource-policy"] == "same-origin"
        assert "server" not in r.headers and "strict-transport-security" not in r.headers
        assert len(r.headers["x-request-id"]) >= 8
    assert client.get("/api/me").headers.get_list("x-content-type-options") == ["nosniff"]


def test_hsts_only_over_https(client, monkeypatch):
    assert "strict-transport-security" not in client.get("/health").headers
    h = {"X-Forwarded-Proto": "https"}
    assert "strict-transport-security" not in client.get("/health", headers=h).headers      # Peer nicht vertraut
    monkeypatch.setenv("FORWARDED_ALLOW_IPS", "testclient")
    assert client.get("/health", headers=h).headers["strict-transport-security"] == \
        "max-age=31536000; includeSubDomains"
    monkeypatch.delenv("FORWARDED_ALLOW_IPS")
    with TestClient(app, base_url="https://testserver") as s:
        assert "includeSubDomains" in s.get("/health").headers["strict-transport-security"]
    monkeypatch.setenv("FORCE_HSTS", "1")
    assert "strict-transport-security" in client.get("/health").headers


def test_request_id(client, caplog):
    rid = "abcDEF-1234-5678"
    assert client.get("/health", headers={"X-Request-ID": rid}).headers["x-request-id"] == rid
    for bad in ("kurz", "a" * 65, "ungueltig id!", "abc_def_ghi", "x\\r\\nSet-Cookie"):
        got = client.get("/health", headers={"X-Request-ID": bad}).headers["x-request-id"]
        assert got != bad and security.REQUEST_ID.match(got)


def test_request_id_in_security_log(client, events):
    client.get("/api/me", headers={"Authorization": "Bearer x", "X-Request-ID": "req-12345678"})
    ev = [e for e in events if e["event"] == "auth_failed"][0]
    assert ev["request_id"] == "req-12345678" and ev["path"] == "/api/me"


def test_uri_too_long(client):
    assert client.get("/api/me?x=" + "a" * 3000).status_code == 414


# ---------- Eingaben ----------
def test_oversized_authorization_header_rejected_without_parsing(client, events, monkeypatch):
    called = []
    monkeypatch.setattr(auth.jwt, "get_unverified_header", lambda t: called.append(t))
    r = client.get("/api/me", headers={"Authorization": "Bearer " + "a" * 9000})
    assert r.status_code == 401 and r.json() == {"detail": "Token ungültig"} and not called
    assert [e["reason"] for e in events if e["event"] == "auth_failed"] == ["oversized_token"]


def test_json_depth_and_items(client, monkeypatch):
    deep = "[" * 40 + "]" * 40
    r = client.post(f"{T}/sync", content='{"ops":' + deep + "}", headers={"Content-Type": "application/json"})
    assert r.status_code == 422 and "verschachtelt" in r.text
    very_deep = "[" * 200_000 + "]" * 200_000              # früher: RecursionError → 500
    assert client.post("/api/geo/match", content=very_deep[:900_000],
                       headers={"Content-Type": "application/json"}).status_code == 422
    # Strings werden übersprungen (Klammern/Kommas darin zählen nicht)
    vid = new_vehicle(client, name="[[[[," * 20)
    assert vid
    monkeypatch.setenv("JSON_MAX_ITEMS", "10")
    r = client.post(f"{T}/sync", json={"ops": [op("vehicle", uid(), {"name": "x"}) for _ in range(3)]})
    assert r.status_code == 422 and "Elementen" in r.text
    # Body-Limit greift weiterhin zuerst
    monkeypatch.delenv("JSON_MAX_ITEMS")
    assert client.post(f"{T}/sync", content=b"[" * (2 * 1024 * 1024),
                       headers={"Content-Type": "application/json"}).status_code == 413


def test_json_problem_unit(monkeypatch):
    assert security.json_problem(b'{"a":[1,2,{"b":"]]]],,,"}]}') is None
    monkeypatch.setenv("JSON_MAX_DEPTH", "2")
    assert security.json_problem(b'{"a":"[[[[[["}') is None
    assert security.json_problem(b'{"a":{"b":{"c":1}}}') is not None
    assert security.json_problem(b'{"a":"\\"[[[[[["}') is None            # escaptes Anführungszeichen


def test_control_chars_and_nfc_in_payloads(client):
    vid = uid()
    sync(client, op("vehicle", vid, {"name": "Golf\x00\u202e X\nY\t", "make": "Re\u0301nault"}),
         op("odometer", (oid := uid()), {"vehicle_id": vid, "date": "2026-01-01", "km": 1,
                                         "note": "Zeile 1\r\nZeile 2\tTab\x07\x1b[31m"}))
    ch = client.get(f"{T}/changes").json()
    v = ch["vehicles"][0]
    assert v["name"] == "Golf X Y " and v["make"] == "Rénault" and len(v["make"]) == 7
    o = [x for x in ch["odometer"] if x["id"] == oid][0]
    assert o["note"] == "Zeile 1\nZeile 2\tTab[31m"


def test_clean_text_unit():
    assert security.clean_text("a\u2028b\u2066c\ufeffd") == "a bcd"
    assert security.clean_text("a\u2029b\rc", multiline=True) == "a\nb\nc"
    assert security.clean_text("\u0041\u030a") == "\u00c5"


def test_path_params_strict(client):
    vid = new_vehicle(client)
    for bad in ("kein-uuid", "..%2F..%2Fetc", vid + "x", "' OR 1=1 --"):
        assert client.get(f"{T}/vehicles/{bad}/stats").status_code == 404, bad
        assert client.get(f"{T}/vehicles/{bad}/trips.csv").status_code == 404, bad
        assert client.get(f"{T}/history/vehicle/{bad}").status_code == 404, bad
    assert client.get(f"{T}/vehicles/{vid.upper()}/stats").status_code == 200        # UUID normalisiert
    assert client.get(f"{T}/history/unbekannt/{vid}").status_code == 404
    assert client.post(f"{T}/vehicles/{vid}/periods/2026-13/close", json={}).status_code == 422
    assert client.post(f"{T}/vehicles/{vid}/periods/x' OR '1/close", json={}).status_code == 422
    assert client.get("/api/t/PRIVAT%2F..%2Ffirma/vehicles").status_code in (403, 404)
    assert client.get("/api/t/" + "a" * 100 + "/vehicles").status_code == 403
    # ohne gültiges Token zuerst 401 (Pfadprüfung erst nach Anmeldung und Mandantenrecht)
    assert client.get(f"{T}/vehicles/kein-uuid/stats", headers={"Authorization": "Bearer x"}).status_code == 401
    assert client.get("/api/t/fremd/vehicles/kein-uuid/stats").status_code == 403


# ---------- Token ----------
def test_token_time_claims(client, monkeypatch, events):
    now = int(time.time())
    cases = {
        "iat_future": make_token(iat=now + 300, exp=now + 600),
        "lifetime": make_token(iat=now, exp=now + 7200),
        "not_yet_valid": make_token(nbf=now + 300),
        "bad_jti": make_token(jti=123),
    }
    for reason, t in cases.items():
        r = client.get("/api/me", headers={"Authorization": f"Bearer {t}"})
        assert r.status_code == 401 and r.json() == {"detail": "Token ungültig"}, reason
    got = [e["reason"] for e in events if e["event"] == "auth_failed"]
    assert got[0] in ("iat_future", "not_yet_valid") and got[1:] == ["lifetime", "not_yet_valid", "bad_jti"]
    assert client.get("/api/me", headers=bearer_token(jti="abc-123", nbf=now - 10)).status_code == 200
    monkeypatch.setenv("MAX_TOKEN_LIFETIME_S", "86400")
    assert client.get("/api/me", headers={"Authorization": f"Bearer {cases['lifetime']}"}).status_code == 200


def test_generic_auth_errors(client, monkeypatch):
    r = client.get("/api/me", headers=bearer_token(azp="anderer-client"))
    assert r.json() == {"detail": "Token ungültig"}
    monkeypatch.setenv("OIDC_REQUIRED_ROLE", "fahrzeugbuch-admin-geheim")
    r = client.get("/api/me")
    assert r.status_code == 403 and "geheim" not in r.text
    r = client.get("/api/t/<b>fremd</b>/vehicles")
    assert "<b>" not in r.text


def test_jwks_https_only(monkeypatch):
    cache = auth.JWKSCache("http://id.example.test/realms/x")
    monkeypatch.delenv("OIDC_ALLOW_HTTP", raising=False)
    with pytest.raises(auth.KeyServiceUnavailable):
        cache.key_for("kid")
    calls = []

    class R:
        def __init__(self, body):
            self.body = body

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def read(self, n):
            return self.body

    def fake_open(url, timeout):
        calls.append(url)
        return R(b'{"jwks_uri": "http://id.example.test/certs"}' if "well-known" in url else b'{"keys": []}')

    monkeypatch.setattr(auth._opener, "open", fake_open)
    monkeypatch.setenv("OIDC_ALLOW_HTTP", "1")
    cache = auth.JWKSCache("http://id.example.test/realms/x")
    with pytest.raises(auth.UnknownKey):
        cache.key_for("kid")
    assert len(calls) == 2
    monkeypatch.setattr(auth._opener, "open", lambda url, timeout: R(b"x" * (auth.MAX_JWKS_BYTES + 10)))
    with pytest.raises(ValueError):
        auth.JWKSCache("https://id.example.test/realms/x")._get_json("https://id.example.test/x")


# ---------- Sicherheits-Log / Log-Injection ----------
def test_security_log_json_lines_sanitized(client, events):
    r = client.get("/api/t/privat%0D%0AFAKE%20event/vehicles", headers={"Authorization": "Bearer x"})
    assert r.status_code == 401
    ev = [e for e in events if e["event"] == "auth_failed"][0]
    assert "\r" not in ev["path"] and "\n" not in ev["path"] and "\\u000d" in ev["path"]
    rec = logging.LogRecord("fahrzeugbuch.security", logging.INFO, "", 0, "x", (), None)
    rec.security = ev
    line = security.JsonFormatter().format(rec)
    assert "\n" not in line and json.loads(line)["event"] == "auth_failed"
    assert list(json.loads(line))[:4] == ["ts", "logger", "event", "ip"]      # feste Reihenfolge (fail2ban)


def test_clean_unit():
    s = security.clean("a\r\nb\x1b[31m\u202e" + "x" * 500, limit=20)
    assert "\r" not in s and "\n" not in s and "\x1b" not in s and "\u202e" not in s and s.endswith("…")


def test_general_logs_sanitized(caplog):
    with caplog.at_level(logging.INFO, logger="fahrzeugbuch"):
        logging.getLogger("fahrzeugbuch.test").warning("Eingabe %s", "ok\r\n2026-01-01 FAKE Zeile")
    msg = caplog.records[-1].getMessage()
    assert "\n" not in msg and "\r" not in msg and "FAKE" in msg
    assert hasattr(caplog.records[-1], "request_id")


def test_events_for_upload_web_only_and_integrity(client, events):
    from sqlalchemy import text

    from app.db import engine

    from .test_audit import _seed
    vid, fid = _seed(client)
    aid = uid()
    sync(client, op("attachment", aid, {"fuel_id": fid, "kind": "receipt", "sha256": "a" * 64,
                                        "mime": "image/jpeg", "size": 3}))
    r = client.put(f"{T}/attachments/{aid}/blob", content=b"abc", headers={"Content-Type": "application/pdf"})
    assert r.status_code == 415
    p = {"year": 2026, "scope": "tenant", "key": "km_rate", "value": 0.7}
    sync(client, op("tax_param", uid(), p))
    with engine.begin() as conn:
        conn.execute(text("UPDATE fuel_entries SET price_total = 9999 WHERE id = :i"), {"i": fid})
    assert client.get(f"{T}/audit/verify").json()["ok"] is False
    by = {e["event"]: e for e in events}
    assert by["upload_rejected"]["reason"] == "content_type" and by["upload_rejected"]["status"] == 415
    assert by["web_only_violation"]["reason"] == "sync tax_param"
    assert by["integrity_failed"]["tenant"] == "privat" and fid in by["integrity_failed"]["reason"]


# ---------- Startprüfung ----------
def test_config_warnings_and_strict(monkeypatch, events):
    monkeypatch.setenv("OIDC_ISSUER", "http://id.example.test/realms/x")
    monkeypatch.setenv("DOCS_ENABLED", "1")
    monkeypatch.setenv("FORWARDED_ALLOW_IPS", "*")
    monkeypatch.setenv("DEFAULT_TENANT", "haushalt")
    monkeypatch.setenv("N8N_WEBHOOK_URL", "https://n8n.example.test/hook")
    monkeypatch.setenv("N8N_WEBHOOK_SECRET", "kurz")
    monkeypatch.setenv("CORS_ORIGINS", "*")
    monkeypatch.setenv("SECURITY_ALLOWLIST", "0.0.0.0/0")
    w = " | ".join(security.config_warnings())
    for part in ("OIDC_ISSUER", "DOCS_ENABLED", "ALLOWED_HOSTS", "FORWARDED_ALLOW_IPS", "ANCHOR_SIGNING_KEY",
                 "DEFAULT_TENANT", "N8N_WEBHOOK_SECRET", "CORS_ORIGINS", "SECURITY_ALLOWLIST"):
        assert part in w, part
    assert len(security.check_config()) == 9
    assert names(events).count("config_warning") == 9
    monkeypatch.setenv("STRICT_CONFIG", "1")
    with pytest.raises(security.InsecureConfig):
        security.check_config()
    with pytest.raises(security.InsecureConfig):
        with TestClient(app):
            pass


def test_secure_config_has_no_warnings(monkeypatch):
    monkeypatch.setenv("ALLOWED_HOSTS", "fahrzeugbuch.j-mb.net")
    monkeypatch.setenv("ANCHOR_SIGNING_KEY", "x")
    monkeypatch.setenv("N8N_WEBHOOK_URL", "https://n8n.example.test/hook")
    monkeypatch.setenv("N8N_WEBHOOK_SECRET", "s" * 64)
    monkeypatch.setenv("STRICT_CONFIG", "1")
    assert security.check_config() == []


# ---------- Injection ----------
@pytest.mark.parametrize("value", ["=1+1", "+1", "-1", "@SUM(A1)", "\t=1", "\r=1", "\n=1", "＝1+1", "＋1", "－1",
                                   "＠SUM(A1)", "﹦1", "  =1", "\u3000=1", "\u00a0@x"])
def test_csv_formula_variants_escaped(value):
    assert _cell(value) == "'" + value


@pytest.mark.parametrize("value", ["Golf", "1.5", "Zürich = Ziel", "", "'=x"])
def test_csv_plain_text_unchanged(value):
    assert _cell(value) == value


def test_csv_export_unicode_formula(client):
    vid = new_vehicle(client)
    sync(client, op("trip", uid(), {"vehicle_id": vid, "start_at": "2026-03-02T08:00:00+01:00",
                                    "end_at": "2026-03-02T09:00:00+01:00", "km_start": 10000, "km_end": 10010,
                                    "category": "business", "purpose": "＝HYPERLINK(\"http://x\")",
                                    "start_label": "＠cmd", "status": "confirmed"}))
    body = client.get(f"{T}/vehicles/{vid}/trips.csv?from=2026-03-01&to=2026-03-31").content.decode("utf-8-sig")
    assert ";'＠cmd;" in body and "'＝HYPERLINK" in body


def test_content_disposition_rfc6266():
    cd = content_disposition('Fahr"zeug\r\n%0d;/\\ Š.pdf', "inline\r\nX-Evil: 1")
    assert cd.startswith("attachment; ") and "\r" not in cd and "\n" not in cd
    ascii_part = cd.split('filename="', 1)[1].split('"', 1)[0]
    assert all(c not in ascii_part for c in '"\\;%/') and "filename*=UTF-8''" in cd
    assert "%C5%A0" in cd


def test_keycloak_path_segments_validated():
    assert members._seg("0b2f0c4e-1234-4a5b-9c8d-001122334455") == "0b2f0c4e-1234-4a5b-9c8d-001122334455"
    for bad in ("../users", "a/b", "x?y=1", "a%2Fb", "", "a" * 37):
        with pytest.raises(UpstreamError):
            members._seg(bad)


def test_admin_actions_logged(client, kc, events):  # noqa: F811 – Fixture aus test_collab
    h = admin_web()
    assert client.post(f"{T}/members", json={"user": "treuhand", "role": "read"}, headers=h).status_code == 201
    assert client.patch(f"{T}/members/user-3", json={"role": "write"}, headers=h).status_code == 200
    assert client.delete(f"{T}/members/user-3", headers=h).status_code == 204
    acts = [(e["reason"], e.get("target"), e.get("role")) for e in events if e["event"] == "admin_action"]
    assert acts == [("member_add", "user-3", "read"), ("member_role", "user-3", "write"),
                    ("member_remove", "user-3", None)]
    assert all(e["sub"] == "user-1" and e["tenant"] == "privat" for e in events if e["event"] == "admin_action")
    r = client.patch(f"{T}/members/user-3", json={"role": "write"}, headers=admin_ios())   # iOS-Token
    assert r.status_code == 403 and "web_only_violation" in names(events)
