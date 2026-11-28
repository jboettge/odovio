"""Vertikale Skalierung ohne externe Dienste: Worker-Zahl/cgroup, Startprüfungen, uvicorn-Argumente, Secrets aus
Dateien, Health/Ready/Live, /metrics-Zugriff, GZip, CSV-Streaming, PDF-Gleichzeitigkeit, Advisory-Locks (PG)."""
import inspect
import threading
import time
from types import SimpleNamespace

import pytest
from sqlalchemy import func, select

from app import config, integrity, jobs, main, metrics, migrate, models, runtime, security, serve
from app.db import SessionLocal

from .conftest import IS_PG, T, new_vehicle, op, sync, uid


# ---------- Worker / cgroup ----------
def _cgroup(tmp_path, content: str):
    (tmp_path / "cpu.max").write_text(content)
    return str(tmp_path)


def test_cpu_quota_cgroup_v2(tmp_path):
    assert config.cpu_quota(_cgroup(tmp_path, "200000 100000\n")) == 2.0
    assert config.cpu_quota(_cgroup(tmp_path, "max 100000\n")) is None
    assert config.cpu_quota(str(tmp_path / "fehlt")) is None


def test_workers_auto_uses_quota_not_cpu_count(tmp_path, monkeypatch):
    monkeypatch.setattr(config.os, "sched_getaffinity", lambda _: set(range(32)))
    assert config.resolve_workers("auto", _cgroup(tmp_path, "150000 100000")) == 3      # 1.5 CPU → 3
    assert config.resolve_workers("auto", _cgroup(tmp_path, "50000 100000")) == 1       # 0.5 CPU → 1
    assert config.resolve_workers("auto", _cgroup(tmp_path, "max 100000")) == 16        # Deckel
    assert config.resolve_workers("4") == 4 and config.resolve_workers(None) == 1
    for bad in ("0", "-1", "viele"):
        with pytest.raises(ValueError):
            config.resolve_workers(bad)


def test_per_worker_budget(monkeypatch):
    monkeypatch.setenv("WEB_CONCURRENCY", "4")
    assert config.per_worker(4) == 1 and config.per_worker(10) == 3 and config.per_worker(1) == 1


# ---------- Startprüfungen ----------
def test_multi_worker_requires_shared_state_and_postgres(monkeypatch):
    monkeypatch.setenv("WEB_CONCURRENCY", "2")
    monkeypatch.setenv("STATE_BACKEND", "memory")
    monkeypatch.setenv("DATABASE_URL", "sqlite:///x.db")
    errs = " | ".join(runtime.errors())
    assert "STATE_BACKEND=redis" in errs and "SQLite" in errs
    with pytest.raises(runtime.StartupError):
        runtime.check()
    monkeypatch.setenv("WEB_CONCURRENCY", "1")
    monkeypatch.setenv("REPLICAS_HINT", "3")            # Replikas zählen mit
    assert len(runtime.errors()) == 2
    monkeypatch.setenv("REPLICAS_HINT", "1")
    assert runtime.errors() == []
    monkeypatch.setenv("STATE_BACKEND", "redis")
    monkeypatch.delenv("REDIS_URL", raising=False)
    assert any("REDIS_URL" in e for e in runtime.errors())


def test_connection_budget_warning_and_strict(monkeypatch):
    monkeypatch.setenv("DATABASE_URL", "postgresql+psycopg://u:p@db/x")
    monkeypatch.setenv("WEB_CONCURRENCY", "8")
    monkeypatch.setenv("DB_POOL_SIZE", "5")
    monkeypatch.setenv("DB_MAX_OVERFLOW", "10")
    monkeypatch.setenv("PG_MAX_CONNECTIONS", "100")
    assert runtime.connection_budget() == (8 * 15 + 10, 100)
    assert any("PG_MAX_CONNECTIONS" in w for w in runtime.warnings())
    monkeypatch.setenv("STRICT_CONFIG", "1")
    with pytest.raises(security.InsecureConfig):
        security.check_config()
    monkeypatch.setenv("PG_MAX_CONNECTIONS", "200")
    assert not any("PG_MAX_CONNECTIONS" in w for w in runtime.warnings())


