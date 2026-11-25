"""Gemeinsamer, flüchtiger Zustand mehrerer Worker/Replikas (Rate-Limits, Brute-Force, Circuit-Breaker,
Metrik-Schnappschüsse).

Env:
  STATE_BACKEND     memory (Default; je Prozess, nur mit genau 1 Worker und 1 Replika) | redis (Valkey/Redis)
  REDIS_URL         z. B. redis://:<passwort>@valkey:6379/0 (Passwort auch über REDIS_PASSWORD[_FILE])
  REDIS_TIMEOUT_MS  Verbindungs-/Antwort-Timeout je Befehl, Default 250
  REDIS_RETRY_S     nach einem Fehler so lange nicht erneut versuchen (sofort Ausweichverhalten), Default 5
  REDIS_MAX_CONNECTIONS  Verbindungen je Worker und Pool (sync + je Event-Loop async), Default 64
  STATE_PREFIX      Schlüsselpräfix, Default "fzb:" (Tests: eigener Präfix)

Alle Schlüssel tragen das Präfix und eine TTL (kein unbegrenztes Wachstum); Uhrzeit aus Redis (TIME), damit alle
Worker dieselbe Zeitbasis haben. Mehrschrittige Änderungen laufen atomar als Lua-Skript (EVALSHA).
Ausweichverhalten bei Ausfall (StateUnavailable, siehe Aufrufer): Rate-Limits fail-open, Brute-Force-Sperren und
Circuit-Breaker lokal je Prozess weiter; /health meldet "degraded", /health/ready 503.
Valkey ist nur ein Cache flüchtiger Zustände: Persistenz aus (--save "" --appendonly no), maxmemory + allkeys-lru.
"""
import asyncio
import hashlib
import logging
import os
import threading
import time
import uuid
import weakref

log = logging.getLogger("fahrzeugbuch.state")


class StateUnavailable(Exception):
    """Backend nicht erreichbar/fehlerhaft (Details nur im Log, keine Verbindungsdaten)."""


def backend_name() -> str:
    return (os.environ.get("STATE_BACKEND") or "memory").strip().lower()


def prefix() -> str:
    return os.environ.get("STATE_PREFIX") or "fzb:"


def _ms(name: str, default: int) -> float:
    try:
        v = int(os.environ.get(name) or default)
    except ValueError:
        v = default
    return max(10, v) / 1000


def _ident(value: str) -> str:
    """Schlüsselteil: kurz und ohne Trennzeichen; lange/ungewöhnliche Werte gehasht."""
    if len(value) <= 64 and value.replace(".", "").replace("-", "").replace("_", "").replace(":", "").isalnum():
        return value
    return "h" + hashlib.sha256(value.encode()).hexdigest()[:32]


