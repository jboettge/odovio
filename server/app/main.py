import datetime as dt
import hashlib
import json
import logging
import os
import unicodedata
import uuid
from contextlib import asynccontextmanager
from dataclasses import dataclass
from typing import Annotated
from urllib.parse import quote

from fastapi import BackgroundTasks, Depends, FastAPI, HTTPException, Query, Request, Response, status
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError, SQLAlchemyError
from sqlalchemy.orm import Session

from . import intel, logfilter, members, models, privacy, schemas, web
from .activity import ACTIVITY_LIMIT, ACTIVITY_MAX, activity
from .attachments import (
    EXTENSIONS,
    blob_path,
    content_matches,
    file_sha256,
    max_upload,
    quota_bytes,
    store_blob,
    tenant_usage,
)
from .auth import TENANT_SLUG, User, can_write, get_config, require_user
from .db import engine, get_session, snapshot_session
from .geo import UpstreamError
from .integrity import key_id, maybe_anchor, public_key_b64, signing_key, verify_tenant
from .logbook import build_logbook, build_year_report, trips_csv
from .migrate import create_schema
from .report import build_report
from .schemas import is_month
from .stats import VehicleData, current_km_by_vehicle, load_vehicle, vehicle_stats
from .sync import CHANGES_LIMIT, CHANGES_MAX, ENTITIES, apply_ops, changes_since, snapshot
from .tax import year_report
from .templates import load_templates
from .timeutil import current_month, today
from .trips import PeriodError, check_month, close_period, month_bounds, send_webhook, webhook_url

log = logging.getLogger("fahrzeugbuch")
logfilter.install()    # Zugriffslog ohne Query-Strings


@asynccontextmanager
async def lifespan(_: FastAPI):
    # Mit getrennter App-Rolle (Compose) migriert der Dienst "migrate"; die API darf das nicht.
    if os.environ.get("AUTO_MIGRATE", "1") == "1":
        create_schema(engine)
    if os.environ.get("DEFAULT_TENANT") and not os.environ.get("OIDC_REQUIRED_ROLE"):
        log.warning("DEFAULT_TENANT ohne OIDC_REQUIRED_ROLE: jeder Realm-Benutzer erhält Schreibzugriff")
    if signing_key() is None:
        log.warning("ANCHOR_SIGNING_KEY fehlt: Hash-Kette wird nicht signiert verankert")
    yield