def test_fs_storage_with_replicas_warns(monkeypatch):
    monkeypatch.setenv("REPLICAS_HINT", "2")
    monkeypatch.delenv("STORAGE_BACKEND", raising=False)
    assert any("RWX" in w for w in runtime.warnings())
    monkeypatch.setenv("FILES_SHARED", "1")                  # Chart: RWX-Volume bestätigt
    assert not any("RWX" in w for w in runtime.warnings())


def test_serve_args_and_abort(monkeypatch):
    env = {"WEB_CONCURRENCY": "3", "UVICORN_LIMIT_CONCURRENCY": "150", "GRACEFUL_TIMEOUT_S": "20",
           "UVICORN_LIMIT_MAX_REQUESTS": "5000"}
    args = serve.build_args(env)
    assert args[0] == "app.main:app"
    assert "--proxy-headers" in args and "--no-server-header" in args
    assert args[args.index("--workers") + 1] == "3"
    assert args[args.index("--limit-concurrency") + 1] == "150"
    assert args[args.index("--timeout-graceful-shutdown") + 1] == "20"
    assert args[args.index("--limit-max-requests") + 1] == "5000"
    assert args[args.index("--limit-max-requests-jitter") + 1] == "500"
    # 1 Worker: kein max-requests (der ganze Server würde enden)
    assert "--limit-max-requests" not in serve.build_args({"UVICORN_LIMIT_MAX_REQUESTS": "10"})
    # Abbruch: 2 Worker ohne gemeinsamen Zustand
    bad = {"WEB_CONCURRENCY": "2", "STATE_BACKEND": "memory", "DATABASE_URL": "postgresql+psycopg://u:p@h/db"}
    monkeypatch.setattr(serve.os, "environ", bad)
    monkeypatch.setattr(config.os, "environ", bad)
    monkeypatch.setattr(runtime.os, "environ", bad)
    with pytest.raises(SystemExit, match="STATE_BACKEND=redis"):
        serve.prepare(bad)
    bad["WEB_CONCURRENCY"] = "x"
    with pytest.raises(SystemExit, match="WEB_CONCURRENCY"):
        serve.prepare(bad)


def test_serve_prepare_sets_env(monkeypatch):
    env = {"WEB_CONCURRENCY": "auto", "STATE_BACKEND": "redis", "REDIS_URL": "redis://localhost:1/0",
           "DATABASE_URL": "postgresql+psycopg://u:p@h/db", "ANCHOR_SIGNING_KEY": "x"}
    for mod in (serve, config, runtime):
        monkeypatch.setattr(mod.os, "environ", env)
    monkeypatch.setattr(config, "available_cpus", lambda root="": 2.0)
    args = serve.prepare(env)
    assert env["WEB_CONCURRENCY"] == "4" and env["FZB_SERVE"] == "1" and len(env["FZB_INSTANCE_ID"]) == 16
    assert args[args.index("--workers") + 1] == "4"


# ---------- Secrets aus Dateien ----------
def test_secret_files(tmp_path):
    (tmp_path / "pw").write_text("geheim/+&\n")
    (tmp_path / "key").write_text("c2lnbmluZw==")
    env = {"DATABASE_URL": "postgresql+psycopg://app@db:5432/fzb", "DATABASE_PASSWORD_FILE": str(tmp_path / "pw"),
           "ANCHOR_SIGNING_KEY_FILE": str(tmp_path / "key"), "REDIS_URL": "redis://valkey:6379/0",
           "REDIS_PASSWORD_FILE": str(tmp_path / "pw")}
    loaded = config.load_secret_files(env)
    assert set(loaded) == {"DATABASE_PASSWORD", "ANCHOR_SIGNING_KEY", "REDIS_PASSWORD"}
    assert env["ANCHOR_SIGNING_KEY"] == "c2lnbmluZw=="
    assert env["DATABASE_URL"] == "postgresql+psycopg://app:geheim%2F%2B%26@db:5432/fzb"
    assert env["REDIS_URL"] == "redis://:geheim%2F%2B%26@valkey:6379/0"
    with pytest.raises(config.ConfigError, match="beide"):
        config.load_secret_files({"METRICS_TOKEN": "a", "METRICS_TOKEN_FILE": str(tmp_path / "pw")})
    with pytest.raises(config.ConfigError, match="nicht lesbar"):
        config.load_secret_files({"METRICS_TOKEN_FILE": str(tmp_path / "fehlt")})