# ---------- Lua ----------
_LIB = """
local function now_ms()
  local t = redis.call('TIME')
  return tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000)
end
local function take(key, per_min, burst, now)
  local rate = per_min / 60000.0
  local v = redis.call('HMGET', key, 't', 'ts')
  local tokens, ts = tonumber(v[1]), tonumber(v[2])
  if tokens == nil or ts == nil then tokens = burst
  else tokens = math.min(burst, tokens + math.max(0, now - ts) * rate) end
  local retry = 0
  if tokens >= 1 then tokens = tokens - 1
  else retry = math.max(1, math.ceil((1 - tokens) / rate / 1000)) end
  redis.call('HSET', key, 't', tostring(tokens), 'ts', tostring(now))
  redis.call('PEXPIRE', key, math.ceil(burst / rate) + 1000)
  return retry
end
local function block(bkey, fkey, pkey, steps_csv, reset_ms, now)
  local steps = {}
  for s in string.gmatch(steps_csv, '%d+') do table.insert(steps, tonumber(s)) end
  if #steps == 0 then steps = {300} end
  local b = redis.call('HMGET', bkey, 'level', 'since')
  local level = 0
  if b[1] and b[2] and now - tonumber(b[2]) < reset_ms then level = tonumber(b[1]) + 1 end
  local duration = steps[math.min(level + 1, #steps)]
  redis.call('HSET', bkey, 'until', tostring(now + duration * 1000), 'level', tostring(level), 'since', tostring(now))
  redis.call('PEXPIRE', bkey, math.max(duration * 1000, reset_ms))
  redis.call('DEL', fkey, pkey)
  return {duration, level + 1}
end
"""
# KEYS: Sperre, Bucket · ARGV: Sperre prüfen, Limit prüfen, per_min, burst → {0|1 gesperrt|2 Limit, Sekunden}
GATE = _LIB + """
local now = now_ms()
if ARGV[1] == '1' then
  local u = tonumber(redis.call('HGET', KEYS[1], 'until'))
  if u and u > now then return {1, math.floor((u - now) / 1000) + 1} end
end
if ARGV[2] == '1' then
  local r = take(KEYS[2], tonumber(ARGV[3]), tonumber(ARGV[4]), now)
  if r > 0 then return {2, r} end
end
return {0, 0}
"""
TAKE = _LIB + "return take(KEYS[1], tonumber(ARGV[1]), tonumber(ARGV[2]), now_ms())"
# Gleitendes Fenster (exakt): ZSET mit höchstens `limit` Einträgen
WINDOW = _LIB + """
local now = now_ms()
local limit, window = tonumber(ARGV[1]), tonumber(ARGV[2])
redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', now - window)
if redis.call('ZCARD', KEYS[1]) >= limit then
  local oldest = redis.call('ZRANGE', KEYS[1], 0, 0, 'WITHSCORES')
  return math.max(1, math.floor((tonumber(oldest[2]) + window - now) / 1000) + 1)
end
redis.call('ZADD', KEYS[1], now, ARGV[3])
redis.call('PEXPIRE', KEYS[1], window)
return 0
"""
# KEYS: Sperre, Fehlversuche, Probing · ARGV: member, threshold, window_ms, steps, reset_ms
FAIL = _LIB + """
local now = now_ms()
local window = tonumber(ARGV[3])
redis.call('ZREMRANGEBYSCORE', KEYS[2], '-inf', '(' .. (now - window))
redis.call('ZADD', KEYS[2], now, ARGV[1])
redis.call('PEXPIRE', KEYS[2], window + 1000)
if redis.call('ZCARD', KEYS[2]) >= tonumber(ARGV[2]) then
  return block(KEYS[1], KEYS[2], KEYS[3], ARGV[4], tonumber(ARGV[5]), now)
end
return {0, 0}
"""
# KEYS: Fehlversuche · ARGV: sub → Fehlversuche dieses sub entfernen (member = 32 Hex + \\31 + sub)
AUTH_OK = """
local n = 0
for _, m in ipairs(redis.call('ZRANGE', KEYS[1], 0, -1)) do
  if string.sub(m, 34) == ARGV[1] then redis.call('ZREM', KEYS[1], m); n = n + 1 end
end
return n
"""
# KEYS: Sperre, Fehlversuche, Probing · ARGV: member, sub, threshold, window_ms, steps, reset_ms
PROBE = _LIB + """
local now = now_ms()
local window = tonumber(ARGV[4])
redis.call('ZREMRANGEBYSCORE', KEYS[3], '-inf', '(' .. (now - window))
redis.call('ZADD', KEYS[3], now, ARGV[1])
redis.call('PEXPIRE', KEYS[3], window + 1000)
local n = 0
for _, m in ipairs(redis.call('ZRANGE', KEYS[3], 0, -1)) do
  if string.sub(m, 34) == ARGV[2] then n = n + 1 end
end
if n >= tonumber(ARGV[3]) then return block(KEYS[1], KEYS[2], KEYS[3], ARGV[5], tonumber(ARGV[6]), now) end
return {0, 0}
"""
BLOCKED = _LIB + """
local u = tonumber(redis.call('HGET', KEYS[1], 'until'))
local now = now_ms()
if u and u > now then return math.floor((u - now) / 1000) + 1 end
return 0
"""
# Circuit-Breaker: KEYS: Dienst · ARGV: threshold, open_ms → 1 = jetzt gesperrt
CB_FAIL = _LIB + """
local now = now_ms()
local f = redis.call('HINCRBY', KEYS[1], 'failures', 1)
redis.call('PEXPIRE', KEYS[1], 3600000)
if f >= tonumber(ARGV[1]) then
  redis.call('HSET', KEYS[1], 'open_until', tostring(now + tonumber(ARGV[2])), 'failures', '0')
  return 1
end
return 0
"""
CB_CHECK = _LIB + """
local u = tonumber(redis.call('HGET', KEYS[1], 'open_until'))
local now = now_ms()
if u and u > now then return u - now end
return 0
"""
SCRIPTS = {name: (src, hashlib.sha1(src.encode(), usedforsecurity=False).hexdigest())
           for name, src in (("gate", GATE), ("take", TAKE), ("window", WINDOW), ("fail", FAIL),
                             ("auth_ok", AUTH_OK), ("probe", PROBE), ("blocked", BLOCKED),
                             ("cb_fail", CB_FAIL), ("cb_check", CB_CHECK))}


def _member(sub: str | None) -> str:
    return uuid.uuid4().hex + "\x1f" + (sub or "")


