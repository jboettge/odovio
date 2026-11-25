"""Sicherheits-Querschnitt (ASGI + Hilfen), unabhängig vom Rest der App (keine Zirkelimporte).

Client-IP: Peer-Adresse; `X-Forwarded-For` nur, wenn der Peer in FORWARDED_ALLOW_IPS steht (IP/CIDR/Literal,
kommagetrennt, "*" = alle) – dann der rechteste nicht vertrauenswürdige Eintrag. uvicorn (--proxy-headers)
setzt den Client bereits gleich; die Prüfung hier gilt auch ohne uvicorn (Tests, andere Server).

Gemeinsamer Zustand (app/state.py): STATE_BACKEND=memory → je Prozess (nur 1 Worker/1 Replika);
STATE_BACKEND=redis → Valkey/Redis für alle Worker und Replikas (Token-Bucket/Sperren atomar per Lua). Ausfall:
Rate-Limits fail-open (Sicherheits-Log state_backend_error), Brute-Force-Sperren lokal je Prozess weiter.

Rate-Limits (Token-Bucket je Client-IP und Kategorie):
  RATE_IP_PER_MIN      /api/* und alles Übrige, Default 600 (Burst RATE_IP_BURST, Default ¼)
  RATE_PUBLIC_PER_MIN  unauthentifiziert: /auth/config, /health, /docs, /openapi.json, Default 120
  RATE_WEB_PER_MIN     Web-Frontend (SPA, Assets), Default 3000
  RATE_USER_PER_MIN    je authentifiziertem Benutzer (sub), zusätzlich, Default 1200
  (Burst je Kategorie: RATE_<KAT>_BURST, Default ¼ des Minutenwerts, mind. 10)
Brute-Force/Missbrauch (Sperre der IP, Antwort 429 „Zu viele fehlgeschlagene Anfragen“):
  BRUTE_401_THRESHOLD  401 je IP im Fenster, Default 20; erfolgreiche Anmeldung desselben sub entfernt dessen
                       (signaturgeprüfte) Fehlversuche, nicht aber anonyme (fehlendes/gefälschtes Token)
  BRUTE_403_THRESHOLD  403 (fremder Mandant) und 404 (fremde/ungültige IDs) je IP+sub, Default 30
  BRUTE_WINDOW_S       Fenster, Default 300
  BRUTE_BACKOFF_S      Sperrdauern bei wiederholter Sperre, Default "300,900,3600"
  BRUTE_LEVEL_RESET_S  ohne neue Sperre in dieser Zeit beginnt der Backoff von vorn, Default 86400
  SECURITY_ALLOWLIST   CIDRs, die nie gesperrt/IP-limitiert werden (z. B. LAN-Monitoring)
Header/Transport: ALLOWED_HOSTS (kommagetrennt, "*.domain" erlaubt; Default "*"), FORCE_HSTS=1,
  CORS_ORIGINS (exakte Origins; leer = keine Cross-Origin-Freigabe), X-Request-ID.
JSON-Bodies: JSON_MAX_DEPTH (32), JSON_MAX_ITEMS (100000) – geprüft vor dem Parsen.
Sicherheits-Log: Logger `fahrzeugbuch.security`, eine JSON-Zeile je Ereignis (stderr).
"""
import contextvars
import ipaddress
import json
import logging
import os
import re
import sys
import threading
import time
import unicodedata
import uuid
from collections import OrderedDict, deque
from dataclasses import dataclass
from functools import lru_cache
from urllib.parse import urlsplit

from fastapi import HTTPException, status

from . import metrics, runtime, state

log = logging.getLogger("fahrzeugbuch.security")


# ---------- Env ----------
def env_int(name: str, default: int, minimum: int = 1) -> int:
    try:
        v = int(os.environ.get(name) or default)
    except ValueError:
        return default
    return v if v >= minimum else default


def env_list(name: str, default: str = "") -> list[str]:
    return [x.strip() for x in (os.environ.get(name, default) or "").split(",") if x.strip()]


# ---------- Säubern (Log-Injection) ----------
_CTRL = re.compile("[\x00-\x1f\x7f-\x9f\u2028\u2029\u202a-\u202e\u2066-\u2069]")


def clean(value, limit: int = 200) -> str:
    """Für Logs: Steuer-/Zeilenumbruch-/Bidi-Zeichen als \\uXXXX, Länge begrenzt."""
    s = value if isinstance(value, str) else str(value)
    if len(s) > limit * 2:
        s = s[:limit * 2]
    s = _CTRL.sub(lambda m: f"\\u{ord(m.group()):04x}", s)
    return s if len(s) <= limit else s[:limit] + "…"