# Bildauswertung: Bild ≤ 2 MiB als Base64 im JSON (≈ 4/3) + Rand für die übrigen Felder
SCAN_MAX_BODY = 4 * ((intel.SCAN_MAX_IMAGE + 2) // 3) + 64 * 1024


class RequestGuard:
    """ASGI: (1) /api/* ohne Bearer-Header → 401 bevor der Body gelesen wird,
    (2) Body-Grösse begrenzen (Content-Length und tatsächlich gestreamte Bytes),
    (3) alle /api/*-Antworten mit `Cache-Control: no-store` (keine Mandantendaten in Geräte-/Proxy-Caches).
    Belegdateien (…/blob) dürfen bis `max_upload`, die Bildauswertung (…/scan) bis SCAN_MAX_BODY,
    alle übrigen Pfade bis `max_body`."""

    def __init__(self, app, max_body: int, max_upload: int | None = None):
        self.app, self.max_body = app, max_body
        self.max_upload = max_upload if max_upload is not None else max_body

    def limit_for(self, path: str) -> int:
        if path.startswith("/api/") and path.endswith("/blob"):
            return self.max_upload
        if path.startswith("/api/") and path.endswith("/scan"):
            return max(self.max_body, SCAN_MAX_BODY)
        return self.max_body

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        headers = dict(scope.get("headers") or [])
        if scope["path"].startswith("/api/"):
            send = _no_store(send)
            if not headers.get(b"authorization", b"").lower().startswith(b"bearer "):
                return await self._reply(send, 401, b'{"detail":"Token fehlt"}',
                                         [(b"www-authenticate", b"Bearer")])
        max_body = self.limit_for(scope["path"])
        length = headers.get(b"content-length")
        if length is not None and (not length.isdigit() or int(length) > max_body):
            return await self._reply(send, 413, b'{"detail":"Anfrage zu gross"}')
        received = 0

        async def limited():
            nonlocal received
            msg = await receive()
            if msg["type"] == "http.request":
                received += len(msg.get("body", b""))
                if received > max_body:
                    raise _TooLarge
            return msg

        try:
            await self.app(scope, limited, send)
        except _TooLarge:
            await self._reply(send, 413, b'{"detail":"Anfrage zu gross"}')

    @staticmethod
    async def _reply(send, code: int, body: bytes, extra: list | None = None):
        await send({"type": "http.response.start", "status": code,
                    "headers": [(b"content-type", b"application/json"), *(extra or [])]})
        await send({"type": "http.response.body", "body": body})


class _TooLarge(Exception):
    pass


def _no_store(send):
    async def wrapped(msg):
        if msg["type"] == "http.response.start":
            hdrs = [(k, v) for k, v in msg.get("headers", []) if k.lower() not in (b"cache-control", b"pragma")]
            msg = {**msg, "headers": [*hdrs, (b"cache-control", b"no-store"), (b"pragma", b"no-cache")]}
        await send(msg)
    return wrapped


_docs = os.environ.get("DOCS_ENABLED") == "1"
app = FastAPI(title="Fahrzeugbuch", version="2.2.0", lifespan=lifespan,
              docs_url="/docs" if _docs else None, redoc_url=None,
              openapi_url="/openapi.json" if _docs else None)
app.add_middleware(RequestGuard, max_body=int(os.environ.get("MAX_BODY_BYTES", str(1024 * 1024))),
                   max_upload=max_upload())
app.include_router(intel.router)
app.add_middleware(web.WebSecurityHeaders)


@app.exception_handler(RequestValidationError)
async def validation_error(_: Request, exc: RequestValidationError):
    """422 ohne Rückspiegelung der Eingabe: NaN/inf würden sonst die JSON-Antwort sprengen (500)
    und Eingaben (z. B. Koordinaten) landeten in Fehlertexten."""
    errors = [{"loc": list(e.get("loc", [])), "msg": e.get("msg", ""), "type": e.get("type", "")}
              for e in exc.errors()]
    return JSONResponse(status_code=422, content={"detail": errors})
DB = Annotated[Session, Depends(get_session)]
CurrentUser = Annotated[User, Depends(require_user)]


@dataclass
class Access:
    tenant: models.Tenant
    role: str          # "admin" | "write" | "read"
    user: User

    @property
    def writable(self) -> bool:
        return can_write(self.role)

    @property
    def masked(self) -> bool:
        """Leserolle: Privatfahrten/private Orte maskiert."""
        return not self.writable


def _get_or_create_tenant(db: Session, slug: str) -> models.Tenant:
    t = db.scalar(select(models.Tenant).where(models.Tenant.slug == slug))
    if t is not None:
        return t
    try:
        t = models.Tenant(slug=slug, name=slug, seq=0, head_hash=models.GENESIS)
        db.add(t)
        db.commit()
    except IntegrityError:  # parallel angelegt
        db.rollback()
        t = db.scalar(select(models.Tenant).where(models.Tenant.slug == slug))
    return t


def tenant_access(tenant: str, user: CurrentUser, db: DB) -> Access:
    slug = tenant.lower()
    role = user.tenants.get(slug)
    if role is None or not TENANT_SLUG.match(slug):
        raise HTTPException(status.HTTP_403_FORBIDDEN, f"Kein Zugriff auf Mandant {tenant}")
    return Access(_get_or_create_tenant(db, slug), role, user)


TenantAccess = Annotated[Access, Depends(tenant_access)]


def _vehicle_or_404(db: Session, access: Access, vid: str, **kw) -> VehicleData:
    """404 nur, wenn das Fahrzeug nie existiert hat bzw. einem anderen Mandanten gehört (Berichte:
    allow_deleted=True → auch stornierte Fahrzeuge)."""
    data = load_vehicle(db, access.tenant.id, vid, **kw)
    if data is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Fahrzeug nicht gefunden")
    return data


def _rate(access: "Access", name: str, env: str, default: int) -> None:
    """Rate-Limit je Benutzer (RateLimiter aus intel, 429 mit Retry-After)."""
    intel.limiter.check(f"{name}:{access.user.sub}", intel.env_limit(env, default))


def _report_rate(access: "Access") -> None:
    _rate(access, "report", "RATE_REPORTS", 20)


def _require_write(access: Access) -> None:
    if not access.writable:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Nur Lesezugriff auf diesen Mandanten")


def _require_admin_web(access: Access) -> None:
    """Mitgliederverwaltung: Rolle admin UND Token des Web-Frontends (azp = OIDC_WEB_CLIENT_ID)."""
    if access.role != "admin":
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Nur für Verwalter dieses Mandanten")
    if not access.user.web:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Verwaltung nur im Webfrontend")


def _locked_tenant(db: Session, access: Access) -> models.Tenant:
    """Mandantenzeile sperren → Revisionskette wird strikt sequenziell fortgeschrieben.
    populate_existing: frisch lesen statt veraltetem Stand aus der Identity-Map."""
    return db.scalar(select(models.Tenant).where(models.Tenant.id == access.tenant.id)
                     .with_for_update().execution_options(populate_existing=True))


def _anchor_and_release(db: Session, access: Access) -> None:
    """Anker setzen (Bericht referenziert einen signierten Anker) und die Mandantensperre sofort wieder
    freigeben – das Rendern läuft danach ohne Sperre in einem Snapshot."""
    tenant = _locked_tenant(db, access)
    maybe_anchor(db, tenant, force=True)
    db.commit()


def _release(db: Session) -> None:
    """Laufende Transaktion der Anfrage beenden (SQLite: Schreibsperre), bevor lange gelesen wird."""
    db.commit()


def _month(month: str) -> str:
    if not is_month(month):
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "Monat im Format YYYY-MM erwartet")
    return month