class RedisState:
    """Valkey/Redis: synchrone Aufrufe (Threadpool) und asynchrone (Event-Loop, z. B. Middleware)."""

    name = "redis"

    def __init__(self, url: str, key_prefix: str | None = None):
        import redis
        import redis.asyncio as aredis

        self._redis, self._aredis = redis, aredis
        self.url = url
        self.p = key_prefix or prefix()
        self.timeout = _ms("REDIS_TIMEOUT_MS", 250)
        try:
            self.retry_s = max(0.0, float(os.environ.get("REDIS_RETRY_S") or 5))
        except ValueError:
            self.retry_s = 5.0
        self.max_conn = max(4, int(os.environ.get("REDIS_MAX_CONNECTIONS") or 64))
        self._sync = redis.Redis(connection_pool=redis.BlockingConnectionPool.from_url(
            url, max_connections=self.max_conn, timeout=self.timeout, socket_timeout=self.timeout,
            socket_connect_timeout=self.timeout, health_check_interval=30))
        self._async: weakref.WeakKeyDictionary = weakref.WeakKeyDictionary()
        self._lock = threading.Lock()
        self.down_until = 0.0
        self.last_error = 0.0
        self.errors = 0

    # ---------- Fehlerbehandlung ----------
    def _check_up(self) -> None:
        if time.monotonic() < self.down_until:
            raise StateUnavailable("zurückgestellt nach Fehler")

    def _failed(self, e: Exception) -> StateUnavailable:
        now = time.monotonic()
        with self._lock:
            self.down_until = now + self.retry_s
            self.last_error = now
            self.errors += 1
        log.warning("State-Backend nicht verfügbar (%s)", type(e).__name__)
        return StateUnavailable(type(e).__name__)

    def degraded(self, window: float = 30.0) -> bool:
        return self.last_error > 0 and time.monotonic() - self.last_error < max(window, self.retry_s)

    def _errors(self):
        return (self._redis.RedisError, OSError)

    # ---------- Skripte ----------
    def _eval(self, script: str, keys: list[str], args: list):
        src, sha = SCRIPTS[script]
        self._check_up()
        try:
            try:
                return self._sync.evalsha(sha, len(keys), *keys, *args)
            except self._redis.exceptions.NoScriptError:
                return self._sync.eval(src, len(keys), *keys, *args)
        except self._errors() as e:
            raise self._failed(e) from None

    def _aclient(self):
        loop = asyncio.get_running_loop()
        c = self._async.get(loop)
        if c is None:
            c = self._aredis.Redis(connection_pool=self._aredis.BlockingConnectionPool.from_url(
                self.url, max_connections=self.max_conn, timeout=self.timeout, socket_timeout=self.timeout,
                socket_connect_timeout=self.timeout, health_check_interval=30))
            self._async[loop] = c
        return c

    async def _aeval(self, script: str, keys: list[str], args: list):
        src, sha = SCRIPTS[script]
        self._check_up()
        c = self._aclient()
        try:
            try:
                return await c.evalsha(sha, len(keys), *keys, *args)
            except self._redis.exceptions.NoScriptError:
                return await c.eval(src, len(keys), *keys, *args)
        except self._errors() as e:
            raise self._failed(e) from None

    def _call(self, fn):
        self._check_up()
        try:
            return fn(self._sync)
        except self._errors() as e:
            raise self._failed(e) from None

    # ---------- Schlüssel ----------
    def k(self, kind: str, *parts: str) -> str:
        return self.p + kind + "".join(":" + _ident(p) for p in parts)

    def _bf_keys(self, ip: str) -> list[str]:
        return [self.k("bf:b", ip), self.k("bf:f", ip), self.k("bf:p", ip)]

    # ---------- Rate-Limits ----------
    def take(self, key: str, per_min: int, burst: int) -> int:
        return int(self._eval("take", [self.k("tb", key)], [per_min, burst]))

    async def agate(self, ip: str, kind: str, per_min: int, burst: int, check_block: bool,
                    check_rate: bool) -> tuple[int, int]:
        """Ein Roundtrip: (Sperre in s, Limit-Wartezeit in s)."""
        code, secs = await self._aeval("gate", [self.k("bf:b", ip), self.k("tb", f"{kind}:{ip}")],
                                       [int(check_block), int(check_rate), per_min, burst])
        return (int(secs), 0) if int(code) == 1 else (0, int(secs) if int(code) == 2 else 0)

    def window(self, key: str, limit: int, window_s: float) -> int:
        return int(self._eval("window", [self.k("rl", key)], [limit, int(window_s * 1000), uuid.uuid4().hex]))

    # ---------- Brute-Force ----------
    def blocked(self, ip: str) -> int:
        return int(self._eval("blocked", [self.k("bf:b", ip)], []))

    @staticmethod
    def _block(res) -> tuple[int, int] | None:
        duration, level = int(res[0]), int(res[1])
        return (duration, level) if duration else None

    def auth_failed(self, ip: str, sub: str | None, threshold: int, window_s: float, steps: list[int],
                    reset_s: float) -> tuple[int, int] | None:
        return self._block(self._eval("fail", self._bf_keys(ip), [
            _member(sub), threshold, int(window_s * 1000), ",".join(map(str, steps)), int(reset_s * 1000)]))

    async def aauth_failed(self, ip, sub, threshold, window_s, steps, reset_s):
        return self._block(await self._aeval("fail", self._bf_keys(ip), [
            _member(sub), threshold, int(window_s * 1000), ",".join(map(str, steps)), int(reset_s * 1000)]))

    def auth_ok(self, ip: str, sub: str) -> int:
        return int(self._eval("auth_ok", [self.k("bf:f", ip)], [sub]))

    def probe(self, ip, sub, threshold, window_s, steps, reset_s):
        return self._block(self._eval("probe", self._bf_keys(ip), [
            _member(sub), sub or "", threshold, int(window_s * 1000), ",".join(map(str, steps)),
            int(reset_s * 1000)]))

    async def aprobe(self, ip, sub, threshold, window_s, steps, reset_s):
        return self._block(await self._aeval("probe", self._bf_keys(ip), [
            _member(sub), sub or "", threshold, int(window_s * 1000), ",".join(map(str, steps)),
            int(reset_s * 1000)]))

    # ---------- Circuit-Breaker ----------
    def breaker_open(self, name: str) -> float:
        """Restdauer der Sperre in Sekunden (0 = offen für Anfragen)."""
        return int(self._eval("cb_check", [self.k("cb", name)], [])) / 1000

    def breaker_failure(self, name: str, threshold: int, open_s: float) -> bool:
        return bool(int(self._eval("cb_fail", [self.k("cb", name)], [threshold, int(open_s * 1000)])))

    def breaker_success(self, name: str) -> None:
        self._call(lambda r: r.hdel(self.k("cb", name), "failures"))

    # ---------- Metrik-Schnappschüsse ----------
    def metrics_put(self, group: str, worker: str, payload: str, ttl_s: float) -> None:
        key, idx = self.k("m", group, worker), self.k("mi", group)

        def run(r):
            now = time.time()
            with r.pipeline(transaction=False) as p:
                p.set(key, payload, px=int(ttl_s * 1000))
                p.zadd(idx, {worker: now})
                p.zremrangebyscore(idx, "-inf", now - ttl_s)
                p.pexpire(idx, int(ttl_s * 4000))
                p.execute()
        self._call(run)

    def metrics_delete(self, group: str, worker: str) -> None:
        self._call(lambda r: (r.delete(self.k("m", group, worker)), r.zrem(self.k("mi", group), worker)))

    def metrics_all(self, group: str) -> list[str]:
        idx = self.k("mi", group)

        def run(r):
            workers = [w.decode() if isinstance(w, bytes) else w for w in r.zrange(idx, 0, -1)]
            if not workers:
                return []
            vals = r.mget([self.k("m", group, w) for w in workers])
            return [v.decode() if isinstance(v, bytes) else v for v in vals if v]
        return self._call(run)

    # ---------- Betrieb ----------
    def ping(self) -> bool:
        try:
            return bool(self._sync.ping())
        except self._errors() as e:
            raise self._failed(e) from None

    def reset(self) -> None:
        """Alle Schlüssel mit diesem Präfix löschen (Tests)."""
        with self._lock:
            self.down_until = self.last_error = 0.0
        batch = []
        for key in self._sync.scan_iter(match=self.p + "*", count=500):
            batch.append(key)
            if len(batch) >= 500:
                self._sync.delete(*batch)
                batch = []
        if batch:
            self._sync.delete(*batch)

    def close(self) -> None:
        self._sync.close()


_shared: RedisState | None = None
_shared_lock = threading.Lock()


class StateConfigError(RuntimeError):
    pass


def shared() -> RedisState | None:
    """Gemeinsames Backend (redis) oder None (memory → In-Memory-Strukturen der Module)."""
    global _shared
    if backend_name() != "redis":
        return None
    if _shared is None:
        with _shared_lock:
            if _shared is None:
                url = os.environ.get("REDIS_URL") or ""
                if not url:
                    raise StateConfigError("STATE_BACKEND=redis ohne REDIS_URL")
                _shared = RedisState(url)
    return _shared


def configure(instance: RedisState | None) -> None:
    """Backend explizit setzen (Tests)."""
    global _shared
    with _shared_lock:
        _shared = instance


def check_config() -> list[str]:
    name = backend_name()
    if name not in ("memory", "redis"):
        raise StateConfigError(f"STATE_BACKEND={name} unbekannt (memory | redis)")
    if name == "redis" and not os.environ.get("REDIS_URL"):
        raise StateConfigError("STATE_BACKEND=redis ohne REDIS_URL")
    return []
