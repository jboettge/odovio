"""Geo-Dienste (selbst gehostet): OSRM Map-Matching/Routing und Photon Reverse-Geocoding.

Env:
  OSRM_URL       z. B. http://osrm:5000 (leer → nicht konfiguriert)
  OSRM_PROFILE   Routing-Profil, Default "driving"
  OSRM_MAX_MATCHING_SIZE  max. Punkte je /match-Anfrage (osrm-routed --max-matching-size), Default 100
  PHOTON_URL     z. B. http://photon:2322 (leer → nicht konfiguriert)
  GEO_TIMEOUT_S  Timeout je HTTP-Anfrage in Sekunden, Default 5
  UPSTREAM_CONCURRENCY       gleichzeitige Anfragen je Dienst (OSRM, Photon, LLM, Vision, Keycloak-Admin), Default 4;
                             ist ein Dienst ausgelastet → sofort 503 (keine wartenden Threads)
  UPSTREAM_BREAKER_FAILURES  Fehler in Folge, nach denen ein Dienst gesperrt wird, Default 3
  UPSTREAM_BREAKER_OPEN_S    Sperrdauer in Sekunden (sofort 503), Default 30

Nur stdlib (urllib); kein Proxy (Dienste liegen im LAN), keine Weiterleitungen, Antwortgrösse begrenzt.
"""
import json
import logging
import os
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass

log = logging.getLogger("fahrzeugbuch.geo")

MAX_POINTS = 500          # Punkte insgesamt nach dem Ausdünnen
GAP_S = 60                # Zeitsprung, ab dem der Track getrennt wird
MAX_SEGMENTS = 30         # mehr Teilstücke → Track zu lückenhaft (begrenzt Anzahl OSRM-Aufrufe)
MAX_RESPONSE_BYTES = 4 * 1024 * 1024


class GeoUnavailable(Exception):
    """Dienst nicht konfiguriert."""


class UpstreamError(Exception):
    """Dienst nicht erreichbar, Timeout oder unerwartete Antwort (Details nur fürs Log)."""


class GeoNoResult(Exception):
    """Dienst antwortet, findet aber nichts (z. B. keine Route)."""


class InvalidTrack(ValueError):
    pass


class UpstreamBusy(UpstreamError):
    """Dienst ausgelastet oder nach wiederholten Fehlern kurz gesperrt (→ 503 mit Retry-After)."""

    def __init__(self, msg: str, retry_after: int):
        super().__init__(msg)
        self.retry_after = retry_after


# ---------- Begrenzung je Dienst ----------
class Upstream:
    """Gleichzeitigkeit (nicht blockierend) und einfacher Circuit-Breaker je Upstream-Dienst."""

    def __init__(self, name: str):
        self.name = name
        self.lock = threading.Lock()
        self.active = 0
        self.failures = 0
        self.open_until = 0.0

    @contextmanager
    def guard(self) -> Iterator[None]:
        limit = int(env_float("UPSTREAM_CONCURRENCY", 4))
        now = time.monotonic()
        with self.lock:
            if self.open_until > now:
                raise UpstreamBusy(f"{self.name} vorübergehend gesperrt", int(self.open_until - now) + 1)
            if self.active >= limit:
                raise UpstreamBusy(f"{self.name} ausgelastet", 1)
            self.active += 1
        try:
            yield
        except UpstreamError:
            with self.lock:
                self.failures += 1
                if self.failures >= int(env_float("UPSTREAM_BREAKER_FAILURES", 3)):
                    self.open_until = time.monotonic() + env_float("UPSTREAM_BREAKER_OPEN_S", 30)
                    self.failures = 0
                    log.warning("%s: nach wiederholten Fehlern vorübergehend gesperrt", self.name)
            raise
        else:
            with self.lock:
                self.failures = 0
        finally:
            with self.lock:
                self.active -= 1

    def reset(self) -> None:
        with self.lock:
            self.active = self.failures = 0
            self.open_until = 0.0


UPSTREAMS = {name: Upstream(name) for name in ("osrm", "photon", "llm", "vision", "keycloak")}


def reset_upstreams() -> None:
    for u in UPSTREAMS.values():
        u.reset()


# ---------- HTTP ----------
class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())


def env_float(name: str, default: float) -> float:
    try:
        v = float(os.environ.get(name) or default)
    except ValueError:
        return default
    return v if 0 < v < 3600 else default


def base_url(name: str) -> str:
    url = (os.environ.get(name) or "").strip().rstrip("/")
    if not url:
        raise GeoUnavailable(name)
    if urllib.parse.urlsplit(url).scheme not in ("http", "https"):
        log.error("%s: nur http/https erlaubt", name)
        raise GeoUnavailable(name)
    return url


