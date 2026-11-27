"""Ende-zu-Ende mit echtem uvicorn (app.serve, 2 Worker) + PostgreSQL + Valkey: Rate-Limit und Brute-Force-Sperre
greifen worker-übergreifend, parallele Berichte erzeugen genau einen Anker, beide Worker migrieren gleichzeitig
ohne Fehler (Advisory-Lock), SIGTERM beendet sauber."""
import base64
import os
import signal
import socket
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

import httpx2
import pytest

from loadtest.issuer import Issuer

from .conftest import REDIS_URL, reset_db

pytestmark = [pytest.mark.requires_redis, pytest.mark.requires_pg]
SERVER_DIR = Path(__file__).resolve().parents[1]
METRICS_TOKEN = "e2e-" + "m" * 40


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _get(url: str, ip: str, **kw) -> httpx2.Response:
    """Neue Verbindung je Anfrage (verteilt sich auf die Worker); Client-IP über X-Forwarded-For."""
    headers = {"X-Forwarded-For": ip, **kw.pop("headers", {})}
    with httpx2.Client(timeout=30) as c:
        return c.request(kw.pop("method", "GET"), url, headers=headers, **kw)


@pytest.fixture(scope="module")
def server():
    reset_db()
    issuer = Issuer().start()
    port = _free_port()
    env = {k: v for k, v in os.environ.items() if not k.startswith(("RATE_", "BRUTE_", "FZB_"))}
    env.update({
        "WEB_CONCURRENCY": "2", "PORT": str(port), "HOST": "127.0.0.1",
        "STATE_BACKEND": "redis", "REDIS_URL": REDIS_URL, "STATE_PREFIX": f"fzbe2e:{uuid.uuid4().hex[:8]}:",
        "DATABASE_URL": os.environ["DATABASE_URL"], "AUTO_MIGRATE": "1",
        "OIDC_ISSUER": issuer.url, "OIDC_ALLOW_HTTP": "1", "OIDC_CLIENT_ID": "fahrzeugbuch-ios",
        "FORWARDED_ALLOW_IPS": "127.0.0.1", "ALLOWED_HOSTS": "127.0.0.1,localhost",
        "ANCHOR_SIGNING_KEY": base64.b64encode(b"e" * 32).decode(), "ANCHOR_INTERVAL_MIN": "100000",
        "RATE_PUBLIC_PER_MIN": "1", "RATE_PUBLIC_BURST": "10", "RATE_IP_PER_MIN": "100000",
        "RATE_IP_BURST": "100000", "RATE_USER_PER_MIN": "100000", "RATE_USER_BURST": "100000",
        "RATE_REPORTS": "100000", "BRUTE_401_THRESHOLD": "5", "METRICS_TOKEN": METRICS_TOKEN,
        "METRICS_ALLOW": "", "METRICS_PUSH_S": "0.3", "GRACEFUL_TIMEOUT_S": "5", "PDF_CONCURRENCY": "4",
        "ATTACHMENT_DIR": "/tmp/fzb-e2e-files", "LOG_LEVEL": "WARNING",
    })
    proc = subprocess.Popen([sys.executable, "-m", "app.serve"], cwd=SERVER_DIR, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    base = f"http://127.0.0.1:{port}"
    deadline = time.monotonic() + 60
    workers: set[str] = set()
    while time.monotonic() < deadline and len(workers) < 2:
        if proc.poll() is not None:
            pytest.fail("Server beendet:\n" + proc.stdout.read())
        try:
            r = _get(f"{base}/metrics", "198.18.0.1", headers={"Authorization": f"Bearer {METRICS_TOKEN}"})
            if r.status_code == 200:
                workers = {line.split('worker="')[1].split('"')[0] for line in r.text.splitlines()
                           if line.startswith("fzb_worker_start_time_seconds{")}
        except httpx2.TransportError:
            pass
        time.sleep(0.3)
    if len(workers) < 2:
        proc.terminate()
        pytest.fail("Nicht beide Worker bereit:\n" + (proc.stdout.read() if proc.stdout else ""))
    yield {"base": base, "issuer": issuer, "proc": proc}
    if proc.poll() is None:
        proc.terminate()
        proc.wait(timeout=30)
    issuer.stop()


def _route_counts(base: str, route: str) -> dict[str, int]:
    r = _get(f"{base}/metrics", "198.18.0.1", headers={"Authorization": f"Bearer {METRICS_TOKEN}"})
    out: dict[str, int] = {}
    for line in r.text.splitlines():
        if line.startswith("fzb_http_requests_total{") and f'route="{route}"' in line:
            w = line.split('worker="')[1].split('"')[0]
            out[w] = out.get(w, 0) + int(line.rsplit(" ", 1)[1])
    return out


def test_rate_limit_across_workers(server):
    base = server["base"]
    codes = [_get(f"{base}/auth/config", "198.18.1.1").status_code for _ in range(24)]
    assert codes.count(200) == 10 and codes.count(429) == 14       # Burst 10 gilt für alle Worker zusammen
    time.sleep(1.0)                                                # Schnappschüsse (METRICS_PUSH_S)
    counts = _route_counts(base, "/auth/config")
    assert len(counts) == 2 and all(n > 0 for n in counts.values()), counts   # beide Worker beteiligt


def test_brute_force_block_across_workers(server):
    base, issuer = server["base"], server["issuer"]
    for _ in range(5):
        forged = issuer.token().rsplit(".", 1)[0] + "." + "A" * 342   # falsche Signatur (zählt, anders als kaputt)
        r = _get(f"{base}/api/me", "198.18.2.2", headers={"Authorization": f"Bearer {forged}"})
        assert r.status_code == 401
    good = {"Authorization": f"Bearer {issuer.token()}"}
    codes = [_get(f"{base}/api/me", "198.18.2.2", headers=good).status_code for _ in range(8)]
    assert codes == [429] * 8                                      # jede Anfrage, egal welcher Worker
    assert _get(f"{base}/api/me", "198.18.2.3", headers=good).status_code == 200


def test_single_anchor_under_parallel_reports(server):
    base, issuer = server["base"], server["issuer"]
    h = {"Authorization": f"Bearer {issuer.token(groups=('/fahrzeugbuch/e2e',))}"}
    vid = str(uuid.uuid4())

    def sync(*ops):
        r = _get(f"{base}/api/t/e2e/sync", "198.18.3.1", method="POST", headers=h, json={"ops": list(ops)})
        assert r.status_code == 200, r.text
        assert all(x["status"] == "applied" for x in r.json()["results"])

    def op(entity, id_, data):
        return {"op_id": str(uuid.uuid4()), "entity": entity, "id": id_, "action": "upsert", "data": data}

    sync(op("vehicle", vid, {"name": "E2E", "initial_km": 1}))                       # Anker 1
    sync(op("odometer", str(uuid.uuid4()), {"vehicle_id": vid, "date": "2026-01-02", "km": 5}))   # kein Anker
    results: list[int] = []

    def report(i):
        r = _get(f"{base}/api/t/e2e/vehicles/{vid}/report.pdf", f"198.18.4.{i}", headers=h)
        results.append(r.status_code)

    threads = [threading.Thread(target=report, args=(i,)) for i in range(1, 9)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert results == [200] * 8
    anchors = _get(f"{base}/api/t/e2e/audit/anchors", "198.18.3.1", headers=h).json()["anchors"]
    seqs = [a["seq"] for a in anchors]
    assert seqs == [1, 2]                                          # genau ein neuer Anker trotz 8 Berichten
    v = _get(f"{base}/api/t/e2e/audit/verify?full=1", "198.18.3.1", headers=h).json()
    assert v["ok"] and v["anchors"] == 2


def test_graceful_sigterm(server):
    proc = server["proc"]
    proc.send_signal(signal.SIGTERM)
    assert proc.wait(timeout=30) == 0