LOGBOOK_MAX_DAYS = 366


def _period(date_from: dt.date | None, date_to: dt.date | None, month: str | None = None,
            max_days: int = 3700) -> tuple[dt.date, dt.date]:
    if month is not None:
        return month_bounds(_month(month))
    date_to = date_to or today()
    date_from = date_from or date_to.replace(month=1, day=1)
    if date_from > date_to:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "Zeitraum ungültig")
    if (date_to - date_from).days >= max_days:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, f"Zeitraum zu lang (max. {max_days} Tage)")
    return date_from, date_to


def content_disposition(filename: str, disposition: str = "attachment") -> str:
    """RFC 6266: ASCII-Fallback + UTF-8 (filename*), keine Steuer-/Anführungszeichen."""
    clean = "".join(c if c.isprintable() and c not in '"\\/;' else "_" for c in filename).replace(" ", "_")
    ascii_name = unicodedata.normalize("NFKD", clean).encode("ascii", "ignore").decode() or "Fahrzeugbuch.pdf"
    return f'{disposition}; filename="{ascii_name}"; filename*=UTF-8\'\'{quote(clean)}'


# ---------- öffentlich ----------
@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/auth/config", response_model=schemas.AuthConfig)
def auth_config():
    """OIDC-Parameter für die App (nur die Server-URL muss konfiguriert werden)."""
    cfg = get_config()
    return {"issuer": cfg.issuer, "client_id": cfg.client_id, "web_client_id": cfg.web_client_id,
            "scopes": "openid profile offline_access"}


# ---------- Benutzer / Mandanten ----------
@app.get("/api/me", response_model=schemas.Me)
def me(user: CurrentUser):
    return {
        "sub": user.sub,
        "name": user.name,
        "display_name": user.display_name,
        "tenants": [{"slug": s, "role": r} for s, r in sorted(user.tenants.items())],
    }