def http_json(url: str, payload: dict | None = None, headers: dict | None = None,
              timeout: float = 5.0) -> dict:
    """GET (payload None) bzw. POST JSON → dict. Fehler → UpstreamError."""
    if urllib.parse.urlsplit(url).scheme not in ("http", "https"):
        raise UpstreamError("Schema nicht erlaubt")
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, method="GET" if data is None else "POST")
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with _opener.open(req, timeout=timeout) as r:
            body = r.read(MAX_RESPONSE_BYTES + 1)
    except urllib.error.HTTPError as e:
        # OSRM liefert bei NoMatch/NoRoute 400 mit JSON-Code → an Aufrufer weiterreichen
        try:
            err = json.loads(e.read(65536) or b"{}")
        except ValueError:
            err = None
        if isinstance(err, dict) and err.get("code"):
            return err
        raise UpstreamError(f"HTTP {e.code}") from e
    except (urllib.error.URLError, OSError, TimeoutError) as e:
        raise UpstreamError(type(e).__name__) from e
    if len(body) > MAX_RESPONSE_BYTES:
        raise UpstreamError("Antwort zu gross")
    try:
        out = json.loads(body)
    except ValueError as e:
        raise UpstreamError("kein JSON") from e
    if not isinstance(out, dict):
        raise UpstreamError("unerwartete Antwort")
    return out


# ---------- OSRM ----------
@dataclass(frozen=True)
class Point:
    lat: float
    lon: float
    ts: int          # Unix-Sekunden
    accuracy: float | None = None


def radius(accuracy: float | None) -> float:
    """Suchradius je Punkt ≈ 3× GPS-Genauigkeit, begrenzt auf 10–100 m."""
    acc = accuracy if accuracy is not None and accuracy > 0 else 10.0
    return round(min(max(3 * acc, 10.0), 100.0), 1)


def thin(points: list, n: int) -> list:
    """Gleichmässig auf n Punkte ausdünnen (erster und letzter bleiben)."""
    if len(points) <= n:
        return list(points)
    if n < 2:
        return points[:n]
    step = (len(points) - 1) / (n - 1)
    return [points[round(i * step)] for i in range(n)]


def prepare_segments(points: list[Point], max_points: int = MAX_POINTS, gap_s: int = GAP_S) -> list[list[Point]]:
    """Zeitlich sortieren, doppelte Zeitstempel verwerfen, bei Sprüngen > gap_s trennen,
    dann insgesamt auf max_points ausdünnen (anteilig je Teilstück)."""
    pts = sorted(points, key=lambda p: p.ts)
    segments: list[list[Point]] = []
    last = None
    for p in pts:
        if last is not None and p.ts == last.ts:
            continue
        if last is None or p.ts - last.ts > gap_s:
            segments.append([])
        segments[-1].append(p)
        last = p
    segments = [s for s in segments if len(s) >= 2]
    if len(segments) > MAX_SEGMENTS:
        raise InvalidTrack("Track zu lückenhaft")
    total = sum(len(s) for s in segments)
    if total > max_points:
        segments = [thin(s, max(2, int(len(s) * max_points / total))) for s in segments]
    return segments


def _chunks(seg: list[Point], size: int) -> list[list[Point]]:
    """Teilstück in Anfragen ≤ size zerlegen; aufeinanderfolgende teilen den Randpunkt
    (Distanzen bleiben lückenlos summierbar)."""
    if len(seg) <= size:
        return [seg]
    out, i = [], 0
    while i < len(seg) - 1:
        out.append(seg[i:i + size])
        i += size - 1
    return out


def _coords(points) -> str:
    return ";".join(f"{p.lon:.6f},{p.lat:.6f}" for p in points)


def _osrm():
    return (base_url("OSRM_URL"), (os.environ.get("OSRM_PROFILE") or "driving").strip(),
            env_float("GEO_TIMEOUT_S", 5))


def match(points: list[Point]) -> dict:
    base, profile, timeout = _osrm()
    with UPSTREAMS["osrm"].guard():
        return _match(points, base, profile, timeout)


