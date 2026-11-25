"""S5 konsistente Prüfung / Sperre vor dem Rendern freigeben, S6 Rate-Limits + Zeitraum + inkrementelle
Prüfung, S14 Webhook-Signatur, S16 alte Anker-Schlüssel."""
import base64
import hashlib
import hmac
import http.server
import json
import threading

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from sqlalchemy import select, text

from app import main, models, trips
from app.db import SessionLocal, engine, snapshot_session
from app.integrity import verify_all

from .conftest import T, new_vehicle, op, sync, uid
from .test_audit import _disable_triggers
from .test_periods import _Resp, close
from .test_trips import trip


def _seed(client, n=3):
    vid = new_vehicle(client)
    for i in range(n):
        sync(client, op("odometer", uid(), {"vehicle_id": vid, "date": f"2026-02-{i + 1:02d}", "km": 10000 + i}))
    return vid


# ---------- S5 ----------
def test_verify_reads_tenant_in_same_snapshot(client):
    """Früher: veralteter Mandantenstand + parallel committeter Sync → „Kettenende stimmt nicht“."""
    _seed(client)
    with SessionLocal() as db:
        stale = db.scalar(select(models.Tenant).where(models.Tenant.slug == "privat"))
        db.expunge(stale)
    sync(client, op("customer", uid(), {"name": "X"}))
    with snapshot_session() as s:
        res = verify_all(s, stale)
    assert res["ok"] and res["count"] == stale.seq + 1, res


def test_tenant_lock_released_before_rendering(client, monkeypatch):
    vid = _seed(client)
    real = main.build_logbook
    outcome = {}

    def slow_render(*args, **kwargs):
        # Während des Renderns muss ein Sync desselben Mandanten durchlaufen (keine Mandantensperre)
        def other():
            r = client.post(f"{T}/sync", json={"ops": [op("customer", uid(), {"name": "parallel"})]})
            outcome["status"] = r.status_code
        t = threading.Thread(target=other)
        t.start()
        t.join(timeout=15)
        outcome["finished"] = not t.is_alive()
        return real(*args, **kwargs)

    monkeypatch.setattr(main, "build_logbook", slow_render)
    r = client.get(f"{T}/vehicles/{vid}/logbook.pdf?month=2026-02")
    assert r.status_code == 200
    assert outcome == {"status": 200, "finished": True}
    assert client.get(f"{T}/audit/verify").json()["ok"]


# ---------- S6 ----------
def test_report_rate_limits_and_period(client, monkeypatch):
    vid = _seed(client)
    monkeypatch.setenv("RATE_REPORTS", "2")
    assert client.get(f"{T}/vehicles/{vid}/trips.csv?from=2026-01-01&to=2026-12-31").status_code == 200
    assert client.get(f"{T}/vehicles/{vid}/logbook.pdf?month=2026-02").status_code == 200
    r = client.get(f"{T}/vehicles/{vid}/year-report.pdf?year=2026")
    assert r.status_code == 429 and int(r.headers["Retry-After"]) >= 1
    monkeypatch.setenv("RATE_REPORTS", "100")
    # Fahrtenbuch/CSV: max. 366 Tage
    for url in ("logbook.pdf", "trips.csv"):
        assert client.get(f"{T}/vehicles/{vid}/{url}?from=2024-01-01&to=2024-12-31").status_code == 200
        r = client.get(f"{T}/vehicles/{vid}/{url}?from=2025-01-01&to=2026-01-02")
        assert r.status_code == 422 and "366" in r.json()["detail"], url
    monkeypatch.setenv("RATE_VERIFY", "1")
    assert client.get(f"{T}/audit/verify").status_code == 200
    assert client.get(f"{T}/audit/verify").status_code == 429


def test_incremental_verify_and_full(client):
    _seed(client, n=4)
    v = client.get(f"{T}/audit/verify").json()
    assert v["ok"] and v["incremental_from"] is None and v["count"] == 5
    sync(client, op("customer", uid(), {"name": "neu"}))
    v = client.get(f"{T}/audit/verify").json()
    assert v["ok"] and v["incremental_from"] == 5 and v["count"] == 6
    # Manipulation einer alten Revision: inkrementell (bewusst) nicht gesehen, Vollprüfung findet sie
    with engine.begin() as conn:
        _disable_triggers(conn)
        conn.execute(text("UPDATE revisions SET actor_name = 'mallory' WHERE seq = 2"))
    assert client.get(f"{T}/audit/verify").json()["chain_ok"] is True
    v = client.get(f"{T}/audit/verify?full=1").json()
    assert v["chain_ok"] is False and v["broken_at"] == 2 and v["incremental_from"] is None
    # nach einem Fehler gibt es keinen bestätigten Stand mehr → wieder voll
    assert client.get(f"{T}/audit/verify").json()["chain_ok"] is False