# ---------- Health ----------
def test_health_live_ready(client):
    assert client.get("/health").json() == {"status": "ok"}
    assert client.get("/health/live").json() == {"status": "ok"}
    r = client.get("/health/ready")
    assert r.status_code == 200 and r.json() == {"status": "ready", "shutdown": "ok", "database": "ok",
                                                 "state": "memory"}
    main.SHUTTING_DOWN.set()
    try:
        r = client.get("/health/ready")
        assert r.status_code == 503 and r.json()["shutdown"] == "shutting_down"
    finally:
        main.SHUTTING_DOWN.clear()
    assert client.get("/health/ready", headers={"Authorization": ""}).status_code == 200   # ohne Anmeldung


def _set_version(version: str) -> None:
    from app.db import engine
    with engine.begin() as conn:
        conn.exec_driver_sql(f"UPDATE alembic_version SET version_num = '{version}'")   # nosec B608 – Testwert
    main._head = None


@pytest.fixture
def restore_head():
    yield
    _set_version(main.head_revision())
    if IS_PG:
        from app.db import engine
        with engine.begin() as conn:
            migrate.write_compat_comment(conn)


def test_ready_schema_newer_needs_compat_mark(client, monkeypatch, restore_head):
    """S1: unbekannter neuerer Stand (Rollback nach Migration) → nur 503, wenn nicht als kompatibel markiert."""
    monkeypatch.delenv("SCHEMA_COMPATIBLE_NEWER", raising=False)
    _set_version("0099")
    r = client.get("/health/ready")
    assert r.status_code == 503 and r.json()["database"] == "schema_newer"
    for value in ("0099", "0098, 0099", "*"):
        monkeypatch.setenv("SCHEMA_COMPATIBLE_NEWER", value)
        r = client.get("/health/ready")
        assert r.status_code == 200 and r.json()["database"] == "compatible_newer" and r.json()["degraded"], value
    monkeypatch.setattr(migrate, "COMPATIBLE_NEWER", frozenset({"0099"}))
    monkeypatch.delenv("SCHEMA_COMPATIBLE_NEWER")
    assert client.get("/health/ready").status_code == 200
    monkeypatch.setattr(migrate, "COMPATIBLE_NEWER", frozenset())
    # älterer Stand bleibt «migration_pending», auch mit "*"
    monkeypatch.setenv("SCHEMA_COMPATIBLE_NEWER", "*")
    _set_version("0001")
    assert client.get("/health/ready").json()["database"] == "migration_pending"


def test_migrate_never_touches_newer_schema(client, monkeypatch, restore_head):
    from app.db import engine
    monkeypatch.delenv("SCHEMA_COMPATIBLE_NEWER", raising=False)
    _set_version("0099")
    with pytest.raises(migrate.SchemaNewer):
        migrate.create_schema(engine)
    monkeypatch.setenv("SCHEMA_COMPATIBLE_NEWER", "0099")
    assert migrate.create_schema(engine) is False
    with engine.connect() as conn:
        assert migrate.current_revision(conn) == "0099"                 # unverändert
    assert migrate.main(["--check"]) == 0


@pytest.mark.requires_pg
def test_ready_compatible_via_marker_of_newer_image(client, monkeypatch, restore_head):
    """Neueres Image (Migration mit compatible_with_previous) vermerkt die kompatiblen älteren Stände an
    alembic_version → das ältere Image bleibt ohne Env bereit (Rolling Update, Rollback)."""
    from app.db import engine
    monkeypatch.delenv("SCHEMA_COMPATIBLE_NEWER", raising=False)
    head = main.head_revision()
    _set_version("0099")
    with engine.begin() as conn:
        migrate.write_compat_comment(conn, ["0042"])
    assert client.get("/health/ready").json()["database"] == "schema_newer"
    with engine.begin() as conn:
        migrate.write_compat_comment(conn, [head, "0001"])
    r = client.get("/health/ready")
    assert r.status_code == 200 and r.json()["database"] == "compatible_newer"


