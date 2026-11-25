import os
import sys
import time
from pathlib import Path

os.environ["DATABASE_URL"] = os.environ.get("FZB_TEST_DATABASE_URL") or "sqlite:///" + str(
    Path(__file__).parent / ".test.db"
)
ISSUER = "https://id.example.test/realms/test"
CLIENT_ID = "fahrzeugbuch-ios"
WEB_CLIENT_ID = "fahrzeugbuch-web"
os.environ.update(OIDC_ISSUER=ISSUER, OIDC_CLIENT_ID=CLIENT_ID)
for _k in ("OIDC_WEB_CLIENT_ID", "KC_ADMIN_URL", "KC_ADMIN_REALM", "KC_ADMIN_CLIENT_ID", "KC_ADMIN_CLIENT_SECRET"):
    os.environ.pop(_k, None)
os.environ.pop("OIDC_AUDIENCE", None)
os.environ.pop("OIDC_REQUIRED_ROLE", None)
os.environ.pop("DEFAULT_TENANT", None)
# Rate-Limits der Berichte/Prüfung/Vollabgleich in Tests praktisch aus (eigene Tests setzen sie gezielt)
os.environ.update(RATE_REPORTS="100000", RATE_VERIFY="100000", RATE_FULL_SYNC="100000")
# Globale Limits/Brute-Force-Sperre ebenfalls praktisch aus (test_security setzt niedrige Werte gezielt)
os.environ.update(RATE_IP_PER_MIN="1000000", RATE_IP_BURST="1000000", RATE_PUBLIC_PER_MIN="1000000",
                  RATE_PUBLIC_BURST="1000000", RATE_WEB_PER_MIN="1000000", RATE_WEB_BURST="1000000",
                  RATE_USER_PER_MIN="1000000", RATE_USER_BURST="1000000",
                  BRUTE_401_THRESHOLD="1000000", BRUTE_403_THRESHOLD="1000000")
for _k in ("ALLOWED_HOSTS", "CORS_ORIGINS", "FORCE_HSTS", "SECURITY_ALLOWLIST", "STRICT_CONFIG", "FORWARDED_ALLOW_IPS",
           "MAX_TOKEN_LIFETIME_S", "OIDC_ALLOW_HTTP", "N8N_WEBHOOK_URL", "N8N_WEBHOOK_SECRET", "DOCS_ENABLED"):
    os.environ.pop(_k, None)
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import jwt  # noqa: E402
import pytest  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import rsa  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from app import attachments, auth, geo, integrity, intel, members, security  # noqa: E402
from app.db import Base, engine  # noqa: E402
from app.main import app  # noqa: E402

KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


class FakeJWKS:
    def key_for(self, kid):
        from app.auth import UnknownKey
        if kid != "test-kid":
            raise UnknownKey
        return KEY.public_key()


def make_token(key=KEY, **overrides) -> str:
    now = int(time.time())
    claims = {
        "iss": ISSUER, "sub": "user-1", "azp": CLIENT_ID, "aud": "account",
        "iat": now, "exp": now + 300, "preferred_username": "jakob", "typ": "Bearer",
        "realm_access": {"roles": ["fahrzeugbuch-user"]},
        "groups": ["/fahrzeugbuch/privat", "/fahrzeugbuch/firma/lesen", "/andere-app/x"],
    }
    claims.update(overrides)
    return jwt.encode(claims, key, algorithm="RS256", headers={"kid": "test-kid"})


@pytest.fixture(autouse=True)
def fake_jwks(monkeypatch):
    monkeypatch.setattr(auth, "jwks", lambda issuer: FakeJWKS())


def reset_db() -> None:
    """Alle Tabellen inkl. Alembic-Stand entfernen (die App legt das Schema beim Start neu an)."""
    Base.metadata.drop_all(engine)
    with engine.begin() as conn:
        conn.exec_driver_sql("DROP TABLE IF EXISTS alembic_version")
    for reset in (intel.limiter.reset, geo.reset_upstreams, integrity.clear_verify_cache,
                  attachments.clear_hash_cache, members.reset_clients, security.reset):
        reset()


@pytest.fixture
def client():
    reset_db()
    with TestClient(app) as c:
        c.headers["Authorization"] = f"Bearer {make_token()}"
        yield c


import uuid  # noqa: E402

T = "/api/t/privat"


def uid() -> str:
    return str(uuid.uuid4())


def op(entity, id_, data=None, action="upsert", base=None, op_id=None, reason=None):
    out = {"op_id": op_id or uid(), "entity": entity, "id": id_, "action": action,
           "base_version": base, "data": data or {}, "client_ts": "2026-11-25T10:00:00+01:00"}
    if reason is not None:
        out["reason"] = reason
    return out


def sync(client, *ops, tenant="privat", expect=200, headers=None):
    r = client.post(f"/api/t/{tenant}/sync", json={"ops": list(ops)}, headers=headers)
    assert r.status_code == expect, r.text
    return r.json()


def new_vehicle(client, name="Golf", initial_km=10000):
    vid = uid()
    res = sync(client, op("vehicle", vid, {"name": name, "plate": "ZH 123", "initial_km": initial_km}))
    assert res["results"][0]["status"] == "applied", res
    return vid


def bearer_token(**claims) -> dict:
    return {"Authorization": f"Bearer {make_token(**claims)}"}


def web_headers(**claims) -> dict:
    """Token des Web-Frontends (azp = OIDC_WEB_CLIENT_ID): Steuerparameter, Mitgliederverwaltung."""
    return bearer_token(azp=WEB_CLIENT_ID, **claims)
