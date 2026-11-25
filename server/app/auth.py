"""OIDC-Resource-Server: prüft Keycloak-Access-Tokens (JWT, JWKS).

Env:
  OIDC_ISSUER         https://id.j-mb.net/realms/<realm>   (Pflicht)
  OIDC_CLIENT_ID      Client der iOS-App (public, PKCE)    (Pflicht, wird der App via /auth/config mitgeteilt)
  OIDC_WEB_CLIENT_ID  Client des Web-Frontends (public, PKCE), Default fahrzeugbuch-web – immer als azp
                      zugelassen; nur dort: Mitgliederverwaltung und Steuerparameter
  OIDC_AUDIENCE       erwartete aud; leer → stattdessen azp == OIDC_CLIENT_ID
  OIDC_REQUIRED_ROLE  optional: Realm- oder Client-Rolle, die der Benutzer haben muss

Mandanten (aus dem `groups`-Claim, Keycloak-Gruppen mit vollem Pfad):
  TENANT_GROUP_PREFIX /fahrzeugbuch/  →  /fahrzeugbuch/<mandant>        = lesen + schreiben ("write")
                                         /fahrzeugbuch/<mandant>/lesen  = nur lesen ("read")
                                         /fahrzeugbuch/<mandant>/admin  = Verwalter ("admin", inkl. schreiben)
  Rangfolge admin > write > read (mehrere Gruppen → höchste Rolle).
  DEFAULT_TENANT      optional: Mandant, auf den jeder berechtigte Benutzer schreibend zugreift

Härtung: Token ≤ 8 KiB; `iat` nicht in der Zukunft, `nbf` beachtet, Lebensdauer exp−iat ≤ MAX_TOKEN_LIFETIME_S
(Default 3600, nur Access-Tokens), `jti` optional (String ≤ 255); JWKS nur über https (OIDC_ALLOW_HTTP=1 nur
für Tests/Entwicklung), ohne Weiterleitungen, Antwortgrösse begrenzt. Fehlermeldungen generisch; der Grund
geht ins Sicherheits-Log (auth_failed). Erfolgreiche Anmeldung: zusätzliches Rate-Limit je Benutzer.
"""
import json
import logging
import os
import re
import threading
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from functools import lru_cache
from typing import Annotated

import jwt
from fastapi import Header, HTTPException, status

from . import security

log = logging.getLogger("fahrzeugbuch.auth")

ALGORITHMS = ["RS256", "RS384", "RS512", "ES256", "ES384", "PS256"]
LEEWAY_S = 30
MAX_TOKEN_BYTES = 8 * 1024
MAX_JWKS_BYTES = 1024 * 1024


def max_lifetime() -> int:
    return security.env_int("MAX_TOKEN_LIFETIME_S", 3600)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


_opener = urllib.request.build_opener(_NoRedirect())


def _allowed_url(url: str) -> bool:
    scheme = urllib.parse.urlsplit(url).scheme
    return scheme == "https" or (scheme == "http" and os.environ.get("OIDC_ALLOW_HTTP") == "1")


@dataclass(frozen=True)
class OIDCConfig:
    issuer: str
    client_id: str
    audience: str | None
    required_role: str | None
    allowed_azp: frozenset = frozenset()
    web_client_id: str = "fahrzeugbuch-web"


def web_client_id() -> str:
    return (os.environ.get("OIDC_WEB_CLIENT_ID") or "").strip() or "fahrzeugbuch-web"


def get_config() -> OIDCConfig:
    issuer = os.environ.get("OIDC_ISSUER", "").rstrip("/")
    client_id = os.environ.get("OIDC_CLIENT_ID", "")
    if not issuer or not client_id:
        raise HTTPException(status.HTTP_500_INTERNAL_SERVER_ERROR, "OIDC_ISSUER/OIDC_CLIENT_ID nicht gesetzt")
    web = web_client_id()
    return OIDCConfig(
        issuer=issuer,
        client_id=client_id,
        audience=os.environ.get("OIDC_AUDIENCE") or None,
        required_role=os.environ.get("OIDC_REQUIRED_ROLE") or None,
        allowed_azp=frozenset([client_id, web, *filter(None, (x.strip() for x in
                                                              os.environ.get("OIDC_ALLOWED_AZP", "").split(",")))]),
        web_client_id=web,
    )


class UnknownKey(Exception):
    pass


class KeyServiceUnavailable(Exception):
    pass