def test_compatible_previous_walks_marked_migrations():
    def rev(r, down, flag):
        return SimpleNamespace(revision=r, down_revision=down, module=SimpleNamespace(compatible_with_previous=flag))
    script = SimpleNamespace(walk_revisions=lambda: iter([rev("0007", "0006", True), rev("0006", "0005", True),
                                                          rev("0005", "0004", False), rev("0004", "0003", True)]))
    assert migrate.compatible_previous(script) == ["0006", "0005"]
    script = SimpleNamespace(walk_revisions=lambda: iter([rev("0007", "0006", False)]))
    assert migrate.compatible_previous(script) == []
    assert all(isinstance(x, str) for x in migrate.compatible_previous())   # echte Revisionen


def test_health_endpoints_async_and_off_threadpool(client, monkeypatch):
    """S2: Health hängt nie vom Threadpool der sync-Endpunkte ab; DB-Prüfung mit Zeitlimit."""
    for fn in (main.health, main.health_live, main.health_ready):
        assert inspect.iscoroutinefunction(fn), fn.__name__
    seen = []
    real = main._schema_state

    def spy():
        seen.append(threading.current_thread().name)
        return real()
    monkeypatch.setattr(main, "_schema_state", spy)
    assert client.get("/health/ready").status_code == 200 and seen[0].startswith("fzb-health")
    monkeypatch.setattr(main, "_schema_state", lambda: time.sleep(0.5) or "ok")
    monkeypatch.setenv("HEALTH_DB_TIMEOUT_S", "0.1")
    r = client.get("/health/ready")
    assert r.status_code == 503 and r.json()["database"] == "unavailable"


def test_ready_requires_migration_head(client):
    from app.db import engine
    with engine.begin() as conn:
        conn.exec_driver_sql("UPDATE alembic_version SET version_num = '0001'")
    main._head = None
    try:
        r = client.get("/health/ready")
        assert r.status_code == 503 and r.json()["database"] == "migration_pending"
    finally:
        with engine.begin() as conn:
            conn.exec_driver_sql(f"UPDATE alembic_version SET version_num = '{main.head_revision()}'")


