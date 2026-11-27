"""Metriken im Prometheus-Textformat (eigene kleine Implementierung, kein zusätzliches Paket).

Entscheidung gegen prometheus-client: dessen Multiprozess-Modus braucht ein gemeinsames beschreibbares
Verzeichnis (PROMETHEUS_MULTIPROC_DIR) und Aufräumen toter Worker (mark_process_dead) – mit read-only-Root und
Worker-Neustarts (--limit-max-requests) fehleranfällig; ausserdem eine weitere Abhängigkeit in der Lock-Datei.
Hier: jeder Worker zählt im Prozess und legt alle METRICS_PUSH_S Sekunden einen Schnappschuss im gemeinsamen
Zustand ab (STATE_BACKEND=redis, Schlüssel fzb:m:<Instanz>:<Worker>, TTL). GET /metrics liefert die Schnappschüsse
aller Worker DIESER Instanz (Container/Pod; FZB_INSTANCE_ID von app.serve) mit Label `worker` (PID) und – falls
gesetzt – `pod` (POD_NAME) und `namespace` (POD_NAMESPACE). Ohne gemeinsamen Zustand (1 Worker) nur der eigene Prozess.

Zugriff (app.main): nur mit `Authorization: Bearer <METRICS_TOKEN>` oder von Adressen aus METRICS_ALLOW (CIDRs),
sonst 404.
"""
import json
import os
import threading
import time
import uuid
from collections.abc import Callable

BUCKETS = (0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0)
COUNTED_EVENTS = {"rate_limited", "brute_force_block", "auth_failed", "auth_missing", "state_backend_error",
                  "integrity_failed", "integrity_full_overdue", "verify_full_busy",
                  "upload_rejected", "forbidden_tenant", "cors_rejected", "host_rejected"}
WORKER_ID = uuid.uuid4().hex[:12]          # Identität des Prozesses im gemeinsamen Zustand (nicht die PID)

_lock = threading.Lock()
_requests: dict[tuple[str, str, str], int] = {}
_durations: dict[tuple[str, str], list[float]] = {}     # [Bucket-Zähler…, Summe, Anzahl]
_events: dict[tuple[str, str], int] = {}
_in_flight = 0
_started = time.time()
_gauges: list[Callable[[], list[tuple[str, str, dict, float]]]] = []


def instance_group() -> str:
    return os.environ.get("FZB_INSTANCE_ID") or os.environ.get("POD_NAME") or "local"


def register_gauge(fn: Callable[[], list[tuple[str, str, dict, float]]]) -> None:
    """fn() → [(Name, Hilfe, Labels, Wert)], beim Schnappschuss ausgewertet."""
    _gauges.append(fn)


def _reason_label(reason: str | None) -> str:
    r = (reason or "").strip()
    if not r or len(r) > 32 or not r.replace("_", "").replace("-", "").isalnum():
        return "other"
    return r


def security_event(name: str, reason: str | None) -> None:
    if name not in COUNTED_EVENTS:
        return
    key = (name, _reason_label(reason) if name != "integrity_failed" else "-")
    with _lock:
        _events[key] = _events.get(key, 0) + 1


def observe(method: str, route: str, status: int, seconds: float) -> None:
    with _lock:
        k = (method, route, str(status))
        _requests[k] = _requests.get(k, 0) + 1
        h = _durations.get((method, route))
        if h is None:
            h = _durations[(method, route)] = [0.0] * (len(BUCKETS) + 2)
        for i, b in enumerate(BUCKETS):
            if seconds <= b:
                h[i] += 1
        h[-2] += seconds
        h[-1] += 1


def route_label(scope) -> str:
    route = scope.get("route")
    path = getattr(route, "path", None)
    if not path:
        return "unmatched"
    return "web" if path == "/{path:path}" else path


