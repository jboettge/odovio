"""„Intelligenz“-Endpunkte: Geo (OSRM/Photon) und LLM-Vorschläge (vLLM).

Einbinden in main.py:  from . import intel;  app.include_router(intel.router)

Bewusst ohne Import aus main.py (kein Zirkelimport): Mandantenrecht wird direkt aus den
Token-Gruppen gelesen (gleiche Logik wie main.tenant_access, aber ohne DB-Zugriff).

Rate-Limits je Benutzer (In-Memory, je Prozess):
  INTEL_RATE_SUGGEST  Anfragen/Minute für /trips/suggest, Default 60
  INTEL_RATE_GEO      Anfragen/Minute für /api/geo/*, Default 300
"""
import datetime as dt
import logging
import os
import threading
import time
from collections import deque
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response, status
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from fastapi.routing import APIRoute
from pydantic import BaseModel, ConfigDict, Field, field_validator

from . import classify, geo
from .auth import TENANT_SLUG, User, require_user
from .classify import PrivateTrip, SuggestRequest
from .geo import GeoNoResult, GeoUnavailable, InvalidTrack, UpstreamError

log = logging.getLogger("fahrzeugbuch.intel")



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


def _limit(name: str, default: int) -> int:
    try:
        v = int(os.environ.get(name) or default)
    except ValueError:
        return default
    return v if v > 0 else default


# ---------- Zugriff ----------
def geo_user(user: CurrentUser) -> User:
    """Geo: irgendein Mandantenrecht (lesen genügt)."""
    if not user.tenants:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Kein Mandant zugeordnet")
    limiter.check(f"geo:{user.sub}", _limit("INTEL_RATE_GEO", 300))
    return user


GeoUser = Annotated[User, Depends(geo_user)]


def write_access(tenant: str, user: CurrentUser) -> User:
    slug = tenant.lower()
    role = user.tenants.get(slug) if TENANT_SLUG.match(slug) else None
    if role is None:
        raise HTTPException(status.HTTP_403_FORBIDDEN, f"Kein Zugriff auf Mandant {tenant}")
    if role != "write":
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Nur Lesezugriff auf diesen Mandanten")
    return user


def _upstream(e: Exception, what: str) -> HTTPException:
    if isinstance(e, GeoUnavailable):
        return HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, f"{what} nicht konfiguriert")
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
            v = (v if v.tzinfo else v.replace(tzinfo=dt.timezone.utc)).timestamp()
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


# ---------- Endpunkte ----------
@router.get("/api/intel/status", response_model=IntelStatus)
def intel_status(_: CurrentUser):
    """Nur ob die Dienste konfiguriert sind (keine URLs, keine Erreichbarkeitsprüfung)."""
    return {**geo.status(), "llm": classify.configured()}


@router.post("/api/geo/match", response_model=MatchResult)
def geo_match(req: MatchRequest, _: GeoUser):
    pts = [geo.Point(p.lat, p.lon, int(p.ts), p.accuracy) for p in req.points]
    try:
        return geo.match(pts)
    except InvalidTrack as e:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, str(e)) from e
    except GeoNoResult as e:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, str(e)) from e
    except (GeoUnavailable, UpstreamError) as e:
        raise _upstream(e, "Geo-Dienst") from e


@router.post("/api/geo/route", response_model=RouteResult)
def geo_route(req: RouteRequest, _: GeoUser):
    try:
        return geo.route(req.from_.lat, req.from_.lon, req.to.lat, req.to.lon)
    except GeoNoResult as e:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, str(e)) from e
    except (GeoUnavailable, UpstreamError) as e:
        raise _upstream(e, "Geo-Dienst") from e


@router.get("/api/geo/reverse", response_model=ReverseResult)
def geo_reverse(_: GeoUser,
                lat: Annotated[float, Query(ge=-90, le=90, allow_inf_nan=False)],
                lon: Annotated[float, Query(ge=-180, le=180, allow_inf_nan=False)]):
    try:
        return geo.reverse(lat, lon)
    except (GeoUnavailable, UpstreamError) as e:
        raise _upstream(e, "Geo-Dienst") from e


@router.post("/api/t/{tenant}/trips/suggest", response_model=Suggestion,
             responses={204: {"description": "kein Vorschlag"}})
def trips_suggest(req: SuggestRequest, user: Annotated[User, Depends(write_access)]):
    if req.trip.private_mode:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "Privatfahrten werden nicht an das LLM gesendet")
    if not classify.configured():
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "LLM nicht konfiguriert")
    limiter.check(f"suggest:{user.sub}", _limit("INTEL_RATE_SUGGEST", 60))
    try:
        result = classify.suggest(req)
    except PrivateTrip as e:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, str(e)) from e
    except (GeoUnavailable, UpstreamError) as e:
        raise _upstream(e, "LLM") from e
    if result is None:
        return Response(status_code=status.HTTP_204_NO_CONTENT)
    return result