class JWKSCache:
    """Signaturschlüssel des Issuers. Neu geladen höchstens alle `min_refetch` Sekunden
    (unbekannte `kid` können so keinen Abruf-Sturm auslösen), regulär nach `max_age`."""

    def __init__(self, issuer: str, min_refetch: float = 60, max_age: float = 3600, timeout: float = 5):
        self.issuer, self.min_refetch, self.max_age, self.timeout = issuer, min_refetch, max_age, timeout
        self.keys: dict[str, object] = {}
        self.fetched = 0.0
        self.lock = threading.Lock()

    def _get_json(self, url: str) -> dict:
        """Nur https (Test/Entwicklung: OIDC_ALLOW_HTTP=1), keine Weiterleitungen, max. 1 MiB."""
        if not _allowed_url(url):
            raise ValueError("JWKS/Discovery nur über https")
        # Schema oben auf https geprüft (bandit B310: kein file:/eigenes Schema möglich)
        with _opener.open(url, timeout=self.timeout) as r:  # nosec B310
            data = r.read(MAX_JWKS_BYTES + 1)
        if len(data) > MAX_JWKS_BYTES:
            raise ValueError("Antwort zu gross")
        return json.loads(data)

    def _fetch(self) -> None:
        self.fetched = time.monotonic()   # auch bei Fehler → Rate-Limit greift
        try:
            jwks_uri = self._get_json(f"{self.issuer}/.well-known/openid-configuration")["jwks_uri"]
            data = self._get_json(jwks_uri)
            keys = {}
            for jwk in data.get("keys", []):
                if jwk.get("use", "sig") == "sig" and "kid" in jwk:
                    try:
                        keys[jwk["kid"]] = jwt.PyJWK(jwk).key
                    except jwt.PyJWKError:
                        continue
        except (OSError, ValueError, KeyError, TypeError) as e:
            log.warning("JWKS-Abruf fehlgeschlagen: %s", type(e).__name__)
            if not self.keys:
                raise KeyServiceUnavailable from e
            return
        self.keys = keys

    def key_for(self, kid: str | None):
        if not kid:
            raise UnknownKey
        age = time.monotonic() - self.fetched
        if kid in self.keys and age < self.max_age:
            return self.keys[kid]
        with self.lock:
            age = time.monotonic() - self.fetched
            if (kid not in self.keys or age >= self.max_age) and (not self.fetched or age >= self.min_refetch):
                self._fetch()
        if kid not in self.keys:
            raise UnknownKey
        return self.keys[kid]


@lru_cache(maxsize=4)
def jwks(issuer: str) -> JWKSCache:
    return JWKSCache(issuer)


def _roles(claims: dict, *client_ids: str) -> set[str]:
    """Nur Realm-Rollen, Rollen der eigenen Clients (iOS, Web) und Gruppen (keine fremden Client-Rollen)."""
    roles = set(claims.get("realm_access", {}).get("roles", []))
    for client_id in client_ids:
        roles.update((claims.get("resource_access", {}).get(client_id) or {}).get("roles", []))
    roles.update(g for g in claims.get("groups", []) or [] if isinstance(g, str))
    return roles


TENANT_SLUG = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")


ROLE_RANK = {"read": 1, "write": 2, "admin": 3}
READ_SUFFIXES = ("lesen", "read")
ADMIN_SUFFIX = "admin"


def can_write(role: str | None) -> bool:
    """Schreibrecht: write und admin (admin impliziert write)."""
    return role in ("write", "admin")


def higher_role(a: str | None, b: str | None) -> str | None:
    return max((r for r in (a, b) if r in ROLE_RANK), key=ROLE_RANK.__getitem__, default=None)


@dataclass(frozen=True)
class User:
    sub: str
    name: str | None
    tenants: dict = field(default_factory=dict)  # slug -> "admin" | "write" | "read"
    display_name: str | None = None              # Claim name, sonst preferred_username
    azp: str | None = None                       # Client, für den das Token ausgestellt wurde
    web: bool = False                            # azp == OIDC_WEB_CLIENT_ID (Web-Frontend)

    @property
    def label(self) -> str | None:
        """Kurzname für created_by/updated_by/driver_name (≤ 100 Zeichen)."""
        return (self.name or None) and self.name[:100]


def group_prefix() -> str:
    return "/" + os.environ.get("TENANT_GROUP_PREFIX", "/fahrzeugbuch/").strip("/") + "/"


def tenants_from_claims(claims: dict) -> dict[str, str]:
    prefix = group_prefix()
    result: dict[str, str] = {}
    for group in claims.get("groups") or []:
        if not isinstance(group, str) or not group.startswith(prefix):
            continue
        parts = group[len(prefix):].strip("/").split("/")
        slug = parts[0].lower()
        if not TENANT_SLUG.match(slug):
            continue
        role = None
        if len(parts) == 1:
            role = "write"
        elif len(parts) == 2 and parts[1].lower() in READ_SUFFIXES:
            role = "read"
        elif len(parts) == 2 and parts[1].lower() == ADMIN_SUFFIX:
            role = "admin"
        if role:
            result[slug] = higher_role(result.get(slug), role)
    default = (os.environ.get("DEFAULT_TENANT") or "").lower()
    if default and TENANT_SLUG.match(default):
        result[default] = higher_role(result.get(default), "write")
    return result


def _unauthorized(detail: str = "Token ungültig") -> HTTPException:
    return HTTPException(status.HTTP_401_UNAUTHORIZED, detail, headers={"WWW-Authenticate": "Bearer"})