@app.get("/api/checklist-templates", response_model=list[schemas.ChecklistTemplate])
def checklist_templates(_: CurrentUser):
    return load_templates()


# ---------- Sync ----------
@app.get("/api/t/{tenant}/changes", response_model=schemas.Changes)
def get_changes(access: TenantAccess, db: DB, since: Annotated[int, Query(ge=0)] = 0,
                limit: Annotated[int, Query(ge=1, le=CHANGES_MAX)] = CHANGES_LIMIT):
    """Änderungen seit `since`, seitenweise: solange `has_more`, mit since=cursor erneut abrufen.
    Leserolle: Privatfahrten und private Orte maskiert."""
    if since == 0:
        _rate(access, "changes0", "RATE_FULL_SYNC", 10)
    db.refresh(access.tenant)
    return changes_since(db, access.tenant, since, limit, mask_private=access.masked)


@app.post("/api/t/{tenant}/sync", response_model=schemas.SyncResponse,
          responses={503: {"description": "Datenbank vorübergehend nicht verfügbar – später erneut senden"}})
def post_sync(req: schemas.SyncRequest, access: TenantAccess, db: DB):
    _require_write(access)
    try:
        tenant = _locked_tenant(db, access)
        results = apply_ops(db, tenant, access.user, req.ops)
        maybe_anchor(db, tenant)
        db.commit()
    except SQLAlchemyError as e:
        # vorübergehend (Verbindung, Serialisierung, Sperre): nichts verwerfen, der Client wiederholt
        db.rollback()
        log.warning("Sync abgebrochen (%s)", type(e).__name__)
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "Datenbank vorübergehend nicht verfügbar",
                            headers={"Retry-After": "30"}) from e
    return {"results": results, "cursor": tenant.seq}


# ---------- Auswertungen ----------
@app.get("/api/t/{tenant}/vehicles")
def list_vehicles(access: TenantAccess, db: DB):
    q = select(models.Vehicle).where(models.Vehicle.tenant_id == access.tenant.id, models.Vehicle.deleted.is_(False))
    kms = current_km_by_vehicle(db, access.tenant.id)
    return [{"id": v.id, "name": v.name, "plate": v.plate, "current_km": max(v.initial_km, kms.get(v.id, 0))}
            for v in db.scalars(q.order_by(models.Vehicle.name))]


@app.get("/api/t/{tenant}/vehicles/{vid}/stats", response_model=schemas.Stats)
def get_stats(vid: str, access: TenantAccess, db: DB):
    return vehicle_stats(_vehicle_or_404(db, access, vid, allow_deleted=True))


@app.get("/api/t/{tenant}/vehicles/{vid}/report.pdf", response_class=Response)
def get_report(
    vid: str,
    access: TenantAccess,
    db: DB,
    date_from: Annotated[dt.date | None, Query(alias="from")] = None,
    date_to: Annotated[dt.date | None, Query(alias="to")] = None,
):
    _report_rate(access)
    date_from, date_to = _period(date_from, date_to)
    _vehicle_or_404(db, access, vid, allow_deleted=True, children=False)
    _anchor_and_release(db, access)
    with snapshot_session() as s:
        tenant = s.get(models.Tenant, access.tenant.id)
        data = _vehicle_or_404(s, access, vid, allow_deleted=True)
        pdf = build_report(s, tenant, data, date_from, date_to, access.user.name)
    return Response(pdf, media_type="application/pdf",
                    headers={"Content-Disposition": content_disposition(
                        f"Fahrzeugbuch_{data.vehicle.name}_{date_from}_{date_to}.pdf")})


# ---------- Fahrtenbuch ----------
DateFrom = Annotated[dt.date | None, Query(alias="from")]
DateTo = Annotated[dt.date | None, Query(alias="to")]
MonthQ = Annotated[str | None, Query(max_length=7)]


