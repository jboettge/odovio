"""Gemeinsamer Zustand gegen echten Valkey/Redis (FZB_TEST_REDIS_URL): Token-Bucket, gleitendes Fenster,
Brute-Force (Sperre, Backoff, auth_ok je sub, Probing), Circuit-Breaker, TTL aller Schlüssel, Metrik-Schnappschüsse,
Ausfall (Rate-Limits mit lokalem Budget, Sperren lokal, Health degraded/ready 503). Zwei RedisState-Instanzen =
zwei Worker."""
import json
import time

import pytest

from app import geo, main, metrics, security, state

from .conftest import REDIS_URL, T, bearer_token, forged_auth
from .test_security import events, other  # noqa: F401  (Fixture)

pytestmark = pytest.mark.requires_redis


def worker2(shared: state.RedisState) -> state.RedisState:
    """Zweiter „Worker“: eigene Verbindungen, gleicher Präfix."""
    return state.RedisState(REDIS_URL, key_prefix=shared.p)


def test_token_bucket_shared_between_workers(redis_state):
    w2 = worker2(redis_state)
    assert [redis_state.take("ip:1.2.3.4", 60, 3) for _ in range(2)] == [0, 0]
    assert w2.take("ip:1.2.3.4", 60, 3) == 0
    assert 1 <= w2.take("ip:1.2.3.4", 60, 3) <= 2               # Burst über beide Worker verbraucht
    assert redis_state.take("ip:1.2.3.4", 60, 3) >= 1
    assert redis_state.take("ip:5.6.7.8", 60, 3) == 0             # andere IP unabhängig


def test_sliding_window_shared(redis_state):
    w2 = worker2(redis_state)
    assert redis_state.window("scan:u1", 2, 60) == 0
    assert w2.window("scan:u1", 2, 60) == 0
    retry = redis_state.window("scan:u1", 2, 60)
    assert 59 <= retry <= 61
    assert redis_state.window("scan:u2", 2, 60) == 0


def test_brute_force_block_backoff_and_auth_ok(redis_state):
    w2 = worker2(redis_state)
    args = (3, 300.0, [300, 900], 86400.0)
    assert redis_state.auth_failed("9.9.9.9", "u1", *args) is None
    assert w2.auth_failed("9.9.9.9", None, *args) is None
    # Erfolg von u1 entfernt nur dessen Fehlversuch (nicht den anonymen)
    assert w2.auth_ok("9.9.9.9", "u1") == 1
    assert redis_state.auth_failed("9.9.9.9", None, *args) is None
    assert redis_state.auth_failed("9.9.9.9", "u2", *args) == (300, 1)
    assert 299 <= w2.blocked("9.9.9.9") <= 301 and w2.blocked("9.9.9.10") == 0
    # Sperre läuft ab (hier: Schlüssel-Feld zurücksetzen) → nächste Sperre auf Stufe 2
    redis_state._sync.hset(redis_state.k("bf:b", "9.9.9.9"), "until", "0")
    assert redis_state.blocked("9.9.9.9") == 0
    for _ in range(2):
        assert redis_state.auth_failed("9.9.9.9", None, *args) is None
    assert redis_state.auth_failed("9.9.9.9", None, *args) == (900, 2)


def test_probe_counts_per_sub(redis_state):
    args = (2, 300.0, [60], 86400.0)
    assert redis_state.probe("8.8.8.8", "a", *args) is None
    assert redis_state.probe("8.8.8.8", "b", *args) is None       # anderer sub zählt getrennt
    assert redis_state.probe("8.8.8.8", "a", *args) == (60, 1)


def test_circuit_breaker_shared(redis_state):
    w2 = worker2(redis_state)
    assert not redis_state.breaker_failure("osrm", 2, 30)
    assert w2.breaker_failure("osrm", 2, 30)                      # zweiter Fehler (anderer Worker) sperrt
    assert 29 <= redis_state.breaker_open("osrm") <= 30
    assert w2.breaker_open("photon") == 0
    w2.breaker_success("osrm")


