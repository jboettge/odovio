"""OIDC-Resource-Server: prüft Keycloak-Access-Tokens (JWT, JWKS).

Env:
  OIDC_ISSUER         https://id.j-mb.net/realms/<realm>   (Pflicht)
  OIDC_CLIENT_ID      Client der iOS-App (public, PKCE)    (Pflicht, wird der App via /auth/config mitgeteilt)
  OIDC_AUDIENCE       erwartete aud; leer → stattdessen azp == OIDC_CLIENT_ID
  OIDC_REQUIRED_ROLE  optional: Realm- oder Client-Rolle, die der Benutzer haben muss
"""
import json
import os
import urllib.request
from dataclasses import dataclass
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


@dataclass(frozen=True)
class User:
    sub: str
    name: str | None


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
    return User(sub=claims["sub"], name=claims.get("preferred_username") or claims.get("name"))


def require_user(authorization: Annotated[str | None, Header()] = None) -> User:
    cfg = get_config()
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Token fehlt", headers={"WWW-Authenticate": "Bearer"})
    return verify_token(authorization[7:].strip(), cfg)