@app.get("/api/t/{tenant}/vehicles/{vid}/trips/check")
def trips_check(vid: str, access: TenantAccess, db: DB, month: Annotated[str, Query(max_length=7)]):
    """km-Kette, Plausibilität und Odometer-Abgleich eines Monats (nur Einträge des Monats laden)."""
    first, last = month_bounds(_month(month))
    data = _vehicle_or_404(db, access, vid, allow_deleted=True, date_from=first, date_to=last, children=False)
    return check_month(db, access.tenant, data, month)


@app.post("/api/t/{tenant}/vehicles/{vid}/periods/{month}/close")
def period_close(vid: str, month: str, req: schemas.CloseRequest, access: TenantAccess, db: DB,
                 background: BackgroundTasks):
    """Monatsabschluss (nur abgelaufene Monate, lokale Zeit): Fahrten sperren, Namen einfrieren,
    Abschluss ins Journal, signierten Anker erzwingen."""
    _require_write(access)
    first, last = month_bounds(_month(month))
    if month >= current_month():
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT,
                            "Nur abgelaufene Monate können abgeschlossen werden")
    tenant = _locked_tenant(db, access)
    data = _vehicle_or_404(db, access, vid, date_from=first, date_to=last, children=False)
    try:
        result = close_period(db, tenant, access.user, data, month, req.force, req.reason)
    except PeriodError as e:
        db.rollback()
        raise HTTPException(status.HTTP_409_CONFLICT, e.detail) from e
    db.commit()
    if url := webhook_url():
        background.add_task(send_webhook, url, {
            "tenant": tenant.slug, "vehicle_id": vid, "month": month, "period": result["period"],
            "logbook_pdf_url": f"/api/t/{tenant.slug}/vehicles/{vid}/logbook.pdf?month={month}",
        })
    return result


@app.get("/api/t/{tenant}/vehicles/{vid}/logbook.pdf", response_class=Response)
def get_logbook(vid: str, access: TenantAccess, db: DB, month: MonthQ = None,
                date_from: DateFrom = None, date_to: DateTo = None):
    _report_rate(access)
    if month is None and date_from is None and date_to is None:
        month = current_month()
    date_from, date_to = _period(date_from, date_to, month, max_days=LOGBOOK_MAX_DAYS)
    _vehicle_or_404(db, access, vid, allow_deleted=True, children=False)
    _anchor_and_release(db, access)
    with snapshot_session() as s:
        tenant = s.get(models.Tenant, access.tenant.id)
        data = _vehicle_or_404(s, access, vid, allow_deleted=True, children=False)
        pdf = build_logbook(s, tenant, data, date_from, date_to, access.user.name,
                            mask_private=access.masked)
    return Response(pdf, media_type="application/pdf", headers={"Content-Disposition": content_disposition(
        f"Fahrtenbuch_{data.vehicle.name}_{month or f'{date_from}_{date_to}'}.pdf")})


@app.get("/api/t/{tenant}/vehicles/{vid}/trips.csv", response_class=Response)
def get_trips_csv(vid: str, access: TenantAccess, db: DB, date_from: DateFrom = None, date_to: DateTo = None):
    _report_rate(access)
    date_from, date_to = _period(date_from, date_to, max_days=LOGBOOK_MAX_DAYS)
    _vehicle_or_404(db, access, vid, allow_deleted=True, children=False)
    _release(db)
    with snapshot_session() as s:
        tenant = s.get(models.Tenant, access.tenant.id)
        data = _vehicle_or_404(s, access, vid, allow_deleted=True, children=False)
        body = trips_csv(s, tenant, data, date_from, date_to, mask_private=access.masked)
    return Response(body, media_type="text/csv; charset=utf-8", headers={"Content-Disposition": content_disposition(
        f"Fahrten_{data.vehicle.name}_{date_from}_{date_to}.csv")})


YearQ = Annotated[int | None, Query(ge=2000, le=2100)]


@app.get("/api/t/{tenant}/vehicles/{vid}/year-report")
def get_year_report(vid: str, access: TenantAccess, db: DB, year: YearQ = None):
    _report_rate(access)
    data = _vehicle_or_404(db, access, vid, allow_deleted=True)
    return year_report(db, access.tenant, data, year or today().year)