def test_all_keys_have_ttl(redis_state):
    redis_state.take("ip:1.1.1.1", 600, 10)
    redis_state.window("geo:u", 5, 60)
    redis_state.auth_failed("1.1.1.1", "u", 2, 300.0, [300], 86400.0)
    redis_state.auth_failed("1.1.1.1", "u", 2, 300.0, [300], 86400.0)
    redis_state.probe("1.1.1.2", "u", 5, 300.0, [300], 86400.0)
    redis_state.breaker_failure("llm", 5, 30)
    redis_state.metrics_put("grp", "w1", "{}", 10)
    keys = list(redis_state._sync.scan_iter(match=redis_state.p + "*"))
    assert len(keys) >= 6
    for k in keys:
        assert redis_state._sync.pttl(k) > 0, k                   # kein Schlüssel ohne Ablauf
    assert all(k.decode().startswith(redis_state.p) for k in keys)


def test_long_identifiers_hashed(redis_state):
    assert redis_state.k("rl", "x" * 500).startswith(redis_state.p + "rl:h")
    assert redis_state.k("tb", "ip:1.2.3.4") == redis_state.p + "tb:ip:1.2.3.4"


def test_app_rate_limits_via_redis(client, redis_state, monkeypatch):
    monkeypatch.setenv("RATE_ACTIVITY", "1")
    assert client.get(f"{T}/activity").status_code == 200
    security.buckets.reset()                                     # lokale Strukturen spielen keine Rolle
    assert client.get(f"{T}/activity").status_code == 429
    monkeypatch.setenv("RATE_IP_PER_MIN", "1")
    monkeypatch.setenv("RATE_IP_BURST", "2")
    c = other("203.0.113.70")
    assert [c.get("/api/me").status_code for _ in range(3)] == [200, 200, 429]
    assert not security.buckets.data                             # nichts im Prozess gezählt


def test_app_brute_force_via_redis(client, redis_state, monkeypatch, events):  # noqa: F811
    monkeypatch.setenv("BRUTE_401_THRESHOLD", "3")
    c = other("203.0.113.80")
    for _ in range(3):
        assert c.get("/api/me", headers=forged_auth()).status_code == 401
    security.guard.reset()                                       # anderer Worker: lokal nichts bekannt
    r = c.get("/api/me")
    assert r.status_code == 429 and 290 <= int(r.headers["retry-after"]) <= 301
    assert [e for e in events if e["event"] == "brute_force_block"][0]["level"] == 1


def test_shared_block_api_only(client, redis_state, monkeypatch):  # noqa: F811
    monkeypatch.setenv("BRUTE_401_THRESHOLD", "2")
    c = other("203.0.113.81")
    for _ in range(3):
        assert c.get("/api/me", headers={"Authorization": ""}).status_code == 401   # zählt nicht
    assert c.get("/api/me").status_code == 200
    for _ in range(2):
        assert c.get("/api/me", headers=forged_auth()).status_code == 401
    security.guard.reset()                                       # Sperre nur in Valkey
    assert c.get("/api/me").status_code == 429
    assert [c.get(p).status_code for p in ("/health", "/health/ready", "/auth/config")] == [200, 200, 200]


def test_app_circuit_breaker_via_redis(client, redis_state, monkeypatch):
    from .test_intel import FakeHTTP
    from .test_upstream_limits import PHOTON
    fake = FakeHTTP()
    monkeypatch.setattr(geo, "http_json", fake)
    monkeypatch.setenv("PHOTON_URL", "http://photon:2322")
    fake.on("/reverse", lambda u, p: geo.UpstreamError("TimeoutError"))
    assert [client.post("/api/geo/reverse", json={"lat": 47, "lon": 8}).status_code for _ in range(3)] == [502] * 3
    geo.reset_upstreams()                                         # lokaler Zustand weg (anderer Worker)
    r = client.post("/api/geo/reverse", json={"lat": 47, "lon": 8})
    assert r.status_code == 503 and len(fake.calls) == 3
    redis_state._sync.delete(redis_state.k("cb", "photon"))
    fake.on("/reverse", PHOTON)
    assert client.post("/api/geo/reverse", json={"lat": 47, "lon": 8}).status_code == 200


