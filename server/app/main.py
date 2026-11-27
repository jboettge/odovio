import asyncio
import datetime as dt
import hashlib
import hmac
import json
import logging
import os
import re
import signal
import threading
import time
import unicodedata
import uuid
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager, contextmanager
from dataclasses import dataclass
from typing import Annotated
from urllib.parse import quote

import anyio
from fastapi import BackgroundTasks, Depends, FastAPI, HTTPException, Query, Request, Response, status
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse, PlainTextResponse, StreamingResponse
from sqlalchemy import select, text
from sqlalchemy.exc import IntegrityError, SQLAlchemyError
from sqlalchemy.orm import Session
from starlette.middleware.gzip import DEFAULT_EXCLUDED_CONTENT_TYPES, GZipMiddleware

from . import config, geo, intel, logfilter, members, metrics, models, privacy, runtime, schemas, security, state, web
from .activity import ACTIVITY_LIMIT, ACTIVITY_MAX, activity
from .attachments import EXTENSIONS, StorageError, content_matches, mark_uploaded, max_upload, quota_bytes, storage
from .auth import TENANT_SLUG, User, can_write, get_config, require_user
from .db import engine, get_session, snapshot_session
from .geo import UpstreamError
from .integrity import VerifyBusy, key_id, maybe_anchor, public_key_b64, signing_key, verify_tenant
from .logbook import build_logbook, build_year_report, iter_trips_csv
from .migrate import create_schema, head_revision, known_revisions, schema_state
from .report import build_report
from .schemas import is_month
from .stats import VehicleData, current_km_by_vehicle, load_vehicle, vehicle_stats
from .sync import CHANGES_LIMIT, CHANGES_MAX, ENTITIES, apply_ops, changes_since, snapshot
from .tax import year_report
from .templates import load_templates
from .timeutil import current_month, today
from .trips import PeriodError, check_month, close_period, month_bounds, send_webhook, webhook_url

log = logging.getLogger("fahrzeugbuch")
logfilter.install()          # Zugriffslog ohne Query-Strings
security.install_logging()   # Logs ohne Steuerzeichen, mit Request-ID; Sicherheits-Log als JSON-Zeilen


# ---------- Lebenszyklus ----------
SHUTTING_DOWN = threading.Event()      # SIGTERM empfangen → /health/ready 503, laufende Anfragen enden normal
_thread_limiter = None


def _flag_on_sigterm() -> None:
    """uvicorn fängt SIGTERM selbst ab (Graceful Shutdown); vorgeschaltet nur das Readiness-Flag setzen."""
    try:
        prev = signal.getsignal(signal.SIGTERM)

        def handler(sig, frame):
            SHUTTING_DOWN.set()
            if callable(prev):
                prev(sig, frame)
        signal.signal(signal.SIGTERM, handler)
    except ValueError:          # nicht im Hauptthread (Tests) → nur Flag beim Lifespan-Ende
        pass


def _push_metrics() -> None:
    if (shared := state.shared()) is not None:
        shared.metrics_put(metrics.instance_group(), metrics.WORKER_ID, json.dumps(metrics.snapshot()),
                           3 * _metrics_interval() + 5)


def _metrics_interval() -> float:
    return config.env_float("METRICS_PUSH_S", 5.0, minimum=0.2)


async def _metrics_loop() -> None:
    while True:
        await asyncio.sleep(_metrics_interval())
        try:
            await anyio.to_thread.run_sync(_push_metrics)
        except state.StateUnavailable:
            security.state_error("metrics")