@app.get("/api/t/{tenant}/vehicles/{vid}/year-report.pdf", response_class=Response)
def get_year_report_pdf(vid: str, access: TenantAccess, db: DB, year: YearQ = None):
    _report_rate(access)
    year = year or today().year
    _vehicle_or_404(db, access, vid, allow_deleted=True, children=False)
    _anchor_and_release(db, access)
    with snapshot_session() as s:
        tenant = s.get(models.Tenant, access.tenant.id)
        data = _vehicle_or_404(s, access, vid, allow_deleted=True)
        pdf = build_year_report(s, tenant, year_report(s, tenant, data, year), access.user.name)
    return Response(pdf, media_type="application/pdf", headers={"Content-Disposition": content_disposition(
        f"Jahresbericht_{data.vehicle.name}_{year}.pdf")})


# ---------- Belege (Dateien) ----------
def _write_access(access: TenantAccess) -> Access:
    """Als Abhängigkeit vor dem Body: Leserolle → 403, ohne den Upload erst einzulesen."""
    _require_write(access)
    return access


async def _raw_body(request: Request) -> bytes:
    return await request.body()


def _attachment_or_404(db: Session, access: Access, aid: str) -> models.Attachment:
    try:
        aid = str(uuid.UUID(aid))
    except ValueError:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Beleg nicht gefunden") from None
    att = db.get(models.Attachment, aid)
    if att is None or att.tenant_id != access.tenant.id:   # fremder Mandant → wie nicht vorhanden
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Beleg nicht gefunden")
    return att


def _media_type(value: str | None) -> str:
    return (value or "").split(";", 1)[0].strip().lower()


@app.put("/api/t/{tenant}/attachments/{aid}/blob", status_code=status.HTTP_201_CREATED,
         responses={200: {"description": "Datei war bereits gespeichert (gleiche Prüfsumme)"}})
def put_attachment_blob(aid: str, request: Request, background: BackgroundTasks, db: DB,
                        access: Annotated[Access, Depends(_write_access)],
                        body: Annotated[bytes, Depends(_raw_body)]):
    """Datei zu bestehenden Beleg-Metadaten hochladen (Roh-Body, Content-Type = mime der Metadaten).
    Idempotent; eine gespeicherte Datei wird nie überschrieben."""
    att = _attachment_or_404(db, access, aid)
    if len(body) > schemas.MAX_ATTACHMENT_BYTES:
        raise HTTPException(status.HTTP_413_CONTENT_TOO_LARGE, "Anfrage zu gross")
    if _media_type(request.headers.get("content-type")) != att.mime:
        raise HTTPException(status.HTTP_415_UNSUPPORTED_MEDIA_TYPE, "Content-Type entspricht nicht dem Beleg (mime)")
    if not content_matches(att.mime, body):
        raise HTTPException(status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
                            f"Dateiinhalt ist kein {EXTENSIONS.get(att.mime, att.mime).upper()} (Magic Bytes)")
    if len(body) != att.size:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "Grösse stimmt nicht")
    if hashlib.sha256(body).hexdigest() != att.sha256:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "Prüfsumme stimmt nicht")
    path = blob_path(access.tenant.id, att.id)
    if path.is_file():
        if file_sha256(path) == att.sha256:
            return JSONResponse({"stored": True, "existing": True}, status_code=status.HTTP_200_OK)
        log.error("Beleg %s: gespeicherte Datei weicht von der Prüfsumme ab – nicht überschrieben", att.id)
        raise HTTPException(status.HTTP_409_CONFLICT, "Datei existiert bereits mit anderem Inhalt")
    if att.deleted:
        raise HTTPException(status.HTTP_409_CONFLICT, "Beleg storniert")
    quota = quota_bytes()
    if tenant_usage(access.tenant.id) + len(body) > quota:
        raise HTTPException(status.HTTP_507_INSUFFICIENT_STORAGE,
                            f"Speicherkontingent für Belege erschöpft (max. {quota // (1024 * 1024)} MB je Mandant)")
    try:
        store_blob(path, body)
    except OSError as e:
        log.error("Beleg %s: Speichern fehlgeschlagen (%s)", att.id, type(e).__name__)
        raise HTTPException(status.HTTP_507_INSUFFICIENT_STORAGE, "Datei konnte nicht gespeichert werden") from e
    if url := webhook_url():
        background.add_task(send_webhook, url, {
            "event": "attachment.uploaded", "tenant": access.tenant.slug, "attachment_id": att.id,
            "kind": att.kind, "fuel_id": att.fuel_id, "maintenance_id": att.maintenance_id,
            "mime": att.mime, "sha256": att.sha256,
            "download_path": f"/api/t/{access.tenant.slug}/attachments/{att.id}/blob",
        })
    return {"stored": True, "existing": False}


