"""Mitglieder eines Mandanten: Keycloak-Gruppen über die Admin-REST-API (optional).

Rollen = Gruppen (Pfad aus TENANT_GROUP_PREFIX):  /fahrzeugbuch/<t> = write, …/<t>/lesen = read,
…/<t>/admin = admin. Ein Mitglied steht in genau EINER der drei Gruppen (Änderungen entfernen die anderen).

Env (alle optional; ohne Client-ID/Secret: nur Anzeige der Akteure aus dem Journal, Änderungen → 501):
  KC_ADMIN_URL            Basis-URL von Keycloak, z. B. https://id.j-mb.net (leer → aus OIDC_ISSUER)
  KC_ADMIN_REALM          Realm der Benutzer/Gruppen (leer → aus OIDC_ISSUER)
  KC_ADMIN_CLIENT_ID      vertraulicher Client mit Service-Account (z. B. fahrzeugbuch-admin-api)
  KC_ADMIN_CLIENT_SECRET  dessen Secret
  KC_ADMIN_TIMEOUT_S      Timeout je Anfrage (Sekunden), Default 5

Client-Credentials-Token wird bis kurz vor Ablauf zwischengespeichert. urllib ohne Weiterleitungen, Antwort-
grösse begrenzt; Gleichzeitigkeit/Circuit-Breaker über geo.Upstream("keycloak").
Änderungen erst in Keycloak, dann als Revision (entity "membership") ins Journal; wirksam werden sie in
den Tokens der Betroffenen nach deren nächster Token-Erneuerung.
"""
import json
import logging
import os
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass

from fastapi import HTTPException, status
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from . import models
from .audit import append_revision
from .auth import ADMIN_SUFFIX, ROLE_RANK, User, group_prefix, higher_role
from .geo import UPSTREAMS, UpstreamBusy, UpstreamError, env_float

log = logging.getLogger("fahrzeugbuch.members")

MAX_RESPONSE_BYTES = 4 * 1024 * 1024
PAGE = 100
MAX_MEMBERS = 2000
GROUP_TTL_S = 300
MEMBER_ID = re.compile(r"^[A-Za-z0-9-]{1,36}$")
ROLE_GROUP_SUFFIX = {"write": None, "read": "lesen", "admin": ADMIN_SUFFIX}
NOT_CONFIGURED = "Mitgliederverwaltung nicht konfiguriert"


class KeycloakDenied(Exception):
    """Service-Account ohne ausreichende Rechte (403) bzw. Token abgelehnt."""


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


_opener = urllib.request.build_opener(_NoRedirect())


@dataclass(frozen=True)
class KCConfig:
    url: str
    realm: str
    client_id: str
    secret: str


def config() -> KCConfig | None:
    client_id = (os.environ.get("KC_ADMIN_CLIENT_ID") or "").strip()
    secret = (os.environ.get("KC_ADMIN_CLIENT_SECRET") or "").strip()
    if not client_id or not secret:
        return None
    issuer = (os.environ.get("OIDC_ISSUER") or "").rstrip("/")
    base, _, realm = issuer.partition("/realms/")
    url = (os.environ.get("KC_ADMIN_URL") or "").strip().rstrip("/") or base
    realm = (os.environ.get("KC_ADMIN_REALM") or "").strip() or realm.split("/")[0]
    if not url or not realm or urllib.parse.urlsplit(url).scheme not in ("http", "https"):
        log.error("KC_ADMIN_URL/KC_ADMIN_REALM ungültig – Mitgliederverwaltung aus")
        return None
    return KCConfig(url, realm, client_id, secret)