# PyJWT-Fehler → Grund im Sicherheits-Log. "signed": Signatur war gültig (Prüfung der Claims danach) →
# der sub ist echt und darf die 401-Serie dieses Benutzers markieren.
_REASONS: list[tuple[type, str, bool]] = [
    (jwt.ExpiredSignatureError, "expired", True),
    (jwt.ImmatureSignatureError, "not_yet_valid", True),
    (jwt.InvalidIssuerError, "wrong_issuer", True),
    (jwt.InvalidAudienceError, "wrong_audience", True),
    (jwt.MissingRequiredClaimError, "missing_claim", True),
    (jwt.InvalidSignatureError, "bad_signature", False),
    (jwt.InvalidAlgorithmError, "bad_algorithm", False),
    (jwt.DecodeError, "malformed", False),
]
for _name, _reason in (("InvalidJTIError", "bad_jti"), ("InvalidSubjectError", "bad_sub"),
                       ("InvalidIssuedAtError", "bad_time_claim")):
    if hasattr(jwt.exceptions, _name):          # PyJWT ≥ 2.10
        _REASONS.insert(0, (getattr(jwt.exceptions, _name), _reason, True))


def _reject(reason: str, claims: dict | None = None) -> HTTPException:
    sub = claims.get("sub") if isinstance(claims, dict) and isinstance(claims.get("sub"), str) else None
    security.auth_failure(reason, sub)
    log.debug("Token abgelehnt: %s", reason)
    return _unauthorized()


def _signed_claims(token: str) -> dict | None:
    """Claims eines Tokens, dessen Signatur bereits geprüft wurde (nur für das Log)."""
    try:
        return jwt.decode(token, options={"verify_signature": False})
    except jwt.InvalidTokenError:
        return None


def _check_times(claims: dict) -> str | None:
    now = time.time()
    exp, iat, nbf = claims.get("exp"), claims.get("iat"), claims.get("nbf")
    if not all(isinstance(x, int | float) and not isinstance(x, bool) for x in (exp, iat)):
        return "bad_time_claim"
    if iat > now + LEEWAY_S:
        return "iat_future"
    if exp - iat > max_lifetime():
        return "lifetime"
    if nbf is not None and (not isinstance(nbf, int | float) or isinstance(nbf, bool) or nbf > now + LEEWAY_S):
        return "not_yet_valid"
    jti = claims.get("jti")
    if jti is not None and (not isinstance(jti, str) or not 0 < len(jti) <= 255):
        return "bad_jti"
    return None


def verify_token(token: str, cfg: OIDCConfig) -> User:
    if not token or len(token) > MAX_TOKEN_BYTES:
        raise _reject("oversized_token" if token else "missing_token")
    try:
        header = jwt.get_unverified_header(token)
        key = jwks(cfg.issuer).key_for(header.get("kid"))
        claims = jwt.decode(
            token,
            key,
            algorithms=ALGORITHMS,
            issuer=cfg.issuer,
            audience=cfg.audience,
            options={"verify_aud": cfg.audience is not None, "require": ["exp", "iat", "sub"],
                     "verify_iat": True, "verify_nbf": True},
            leeway=LEEWAY_S,
        )
    except KeyServiceUnavailable as e:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "Anmeldedienst nicht erreichbar") from e
    except UnknownKey as e:
        raise _reject("unknown_kid") from e
    except jwt.InvalidTokenError as e:
        reason, signed = next(((r, s) for cls, r, s in _REASONS if isinstance(e, cls)), ("invalid", False))
        raise _reject(reason, _signed_claims(token) if signed else None) from e

    if (problem := _check_times(claims)) is not None:
        raise _reject(problem, claims)
    if not isinstance(claims.get("sub"), str) or not 0 < len(claims["sub"]) <= 255:
        raise _reject("bad_sub")
    # Nur Access-Tokens (Keycloak: typ=Bearer; ID-Tokens haben typ=ID) unserer Clients
    if str(claims.get("typ", "Bearer")).lower() != "bearer":
        raise _reject("wrong_type", claims)
    if claims.get("azp") not in cfg.allowed_azp:
        raise _reject("wrong_client", claims)
    if cfg.required_role and cfg.required_role not in _roles(claims, cfg.client_id, cfg.web_client_id):
        security.event("forbidden_role", status=403, reason="Rolle fehlt", sub=claims["sub"])
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Zugriff verweigert")

    def text(key: str) -> str | None:
        v = claims.get(key)
        return (v.strip() or None) if isinstance(v, str) else None

    return User(
        sub=claims["sub"],
        name=text("preferred_username") or text("name"),
        tenants=tenants_from_claims(claims),
        display_name=text("name") or text("preferred_username"),
        azp=claims.get("azp"),
        web=claims.get("azp") == cfg.web_client_id,
    )


def require_user(authorization: Annotated[str | None, Header()] = None) -> User:
    cfg = get_config()
    if not authorization or not authorization.lower().startswith("bearer "):
        security.auth_failure("missing_token")
        raise _unauthorized("Token fehlt")
    user = verify_token(authorization[7:].strip(), cfg)
    security.after_auth(user.sub)   # 401-Serie dieses Benutzers zurücksetzen, Rate-Limit je Benutzer
    return user
