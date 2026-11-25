"""„Intelligenz“-Endpunkte: Geo (OSRM/Photon) und LLM-Vorschläge (vLLM).

Einbinden in main.py:  from . import intel;  app.include_router(intel.router)

Bewusst ohne Import aus main.py (kein Zirkelimport): Mandantenrecht wird direkt aus den
Token-Gruppen gelesen (gleiche Logik wie main.tenant_access, aber ohne DB-Zugriff).

Rate-Limits je Benutzer (In-Memory, je Prozess):
  INTEL_RATE_SUGGEST  Anfragen/Minute für /trips/suggest, Default 60
  INTEL_RATE_GEO      Anfragen/Minute für /api/geo/*, Default 30
  INTEL_RATE_SCAN     Anfragen/Minute für /scan (Bildauswertung), Default 20 – geprüft bevor der Body
                      gelesen wird
Je Upstream begrenzt geo.Upstream die Gleichzeitigkeit (sofort 503) und sperrt nach Fehlern kurz.

Reverse-Geocoding: POST /api/geo/reverse {lat, lon} – Koordinaten nicht in der URL (Access-Logs).
GET mit Query-Parametern bleibt eine Version lang erhalten (deprecated).
"""
import datetime as dt
import logging
import os
import threading
import time
from collections import deque
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response, status
from fastapi.concurrency import run_in_threadpool
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from fastapi.routing import APIRoute
from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator

from . import classify, geo, vision
from .auth import TENANT_SLUG, User, can_write, require_user
from .classify import PrivateTrip, SuggestRequest
from .geo import GeoNoResult, GeoUnavailable, InvalidTrack, UpstreamBusy, UpstreamError

log = logging.getLogger("fahrzeugbuch.intel")
SCAN_MAX_IMAGE = vision.MAX_IMAGE_BYTES


class _SafeRoute(APIRoute):
    """422 ohne Echo der Eingabe: NaN/inf wären nicht JSON-kodierbar (→ 500), und Koordinaten
    sollen nicht in Fehlermeldungen/Logs zurückgespiegelt werden."""

    def get_route_handler(self):
        handler = super().get_route_handler()

        async def route_handler(request: Request):
            try:
                return await handler(request)
            except RequestValidationError as e:
                return JSONResponse(status_code=422, content={"detail": [
                    {"loc": [str(x) for x in err.get("loc", ())], "msg": err.get("msg", ""),
                     "type": err.get("type", "")} for err in e.errors()]})
        return route_handler


router = APIRouter(route_class=_SafeRoute)
CurrentUser = Annotated[User, Depends(require_user)]


# ---------- Rate-Limit ----------
class RateLimiter:
    def __init__(self, window: float = 60.0):
        self.window = window
        self.hits: dict[str, deque] = {}
        self.lock = threading.Lock()

    def check(self, key: str, limit: int) -> None:
        now = time.monotonic()
        with self.lock:
            if len(self.hits) > 10_000:   # Speicher begrenzen: leere/alte Einträge verwerfen
                self.hits = {k: q for k, q in self.hits.items() if q and now - q[-1] < self.window}
            q = self.hits.setdefault(key, deque())
            while q and now - q[0] >= self.window:
                q.popleft()
            if len(q) >= limit:
                retry = max(1, int(self.window - (now - q[0])) + 1)
                raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, "Zu viele Anfragen",
                                    headers={"Retry-After": str(retry)})
            q.append(now)

    def reset(self) -> None:
        with self.lock:
            self.hits.clear()


limiter = RateLimiter()


def env_limit(name: str, default: int) -> int:
    try:
        v = int(os.environ.get(name) or default)
    except ValueError:
        return default
    return v if v > 0 else default


_limit = env_limit


# ---------- Zugriff ----------
def geo_user(user: CurrentUser) -> User:
    """Geo: irgendein Mandantenrecht (lesen genügt)."""
    if not user.tenants:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Kein Mandant zugeordnet")
    limiter.check(f"geo:{user.sub}", _limit("INTEL_RATE_GEO", 30))
    return user