@asynccontextmanager
async def lifespan(_: FastAPI):
    global _thread_limiter
    if os.environ.get("FZB_SERVE") != "1":
        # Direkter uvicorn-Start (ohne app.serve): Prozessmodell und Konfiguration hier prüfen
        runtime.check()
        # Unsichere Konfiguration → Warnungen im Sicherheits-Log (config_warning); STRICT_CONFIG=1 → Abbruch
        security.check_config()
    SHUTTING_DOWN.clear()
    _flag_on_sigterm()
    # Threadpool (sync-Endpunkte, DB, PDF): THREADPOOL_SIZE je Worker
    _thread_limiter = anyio.to_thread.current_default_thread_limiter()
    _thread_limiter.total_tokens = config.env_int("THREADPOOL_SIZE", 40, minimum=1)
    # Mit getrennter App-Rolle (Compose/Kubernetes) migriert ein eigener Lauf (python -m app.migrate);
    # die API darf das nicht. Mehrere Worker mit AUTO_MIGRATE=1: Advisory-Lock (app.migrate).
    if os.environ.get("AUTO_MIGRATE", "1") == "1":
        await anyio.to_thread.run_sync(create_schema, engine)
    task = asyncio.create_task(_metrics_loop()) if state.shared() is not None else None
    try:
        yield
    finally:
        SHUTTING_DOWN.set()
        if task is not None:
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass
            try:
                state.shared().metrics_delete(metrics.instance_group(), metrics.WORKER_ID)
            except state.StateUnavailable:
                pass
        engine.dispose()        # Verbindungen (und damit Session-Advisory-Locks) freigeben


