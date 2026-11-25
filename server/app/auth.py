"""OIDC-Resource-Server: prüft Keycloak-Access-Tokens (JWT, JWKS).

Env:
  OIDC_ISSUER         https://id.j-mb.net/realms/<realm>   (Pflicht)
  OIDC_CLIENT_ID      Client der iOS-App (public, PKCE)    (Pflicht, wird der App via /auth/config mitgeteilt)
  OIDC_AUDIENCE       erwartete aud; leer → stattdessen azp == OIDC_CLIENT_ID
  OIDC_REQUIRED_ROLE  optional: Realm- oder Client-Rolle, die der Benutzer haben muss

Mandanten (aus dem `groups`-Claim, Keycloak-Gruppen mit vollem Pfad):
  TENANT_GROUP_PREFIX /fahrzeugbuch/  →  /fahrzeugbuch/<mandant>        = lesen + schreiben
                                         /fahrzeugbuch/<mandant>/lesen  = nur lesen
  DEFAULT_TENANT      optional: Mandant, auf den jeder berechtigte Benutzer schreibend zugreift
"""
import json
import os
import re
import urllib.request
from dataclasses import dataclass, field
from functools import lru_cache
from typing import Annotated

import jwt
from fastapi import Header, HTTPException, status

ALGORITHMS = ["RS256", "RS384", "RS512", "ES256", "ES384", "PS256"]


@dataclass(frozen=True)
class OIDCConfig:
    issuer: str
    client_id: str
    audience: str | None
    required_role: str | None


def get_config() -> OIDCConfig:
    issuer = os.environ.get("OIDC_ISSUER", "").rstrip("/")
    client_id = os.environ.get("OIDC_CLIENT_ID", "")
    if not issuer or not client_id:
        raise HTTPException(status.HTTP_500_INTERNAL_SERVER_ERROR, "OIDC_ISSUER/OIDC_CLIENT_ID nicht gesetzt")
    return OIDCConfig(
        issuer=issuer,
        client_id=client_id,
        audience=os.environ.get("OIDC_AUDIENCE") or None,
        required_role=os.environ.get("OIDC_REQUIRED_ROLE") or None,
    )


@lru_cache(maxsize=4)
def jwks_client(issuer: str) -> jwt.PyJWKClient:
    with urllib.request.urlopen(f"{issuer}/.well-known/openid-configuration", timeout=10) as r:
        discovery = json.load(r)
    return jwt.PyJWKClient(discovery["jwks_uri"], cache_keys=True, lifespan=3600)


def _roles(claims: dict, client_id: str) -> set[str]:
    roles = set(claims.get("realm_access", {}).get("roles", []))
    for client, access in claims.get("resource_access", {}).items():
        roles.update(access.get("roles", []))
        if client == client_id:
            roles.update(f"{client}:{r}" for r in access.get("roles", []))
    roles.update(claims.get("groups", []) or [])
    return roles


TENANT_SLUG = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")


@dataclass(frozen=True)
class User:
    sub: str
    name: str | None
    tenants: dict = field(default_factory=dict)  # slug -> "write" | "read"


def tenants_from_claims(claims: dict) -> dict[str, str]:
    prefix = "/" + os.environ.get("TENANT_GROUP_PREFIX", "/fahrzeugbuch/").strip("/") + "/"
    result: dict[str, str] = {}
    for group in claims.get("groups") or []:
        if not isinstance(group, str) or not group.startswith(prefix):
            continue
        parts = group[len(prefix):].strip("/").split("/")
        slug = parts[0].lower()
        if not TENANT_SLUG.match(slug):
            continue
        if len(parts) == 1:
            result[slug] = "write"
        elif len(parts) == 2 and parts[1].lower() in ("lesen", "read"):
            result.setdefault(slug, "read")
    default = (os.environ.get("DEFAULT_TENANT") or "").lower()
    if default and TENANT_SLUG.match(default):
        result[default] = "write"
    return result


def verify_token(token: str, cfg: OIDCConfig) -> User:
    try:
        key = jwks_client(cfg.issuer).get_signing_key_from_jwt(token).key
        claims = jwt.decode(
            token,
            key,
            algorithms=ALGORITHMS,
            issuer=cfg.issuer,
            audience=cfg.audience,
            options={"verify_aud": cfg.audience is not None, "require": ["exp", "iat", "sub"]},
            leeway=30,
        )
    except (jwt.PyJWKClientError, OSError, KeyError, ValueError) as e:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, f"JWKS nicht erreichbar: {e}") from e
    except jwt.InvalidTokenError as e:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, f"Token ungültig: {e}") from e

    if cfg.audience is None and claims.get("azp") != cfg.client_id:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Token wurde für einen anderen Client ausgestellt")
    if cfg.required_role and cfg.required_role not in _roles(claims, cfg.client_id):
        raise HTTPException(status.HTTP_403_FORBIDDEN, f"Rolle {cfg.required_role} fehlt")
    return User(
        sub=claims["sub"],
        name=claims.get("preferred_username") or claims.get("name"),
        tenants=tenants_from_claims(claims),
    )


def require_user(authorization: Annotated[str | None, Header()] = None) -> User:
    cfg = get_config()
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Token fehlt", headers={"WWW-Authenticate": "Bearer"})
    return verify_token(authorization[7:].strip(), cfg)