GeoUser = Annotated[User, Depends(geo_user)]


def write_access(tenant: str, user: CurrentUser) -> User:
    slug = tenant.lower()
    role = user.tenants.get(slug) if TENANT_SLUG.match(slug) else None
    if role is None:
        raise HTTPException(status.HTTP_403_FORBIDDEN, f"Kein Zugriff auf Mandant {tenant}")
    if not can_write(role):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Nur Lesezugriff auf diesen Mandanten")
    return user


def _upstream(e: Exception, what: str) -> HTTPException:
    if isinstance(e, GeoUnavailable):
        return HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, f"{what} nicht konfiguriert")
    if isinstance(e, UpstreamBusy):
        return HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, f"{what} ausgelastet – bitte später erneut",
                             headers={"Retry-After": str(e.retry_after)})
    log.warning("%s fehlgeschlagen: %s", what, e)
    return HTTPException(status.HTTP_502_BAD_GATEWAY, f"{what} nicht erreichbar")


# ---------- Schemas ----------
class _In(BaseModel):
    model_config = ConfigDict(allow_inf_nan=False, extra="ignore")


class LatLon(_In):
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)


TS_MIN, TS_MAX = 946684800, 4102444800   # 2000-01-01 … 2100-01-01


class TrackPoint(LatLon):
    ts: float | dt.datetime = Field(description="ISO 8601 oder Unix-Sekunden (Millisekunden werden erkannt)")
    accuracy: float | None = Field(default=None, ge=0, le=10_000, description="horizontale Genauigkeit in m")

    @field_validator("ts")
    @classmethod
    def _epoch(cls, v):
        if isinstance(v, dt.datetime):
            v = (v if v.tzinfo else v.replace(tzinfo=dt.UTC)).timestamp()
        elif v > 1e11:
            v = v / 1000
        if not TS_MIN <= v <= TS_MAX:
            raise ValueError("Zeitstempel ausserhalb des gültigen Bereichs")
        return v


class MatchRequest(_In):
    points: list[TrackPoint] = Field(min_length=2, max_length=5000)


class MatchResult(BaseModel):
    distance_km: float
    duration_s: float
    confidence: float
    matched_points: int


class RouteRequest(_In):
    model_config = ConfigDict(allow_inf_nan=False, extra="ignore", populate_by_name=True)
    from_: LatLon = Field(alias="from")
    to: LatLon


class RouteResult(BaseModel):
    distance_km: float
    duration_s: float


class ReverseResult(BaseModel):
    label: str | None
    municipality: str | None
    country: str | None


class Suggestion(BaseModel):
    category: str
    purpose: str
    customer_id: str | None
    confidence: float
    reason: str
    source: str = "llm"


class IntelStatus(BaseModel):
    geo_match: bool
    geo_reverse: bool
    llm: bool
    vision: bool


class ScanRequest(_In):
    image_b64: str = Field(min_length=4, max_length=vision.MAX_IMAGE_B64 + 4096,
                           description="JPEG/PNG als Base64 (dekodiert max. 2 MiB)")
    kind: vision.ScanKind


class ScanResult(BaseModel):
    liters: float | None
    amount: float | None
    price_per_liter: float | None
    km: int | None
    date: str | None
    station: str | None
    confidence: float
    reason: str


# ---------- Endpunkte ----------
@router.get("/api/intel/status", response_model=IntelStatus)
def intel_status(_: CurrentUser):
    """Nur ob die Dienste konfiguriert sind (keine URLs, keine Erreichbarkeitsprüfung)."""
    return {**geo.status(), "llm": classify.configured(), "vision": vision.configured()}


@router.post("/api/geo/match", response_model=MatchResult)
def geo_match(req: MatchRequest, _: GeoUser):
    pts = [geo.Point(p.lat, p.lon, int(p.ts), p.accuracy) for p in req.points]
    try:
        return geo.match(pts)
    except InvalidTrack as e:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, str(e)) from e
    except GeoNoResult as e:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, str(e)) from e
    except (GeoUnavailable, UpstreamError) as e:
        raise _upstream(e, "Geo-Dienst") from e