def _match(points: list[Point], base: str, profile: str, timeout: float) -> dict:
    size = int(env_float("OSRM_MAX_MATCHING_SIZE", 100))
    size = max(size, 2)
    segments = prepare_segments(points)
    if not segments:
        raise InvalidTrack("Zu wenige Punkte")
    deadline = time.monotonic() + 3 * timeout
    distance = duration = weighted = 0.0
    conf_sum = 0.0
    n_match = 0
    matched = 0
    for seg in segments:
        for k, chunk in enumerate(_chunks(seg, size)):
            if time.monotonic() > deadline:
                raise UpstreamError("Gesamtzeit überschritten")
            query = urllib.parse.urlencode({
                "timestamps": ";".join(str(p.ts) for p in chunk),
                "radiuses": ";".join(f"{radius(p.accuracy):g}" for p in chunk),
                "overview": "false", "gaps": "split", "tidy": "true",
            })
            res = http_json(f"{base}/match/v1/{urllib.parse.quote(profile)}/{_coords(chunk)}?{query}",
                            timeout=timeout)
            code = res.get("code")
            if code in ("NoMatch", "NoSegment"):
                continue
            if code != "Ok":
                raise UpstreamError(f"OSRM {code}")
            for m in res.get("matchings") or []:
                d = float(m.get("distance") or 0)
                c = float(m.get("confidence") or 0)
                distance += d
                duration += float(m.get("duration") or 0)
                weighted += d * c
                conf_sum += c
                n_match += 1
            tps = res.get("tracepoints") or []
            # Randpunkt mit dem vorherigen Stück geteilt → nicht doppelt zählen
            matched += sum(1 for i, t in enumerate(tps) if t is not None and not (k > 0 and i == 0))
    if n_match == 0:
        raise GeoNoResult("Track konnte keiner Strasse zugeordnet werden")
    confidence = weighted / distance if distance > 0 else conf_sum / n_match
    return {"distance_km": round(distance / 1000, 3), "duration_s": round(duration, 1),
            "confidence": round(min(max(confidence, 0.0), 1.0), 3), "matched_points": matched}


def route(from_lat: float, from_lon: float, to_lat: float, to_lon: float) -> dict:
    base, profile, timeout = _osrm()
    coords = f"{from_lon:.6f},{from_lat:.6f};{to_lon:.6f},{to_lat:.6f}"
    query = urllib.parse.urlencode({"overview": "false", "alternatives": "false", "steps": "false"})
    with UPSTREAMS["osrm"].guard():
        res = http_json(f"{base}/route/v1/{urllib.parse.quote(profile)}/{coords}?{query}", timeout=timeout)
    code = res.get("code")
    if code in ("NoRoute", "NoSegment"):
        raise GeoNoResult("Keine Route gefunden")
    if code != "Ok" or not res.get("routes"):
        raise UpstreamError(f"OSRM {code}")
    r = res["routes"][0]
    return {"distance_km": round(float(r.get("distance") or 0) / 1000, 3),
            "duration_s": round(float(r.get("duration") or 0), 1)}


# ---------- Photon ----------
CITY_TYPES = {"city", "town", "village", "municipality", "hamlet"}


def _label(p: dict) -> str | None:
    """„Strasse Nr, PLZ Ort“; ohne Strasse „Name, PLZ Ort“ bzw. „PLZ Ort“."""
    ort = municipality(p) if p.get("type") in CITY_TYPES or not p.get("locality") else \
        (p.get("city") or p.get("town") or p.get("village"))
    place = " ".join(x for x in (p.get("postcode"), ort) if x)
    name = p.get("name")
    street = " ".join(x for x in (p.get("street"), p.get("housenumber")) if x)
    if street:
        head = street
        if name and name != p.get("street") and p.get("osm_key") not in ("highway", "building", "place"):
            head = f"{name}, {street}"      # POI (Firma, Geschäft …)
    else:
        head = name if name and name != ort else ""
    label = ", ".join(x for x in (head, place) if x)
    return label[:200] or None


def municipality(p: dict) -> str | None:
    for key in ("city", "town", "village"):
        if p.get(key):
            return p[key]
    if p.get("type") in CITY_TYPES and p.get("name"):
        return p["name"]
    return p.get("locality") or p.get("district") or None


def reverse(lat: float, lon: float) -> dict:
    base = base_url("PHOTON_URL")
    lat, lon = round(lat, 4), round(lon, 4)
    query = urllib.parse.urlencode({"lat": f"{lat:.4f}", "lon": f"{lon:.4f}", "lang": "de", "limit": 1})
    with UPSTREAMS["photon"].guard():
        res = http_json(f"{base}/reverse?{query}", timeout=env_float("GEO_TIMEOUT_S", 5))
        features = res.get("features")
        if not isinstance(features, list):
            raise UpstreamError("Photon: keine features")
    if not features:
        return {"label": None, "municipality": None, "country": None}
    props = features[0].get("properties") or {}
    return {"label": _label(props), "municipality": municipality(props), "country": props.get("country")}


def status() -> dict:
    def ok(name):
        try:
            base_url(name)
            return True
        except GeoUnavailable:
            return False
    return {"geo_match": ok("OSRM_URL"), "geo_reverse": ok("PHOTON_URL")}