def test_incremental_verify_detects_change_at_cached_head(client):
    _seed(client)
    assert client.get(f"{T}/audit/verify").json()["ok"]
    with engine.begin() as conn:
        _disable_triggers(conn)
        conn.execute(text("UPDATE revisions SET hash = :h WHERE seq = 4"), {"h": "f" * 64})
    v = client.get(f"{T}/audit/verify").json()
    assert v["chain_ok"] is False and v["incremental_from"] is None


# ---------- S14 ----------
def test_webhook_signed(client, monkeypatch):
    calls = []

    def fake_open(req, timeout=None):
        calls.append((req.data, req.get_header("X-fahrzeugbuch-signature")))
        return _Resp(b"ok")

    monkeypatch.setattr(trips, "_open", fake_open)
    monkeypatch.setenv("N8N_WEBHOOK_URL", "https://n8n.example.test/webhook/x")
    monkeypatch.setenv("N8N_WEBHOOK_SECRET", "geheim-123")
    close(client, new_vehicle(client), month="2026-01")
    body, sig = calls[0]
    assert sig == "sha256=" + hmac.new(b"geheim-123", body, hashlib.sha256).hexdigest()
    assert json.loads(body)["month"] == "2026-01"
    monkeypatch.delenv("N8N_WEBHOOK_SECRET")
    calls.clear()
    trips.send_webhook("https://n8n.example.test/webhook/x", {"a": 1})
    assert calls[0][1] is None


def test_webhook_no_redirect_and_url_not_logged(monkeypatch, caplog):
    hits = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):  # noqa: N802
            hits.append(self.path)
            self.rfile.read(int(self.headers["Content-Length"]))
            self.send_response(307 if self.path.startswith("/start") else 200)
            self.send_header("Location", "/ziel")
            self.send_header("Content-Length", "0")
            self.end_headers()

        def log_message(self, *a):
            pass

    srv = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    for k in ("NO_PROXY", "no_proxy"):
        monkeypatch.setenv(k, "127.0.0.1,localhost")
    try:
        url = f"http://127.0.0.1:{srv.server_port}/start?token=GEHEIM"
        trips.send_webhook(url, {"a": 1})
    finally:
        srv.shutdown()
    assert hits == ["/start?token=GEHEIM"]                    # Weiterleitung nicht gefolgt
    assert "GEHEIM" not in caplog.text and "Webhook fehlgeschlagen" in caplog.text


# ---------- S16 ----------
def _b64key(k: Ed25519PrivateKey) -> tuple[str, str]:
    from cryptography.hazmat.primitives.serialization import NoEncryption, PrivateFormat
    seed = k.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())
    pub = k.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    return base64.b64encode(seed).decode(), base64.b64encode(pub).decode()


def test_old_anchor_keys_still_verify(client, monkeypatch):
    old_seed, old_pub = _b64key(Ed25519PrivateKey.generate())
    new_seed, _ = _b64key(Ed25519PrivateKey.generate())
    monkeypatch.setenv("ANCHOR_SIGNING_KEY", old_seed)
    vid = _seed(client)
    client.get(f"{T}/vehicles/{vid}/report.pdf")                 # erzwingt Anker mit altem Schlüssel
    assert client.get(f"{T}/audit/verify").json()["ok"]
    monkeypatch.setenv("ANCHOR_SIGNING_KEY", new_seed)           # Schlüsselwechsel
    v = client.get(f"{T}/audit/verify").json()
    assert not v["ok"] and any("unbekannter Schlüssel" in p for p in v["problems"])
    monkeypatch.setenv("ANCHOR_PUBLIC_KEYS", f"kaputt, {old_pub}")
    sync(client, op("trip", uid(), trip(vid)))
    client.get(f"{T}/vehicles/{vid}/report.pdf")                 # neuer Anker mit neuem Schlüssel
    v = client.get(f"{T}/audit/verify").json()
    assert v["ok"] and v["anchors"] == 3, v
    monkeypatch.delenv("ANCHOR_SIGNING_KEY")                     # nur Public Keys: alte Anker prüfbar
    assert any("unbekannter Schlüssel" in p for p in client.get(f"{T}/audit/verify").json()["problems"])