class KeycloakAdmin:
    def __init__(self, cfg: KCConfig):
        self.cfg = cfg
        self.lock = threading.Lock()
        self.token: str | None = None
        self.token_until = 0.0
        self.groups: dict[str, tuple[str, float]] = {}
        self.upstream = UPSTREAMS["keycloak"]

    # ---------- HTTP ----------
    def _send(self, method: str, url: str, body: bytes | None, headers: dict) -> tuple[int, bytes, object]:
        req = urllib.request.Request(url, data=body, method=method)
        for k, v in headers.items():
            req.add_header(k, v)
        timeout = env_float("KC_ADMIN_TIMEOUT_S", 5)
        with self.upstream.guard():
            try:
                with _opener.open(req, timeout=timeout) as r:
                    data = r.read(MAX_RESPONSE_BYTES + 1)
                    code, hdrs = r.status, r.headers
            except urllib.error.HTTPError as e:
                if e.code in (401, 403, 404, 409):     # fachliche Antworten, kein Ausfall
                    return e.code, e.read(65536), e.headers
                raise UpstreamError(f"HTTP {e.code}") from e
            except (urllib.error.URLError, OSError, TimeoutError) as e:
                raise UpstreamError(type(e).__name__) from e
        if len(data) > MAX_RESPONSE_BYTES:
            raise UpstreamError("Antwort zu gross")
        return code, data, hdrs

    def _access_token(self, refresh: bool = False) -> str:
        with self.lock:
            if not refresh and self.token and time.monotonic() < self.token_until:
                return self.token
        form = urllib.parse.urlencode({"grant_type": "client_credentials", "client_id": self.cfg.client_id,
                                       "client_secret": self.cfg.secret}).encode()
        url = f"{self.cfg.url}/realms/{urllib.parse.quote(self.cfg.realm, safe='')}/protocol/openid-connect/token"
        code, data, _ = self._send("POST", url, form, {"Content-Type": "application/x-www-form-urlencoded",
                                                         "Accept": "application/json"})
        if code in (401, 403):
            raise KeycloakDenied("Client-Credentials abgelehnt")
        try:
            out = json.loads(data)
            token, ttl = str(out["access_token"]), float(out.get("expires_in") or 60)
        except (ValueError, KeyError, TypeError) as e:
            raise UpstreamError("Token-Antwort ungültig") from e
        with self.lock:
            self.token, self.token_until = token, time.monotonic() + max(5.0, ttl - 30)
        return token

    def call(self, method: str, path: str, payload=None, query: dict | None = None) -> tuple[int, object, object]:
        """Admin-API: /admin/realms/<realm><path>. Gibt (Status, JSON|None, Header) zurück; 401 → einmal mit
        frischem Token wiederholen, 403 → KeycloakDenied."""
        url = f"{self.cfg.url}/admin/realms/{urllib.parse.quote(self.cfg.realm, safe='')}{path}"
        if query:
            url += "?" + urllib.parse.urlencode(query)
        body = None if payload is None else json.dumps(payload).encode()
        for attempt in (0, 1):
            headers = {"Authorization": f"Bearer {self._access_token(refresh=attempt == 1)}",
                       "Accept": "application/json"}
            if body is not None:
                headers["Content-Type"] = "application/json"
            code, data, hdrs = self._send(method, url, body, headers)
            if code != 401:
                break
        if code in (401, 403):
            raise KeycloakDenied(f"{method} {path.split('?')[0]}: HTTP {code}")
        try:
            out = json.loads(data) if data else None
        except ValueError:
            out = None
        return code, out, hdrs

    # ---------- Gruppen ----------
    def group_id(self, path: str) -> str | None:
        hit = self.groups.get(path)
        if hit and time.monotonic() - hit[1] < GROUP_TTL_S:
            return hit[0]
        quoted = "/".join(urllib.parse.quote(p, safe="") for p in path.strip("/").split("/"))
        code, out, _ = self.call("GET", f"/group-by-path/{quoted}")
        if code == 404 or not isinstance(out, dict) or not out.get("id"):
            self.groups.pop(path, None)
            return None
        self.groups[path] = (str(out["id"]), time.monotonic())
        return str(out["id"])

    def ensure_group(self, path: str) -> str:
        gid = self.group_id(path)
        if gid:
            return gid
        parent, _, name = path.strip("/").rpartition("/")
        if parent:
            pid = self.ensure_group("/" + parent)
            code, _, hdrs = self.call("POST", f"/groups/{pid}/children", {"name": name})
        else:
            code, _, hdrs = self.call("POST", "/groups", {"name": name})
        if code not in (200, 201, 204, 409):
            raise UpstreamError(f"Gruppe anlegen: HTTP {code}")
        log.info("Keycloak-Gruppe %s angelegt", path)
        self.groups.pop(path, None)
        gid = self.group_id(path)
        if not gid:
            raise UpstreamError("Gruppe nach dem Anlegen nicht gefunden")
        return gid

    def group_members(self, gid: str) -> list[dict]:
        out: list[dict] = []
        while len(out) < MAX_MEMBERS:
            code, page, _ = self.call("GET", f"/groups/{gid}/members",
                                      query={"first": len(out), "max": PAGE, "briefRepresentation": "true"})
            if code == 404:
                return out
            if not isinstance(page, list):
                raise UpstreamError("Mitgliederliste ungültig")
            out += [u for u in page if isinstance(u, dict) and u.get("id")]
            if len(page) < PAGE:
                break
        return out

    # ---------- Benutzer ----------
    def find_user(self, query: str) -> dict | None:
        """Exakte Suche: Benutzername, sonst E-Mail (Gross-/Kleinschreibung egal)."""
        q = query.strip().lower()
        for fld in ("username", "email"):
            code, users, _ = self.call("GET", "/users", query={fld: q, "exact": "true", "max": 5})
            if code == 200 and isinstance(users, list):
                hit = [u for u in users if isinstance(u, dict) and str(u.get(fld) or "").lower() == q]
                if len(hit) == 1:
                    return hit[0]
        return None

    def get_user(self, uid: str) -> dict | None:
        code, user, _ = self.call("GET", f"/users/{uid}")
        return user if code == 200 and isinstance(user, dict) else None

    def join(self, uid: str, gid: str) -> None:
        code, _, _ = self.call("PUT", f"/users/{uid}/groups/{gid}")
        if code not in (200, 204):
            raise UpstreamError(f"Gruppe zuweisen: HTTP {code}")

    def leave(self, uid: str, gid: str) -> None:
        code, _, _ = self.call("DELETE", f"/users/{uid}/groups/{gid}")
        if code not in (200, 204, 404):
            raise UpstreamError(f"Gruppe entfernen: HTTP {code}")