@app.get("/api/t/{tenant}/attachments/{aid}/blob", response_class=FileResponse)
def get_attachment_blob(aid: str, access: TenantAccess, db: DB):
    """Datei eines Belegs (auch stornierter Belege: revisionssicher abrufbar)."""
    att = _attachment_or_404(db, access, aid)
    path = blob_path(access.tenant.id, att.id)
    if not path.is_file():
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Datei nicht vorhanden")
    name = f"Beleg_{att.kind}_{att.id[:8]}.{EXTENSIONS.get(att.mime, 'bin')}"
    return FileResponse(path, media_type=att.mime, headers={
        "Content-Disposition": content_disposition(name, "inline"),
        "X-Content-Type-Options": "nosniff",
        "Content-Security-Policy": "default-src 'none'; sandbox",
        "Cache-Control": "no-store",
        "ETag": f'"{att.sha256}"',
    })


# ---------- Revisionssicherheit ----------
@app.get("/api/t/{tenant}/history/{entity}/{eid}", response_model=list[schemas.RevisionOut])
def get_history(entity: str, eid: str, access: TenantAccess, db: DB):
    if entity not in ENTITIES:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Unbekannter Objekttyp")
    q = select(models.Revision).where(
        models.Revision.tenant_id == access.tenant.id,
        models.Revision.entity == entity,
        models.Revision.entity_id == eid,
    ).order_by(models.Revision.seq)
    out = [{**{f: getattr(r, f) for f in schemas.RevisionOut.model_fields if f != "data"},
            "data": json.loads(r.data)} for r in db.scalars(q)]
    if access.masked and out:
        # Leserolle: ist das Objekt heute privat, werden auch ältere Stände maskiert
        model, schema, _ = ENTITIES[entity]
        obj = db.get(model, out[0]["entity_id"])
        force = obj is not None and obj.tenant_id == access.tenant.id and \
            privacy.is_private(entity, snapshot(obj, schema))
        for r in out:
            r["data"] = privacy.mask(entity, r["data"], force)
    return out


@app.get("/api/t/{tenant}/audit/verify", response_model=schemas.AuditResult)
def audit_verify(access: TenantAccess, db: DB, full: Annotated[bool, Query()] = False):
    """Integritätsprüfung in einem konsistenten Snapshot; inkrementell ab dem zuletzt bestätigten Stand,
    `full=1` erzwingt die Vollprüfung (Kette + alle Belegdateien)."""
    _rate(access, "verify", "RATE_VERIFY", 10)
    _release(db)
    return verify_tenant(access.tenant.id, full)


@app.get("/api/t/{tenant}/audit/anchors", response_model=schemas.AnchorList)
def audit_anchors(access: TenantAccess, db: DB):
    """Signierte Anker zur externen Archivierung (z. B. täglich per n8n → Paperless)."""
    key = signing_key()
    q = select(models.Anchor).where(models.Anchor.tenant_id == access.tenant.id).order_by(models.Anchor.seq)
    return {
        "tenant": access.tenant.slug,
        "public_key": public_key_b64(key) if key else None,
        "key_id": key_id(key) if key else None,
        "message_format": "fahrzeugbuch-anchor|<tenant>|<seq>|<head_hash>|<created_at>",
        "anchors": [{c: getattr(a, c) for c in schemas.AnchorOut.model_fields} for a in db.scalars(q)],
    }