# ---------- Metriken ----------
def test_metrics_access(client, monkeypatch):
    monkeypatch.delenv("METRICS_TOKEN", raising=False)
    monkeypatch.delenv("METRICS_ALLOW", raising=False)
    assert client.get("/metrics").status_code == 404                     # nicht konfiguriert → aus
    token = "m" * 40
    monkeypatch.setenv("METRICS_TOKEN", token)
    assert client.get("/metrics").status_code == 404
    assert client.get("/metrics", headers={"Authorization": "Bearer falsch"}).status_code == 404
    client.get(f"{T}/changes")
    r = client.get("/metrics", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 200 and r.headers["content-type"].startswith("text/plain; version=0.0.4")
    body = r.text
    assert '# TYPE fzb_http_requests_total counter' in body
    assert 'route="/api/t/{tenant}/changes"' in body and 'status="200"' in body
    assert "fzb_http_request_duration_seconds_bucket" in body and 'le="+Inf"' in body
    assert "fzb_db_pool_checked_out" in body and 'fzb_upstream_circuit_open{worker=' in body
    assert "fzb_http_requests_in_flight" in body and 'worker="' in body
    assert "/api/t/privat" not in body                                    # Template, nicht konkreter Pfad
    monkeypatch.delenv("METRICS_TOKEN")
    monkeypatch.setenv("METRICS_ALLOW", "10.0.0.0/8")
    assert client.get("/metrics").status_code == 404                      # Peer "testclient"
    monkeypatch.setenv("METRICS_ALLOW", "testclient")
    assert client.get("/metrics").status_code == 200


def test_metrics_count_security_events(client, monkeypatch):
    metrics.reset()
    monkeypatch.setenv("RATE_ACTIVITY", "1")
    client.get(f"{T}/activity")
    assert client.get(f"{T}/activity").status_code == 429
    text = metrics.render([metrics.snapshot()])
    assert 'fzb_security_events_total{worker="' in text and 'event="rate_limited",reason="activity"' in text


def test_metrics_render_escapes_labels():
    snap = {"worker": "1", "requests": [["GET", 'a"b\\c\n', "200", 1]], "durations": [], "events": [],
            "gauges": []}
    assert 'route="a\\"b\\\\c\\n"' in metrics.render([snap])


# ---------- GZip, CSV, PDF ----------
def test_gzip_api_json_only(client):
    vid = new_vehicle(client)
    for i in range(30):
        sync(client, op("odometer", uid(), {"vehicle_id": vid, "date": "2026-01-01", "km": 10000 + i,
                                            "note": "x" * 50}))
    r = client.get(f"{T}/changes", headers={"Accept-Encoding": "gzip"})
    assert r.headers.get("content-encoding") == "gzip" and "accept-encoding" in r.headers["vary"].lower()
    assert r.json()["odometer"]                                       # httpx2 dekomprimiert
    small = client.get("/api/me", headers={"Accept-Encoding": "gzip"})
    assert "content-encoding" not in small.headers                    # < 1 KiB
    pdf = client.get(f"{T}/vehicles/{vid}/report.pdf", headers={"Accept-Encoding": "gzip"})
    assert pdf.status_code == 200 and "content-encoding" not in pdf.headers
    plain = client.get(f"{T}/changes", headers={"Accept-Encoding": "identity"})
    assert "content-encoding" not in plain.headers


def test_csv_streamed(client):
    vid = new_vehicle(client)
    for d in range(1, 4):
        sync(client, op("trip", uid(), {"vehicle_id": vid, "start_at": f"2026-02-0{d}T08:00:00+01:00",
                                        "end_at": f"2026-02-0{d}T09:00:00+01:00", "km_start": 10000 + d * 10,
                                        "km_end": 10005 + d * 10, "category": "business", "purpose": "Kunde"}))
    with client.stream("GET", f"{T}/vehicles/{vid}/trips.csv?from=2026-02-01&to=2026-02-28") as r:
        assert r.status_code == 200 and "content-length" not in r.headers
        body = r.read()
    assert r.headers["content-type"].startswith("text/csv")
    assert body.startswith("﻿".encode()) and body.count(b"\r\n") == 4


def test_pdf_concurrency_limit(client, monkeypatch):
    monkeypatch.setattr(main, "_pdf_slots", threading.BoundedSemaphore(1))
    monkeypatch.setenv("PDF_WAIT_S", "0.2")
    vid = new_vehicle(client)
    with main.pdf_slot():                     # einziger Platz belegt
        r = client.get(f"{T}/vehicles/{vid}/report.pdf")
    assert r.status_code == 503 and r.headers["retry-after"] == "5"
    assert client.get(f"{T}/vehicles/{vid}/report.pdf").status_code == 200


def test_pdf_wait_short_and_queue_bounded(client, monkeypatch):
    """S2: Wartezeit höchstens 1 s (auch mit grösserem PDF_WAIT_S), volle Warteschlange → sofort 503."""
    monkeypatch.setattr(main, "_pdf_slots", threading.BoundedSemaphore(1))
    monkeypatch.setenv("PDF_WAIT_S", "20")
    vid = new_vehicle(client)
    with main.pdf_slot():
        t = time.monotonic()
        r = client.get(f"{T}/vehicles/{vid}/report.pdf")
        waited = time.monotonic() - t
        assert r.status_code == 503 and 0.9 <= waited < 3, waited
        monkeypatch.setenv("PDF_QUEUE", "0")
        t = time.monotonic()
        assert client.get(f"{T}/vehicles/{vid}/report.pdf").status_code == 503
        assert time.monotonic() - t < 0.5
    assert main._pdf_waiting == 0
    assert client.get(f"{T}/vehicles/{vid}/report.pdf").status_code == 200


def test_threadpool_size_from_env(client):
    import anyio.to_thread

    async def size():
        return anyio.to_thread.current_default_thread_limiter().total_tokens
    assert client.portal.call(size) == 40


def test_changes_page_size_limited(client):
    assert client.get(f"{T}/changes?limit=5001").status_code == 422
    vid = new_vehicle(client)
    for i in range(5):
        sync(client, op("odometer", uid(), {"vehicle_id": vid, "date": "2026-01-01", "km": 10000 + i}))
    seen, since = [], 0
    while True:
        page = client.get(f"{T}/changes?since={since}&limit=2").json()
        seen += [o["id"] for o in page["odometer"]] + [v["id"] for v in page["vehicles"]]
        since = page["cursor"]
        if not page["has_more"]:
            break
    assert len(seen) == len(set(seen)) == 6


# ---------- Advisory-Locks ----------
def test_lock_key_stable():
    assert jobs.lock_key("anchor", 1) == jobs.lock_key("anchor", 1) != jobs.lock_key("anchor", 2)
    assert -(2 ** 63) <= jobs.lock_key("x") < 2 ** 63


@pytest.mark.requires_pg
def test_parallel_anchor_only_once(client, monkeypatch):
    """Zwei Sitzungen (Threads) erzwingen gleichzeitig einen Anker OHNE Mandantensperre → genau einer."""
    import base64
    monkeypatch.setenv("ANCHOR_SIGNING_KEY", base64.b64encode(b"k" * 32).decode())
    monkeypatch.setenv("ANCHOR_INTERVAL_MIN", "100000")
    vid = new_vehicle(client)                 # erster Anker (noch keiner vorhanden)
    sync(client, op("odometer", uid(), {"vehicle_id": vid, "date": "2026-01-01", "km": 10001}))   # ohne Anker
    with SessionLocal() as db:
        tid = db.scalar(select(models.Tenant.id).where(models.Tenant.slug == "privat"))
        before = db.scalar(select(func.count()).select_from(models.Anchor).where(models.Anchor.tenant_id == tid))
    barrier, results = threading.Barrier(2), []

    def worker():
        with SessionLocal() as db:
            tenant = db.get(models.Tenant, tid)
            barrier.wait()
            a = integrity.maybe_anchor(db, tenant, force=True)
            time.sleep(0.3)                   # Fenster offen halten
            db.commit()
            results.append(a is not None)

    threads = [threading.Thread(target=worker) for _ in range(2)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    with SessionLocal() as db:
        seqs = list(db.scalars(select(models.Anchor.seq).where(models.Anchor.tenant_id == tid)))
    assert sorted(results) == [False, True]
    assert len(seqs) == before + 1 and len(seqs) == len(set(seqs))


@pytest.mark.requires_pg
def test_full_verify_busy_on_other_worker(client):
    """Läuft die Vollprüfung desselben Mandanten bereits (Advisory-Lock belegt) → 409 mit Retry-After."""
    from sqlalchemy import text

    from app.db import engine
    client.get(f"{T}/changes")
    with SessionLocal() as db:
        tid = db.scalar(select(models.Tenant.id).where(models.Tenant.slug == "privat"))
    with engine.connect() as other:
        other.execute(text("SELECT pg_advisory_lock(:k)"), {"k": jobs.lock_key("verify_full", tid)})
        r = client.get(f"{T}/audit/verify?full=1")
        assert r.status_code == 409 and r.headers["retry-after"] == "30"
        assert client.get(f"{T}/audit/verify").status_code == 200          # inkrementell nicht betroffen
        other.execute(text("SELECT pg_advisory_unlock_all()"))
    assert client.get(f"{T}/audit/verify?full=1").status_code == 200


@pytest.mark.requires_pg
def test_migration_lock_serializes(client):
    """Zwei gleichzeitige create_schema (2 Worker mit AUTO_MIGRATE=1) laufen ohne Fehler nacheinander."""
    from app.db import engine
    from app.migrate import create_schema
    errors = []

    def run():
        try:
            create_schema(engine)
        except Exception as e:  # noqa: BLE001
            errors.append(e)
    threads = [threading.Thread(target=run) for _ in range(2)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert errors == []


def test_sigterm_sets_readiness_flag():
    """uvicorn-Handler bleibt in Kraft; vorgeschaltet wird nur das Flag gesetzt (Hauptthread)."""
    import os
    import signal
    called = []
    prev = signal.signal(signal.SIGTERM, lambda s, f: called.append(s))
    try:
        main.SHUTTING_DOWN.clear()
        main._flag_on_sigterm()
        os.kill(os.getpid(), signal.SIGTERM)
        time.sleep(0.05)
        assert main.SHUTTING_DOWN.is_set() and called == [signal.SIGTERM]
    finally:
        signal.signal(signal.SIGTERM, prev)
        main.SHUTTING_DOWN.clear()