# ---------- Anfragekontext ----------
@dataclass
class RequestContext:
    request_id: str
    ip: str
    method: str = ""
    path: str = ""
    sub: str | None = None
    tenant: str | None = None
    auth_reason: str | None = None   # Grund eines 401 (auth.py)
    auth_sub: str | None = None      # sub aus signaturgeprüftem, aber abgelehntem Token
    probe: str | None = None         # 403/404 zählt als Mandanten-/ID-Probing


_ctx: contextvars.ContextVar[RequestContext | None] = contextvars.ContextVar("fzb_request", default=None)


def current() -> RequestContext | None:
    return _ctx.get()


def mark_probe(reason: str) -> None:
    if (c := current()) is not None:
        c.probe = reason


def set_tenant(slug: str) -> None:
    if (c := current()) is not None:
        c.tenant = slug


def auth_failure(reason: str, sub: str | None = None) -> None:
    if (c := current()) is not None:
        c.auth_reason, c.auth_sub = reason, sub


REQUEST_ID = re.compile(r"^[A-Za-z0-9-]{8,64}$")


def request_id_from(headers: dict) -> str:
    rid = headers.get(b"x-request-id", b"").decode("latin-1")
    return rid if REQUEST_ID.match(rid) else uuid.uuid4().hex


# ---------- Logging ----------
class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        fields = getattr(record, "security", None)
        if not isinstance(fields, dict):
            fields = {"ts": _ts(record.created), "logger": record.name, "event": "message",
                      "reason": clean(record.getMessage(), 500)}
        return json.dumps(fields, ensure_ascii=True, separators=(",", ":"))


def _ts(created: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(created)) + f".{int(created * 1000) % 1000:03d}Z"


_last: OrderedDict = OrderedDict()
_last_lock = threading.Lock()


def _throttled(key: tuple, every: float) -> bool:
    """True → Ereignis in den letzten `every` Sekunden schon protokolliert (Log-Flut begrenzen)."""
    now = time.monotonic()
    with _last_lock:
        prev = _last.get(key)
        if prev is not None and now - prev < every:
            return True
        _last[key] = now
        _last.move_to_end(key)
        while len(_last) > 10_000:
            _last.popitem(last=False)
    return False


def event(name: str, *, status: int | None = None, reason: str | None = None, throttle: float = 0,
          **extra) -> None:
    """Sicherheits-Ereignis als JSON-Zeile: ts, event, ip, sub?, tenant?, path (ohne Query), status, reason,
    request_id (+ weitere Felder). Alle Werte gesäubert."""
    c = current()
    ip = extra.pop("ip", None) or (c.ip if c else None)
    metrics.security_event(name, reason)
    if throttle and _throttled((name, ip, reason), throttle):
        return
    fields: dict = {"ts": _ts(time.time()), "logger": log.name, "event": name, "ip": clean(ip or "-", 64)}
    sub = extra.pop("sub", None) or (c.sub if c else None)
    tenant = extra.pop("tenant", None) or (c.tenant if c else None)
    if sub:
        fields["sub"] = clean(sub, 64)
    if tenant:
        fields["tenant"] = clean(tenant, 64)
    path = extra.pop("path", None) or (c.path if c else None)
    if path:
        fields["path"] = clean(path.split("?", 1)[0], 256)
    if c and c.method:
        fields["method"] = clean(c.method, 10)
    if status is not None:
        fields["status"] = int(status)
    if reason:
        fields["reason"] = clean(reason, 200)
    for k, v in extra.items():
        if v is not None:
            fields[clean(k, 32)] = v if isinstance(v, bool | int | float) else clean(v, 200)
    if c:
        fields["request_id"] = c.request_id
    level = logging.WARNING if name in ("brute_force_block", "integrity_failed", "config_warning",
                                        "state_backend_error") else logging.INFO
    log.log(level, "%s", name, extra={"security": fields})


_installed = False


def install_logging() -> None:
    """Allgemeine Logs säubern (Record-Factory: Nachricht ohne CR/LF/Steuerzeichen, + request_id), Handler für
    `fahrzeugbuch` (Text) und `fahrzeugbuch.security` (JSON-Zeilen). Idempotent."""
    global _installed
    if _installed:
        return
    _installed = True
    previous = logging.getLogRecordFactory()

    def factory(*args, **kwargs):
        record = previous(*args, **kwargs)
        c = current()
        record.request_id = c.request_id if c else "-"
        # uvicorn.access formatiert args selbst (Pfad ist dort bereits URL-kodiert, logfilter kürzt Query)
        if record.name != "uvicorn.access" and (record.args or _CTRL.search(str(record.msg))):
            try:
                record.msg, record.args = clean(record.getMessage(), 8000), ()
            except (TypeError, ValueError):
                pass
        return record

    logging.setLogRecordFactory(factory)
    level = os.environ.get("LOG_LEVEL", "INFO").upper()
    app_log = logging.getLogger("fahrzeugbuch")
    if not app_log.handlers:
        h = logging.StreamHandler(sys.stderr)
        h.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s [%(request_id)s] %(message)s"))
        app_log.addHandler(h)
        app_log.setLevel(level if level in logging.getLevelNamesMapping() else "INFO")
    if not log.handlers:
        h = logging.StreamHandler(sys.stderr)
        h.setFormatter(JsonFormatter())
        log.addHandler(h)
        log.setLevel(logging.INFO)
    log.propagate = False      # nicht zusätzlich als Textzeile über `fahrzeugbuch`