@router.post("/api/geo/route", response_model=RouteResult)
def geo_route(req: RouteRequest, _: GeoUser):
    try:
        return geo.route(req.from_.lat, req.from_.lon, req.to.lat, req.to.lon)
    except GeoNoResult as e:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, str(e)) from e
    except (GeoUnavailable, UpstreamError) as e:
        raise _upstream(e, "Geo-Dienst") from e


def _reverse(lat: float, lon: float) -> dict:
    try:
        return geo.reverse(lat, lon)
    except (GeoUnavailable, UpstreamError) as e:
        raise _upstream(e, "Geo-Dienst") from e


@router.post("/api/geo/reverse", response_model=ReverseResult)
def geo_reverse_post(req: LatLon, _: GeoUser):
    """Reverse-Geocoding; Koordinaten im Body (nicht in URL/Access-Log)."""
    return _reverse(req.lat, req.lon)


@router.get("/api/geo/reverse", response_model=ReverseResult, deprecated=True)
def geo_reverse(_: GeoUser, response: Response,
                lat: Annotated[float, Query(ge=-90, le=90, allow_inf_nan=False)],
                lon: Annotated[float, Query(ge=-180, le=180, allow_inf_nan=False)]):
    """Veraltet: POST verwenden. Das Zugriffslog enthält keine Query-Strings (logfilter)."""
    response.headers["Deprecation"] = "true"
    return _reverse(lat, lon)


@router.post("/api/t/{tenant}/trips/suggest", response_model=Suggestion,
             responses={204: {"description": "kein Vorschlag"}})
def trips_suggest(req: SuggestRequest, user: Annotated[User, Depends(write_access)]):
    if req.trip.private_mode:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "Privatfahrten werden nicht an das LLM gesendet")
    if not classify.configured():
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "LLM nicht konfiguriert")
    limiter.check(f"suggest:{user.sub}", _limit("INTEL_RATE_SUGGEST", 60))
    try:
        result = classify.suggest(req)
    except PrivateTrip as e:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, str(e)) from e
    except (GeoUnavailable, UpstreamError) as e:
        raise _upstream(e, "LLM") from e
    if result is None:
        return Response(status_code=status.HTTP_204_NO_CONTENT)
    return result


def scan_access(tenant: str, user: CurrentUser) -> User:
    """Vor dem Body: Schreibrecht, Konfiguration und Rate-Limit – ein abgelehnter Aufruf liest und
    parst die bis zu 2.8 MB nicht erst."""
    write_access(tenant, user)
    if not vision.configured():
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "Bildauswertung nicht konfiguriert")
    limiter.check(f"scan:{user.sub}", _limit("INTEL_RATE_SCAN", 20))
    return user


async def _scan_request(request: Request) -> ScanRequest:
    body = await request.body()
    try:
        return ScanRequest.model_validate_json(body)
    except ValidationError as e:
        raise RequestValidationError([{"loc": ("body", *err.get("loc", ())), "msg": err.get("msg", ""),
                                       "type": err.get("type", "")} for err in e.errors()]) from None


@router.post("/api/t/{tenant}/scan", response_model=ScanResult,
             responses={204: {"description": "nichts erkannt"}},
             openapi_extra={"requestBody": {"required": True, "content": {"application/json": {
                 "schema": ScanRequest.model_json_schema()}}}})
async def scan(user: Annotated[User, Depends(scan_access)], request: Request):
    """Werte aus einem Belegfoto lesen (Vorschlag). Das Bild wird weder gespeichert noch protokolliert."""
    req = await _scan_request(request)
    return await run_in_threadpool(_scan, req)


def _scan(req: ScanRequest):
    try:
        raw, mime = vision.decode_image(req.image_b64)
    except vision.InvalidImage as e:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, str(e)) from None
    try:
        result = vision.scan(raw, mime, req.kind)
    except (GeoUnavailable, UpstreamError) as e:
        raise _upstream(e, "Bildauswertung") from None
    if result is None:
        return Response(status_code=status.HTTP_204_NO_CONTENT)
    return result