# Bildauswertung: Bild ≤ 2 MiB als Base64 im JSON (≈ 4/3) + Rand für die übrigen Felder
SCAN_MAX_BODY = 4 * ((intel.SCAN_MAX_IMAGE + 2) // 3) + 64 * 1024


MAX_AUTH_HEADER = 8 * 1024


class RequestGuard:
    """ASGI: (1) /api/* ohne Bearer-Header bzw. mit Authorization-Header > 8 KiB → 401 bevor der Body
    gelesen und das Token geparst wird,
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
            authorization = headers.get(b"authorization", b"")
            if len(authorization) > MAX_AUTH_HEADER:
                security.auth_failure("oversized_token")
                return await self._reply(send, 401, b'{"detail":"Token ung\\u00fcltig"}',
                                         [(b"www-authenticate", b"Bearer")])
            if not authorization.lower().startswith(b"bearer "):
                security.auth_failure("missing_token")
                return await self._reply(send, 401, b'{"detail":"Token fehlt"}',
                                         [(b"www-authenticate", b"Bearer")])
        max_body = self.limit_for(scope["path"])
        length = headers.get(b"content-length")
        if length is not None and (not length.isdigit() or int(length) > max_body):
            if scope["path"].endswith("/blob"):
                security.event("upload_rejected", status=413, reason="too_large")
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
            if scope["path"].endswith("/blob"):
                security.event("upload_rejected", status=413, reason="too_large")
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


class ApiGZip:
    """GZip nur für /api/*-Antworten ≥ GZIP_MIN_BYTES (1 KiB) bei Accept-Encoding gzip; nicht für Belegdateien
    (…/blob), PDF und bereits komprimierte Typen. Stufe GZIP_LEVEL (5: gutes Verhältnis CPU/Grösse)."""

    EXCLUDED = (*DEFAULT_EXCLUDED_CONTENT_TYPES, "application/pdf", "application/octet-stream", "image/heic")

    def __init__(self, app):
        self.app = app
        self.gzip = GZipMiddleware(app, minimum_size=config.env_int("GZIP_MIN_BYTES", 1024, minimum=1),
                                   compresslevel=config.env_int("GZIP_LEVEL", 5, minimum=1, maximum=9),
                                   exclude_content_types=self.EXCLUDED)

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http" and scope["path"].startswith("/api/") and not scope["path"].endswith("/blob"):
            return await self.gzip(scope, receive, send)
        return await self.app(scope, receive, send)


# Reihenfolge (aussen → innen): MetricsMiddleware (Dauer/Status je Route) → SecurityMiddleware (Request-ID, Host,
# IP-Sperre/Rate-Limit, CORS/CSRF, Header) → WebSecurityHeaders (CSP für das Frontend) → RequestGuard (Bearer
# vorhanden, Body-Limits, no-store) → JsonGuard (JSON-Tiefe/-Elemente vor dem Parsen) → ApiGZip → App
app.add_middleware(ApiGZip)
app.add_middleware(security.JsonGuard)
app.add_middleware(RequestGuard, max_body=int(os.environ.get("MAX_BODY_BYTES", str(1024 * 1024))),
                   max_upload=max_upload())
app.include_router(intel.router)
app.add_middleware(web.WebSecurityHeaders)
app.add_middleware(security.SecurityMiddleware)
app.add_middleware(metrics.MetricsMiddleware)


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
    role = user.tenants.get(slug) if len(slug) <= 64 and TENANT_SLUG.match(slug) else None
    if role is None:
        security.mark_probe("forbidden_tenant")
        security.event("forbidden_tenant", status=403, tenant=slug, reason="kein Mandantenrecht")
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Kein Zugriff auf diesen Mandanten")
    security.set_tenant(slug)
    return Access(_get_or_create_tenant(db, slug), role, user)


TenantAccess = Annotated[Access, Depends(tenant_access)]

# ---------- Pfadparameter (strikt, nach Anmeldung und Mandantenprüfung) ----------
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")


def _not_found(detail: str) -> HTTPException:
    """404 für unbekannte/fremde/ungültige IDs – zählt als Probing (Brute-Force-Sperre)."""
    security.mark_probe("unknown_id")
    return HTTPException(status.HTTP_404_NOT_FOUND, detail)


def _uuid_or_404(value: str, detail: str) -> str:
    if not UUID_RE.match(value):
        raise _not_found(detail)
    return value.lower()


def vehicle_id(vid: str, _: TenantAccess) -> str:
    return _uuid_or_404(vid, "Fahrzeug nicht gefunden")


def attachment_id(aid: str, _: TenantAccess) -> str:
    return _uuid_or_404(aid, "Beleg nicht gefunden")


def month_path(month: str, _: TenantAccess) -> str:
    return _month(month)


def member_id(member_id: str, _: TenantAccess) -> str:
    if not members.MEMBER_ID.match(member_id):
        raise _not_found("Mitglied nicht gefunden")
    return member_id


VehicleId = Annotated[str, Depends(vehicle_id)]
AttachmentId = Annotated[str, Depends(attachment_id)]
MonthPath = Annotated[str, Depends(month_path)]
MemberId = Annotated[str, Depends(member_id)]


def _vehicle_or_404(db: Session, access: Access, vid: str, **kw) -> VehicleData:
    """404 nur, wenn das Fahrzeug nie existiert hat bzw. einem anderen Mandanten gehört (Berichte:
    allow_deleted=True → auch stornierte Fahrzeuge)."""
    data = load_vehicle(db, access.tenant.id, vid, **kw) if UUID_RE.match(vid) else None
    if data is None:
        raise _not_found("Fahrzeug nicht gefunden")
    return data


def _rate(access: Access, name: str, env: str, default: int) -> None:
    """Rate-Limit je Benutzer (RateLimiter aus intel, 429 mit Retry-After)."""
    intel.limiter.check(f"{name}:{access.user.sub}", intel.env_limit(env, default))


def _report_rate(access: Access) -> None:
    _rate(access, "report", "RATE_REPORTS", 20)


def _require_write(access: Access) -> None:
    if not access.writable:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Nur Lesezugriff auf diesen Mandanten")


def _require_admin_web(access: Access) -> None:
    """Mitgliederverwaltung: Rolle admin UND Token des Web-Frontends (azp = OIDC_WEB_CLIENT_ID)."""
    if access.role != "admin":
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Nur für Verwalter dieses Mandanten")
    if not access.user.web:
        security.event("web_only_violation", status=403, reason="Mitgliederverwaltung")
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
    clean = "".join(c if c.isprintable() and c not in '"\\/;%' else "_" for c in filename).replace(" ", "_")
    clean = unicodedata.normalize("NFC", clean)[:150] or "Fahrzeugbuch.pdf"
    ascii_name = unicodedata.normalize("NFKD", clean).encode("ascii", "ignore").decode() or "Fahrzeugbuch.pdf"
    ascii_name = "".join(c if c.isprintable() and c not in '"\\/;%' else "_" for c in ascii_name)
    if disposition not in ("attachment", "inline"):
        disposition = "attachment"
    return f'{disposition}; filename="{ascii_name}"; filename*=UTF-8\'\'{quote(clean, safe="")}'


# ---------- PDF: Gleichzeitigkeit je Worker ----------
_pdf_lock = threading.Lock()
_pdf_slots: threading.BoundedSemaphore | None = None
_pdf_busy = 0
_pdf_waiting = 0
PDF_WAIT_MAX_S = 1.0


def _pdf_busy_error() -> HTTPException:
    return HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "Berichtserzeugung ausgelastet – bitte erneut",
                         headers={"Retry-After": "5"})


@contextmanager
def pdf_slot():
    """PDF_CONCURRENCY (2) gleichzeitige PDF-Erzeugungen je Worker (Speicherspitzen). Weitere warten höchstens
    PDF_WAIT_S (Default 1 s, max. 1 s) und nur, solange höchstens PDF_QUEUE (Default 2 × PDF_CONCURRENCY)
    Anfragen warten – sonst sofort 503 mit Retry-After. So blockieren wartende PDF-Anfragen nie den Threadpool
    der übrigen sync-Endpunkte (/sync, /changes …)."""
    global _pdf_slots, _pdf_busy, _pdf_waiting
    concurrency = config.env_int("PDF_CONCURRENCY", 2, minimum=1)
    with _pdf_lock:
        if _pdf_slots is None:
            _pdf_slots = threading.BoundedSemaphore(concurrency)
    if not _pdf_slots.acquire(blocking=False):
        with _pdf_lock:
            if _pdf_waiting >= config.env_int("PDF_QUEUE", 2 * concurrency, minimum=0):
                raise _pdf_busy_error()
            _pdf_waiting += 1
        try:
            got = _pdf_slots.acquire(timeout=min(config.env_float("PDF_WAIT_S", PDF_WAIT_MAX_S), PDF_WAIT_MAX_S))
        finally:
            with _pdf_lock:
                _pdf_waiting -= 1
        if not got:
            raise _pdf_busy_error()
    with _pdf_lock:
        _pdf_busy += 1
    try:
        yield
    finally:
        with _pdf_lock:
            _pdf_busy -= 1
        _pdf_slots.release()


def _gauges() -> list[tuple[str, str, dict, float]]:
    out = []
    pool = engine.pool
    for name, fn, help_ in (("fzb_db_pool_checked_out", "checkedout", "DB-Verbindungen in Benutzung"),
                            ("fzb_db_pool_overflow", "overflow", "DB-Verbindungen über DB_POOL_SIZE"),
                            ("fzb_db_pool_size", "size", "DB-Poolgrösse")):
        if callable(getattr(pool, fn, None)):
            out.append((name, help_, {}, float(getattr(pool, fn)())))
    now = time.monotonic()
    for name, u in geo.UPSTREAMS.items():
        out.append(("fzb_upstream_circuit_open", "Circuit-Breaker gesperrt (1) je Upstream (lokale Sicht)",
                    {"upstream": name}, 1.0 if u.open_until > now else 0.0))
        out.append(("fzb_upstream_active", "laufende Upstream-Anfragen", {"upstream": name}, float(u.active)))
    shared = state.shared()
    out.append(("fzb_state_backend_up", "gemeinsamer Zustand erreichbar (1), memory immer 1",
                {"backend": state.backend_name()}, 0.0 if shared is not None and shared.degraded() else 1.0))
    if _thread_limiter is not None:
        out.append(("fzb_threadpool_busy", "belegte Threads", {}, float(_thread_limiter.borrowed_tokens)))
        out.append(("fzb_threadpool_size", "Threadpool-Grösse", {}, float(_thread_limiter.total_tokens)))
    out.append(("fzb_pdf_in_progress", "laufende PDF-Erzeugungen", {}, float(_pdf_busy)))
    out.append(("fzb_pdf_waiting", "auf einen PDF-Platz wartende Anfragen", {}, float(_pdf_waiting)))
    return out


metrics.register_gauge(_gauges)


# ---------- öffentlich ----------
# Health-Endpunkte sind async: sie laufen in der Event-Loop und hängen nie vom (evtl. ausgelasteten) Threadpool
# der sync-Endpunkte ab. Die DB-Prüfung der Readiness läuft in einem eigenen Mini-Pool mit Zeitlimit.
_health_pool = ThreadPoolExecutor(max_workers=2, thread_name_prefix="fzb-health")


@app.get("/health")
async def health():
    """Leichtgewichtig (keine DB/Netz): "degraded", wenn der gemeinsame Zustand zuletzt nicht erreichbar war."""
    shared = state.shared()
    return {"status": "degraded" if shared is not None and shared.degraded() else "ok"}


@app.get("/health/live", include_in_schema=False)
async def health_live():
    """Liveness: Prozess antwortet (keine Abhängigkeiten)."""
    return {"status": "ok"}


_head: str | None = None
_known: frozenset[str] | None = None


def _schema_state() -> str:
    """ok | compatible_newer | migration_pending | schema_newer (app.migrate.schema_state)."""
    global _head, _known
    if _head is None:
        _head, _known = head_revision(), known_revisions()
    with engine.connect() as conn:
        try:
            current = conn.execute(text("SELECT version_num FROM alembic_version")).scalar()
        except SQLAlchemyError:
            return "migration_pending"
        return schema_state(conn, current, _head, _known)


@app.get("/health/ready", include_in_schema=False)
async def health_ready():
    """Readiness: DB erreichbar, Schema = Alembic head oder ein neuerer, als kompatibel markierter Stand
    (Rolling Update/Rollback, app.migrate), kein SIGTERM. Valkey-Ausfall macht NICHT unbereit (alle Pods teilen
    Valkey – sonst Totalausfall bei dessen Neustart): 200 mit "degraded": true; Rate-Limits laufen dann
    fail-open, Sperren lokal (app.security)."""
    checks = {"shutdown": "ok" if not SHUTTING_DOWN.is_set() else "shutting_down"}
    loop = asyncio.get_running_loop()
    try:
        checks["database"] = await asyncio.wait_for(loop.run_in_executor(_health_pool, _schema_state),
                                                    timeout=config.env_float("HEALTH_DB_TIMEOUT_S", 2.0))
    except (SQLAlchemyError, TimeoutError):
        checks["database"] = "unavailable"
    shared = state.shared()
    if shared is None:
        checks["state"] = "memory"
    else:
        try:
            await shared.aping()
            checks["state"] = "ok"
        except state.StateUnavailable:
            checks["state"] = "unavailable"
    ready = checks["shutdown"] == "ok" and checks["database"] in ("ok", "compatible_newer")
    body = {"status": "ready" if ready else "not_ready", **checks}
    if checks["state"] == "unavailable" or checks["database"] == "compatible_newer":
        body["degraded"] = True
    return JSONResponse(body, status_code=200 if ready else 503)


def _metrics_allowed(request: Request) -> bool:
    token = (os.environ.get("METRICS_TOKEN") or "").strip()
    auth = request.headers.get("authorization") or ""
    if token and auth[:7].lower() == "bearer " and hmac.compare_digest(auth[7:].strip().encode(), token.encode()):
        return True
    if auth:
        security.mark_probe("metrics_token")
    allow = os.environ.get("METRICS_ALLOW") or ""
    ctx = security.current()
    return bool(allow) and ctx is not None and security.in_list(ctx.ip, allow)


@app.get("/metrics", include_in_schema=False)
def get_metrics(request: Request):
    """Prometheus-Textformat; nur mit METRICS_TOKEN (Bearer) oder aus METRICS_ALLOW, sonst 404."""
    if not _metrics_allowed(request):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Nicht gefunden")
    own = metrics.snapshot()
    snaps = [own]
    if (shared := state.shared()) is not None:
        try:
            snaps += [x for x in metrics.snapshots_json(shared.metrics_all(metrics.instance_group()))
                      if x.get("id") != own["id"]]
        except state.StateUnavailable:
            security.state_error("metrics")
    return PlainTextResponse(metrics.render(snaps), media_type="text/plain; version=0.0.4; charset=utf-8",
                             headers={"Cache-Control": "no-store"})


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
def get_stats(vid: VehicleId, access: TenantAccess, db: DB):
    return vehicle_stats(_vehicle_or_404(db, access, vid, allow_deleted=True))


@app.get("/api/t/{tenant}/vehicles/{vid}/report.pdf", response_class=Response)
def get_report(
    vid: VehicleId,
    access: TenantAccess,
    db: DB,
    date_from: Annotated[dt.date | None, Query(alias="from")] = None,
    date_to: Annotated[dt.date | None, Query(alias="to")] = None,
):
    _report_rate(access)
    date_from, date_to = _period(date_from, date_to)
    _vehicle_or_404(db, access, vid, allow_deleted=True, children=False)
    _anchor_and_release(db, access)
    with pdf_slot(), snapshot_session() as s:
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
def trips_check(vid: VehicleId, access: TenantAccess, db: DB, month: Annotated[str, Query(max_length=7)]):
    """km-Kette, Plausibilität und Odometer-Abgleich eines Monats (nur Einträge des Monats laden)."""
    first, last = month_bounds(_month(month))
    data = _vehicle_or_404(db, access, vid, allow_deleted=True, date_from=first, date_to=last, children=False)
    return check_month(db, access.tenant, data, month)


@app.post("/api/t/{tenant}/vehicles/{vid}/periods/{month}/close")
def period_close(vid: VehicleId, month: MonthPath, req: schemas.CloseRequest, access: TenantAccess, db: DB,
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
def get_logbook(vid: VehicleId, access: TenantAccess, db: DB, month: MonthQ = None,
                date_from: DateFrom = None, date_to: DateTo = None):
    _report_rate(access)
    if month is None and date_from is None and date_to is None:
        month = current_month()
    date_from, date_to = _period(date_from, date_to, month, max_days=LOGBOOK_MAX_DAYS)
    _vehicle_or_404(db, access, vid, allow_deleted=True, children=False)
    _anchor_and_release(db, access)
    with pdf_slot(), snapshot_session() as s:
        tenant = s.get(models.Tenant, access.tenant.id)
        data = _vehicle_or_404(s, access, vid, allow_deleted=True, children=False)
        pdf = build_logbook(s, tenant, data, date_from, date_to, access.user.name,
                            mask_private=access.masked)
    return Response(pdf, media_type="application/pdf", headers={"Content-Disposition": content_disposition(
        f"Fahrtenbuch_{data.vehicle.name}_{month or f'{date_from}_{date_to}'}.pdf")})


def _csv_rows(access: Access, vid: str, date_from: dt.date, date_to: dt.date):
    """CSV blockweise aus einem Snapshot (Sitzung lebt bis zum letzten Block)."""
    with snapshot_session() as s:
        tenant = s.get(models.Tenant, access.tenant.id)
        data = _vehicle_or_404(s, access, vid, allow_deleted=True, children=False)
        yield from iter_trips_csv(s, tenant, data, date_from, date_to, mask_private=access.masked)


@app.get("/api/t/{tenant}/vehicles/{vid}/trips.csv", response_class=Response)
def get_trips_csv(vid: VehicleId, access: TenantAccess, db: DB, date_from: DateFrom = None, date_to: DateTo = None):
    _report_rate(access)
    date_from, date_to = _period(date_from, date_to, max_days=LOGBOOK_MAX_DAYS)
    name = _vehicle_or_404(db, access, vid, allow_deleted=True, children=False).vehicle.name
    _release(db)
    return StreamingResponse(_csv_rows(access, vid, date_from, date_to), media_type="text/csv; charset=utf-8",
                             headers={"Content-Disposition": content_disposition(
                                 f"Fahrten_{name}_{date_from}_{date_to}.csv")})


YearQ = Annotated[int | None, Query(ge=2000, le=2100)]


@app.get("/api/t/{tenant}/vehicles/{vid}/year-report")
def get_year_report(vid: VehicleId, access: TenantAccess, db: DB, year: YearQ = None):
    _report_rate(access)
    data = _vehicle_or_404(db, access, vid, allow_deleted=True)
    return year_report(db, access.tenant, data, year or today().year)


@app.get("/api/t/{tenant}/vehicles/{vid}/year-report.pdf", response_class=Response)
def get_year_report_pdf(vid: VehicleId, access: TenantAccess, db: DB, year: YearQ = None):
    _report_rate(access)
    year = year or today().year
    _vehicle_or_404(db, access, vid, allow_deleted=True, children=False)
    _anchor_and_release(db, access)
    with pdf_slot(), snapshot_session() as s:
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
        raise _not_found("Beleg nicht gefunden") from None
    att = db.get(models.Attachment, aid)
    if att is None or att.tenant_id != access.tenant.id:   # fremder Mandant → wie nicht vorhanden
        raise _not_found("Beleg nicht gefunden")
    return att


def _storage_unavailable() -> HTTPException:
    return HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "Belegspeicher nicht erreichbar",
                         headers={"Retry-After": "30"})


def _existing_blob(st, db: Session, access: Access, att: models.Attachment):
    if st.sha256(access.tenant.id, att.id) == att.sha256:
        mark_uploaded(db, access.tenant.id, att.id, att.sha256)
        return JSONResponse({"stored": True, "existing": True}, status_code=status.HTTP_200_OK)
    log.error("Beleg %s: gespeicherte Datei weicht von der Prüfsumme ab – nicht überschrieben", att.id)
    raise _upload_rejected(status.HTTP_409_CONFLICT, "Datei existiert bereits mit anderem Inhalt", "exists")


def _upload_rejected(code: int, detail: str, reason: str) -> HTTPException:
    security.event("upload_rejected", status=code, reason=reason)
    return HTTPException(code, detail)


def _media_type(value: str | None) -> str:
    return (value or "").split(";", 1)[0].strip().lower()


@app.put("/api/t/{tenant}/attachments/{aid}/blob", status_code=status.HTTP_201_CREATED,
         responses={200: {"description": "Datei war bereits gespeichert (gleiche Prüfsumme)"}})
def put_attachment_blob(aid: AttachmentId, request: Request, background: BackgroundTasks, db: DB,
                        access: Annotated[Access, Depends(_write_access)],
                        body: Annotated[bytes, Depends(_raw_body)]):
    """Datei zu bestehenden Beleg-Metadaten hochladen (Roh-Body, Content-Type = mime der Metadaten).
    Idempotent; eine gespeicherte Datei wird nie überschrieben."""
    att = _attachment_or_404(db, access, aid)
    if len(body) > schemas.MAX_ATTACHMENT_BYTES:
        raise _upload_rejected(status.HTTP_413_CONTENT_TOO_LARGE, "Anfrage zu gross", "too_large")
    if _media_type(request.headers.get("content-type")) != att.mime:
        raise _upload_rejected(status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
                               "Content-Type entspricht nicht dem Beleg (mime)", "content_type")
    if not content_matches(att.mime, body):
        raise _upload_rejected(status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
                               f"Dateiinhalt ist kein {EXTENSIONS.get(att.mime, att.mime).upper()} (Magic Bytes)",
                               "magic_bytes")
    if len(body) != att.size:
        raise _upload_rejected(status.HTTP_422_UNPROCESSABLE_CONTENT, "Grösse stimmt nicht", "size")
    if hashlib.sha256(body).hexdigest() != att.sha256:
        raise _upload_rejected(status.HTTP_422_UNPROCESSABLE_CONTENT, "Prüfsumme stimmt nicht", "sha256")
    try:
        st = storage()
        if st.exists(access.tenant.id, att.id):
            return _existing_blob(st, db, access, att)
        if att.deleted:
            raise _upload_rejected(status.HTTP_409_CONFLICT, "Beleg storniert", "deleted")
        quota = quota_bytes()
        if st.usage(access.tenant.id) + len(body) > quota:
            raise _upload_rejected(status.HTTP_507_INSUFFICIENT_STORAGE,
                                   f"Speicherkontingent für Belege erschöpft (max. {quota // (1024 * 1024)} MB je "
                                   "Mandant)", "quota")
        if not st.put(access.tenant.id, att.id, body, att.mime, att.sha256):   # parallel gespeichert
            return _existing_blob(st, db, access, att)
    except StorageError as e:
        raise _storage_unavailable() from e
    except OSError as e:
        log.error("Beleg %s: Speichern fehlgeschlagen (%s)", att.id, type(e).__name__)
        raise HTTPException(status.HTTP_507_INSUFFICIENT_STORAGE, "Datei konnte nicht gespeichert werden") from e
    mark_uploaded(db, access.tenant.id, att.id, att.sha256)    # Existenz belegt → späteres Fehlen ist ein Befund
    if url := webhook_url():
        background.add_task(send_webhook, url, {
            "event": "attachment.uploaded", "tenant": access.tenant.slug, "attachment_id": att.id,
            "kind": att.kind, "fuel_id": att.fuel_id, "maintenance_id": att.maintenance_id,
            "mime": att.mime, "sha256": att.sha256,
            "download_path": f"/api/t/{access.tenant.slug}/attachments/{att.id}/blob",
        })
    return {"stored": True, "existing": False}


@app.get("/api/t/{tenant}/attachments/{aid}/blob", response_class=FileResponse)
def get_attachment_blob(aid: AttachmentId, access: TenantAccess, db: DB):
    """Datei eines Belegs (auch stornierter Belege: revisionssicher abrufbar)."""
    att = _attachment_or_404(db, access, aid)
    name = f"Beleg_{att.kind}_{att.id[:8]}.{EXTENSIONS.get(att.mime, 'bin')}"
    _release(db)
    try:
        return storage().response(access.tenant.id, att.id, att.mime, {
            "Content-Disposition": content_disposition(name, "inline"),
            "X-Content-Type-Options": "nosniff",
            "Content-Security-Policy": "default-src 'none'; sandbox",
            "Cache-Control": "no-store",
            "ETag": f'"{att.sha256}"',
        })
    except StorageError as e:
        raise _storage_unavailable() from e


# ---------- Revisionssicherheit ----------
@app.get("/api/t/{tenant}/history/{entity}/{eid}", response_model=list[schemas.RevisionOut])
def get_history(entity: str, eid: str, access: TenantAccess, db: DB):
    if entity not in ENTITIES:
        raise _not_found("Unbekannter Objekttyp")
    eid = _uuid_or_404(eid, "Objekt nicht gefunden")
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


# ?full=1 → 409 in Folge je Mandant (je Worker); ab VERIFY_BUSY_ALERT als Warnung im Sicherheits-Log: eine
# Vollprüfung, die nie zustande kommt, kann auf einen festgehaltenen Advisory-Lock hindeuten (s. integrity)
VERIFY_BUSY_ALERT = 3
_verify_busy: dict[int, int] = {}
_verify_busy_lock = threading.Lock()


def _verify_busy_count(tenant_id: int, busy: bool) -> int:
    with _verify_busy_lock:
        n = _verify_busy[tenant_id] = _verify_busy.get(tenant_id, 0) + 1 if busy else 0
        return n


@app.get("/api/t/{tenant}/audit/verify", response_model=schemas.AuditResult)
def audit_verify(access: TenantAccess, db: DB, full: Annotated[bool, Query()] = False):
    """Integritätsprüfung in einem konsistenten Snapshot; inkrementell ab dem zuletzt bestätigten Stand,
    `full=1` erzwingt die Vollprüfung (Kette + alle Belegdateien)."""
    _rate(access, "verify", "RATE_VERIFY", 10)
    _release(db)
    try:
        result = verify_tenant(access.tenant.id, full)
    except VerifyBusy:
        n = _verify_busy_count(access.tenant.id, True)
        security.event("verify_full_busy", status=409, reason=f"Vollprüfung läuft bereits ({n}× in Folge)",
                       count=n, warn=n >= VERIFY_BUSY_ALERT)
        raise HTTPException(status.HTTP_409_CONFLICT, "Vollprüfung dieses Mandanten läuft bereits",
                            headers={"Retry-After": "30"}) from None
    if full:
        _verify_busy_count(access.tenant.id, False)
    return result


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
    out = _member_change(db, tenant, lambda t: members.add_member(db, t, access.user, kc, req.user, req.role,
                                                                  is_admin=True))
    security.event("admin_action", status=201, reason="member_add", target=out["id"], role=req.role)
    return out


@app.patch("/api/t/{tenant}/members/{member_id}", response_model=schemas.Member)
def patch_member(member_id: MemberId, req: schemas.MemberUpdate, access: TenantAccess, db: DB):
    kc, tenant = _member_admin(access, db)
    out = _member_change(db, tenant, lambda t: members.change_role(db, t, access.user, kc, member_id, req.role,
                                                                   is_admin=True))
    security.event("admin_action", status=200, reason="member_role", target=member_id, role=req.role)
    return out


@app.delete("/api/t/{tenant}/members/{member_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_member(member_id: MemberId, access: TenantAccess, db: DB):
    kc, tenant = _member_admin(access, db)
    _member_change(db, tenant, lambda t: members.remove_member(db, t, access.user, kc, member_id))
    security.event("admin_action", status=204, reason="member_remove", target=member_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


# Web-Frontend (SPA) – als letzte Route, damit alle API-Routen Vorrang haben
app.include_router(web.router)