# ---------- Gemeinsames Bewirtschaften: Aktivität, Mitglieder ----------
@app.get("/api/t/{tenant}/activity", response_model=schemas.ActivityList)
def get_activity(access: TenantAccess, db: DB,
                 limit: Annotated[int, Query(ge=1, le=ACTIVITY_MAX)] = ACTIVITY_LIMIT,
                 before_seq: Annotated[int | None, Query(ge=1)] = None):
    """Letzte Änderungen (neueste zuerst) als Kurztexte; weiter mit before_seq=next_before_seq.
    Leserolle: Privatfahrten maskiert („Privatfahrt · 22 km“)."""
    _rate(access, "activity", "RATE_ACTIVITY", 60)
    return activity(db, access.tenant.id, limit, before_seq, mask=access.masked)


def _manageable(access: Access) -> bool:
    return access.role == "admin" and access.user.web and members.config() is not None


@app.get("/api/t/{tenant}/members", response_model=schemas.MemberList)
def get_members(access: TenantAccess, db: DB):
    """Mitglieder aus Keycloak (Gruppen des Mandanten) bzw. ohne Keycloak-Admin-Konfiguration die Akteure
    des Journals (role null, source "activity"). E-Mail nur für Verwalter."""
    _rate(access, "members", "RATE_MEMBERS", 30)
    return {"members": members.list_members(db, access.tenant, is_admin=access.role == "admin"),
            "manageable": _manageable(access)}


def _member_admin(access: Access, db: Session) -> tuple[members.KeycloakAdmin, models.Tenant]:
    """Verwalter im Web-Frontend + Keycloak konfiguriert; Mandantenzeile sperren (Änderungen je Mandant
    nacheinander → „letzter Verwalter“ sicher geprüft, Journal sequenziell)."""
    _require_admin_web(access)
    _rate(access, "members-write", "RATE_MEMBERS", 30)
    kc = members.admin_client()
    if kc is None:
        raise HTTPException(status.HTTP_501_NOT_IMPLEMENTED, members.NOT_CONFIGURED)
    return kc, _locked_tenant(db, access)


def _member_change(db: Session, tenant: models.Tenant, fn):
    """Keycloak ändern, dann Journal (Revision „membership“) committen; Fehler → nichts im Journal."""
    try:
        out = fn(tenant)
    except (UpstreamError, members.KeycloakDenied) as e:
        db.rollback()
        raise members.upstream_error(e) from e
    except HTTPException:
        db.rollback()
        raise
    maybe_anchor(db, tenant)
    db.commit()
    return out


@app.post("/api/t/{tenant}/members", response_model=schemas.Member, status_code=status.HTTP_201_CREATED)
def add_member(req: schemas.MemberCreate, access: TenantAccess, db: DB):
    """Benutzer (Benutzername oder E-Mail, muss in Keycloak existieren) mit genau einer Rolle aufnehmen."""
    kc, tenant = _member_admin(access, db)
    return _member_change(db, tenant, lambda t: members.add_member(db, t, access.user, kc, req.user, req.role,
                                                                   is_admin=True))


@app.patch("/api/t/{tenant}/members/{member_id}", response_model=schemas.Member)
def patch_member(member_id: str, req: schemas.MemberUpdate, access: TenantAccess, db: DB):
    kc, tenant = _member_admin(access, db)
    return _member_change(db, tenant, lambda t: members.change_role(db, t, access.user, kc, member_id, req.role,
                                                                    is_admin=True))


@app.delete("/api/t/{tenant}/members/{member_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_member(member_id: str, access: TenantAccess, db: DB):
    kc, tenant = _member_admin(access, db)
    _member_change(db, tenant, lambda t: members.remove_member(db, t, access.user, kc, member_id))
    return Response(status_code=status.HTTP_204_NO_CONTENT)


# Web-Frontend (SPA) – als letzte Route, damit alle API-Routen Vorrang haben
app.include_router(web.router)