_clients: dict[KCConfig, KeycloakAdmin] = {}
_clients_lock = threading.Lock()


def admin_client() -> KeycloakAdmin | None:
    cfg = config()
    if cfg is None:
        return None
    with _clients_lock:
        return _clients.setdefault(cfg, KeycloakAdmin(cfg))


def reset_clients() -> None:
    with _clients_lock:
        _clients.clear()


def upstream_error(e: Exception) -> HTTPException:
    if isinstance(e, UpstreamBusy):
        return HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "Keycloak ausgelastet – bitte später erneut",
                             headers={"Retry-After": str(e.retry_after)})
    if isinstance(e, KeycloakDenied):
        log.error("Keycloak-Admin-API verweigert: %s (Rechte des Service-Accounts prüfen)", e)
        return HTTPException(status.HTTP_502_BAD_GATEWAY, "Keycloak verweigert die Mitgliederverwaltung")
    log.warning("Keycloak-Admin-API fehlgeschlagen: %s", e)
    return HTTPException(status.HTTP_502_BAD_GATEWAY, "Keycloak nicht erreichbar")


# ---------- Mitglieder ----------
def role_paths(slug: str) -> dict[str, str]:
    base = group_prefix() + slug
    return {role: base if suffix is None else f"{base}/{suffix}" for role, suffix in ROLE_GROUP_SUFFIX.items()}


@dataclass
class Membership:
    user: dict
    role: str
    groups: dict          # Rolle → Gruppen-ID, in denen der Benutzer direkt Mitglied ist


def keycloak_members(kc: KeycloakAdmin, slug: str, create: bool = False) -> tuple[dict[str, str], dict]:
    """(Rolle → Gruppen-ID, Benutzer-ID → Membership). Fehlende Gruppen werden mit `create` angelegt."""
    gids: dict[str, str] = {}
    for role, path in role_paths(slug).items():
        gid = kc.ensure_group(path) if create else kc.group_id(path)
        if gid:
            gids[role] = gid
    members: dict[str, Membership] = {}
    for role, gid in gids.items():
        for u in kc.group_members(gid):
            m = members.get(u["id"])
            if m is None:
                members[u["id"]] = Membership(u, role, {role: gid})
            else:
                m.groups[role] = gid
                m.role = higher_role(m.role, role)
    return gids, members


def _display(u: dict) -> str | None:
    full = " ".join(str(u.get(k) or "").strip() for k in ("firstName", "lastName")).strip()
    return full or u.get("username")


def last_activity(db: Session, tenant_id: int) -> dict[str, tuple[str | None, str]]:
    """actor_sub → (letzter actor_name, letzte Aktivität) aus dem Journal."""
    last = select(models.Revision.actor_sub, func.max(models.Revision.seq).label("seq")).where(
        models.Revision.tenant_id == tenant_id).group_by(models.Revision.actor_sub).subquery()
    q = select(models.Revision.actor_sub, models.Revision.actor_name, models.Revision.recorded_at).join(
        last, (models.Revision.tenant_id == tenant_id) & (models.Revision.seq == last.c.seq)).limit(MAX_MEMBERS)
    return {r.actor_sub: (r.actor_name, r.recorded_at) for r in db.execute(q)}


def member_out(m: Membership, activity: dict, show_email: bool) -> dict:
    u = m.user
    return {"id": u["id"], "username": u.get("username"), "name": _display(u),
            "email": u.get("email") if show_email else None, "role": m.role, "source": "keycloak",
            "last_activity_at": (activity.get(u["id"]) or (None, None))[1]}