# ---------- IP / Netze ----------
@lru_cache(maxsize=32)
def _nets(spec: str) -> tuple[bool, tuple, frozenset]:
    """(alle, Netze, Literale) aus "1.2.3.4, 10.0.0.0/8, *, unix-literal"."""
    nets, literals, wildcard = [], set(), False
    for item in (x.strip() for x in spec.split(",")):
        if not item:
            continue
        if item == "*":
            wildcard = True
            continue
        try:
            nets.append(ipaddress.ip_network(item, strict=False))
        except ValueError:
            literals.add(item)
    return wildcard, tuple(nets), frozenset(literals)


def _ip(value: str):
    try:
        return ipaddress.ip_address(value)
    except ValueError:
        return None


def in_list(host: str | None, spec: str) -> bool:
    if not host:
        return False
    wildcard, nets, literals = _nets(spec)
    if wildcard or host in literals:
        return True
    addr = _ip(host)
    return addr is not None and any(addr.version == n.version and addr in n for n in nets)


def trusted_proxy(host: str | None) -> bool:
    return in_list(host, os.environ.get("FORWARDED_ALLOW_IPS", "127.0.0.1"))


def allowlisted(ip: str | None) -> bool:
    return in_list(ip, os.environ.get("SECURITY_ALLOWLIST", ""))


def _strip_port(value: str) -> str:
    value = value.strip()
    if value.startswith("["):
        return value[1:value.find("]")] if "]" in value else value
    if value.count(":") == 1:         # IPv4:Port
        return value.split(":", 1)[0]
    return value


def _header_values(scope, name: bytes) -> list[str]:
    return [v.decode("latin-1") for k, v in scope.get("headers") or [] if k == name]


def client_ip(scope) -> str:
    peer = (scope.get("client") or ("",))[0] or "unknown"
    if not trusted_proxy(peer):
        return peer
    hops = [_strip_port(h) for h in ",".join(_header_values(scope, b"x-forwarded-for")).split(",") if h.strip()]
    for hop in reversed(hops):
        if not trusted_proxy(hop):
            return hop if _ip(hop) is not None else peer
    return hops[0] if hops and _ip(hops[0]) is not None else peer


def is_https(scope) -> bool:
    if scope.get("scheme") == "https":
        return True
    peer = (scope.get("client") or ("",))[0]
    proto = (_header_values(scope, b"x-forwarded-proto") or [""])[-1].split(",")[-1].strip().lower()
    return proto == "https" and trusted_proxy(peer)


# ---------- Token-Bucket ----------
class Buckets:
    """Token-Bucket je Schlüssel; LRU-begrenzt, threadsafe."""

    def __init__(self, max_keys: int = 50_000):
        self.max_keys = max_keys
        self.data: OrderedDict[str, list[float]] = OrderedDict()
        self.lock = threading.Lock()

    def take(self, key: str, per_min: int, burst: int) -> int:
        """0 → erlaubt, sonst Sekunden bis zum nächsten Token (Retry-After)."""
        now = time.monotonic()
        rate = per_min / 60.0
        with self.lock:
            b = self.data.get(key)
            if b is None:
                b = self.data[key] = [float(burst), now]
                while len(self.data) > self.max_keys:
                    self.data.popitem(last=False)
            else:
                self.data.move_to_end(key)
                b[0] = min(float(burst), b[0] + (now - b[1]) * rate)
                b[1] = now
            if b[0] >= 1:
                b[0] -= 1
                return 0
            return max(1, int((1 - b[0]) / rate + 0.999))

    def reset(self) -> None:
        with self.lock:
            self.data.clear()


buckets = Buckets()


def state_error(where: str) -> None:
    """Gemeinsamer Zustand nicht erreichbar → Sicherheits-Log (gedrosselt), Ausweichverhalten beim Aufrufer."""
    event("state_backend_error", reason=where, throttle=30)


