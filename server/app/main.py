import datetime as dt
import json
from contextlib import asynccontextmanager
from dataclasses import dataclass
from typing import Annotated

from fastapi import Depends, FastAPI, HTTPException, Query, Response, status
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from . import models, schemas
from .audit import install_triggers, verify_chain
from .auth import TENANT_SLUG, User, get_config, require_user
from .db import Base, engine, get_session
from .report import build_report
from .stats import load_vehicle, vehicle_stats
from .sync import ENTITIES, apply_ops, changes_since
from .templates import load_templates


@asynccontextmanager
async def lifespan(_: FastAPI):
    Base.metadata.create_all(engine)
    install_triggers(engine)
    yield


app = FastAPI(title="Fahrzeugbuch", version="2.0.0", lifespan=lifespan)
DB = Annotated[Session, Depends(get_session)]
CurrentUser = Annotated[User, Depends(require_user)]


@dataclass
class Access:
    tenant: models.Tenant
    role: str
    user: User


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


def _vehicle_or_404(db: Session, access: Access, vid: str):
    data = load_vehicle(db, access.tenant.id, vid)
    if data is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Fahrzeug nicht gefunden")
    return data


# ---------- öffentlich ----------
@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/auth/config", response_model=schemas.AuthConfig)
def auth_config():
    """OIDC-Parameter für die App (nur die Server-URL muss konfiguriert werden)."""
    cfg = get_config()
    return {"issuer": cfg.issuer, "client_id": cfg.client_id, "scopes": "openid profile offline_access"}


# ---------- Benutzer / Mandanten ----------
@app.get("/api/me", response_model=schemas.Me)
def me(user: CurrentUser):
    return {
        "sub": user.sub,
        "name": user.name,
        "tenants": [{"slug": s, "role": r} for s, r in sorted(user.tenants.items())],
    }


@app.get("/api/checklist-templates", response_model=list[schemas.ChecklistTemplate])
def checklist_templates(_: CurrentUser):
    return load_templates()


# ---------- Sync ----------
@app.get("/api/t/{tenant}/changes", response_model=schemas.Changes)
def get_changes(access: TenantAccess, db: DB, since: Annotated[int, Query(ge=0)] = 0):
    db.refresh(access.tenant)
    return changes_since(db, access.tenant, since)


@app.post("/api/t/{tenant}/sync", response_model=schemas.SyncResponse)
def post_sync(req: schemas.SyncRequest, access: TenantAccess, db: DB):
    if access.role != "write":
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Nur Lesezugriff auf diesen Mandanten")
    # Mandantenzeile sperren → Revisionskette wird strikt sequenziell fortgeschrieben
    # populate_existing: frisch lesen statt veraltetem Stand aus der Identity-Map
    tenant = db.scalar(
        select(models.Tenant).where(models.Tenant.id == access.tenant.id)
        .with_for_update().execution_options(populate_existing=True)
    )
    results = apply_ops(db, tenant, access.user, req.ops)
    db.commit()
    return {"results": results, "cursor": tenant.seq}


# ---------- Auswertungen ----------
@app.get("/api/t/{tenant}/vehicles")
def list_vehicles(access: TenantAccess, db: DB):
    q = select(models.Vehicle).where(models.Vehicle.tenant_id == access.tenant.id, models.Vehicle.deleted.is_(False))
    out = []
    for v in db.scalars(q.order_by(models.Vehicle.name)):
        data = load_vehicle(db, access.tenant.id, v.id)
        out.append({"id": v.id, "name": v.name, "plate": v.plate, "current_km": data.current_km})
    return out


@app.get("/api/t/{tenant}/vehicles/{vid}/stats", response_model=schemas.Stats)
def get_stats(vid: str, access: TenantAccess, db: DB):
    return vehicle_stats(_vehicle_or_404(db, access, vid))


@app.get("/api/t/{tenant}/vehicles/{vid}/report.pdf", response_class=Response)
def get_report(
    vid: str,
    access: TenantAccess,
    db: DB,
    date_from: Annotated[dt.date | None, Query(alias="from")] = None,
    date_to: Annotated[dt.date | None, Query(alias="to")] = None,
):
    data = _vehicle_or_404(db, access, vid)
    date_to = date_to or dt.date.today()
    date_from = date_from or date_to.replace(month=1, day=1)
    if date_from > date_to:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "Zeitraum ungültig")
    pdf = build_report(db, access.tenant, data, date_from, date_to, access.user.name)
    filename = f"fahrzeugbuch_{data.vehicle.name}_{date_from}_{date_to}.pdf".replace(" ", "_")
    return Response(pdf, media_type="application/pdf",
                    headers={"Content-Disposition": f'attachment; filename="{filename}"'})


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
    return [{**{f: getattr(r, f) for f in schemas.RevisionOut.model_fields if f != "data"},
             "data": json.loads(r.data)} for r in db.scalars(q)]


@app.get("/api/t/{tenant}/audit/verify", response_model=schemas.AuditResult)
def audit_verify(access: TenantAccess, db: DB):
    db.refresh(access.tenant)
    return verify_chain(db, access.tenant)