def _sort_key(m: dict):
    return (-ROLE_RANK.get(m["role"] or "", 0), (m["name"] or m["username"] or "").lower())


def list_members(db: Session, tenant: models.Tenant, is_admin: bool) -> list[dict]:
    activity = last_activity(db, tenant.id)
    kc = admin_client()
    if kc is not None:
        try:
            _, members = keycloak_members(kc, tenant.slug)
            return sorted((member_out(m, activity, is_admin) for m in members.values()), key=_sort_key)
        except (UpstreamError, KeycloakDenied) as e:
            log.warning("Mitglieder aus Keycloak nicht abrufbar (%s) – Akteure aus dem Journal", e)
    out = [{"id": sub, "username": name, "name": name, "email": None, "role": None, "source": "activity",
            "last_activity_at": at} for sub, (name, at) in activity.items()]
    return sorted(out, key=lambda m: m["last_activity_at"] or "", reverse=True)


def journal(db: Session, tenant: models.Tenant, user: User, uid: str, action: str, username: str | None,
            role: str | None, previous: str | None = None) -> models.Revision:
    """Mitgliederänderung als Revision (Hash-Kette); Aufrufer hält die Mandantensperre."""
    version = db.scalar(select(func.count()).select_from(models.Revision).where(
        models.Revision.tenant_id == tenant.id, models.Revision.entity == "membership",
        models.Revision.entity_id == uid)) or 0
    data = {"username": username, "role": role,
            "action": {"create": "add", "update": "change_role", "delete": "remove"}[action]}
    if previous is not None:
        data["previous_role"] = previous
    return append_revision(db, tenant, entity="membership", entity_id=uid, version=version + 1, action=action,
                           data=data, user=user)


def _admins(members: dict[str, Membership]) -> set[str]:
    return {uid for uid, m in members.items() if m.role == "admin"}


def _check_last_admin(members: dict[str, Membership], target: str, requester: str, new_role: str | None) -> None:
    """Letzten Verwalter nicht entfernen/herabstufen; sich selbst nur, wenn ein anderer Verwalter bleibt."""
    if new_role == "admin":
        return
    others = _admins(members) - {target}
    if not others and (members[target].role == "admin" or target == requester):
        raise HTTPException(status.HTTP_409_CONFLICT, "Mindestens ein anderer Verwalter muss bestehen bleiben")


def set_role(kc: KeycloakAdmin, gids: dict[str, str], m: Membership | None, uid: str, role: str) -> None:
    """Genau EINE der drei Gruppen: Zielgruppe zuweisen, übrige entfernen."""
    if m is None or role not in m.groups:
        kc.join(uid, gids[role])
    for r, gid in (m.groups if m else {}).items():
        if r != role:
            kc.leave(uid, gid)


def add_member(db, tenant, user: User, kc: KeycloakAdmin, query: str, role: str, is_admin: bool) -> dict:
    target = kc.find_user(query)
    if target is None or not MEMBER_ID.match(str(target.get("id", ""))):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Benutzer nicht gefunden")
    gids, members = keycloak_members(kc, tenant.slug, create=True)
    if target["id"] in members:
        raise HTTPException(status.HTTP_409_CONFLICT, "Bereits Mitglied")
    set_role(kc, gids, None, target["id"], role)
    journal(db, tenant, user, target["id"], "create", target.get("username"), role)
    m = Membership(target, role, {role: gids[role]})
    return member_out(m, last_activity(db, tenant.id), is_admin)


def _member_or_404(members: dict[str, Membership], uid: str) -> Membership:
    m = members.get(uid) if MEMBER_ID.match(uid) else None
    if m is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Mitglied nicht gefunden")
    return m


def change_role(db, tenant, user: User, kc: KeycloakAdmin, uid: str, role: str, is_admin: bool) -> dict:
    gids, members = keycloak_members(kc, tenant.slug, create=True)
    m = _member_or_404(members, uid)
    previous = m.role
    if previous != role or len(m.groups) > 1:
        _check_last_admin(members, uid, user.sub, role)
        set_role(kc, gids, m, uid, role)
        m.role, m.groups = role, {role: gids[role]}
        if previous != role:
            journal(db, tenant, user, uid, "update", m.user.get("username"), role, previous)
    return member_out(m, last_activity(db, tenant.id), is_admin)


def remove_member(db, tenant, user: User, kc: KeycloakAdmin, uid: str) -> None:
    _, members = keycloak_members(kc, tenant.slug)
    m = _member_or_404(members, uid)
    _check_last_admin(members, uid, user.sub, None)
    for gid in m.groups.values():
        kc.leave(uid, gid)
    journal(db, tenant, user, uid, "delete", m.user.get("username"), m.role)