def take(key: str, per_min: int, burst: int) -> int:
    """Token-Bucket (gemeinsam oder je Prozess); 0 → erlaubt, sonst Retry-After. Ausfall → fail-open."""
    shared = state.shared()
    if shared is None:
        return buckets.take(key, per_min, burst)
    try:
        return shared.take(key, per_min, burst)
    except state.StateUnavailable:
        state_error("rate_limit")
        return 0

PUBLIC_PATHS = ("/auth/config", "/health", "/health/live", "/health/ready", "/metrics", "/docs", "/openapi.json")


def category(path: str) -> str:
    if path.startswith("/api/"):
        return "ip"
    if path in PUBLIC_PATHS or path.startswith("/docs/"):
        return "public"
    return "web"


LIMITS = {"ip": ("RATE_IP", 600), "public": ("RATE_PUBLIC", 120), "web": ("RATE_WEB", 3000),
          "user": ("RATE_USER", 1200)}


def limit_for(kind: str) -> tuple[int, int]:
    env, default = LIMITS[kind]
    per_min = env_int(f"{env}_PER_MIN", default)
    return per_min, env_int(f"{env}_BURST", max(10, per_min // 4))


def check_user_rate(sub: str) -> None:
    """Zusätzliches Limit je Benutzer (nach erfolgreicher Anmeldung) → 429."""
    per_min, burst = limit_for("user")
    retry = take(f"user:{sub}", per_min, burst)
    if retry:
        event("rate_limited", status=429, reason="user", sub=sub, throttle=10)
        raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, "Zu viele Anfragen",
                            headers={"Retry-After": str(retry)})


# ---------- Brute-Force-/Missbrauchserkennung ----------
class Guard:
    def __init__(self, max_keys: int = 20_000):
        self.max_keys = max_keys
        self.fails: OrderedDict[str, deque] = OrderedDict()           # ip → (ts, sub|None)
        self.probes: OrderedDict[tuple, deque] = OrderedDict()        # (ip, sub) → ts
        self.blocks: OrderedDict[str, tuple[float, int, float]] = OrderedDict()   # ip → (bis, Stufe, seit)
        self.lock = threading.Lock()

    @staticmethod
    def _window() -> float:
        return float(env_int("BRUTE_WINDOW_S", 300))

    def _touch(self, store: OrderedDict, key):
        q = store.get(key)
        if q is None:
            q = store[key] = deque()
            while len(store) > self.max_keys:
                store.popitem(last=False)
        else:
            store.move_to_end(key)
        return q

    def blocked(self, ip: str) -> int:
        """Restdauer der Sperre in Sekunden (0 = nicht gesperrt)."""
        with self.lock:
            b = self.blocks.get(ip)
            if b is None:
                return 0
            remaining = b[0] - time.monotonic()
            return int(remaining) + 1 if remaining > 0 else 0

    def _block(self, ip: str, reason: str) -> None:
        now = time.monotonic()
        steps, reset_s = backoff_steps(), float(env_int("BRUTE_LEVEL_RESET_S", 86400))
        prev = self.blocks.get(ip)
        level = prev[1] + 1 if prev and now - prev[2] < reset_s else 0
        duration = steps[min(level, len(steps) - 1)]
        self._set_block(ip, now, duration, level)
        event("brute_force_block", status=429, reason=reason, ip=ip, retry_after=duration, level=level + 1)

    def _set_block(self, ip: str, now: float, duration: int, level: int) -> None:
        self.blocks[ip] = (now + duration, level, now)
        self.blocks.move_to_end(ip)
        while len(self.blocks) > self.max_keys:
            self.blocks.popitem(last=False)
        self.fails.pop(ip, None)
        for key in [k for k in self.probes if k[0] == ip]:
            del self.probes[key]

    def mirror(self, ip: str, duration: int, level: int) -> None:
        """Sperre aus dem gemeinsamen Zustand lokal übernehmen (gilt bei dessen Ausfall weiter)."""
        with self.lock:
            self._set_block(ip, time.monotonic(), duration, level - 1)

    def auth_failed(self, ip: str, sub: str | None) -> None:
        if allowlisted(ip):
            return
        now, window = time.monotonic(), self._window()
        with self.lock:
            q = self._touch(self.fails, ip)
            q.append((now, sub))
            while q and now - q[0][0] > window:
                q.popleft()
            if len(q) >= env_int("BRUTE_401_THRESHOLD", 20):
                self._block(ip, "auth_failed")

    def auth_ok(self, ip: str, sub: str) -> None:
        """Erfolgreiche Anmeldung: Fehlversuche DIESES sub (z. B. abgelaufenes Token vor dem Refresh) vergessen;
        anonyme Fehlversuche und eine laufende Sperre bleiben."""
        with self.lock:
            q = self.fails.get(ip)
            if q and any(s == sub for _, s in q):
                self.fails[ip] = deque(x for x in q if x[1] != sub)

    def probe(self, ip: str, sub: str | None, reason: str) -> None:
        if allowlisted(ip):
            return
        now, window = time.monotonic(), self._window()
        with self.lock:
            q = self._touch(self.probes, (ip, sub or ""))
            q.append(now)
            while q and now - q[0] > window:
                q.popleft()
            if len(q) >= env_int("BRUTE_403_THRESHOLD", 30):
                self._block(ip, reason)

    def reset(self) -> None:
        with self.lock:
            self.fails.clear()
            self.probes.clear()
            self.blocks.clear()


guard = Guard()


def backoff_steps() -> list[int]:
    return [int(x) for x in env_list("BRUTE_BACKOFF_S", "300,900,3600") if x.isdigit() and int(x) > 0] or [300]


def _bf_args(threshold_env: str, default: int) -> tuple:
    return (env_int(threshold_env, default), float(env_int("BRUTE_WINDOW_S", 300)), backoff_steps(),
            float(env_int("BRUTE_LEVEL_RESET_S", 86400)))


def _shared_block(ip: str, reason: str, res: tuple[int, int] | None) -> None:
    if res is not None:
        duration, level = res
        guard.mirror(ip, duration, level)
        event("brute_force_block", status=429, reason=reason, ip=ip, retry_after=duration, level=level)


async def gate(ip: str, kind: str, per_min: int, burst: int) -> tuple[int, int]:
    """(Sperre in s, Rate-Limit-Wartezeit in s) für die Middleware – gemeinsam in einem Roundtrip.
    Lokale Sperren (Spiegel bzw. während eines Ausfalls entstanden) gelten immer zusätzlich."""
    local_block = guard.blocked(ip)
    shared = state.shared()
    if shared is None:
        if local_block:
            return local_block, 0
        return 0, buckets.take(f"{kind}:{ip}", per_min, burst)
    try:
        blocked, retry = await shared.agate(ip, kind, per_min, burst, True, not local_block)
    except state.StateUnavailable:
        state_error("gate")
        return local_block, 0                     # Rate-Limit fail-open, Sperren lokal
    return max(blocked, local_block), (0 if local_block else retry)


async def record_auth_failed(ip: str, sub: str | None) -> None:
    shared = state.shared()
    if shared is None or allowlisted(ip):
        return guard.auth_failed(ip, sub)
    try:
        _shared_block(ip, "auth_failed", await shared.aauth_failed(ip, sub, *_bf_args("BRUTE_401_THRESHOLD", 20)))
    except state.StateUnavailable:
        state_error("brute_force")
        guard.auth_failed(ip, sub)


async def record_probe(ip: str, sub: str | None, reason: str) -> None:
    shared = state.shared()
    if shared is None or allowlisted(ip):
        return guard.probe(ip, sub, reason)
    try:
        _shared_block(ip, reason, await shared.aprobe(ip, sub, *_bf_args("BRUTE_403_THRESHOLD", 30)))
    except state.StateUnavailable:
        state_error("brute_force")
        guard.probe(ip, sub, reason)


def after_auth(sub: str) -> None:
    """Von auth.require_user nach erfolgreicher Prüfung: Kontext, 401-Serie dieses sub, Benutzer-Limit."""
    c = current()
    if c is not None:
        c.sub = sub
        guard.auth_ok(c.ip, sub)
        if (shared := state.shared()) is not None:
            try:
                shared.auth_ok(c.ip, sub)
            except state.StateUnavailable:
                state_error("brute_force")
    check_user_rate(sub)


def reset() -> None:
    buckets.reset()
    guard.reset()
    if (shared := state.shared()) is not None:
        shared.reset()
    with _last_lock:
        _last.clear()


# ---------- Host / Origin ----------
LOOPBACK_HOSTS = ("localhost", "127.0.0.1", "::1")   # Healthcheck im Container
HOST_CHECK_EXEMPT = ("/health", "/metrics")


def _split_host(value: str) -> tuple[str, str]:
    value = value.strip().lower()
    if value.startswith("["):
        end = value.find("]")
        return (value[1:end], value[end + 2:]) if end != -1 else (value, "")
    host, _, port = value.partition(":")
    return host, port


def allowed_hosts() -> list[str]:
    return [h.lower() for h in env_list("ALLOWED_HOSTS", "*")] or ["*"]


def host_allowed(host_header: str | None) -> bool:
    hosts = allowed_hosts()
    if "*" in hosts:
        return True
    if not host_header:
        return False
    host, _ = _split_host(host_header)
    if host in LOOPBACK_HOSTS:
        return True
    return any(host == h or (h.startswith("*.") and host.endswith(h[1:])) for h in hosts)


def _normalize_origin(origin: str) -> str | None:
    parts = urlsplit(origin.strip().lower())
    if parts.scheme not in ("http", "https") or not parts.hostname or parts.path not in ("", "/"):
        return None
    port = parts.port
    default = {"http": 80, "https": 443}[parts.scheme]
    host = f"[{parts.hostname}]" if ":" in parts.hostname else parts.hostname
    return f"{parts.scheme}://{host}" + (f":{port}" if port and port != default else "")


def cors_origins() -> set[str]:
    out = set()
    for o in env_list("CORS_ORIGINS"):
        n = _normalize_origin(o) if o != "*" else None
        if n:
            out.add(n)
    return out


def same_origin(origin: str, host_header: str | None) -> bool:
    """Origin = eigene Origin: Host (+Port) wie im Host-Header oder ein Eintrag aus ALLOWED_HOSTS. Das Schema
    wird nicht verglichen (TLS endet am Proxy; ohne vertrauten X-Forwarded-Proto sähe die App nur http)."""
    n = _normalize_origin(origin)
    if n is None:
        return False
    scheme, netloc = n.split("://", 1)
    default = "443" if scheme == "https" else "80"
    o_host, o_port = _split_host(netloc)
    if host_header:
        h_host, h_port = _split_host(host_header)
        if o_host == h_host and (o_port or default) == (h_port or default):
            return True
    hosts = [h for h in allowed_hosts() if h != "*" and not h.startswith("*.")]
    return o_host in hosts and not o_port


CORS_METHODS = b"GET, POST, PUT, PATCH, DELETE"
CORS_HEADERS = b"Authorization, Content-Type, X-Request-ID"
CORS_EXPOSE = b"Content-Disposition, Retry-After, X-Request-ID"
UNSAFE_METHODS = ("POST", "PUT", "PATCH", "DELETE")


# ---------- JSON-Struktur ----------
_JSON_TOKEN = re.compile(rb'"[^"\\]*(?:\\.[^"\\]*)*"|[\[\]{},]')


def json_problem(body: bytes) -> str | None:
    """Verschachtelungstiefe und Elementzahl prüfen, ohne zu parsen (Strings werden übersprungen)."""
    max_depth, max_items = env_int("JSON_MAX_DEPTH", 32), env_int("JSON_MAX_ITEMS", 100_000)
    if body.count(b"[") + body.count(b"{") <= max_depth and body.count(b",") <= max_items:
        return None   # schneller Weg: kann die Grenzen gar nicht überschreiten
    depth = items = 0
    for m in _JSON_TOKEN.finditer(body):
        c = m.group()[0]
        if c in (0x5B, 0x7B):           # [ {
            depth += 1
            items += 1
            if depth > max_depth:
                return f"JSON zu tief verschachtelt (max. {max_depth})"
        elif c in (0x5D, 0x7D):         # ] }
            depth -= 1
        elif c == 0x2C:                 # ,
            items += 1
        if items > max_items:
            return f"JSON mit zu vielen Elementen (max. {max_items})"
    return None


class JsonGuard:
    """ASGI (innerhalb RequestGuard, d. h. nach den Body-Limits): JSON-Bodies unter /api/* vor dem Parsen auf
    Tiefe/Elementzahl prüfen → 422; der gepufferte Body wird danach unverändert an die App gereicht."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope["method"] not in UNSAFE_METHODS or \
                not scope["path"].startswith("/api/") or scope["path"].endswith("/blob"):
            return await self.app(scope, receive, send)
        ctype = dict(scope.get("headers") or []).get(b"content-type", b"").lower()
        if ctype and b"json" not in ctype:
            return await self.app(scope, receive, send)
        chunks, more = [], True
        while more:
            msg = await receive()
            if msg["type"] != "http.request":
                return await self.app(scope, _replay([msg], receive), send)
            chunks.append(msg.get("body", b""))
            more = msg.get("more_body", False)
        body = b"".join(chunks)
        problem = json_problem(body)
        if problem:
            detail = json.dumps({"detail": [{"loc": ["body"], "msg": problem, "type": "json_structure"}]})
            await send({"type": "http.response.start", "status": 422,
                        "headers": [(b"content-type", b"application/json")]})
            await send({"type": "http.response.body", "body": detail.encode()})
            return
        await self.app(scope, _replay([{"type": "http.request", "body": body, "more_body": False}], receive), send)


def _replay(messages: list, receive):
    pending = list(messages)

    async def replay():
        if pending:
            return pending.pop(0)
        return await receive()
    return replay


# ---------- Haupt-Middleware ----------
MAX_PATH = 2048
MAX_QUERY = 2048


class SecurityMiddleware:
    """ASGI, äusserste Schicht: Request-ID, Host-Prüfung, Sperre/Rate-Limit je IP, CORS/CSRF-Origin,
    Sicherheits-Header (nosniff, Referrer-Policy, CORP, HSTS bei HTTPS), ohne Server-Header; zählt 401 und
    Probing-403/404 für die Brute-Force-Sperre."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        headers = dict(scope.get("headers") or [])
        ip = client_ip(scope)
        path = scope.get("path", "")
        ctx = RequestContext(request_id=request_id_from(headers), ip=ip, method=scope.get("method", ""),
                             path=path)
        token = _ctx.set(ctx)
        try:
            await self._handle(scope, receive, send, headers, ctx)
        finally:
            _ctx.reset(token)

    async def _handle(self, scope, receive, send, headers, ctx: RequestContext):
        host = headers.get(b"host", b"").decode("latin-1") or None
        origin = headers.get(b"origin", b"").decode("latin-1") or None
        allowed_cors = cors_origins()
        n_origin = _normalize_origin(origin) if origin else None
        cors_ok = n_origin is not None and n_origin in allowed_cors
        extra = self._headers(scope, ctx, cors_ok and n_origin, bool(allowed_cors))
        status_holder = {"code": 0}

        async def wrapped(msg):
            if msg["type"] == "http.response.start":
                status_holder["code"] = msg["status"]
                names = {k.lower() for k, _ in extra}
                hdrs = [(k, v) for k, v in msg.get("headers", []) if k.lower() not in names and k.lower() != b"server"]
                msg = {**msg, "headers": [*hdrs, *extra]}
            await send(msg)

        path, method = ctx.path, ctx.method
        if len(scope.get("raw_path") or path) > MAX_PATH or len(scope.get("query_string") or b"") > MAX_QUERY:
            return await reply(wrapped, 414, "Adresse zu lang")
        # Probes/Prometheus sprechen Pods über die IP an (Host = Pod-IP): /health* und /metrics ohne Host-Prüfung
        # (/metrics bleibt über METRICS_TOKEN/METRICS_ALLOW geschützt, Health liefert keine Daten)
        if not path.startswith(HOST_CHECK_EXEMPT) and not host_allowed(host):
            event("host_rejected", status=400, reason=host or "(leer)", throttle=60)
            return await reply(wrapped, 400, "Ungültiger Host")
        if not allowlisted(ctx.ip):
            kind = category(path)
            per_min, burst = limit_for(kind)
            blocked, retry = await gate(ctx.ip, kind, per_min, burst)
            if blocked:
                event("rate_limited", status=429, reason="blocked", throttle=30)
                return await reply(wrapped, 429, "Zu viele fehlgeschlagene Anfragen", blocked)
            if retry:
                event("rate_limited", status=429, reason=kind, throttle=10)
                return await reply(wrapped, 429, "Zu viele Anfragen", retry)
        if method == "OPTIONS" and origin and b"access-control-request-method" in headers:
            if cors_ok:
                return await reply(wrapped, 204, None, cors_preflight=True)
            event("cors_rejected", status=403, reason=f"preflight {origin}", throttle=60)
            return await reply(wrapped, 403, "Cross-Origin nicht erlaubt")
        if method in UNSAFE_METHODS and origin and not cors_ok and not same_origin(origin, host):
            event("cors_rejected", status=403, reason=f"origin {origin}", throttle=60)
            return await reply(wrapped, 403, "Ungültige Origin")

        await self.app(scope, receive, wrapped)

        code = status_holder["code"]
        if code == 401 and path.startswith("/api/"):
            reason = ctx.auth_reason or "invalid_token"
            event("auth_failed", status=401, reason=reason, sub=ctx.auth_sub)
            await record_auth_failed(ctx.ip, ctx.auth_sub)
        elif code in (403, 404) and ctx.probe:
            await record_probe(ctx.ip, ctx.sub, ctx.probe)

    @staticmethod
    def _headers(scope, ctx: RequestContext, cors_origin: str | bool | None, cors_configured: bool) -> list:
        out = [(b"x-request-id", ctx.request_id.encode()),
               (b"x-content-type-options", b"nosniff"),
               (b"referrer-policy", b"no-referrer"),
               (b"cross-origin-resource-policy", b"same-origin")]
        if is_https(scope) or os.environ.get("FORCE_HSTS") == "1":
            out.append((b"strict-transport-security", b"max-age=31536000; includeSubDomains"))
        if cors_configured:
            out.append((b"vary", b"Origin"))
        if cors_origin:
            out += [(b"access-control-allow-origin", cors_origin.encode()),
                    (b"access-control-expose-headers", CORS_EXPOSE)]
        return out


async def reply(send, code: int, detail: str | None, retry_after: int | None = None,
                cors_preflight: bool = False) -> None:
    hdrs = [(b"content-type", b"application/json")]
    if retry_after:
        hdrs.append((b"retry-after", str(retry_after).encode()))
    if cors_preflight:
        hdrs += [(b"access-control-allow-methods", CORS_METHODS), (b"access-control-allow-headers", CORS_HEADERS),
                 (b"access-control-max-age", b"600")]
    body = b"" if detail is None else json.dumps({"detail": detail}).encode()
    await send({"type": "http.response.start", "status": code, "headers": hdrs})
    await send({"type": "http.response.body", "body": body})


# ---------- Startprüfung ----------
def config_warnings() -> list[str]:
    env = os.environ.get
    out = []
    issuer = (env("OIDC_ISSUER") or "").strip()
    if issuer and urlsplit(issuer).scheme != "https":
        out.append("OIDC_ISSUER ist nicht https")
    if env("OIDC_ALLOW_HTTP") == "1":
        out.append("OIDC_ALLOW_HTTP=1: Schlüssel (JWKS) auch über http")
    if env("DOCS_ENABLED") == "1":
        out.append("DOCS_ENABLED=1: OpenAPI/Swagger öffentlich")
    if "*" in allowed_hosts():
        out.append("ALLOWED_HOSTS=*: Host-Header wird nicht geprüft")
    if "*" in env_list("FORWARDED_ALLOW_IPS", "127.0.0.1"):
        out.append("FORWARDED_ALLOW_IPS=*: X-Forwarded-For von jedem Absender vertraut (IP-Sperren umgehbar)")
    if not (env("ANCHOR_SIGNING_KEY") or "").strip():
        out.append("ANCHOR_SIGNING_KEY fehlt: Hash-Kette wird nicht signiert verankert")
    if env("DEFAULT_TENANT") and not env("OIDC_REQUIRED_ROLE"):
        out.append("DEFAULT_TENANT ohne OIDC_REQUIRED_ROLE: jeder Realm-Benutzer erhält Schreibzugriff")
    if (env("N8N_WEBHOOK_URL") or "").strip():
        secret = (env("N8N_WEBHOOK_SECRET") or "").strip()
        if len(secret) < 32:
            out.append("N8N_WEBHOOK_SECRET fehlt oder ist zu kurz (< 32 Zeichen) bei gesetzter Webhook-URL")
    if "*" in env_list("CORS_ORIGINS"):
        out.append("CORS_ORIGINS enthält *: wird ignoriert, nur exakte Origins")
    wildcard, nets, _ = _nets(env("SECURITY_ALLOWLIST", ""))
    if wildcard or any(n.prefixlen == 0 for n in nets):
        out.append("SECURITY_ALLOWLIST umfasst alle Adressen: keine IP-Sperren/-Limits")
    if (env("METRICS_TOKEN") or "").strip() and len(env("METRICS_TOKEN").strip()) < 32:
        out.append("METRICS_TOKEN zu kurz (< 32 Zeichen)")
    mw, mnets, _ = _nets(env("METRICS_ALLOW", ""))
    if mw or any(n.prefixlen == 0 for n in mnets):
        out.append("METRICS_ALLOW umfasst alle Adressen: /metrics öffentlich")
    return out + runtime.warnings()


class InsecureConfig(RuntimeError):
    pass


def check_config() -> list[str]:
    """Warnungen ins Sicherheits-Log; STRICT_CONFIG=1 → Abbruch beim Start."""
    warnings = config_warnings()
    for w in warnings:
        event("config_warning", reason=w)
    if warnings and os.environ.get("STRICT_CONFIG") == "1":
        raise InsecureConfig("Unsichere Konfiguration (STRICT_CONFIG=1): " + "; ".join(warnings))
    return warnings


# ---------- Text-Normalisierung (Payloads) ----------
_TEXT_CTRL = re.compile("[\x00-\x08\x0b-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069\ufeff]")
_LINE_BREAKS = re.compile("[\t\n\r\u2028\u2029]")


def clean_text(value: str, multiline: bool = False) -> str:
    """NFC; Steuer- und Bidi-Zeichen entfernt. Mehrzeilig (Notizen): \\n und \\t bleiben (CR → LF),
    einzeilig: Zeilenumbrüche/Tab → Leerzeichen."""
    if multiline:
        value = value.replace("\r\n", "\n").replace("\r", "\n").replace("\u2028", "\n").replace("\u2029", "\n")
    else:
        value = _LINE_BREAKS.sub(" ", value)
    value = _TEXT_CTRL.sub("", value)
    return value if value.isascii() else unicodedata.normalize("NFC", value)