class MetricsMiddleware:
    """ASGI, äusserste Schicht: Dauer/Status je Route-Template (nicht je konkretem Pfad), In-Flight."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        global _in_flight
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        start = time.perf_counter()
        status = {"code": 500}

        async def wrapped(msg):
            if msg["type"] == "http.response.start":
                status["code"] = msg["status"]
            await send(msg)

        with _lock:
            _in_flight += 1
        try:
            await self.app(scope, receive, wrapped)
        finally:
            with _lock:
                _in_flight -= 1
            method = scope.get("method", "")
            method = method if method in ("GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS") else "OTHER"
            observe(method, route_label(scope), status["code"], time.perf_counter() - start)


def snapshot() -> dict:
    gauges = []
    for fn in _gauges:
        try:
            gauges += [list(g) for g in fn()]
        except Exception:  # noqa: BLE001 – eine defekte Quelle darf /metrics nicht verhindern
            continue
    with _lock:
        return {
            "worker": str(os.getpid()), "id": WORKER_ID, "pod": os.environ.get("POD_NAME") or "",
            "namespace": os.environ.get("POD_NAMESPACE") or "",
            "ts": time.time(), "started": _started, "in_flight": _in_flight,
            "requests": [[*k, v] for k, v in _requests.items()],
            "durations": [[*k, h] for k, h in _durations.items()],
            "events": [[*k, v] for k, v in _events.items()],
            "gauges": gauges,
        }


def reset() -> None:
    global _in_flight
    with _lock:
        _requests.clear()
        _durations.clear()
        _events.clear()


# ---------- Textformat ----------
def _esc(v) -> str:
    return str(v).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def _labels(base: dict, extra: dict | None = None) -> str:
    items = {**base, **(extra or {})}
    return "{" + ",".join(f'{k}="{_esc(v)}"' for k, v in items.items()) + "}"


def _num(v: float) -> str:
    return str(int(v)) if float(v).is_integer() else repr(float(v))


def render(snapshots: list[dict]) -> str:
    out: dict[str, tuple[str, str, list[str]]] = {}

    def add(name: str, kind: str, help_: str, line: str) -> None:
        out.setdefault(name, (kind, help_, []))[2].append(line)

    for s in snapshots:
        base = {"worker": s.get("worker", "")}
        if s.get("pod"):
            base["pod"] = s["pod"]
        if s.get("namespace"):
            base["namespace"] = s["namespace"]
        add("fzb_worker_start_time_seconds", "gauge", "Startzeit des Workers (Unix)",
            f"fzb_worker_start_time_seconds{_labels(base)} {_num(s.get('started', 0))}")
        add("fzb_http_requests_in_flight", "gauge", "Laufende HTTP-Anfragen",
            f"fzb_http_requests_in_flight{_labels(base)} {_num(s.get('in_flight', 0))}")
        for method, route, status, n in s.get("requests", []):
            add("fzb_http_requests_total", "counter", "HTTP-Anfragen je Route-Template und Status",
                f"fzb_http_requests_total{_labels(base, {'method': method, 'route': route, 'status': status})} "
                f"{_num(n)}")
        for method, route, h in s.get("durations", []):
            lbl = {"method": method, "route": route}
            name = "fzb_http_request_duration_seconds"
            for b, cnt in zip(BUCKETS, h[:len(BUCKETS)], strict=True):
                add(name, "histogram", "Antwortzeit je Route-Template",
                    f"{name}_bucket{_labels(base, {**lbl, 'le': repr(b)})} {_num(cnt)}")
            add(name, "histogram", "", f"{name}_bucket{_labels(base, {**lbl, 'le': '+Inf'})} {_num(h[-1])}")
            add(name, "histogram", "", f"{name}_sum{_labels(base, lbl)} {_num(h[-2])}")
            add(name, "histogram", "", f"{name}_count{_labels(base, lbl)} {_num(h[-1])}")
        for event, reason, n in s.get("events", []):
            add("fzb_security_events_total", "counter",
                "Sicherheitsereignisse (rate_limited, brute_force_block, auth_failed, state_backend_error …)",
                f"fzb_security_events_total{_labels(base, {'event': event, 'reason': reason})} {_num(n)}")
        for name, help_, lbl, value in s.get("gauges", []):
            add(name, "gauge", help_, f"{name}{_labels(base, lbl)} {_num(value)}")
    lines = []
    for name, (kind, help_, rows) in out.items():
        lines.append(f"# HELP {name} {help_}")
        lines.append(f"# TYPE {name} {kind}")
        lines += rows
    return "\n".join(lines) + "\n"


def snapshots_json(raw: list[str]) -> list[dict]:
    out = []
    for r in raw:
        try:
            d = json.loads(r)
        except ValueError:
            continue
        if isinstance(d, dict):
            out.append(d)
    return out