def test_metrics_snapshots_of_all_workers(client, redis_state, monkeypatch):
    monkeypatch.setenv("METRICS_TOKEN", "t" * 40)
    monkeypatch.setenv("FZB_INSTANCE_ID", "inst-a")
    other_worker = {**metrics.snapshot(), "worker": "99999", "id": "fremd",
                    "requests": [["GET", "/api/me", "200", 7]]}
    redis_state.metrics_put("inst-a", "fremd", json.dumps(other_worker), 30)
    redis_state.metrics_put("inst-b", "x", json.dumps({**other_worker, "worker": "4242"}), 30)  # anderer Pod
    main._push_metrics()
    body = client.get("/metrics", headers={"Authorization": "Bearer " + "t" * 40}).text
    assert 'worker="99999"' in body and 'route="/api/me",status="200"} 7' in body
    assert 'worker="4242"' not in body
    assert 'fzb_state_backend_up{worker=' in body


# ---------- Ausfall ----------
@pytest.fixture
def broken_state(monkeypatch):
    monkeypatch.setenv("STATE_BACKEND", "redis")
    monkeypatch.setenv("REDIS_URL", "redis://127.0.0.1:1/0")
    monkeypatch.setenv("REDIS_TIMEOUT_MS", "100")
    monkeypatch.setenv("REDIS_RETRY_S", "5")
    broken = state.RedisState("redis://127.0.0.1:1/0", key_prefix="fzbbroken:")
    state.configure(broken)
    yield broken
    state.configure(None)


def test_outage_local_budget_and_local_blocks(client, broken_state, monkeypatch, events):  # noqa: F811
    # X5: Ausfall → Rate-Limits lokal mit dem Anteil dieses Prozesses (4 ÷ 2 Worker = 2, Aktivität 2 ÷ 2 = 1)
    monkeypatch.setenv("WEB_CONCURRENCY", "2")
    monkeypatch.setenv("RATE_IP_PER_MIN", "4")
    monkeypatch.setenv("RATE_IP_BURST", "4")
    monkeypatch.setenv("RATE_ACTIVITY", "2")
    monkeypatch.setenv("BRUTE_401_THRESHOLD", "2")
    c = other("203.0.113.90")
    assert [c.get("/api/me").status_code for _ in range(3)] == [200, 200, 429]
    assert [client.get(f"{T}/activity").status_code for _ in range(2)] == [200, 429]
    assert any(e["event"] == "state_backend_error" for e in events)
    # Brute-Force gilt lokal weiter
    monkeypatch.setenv("RATE_IP_PER_MIN", "100000")
    monkeypatch.setenv("RATE_IP_BURST", "100000")
    c = other("203.0.113.91")
    for _ in range(2):
        assert c.get("/api/me", headers=forged_auth()).status_code == 401
    assert c.get("/api/me").status_code == 429
    assert client.get("/health").json() == {"status": "degraded"}
    r = client.get("/health/ready")            # S1: Valkey weg → nur «degraded», Pod bleibt bereit
    assert r.status_code == 200 and r.json()["state"] == "unavailable" and r.json()["degraded"] is True
    assert r.json()["status"] == "ready"
    assert client.get("/health/live").status_code == 200


def test_outage_does_not_wait_per_request(broken_state):
    with pytest.raises(state.StateUnavailable):
        broken_state.take("k", 60, 1)
    t = time.monotonic()
    for _ in range(50):
        with pytest.raises(state.StateUnavailable):
            broken_state.take("k", 60, 1)
    assert time.monotonic() - t < 0.5                            # zurückgestellt (REDIS_RETRY_S)


def test_blocks_mirrored_locally_survive_outage(client, redis_state, monkeypatch):
    monkeypatch.setenv("BRUTE_401_THRESHOLD", "2")
    c = other("203.0.113.95")
    for _ in range(2):
        c.get("/api/me", headers=forged_auth())
    assert security.guard.blocked("203.0.113.95") > 0             # gespiegelt
    state.configure(state.RedisState("redis://127.0.0.1:1/0", key_prefix="fzbbroken:"))
    assert c.get("/api/me").status_code == 429                    # Valkey weg, Sperre gilt weiter


def test_user_token_ok_after_backend_recovers(client, redis_state):
    assert client.get("/api/me", headers=bearer_token()).status_code == 200
