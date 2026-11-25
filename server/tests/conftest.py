import os
import sys
import time
from pathlib import Path

os.environ["DATABASE_URL"] = os.environ.get("FZB_TEST_DATABASE_URL") or "sqlite:///" + str(
    Path(__file__).parent / ".test.db"
)
ISSUER = "https://id.example.test/realms/test"
CLIENT_ID = "fahrzeugbuch-ios"
os.environ.update(OIDC_ISSUER=ISSUER, OIDC_CLIENT_ID=CLIENT_ID)
os.environ.pop("OIDC_AUDIENCE", None)
os.environ.pop("OIDC_REQUIRED_ROLE", None)
os.environ.pop("DEFAULT_TENANT", None)
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import jwt  # noqa: E402
import pytest  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import rsa  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from app import auth  # noqa: E402
from app.db import Base, engine  # noqa: E402
from app.main import app  # noqa: E402

KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


class FakeJWKS:
    def get_signing_key_from_jwt(self, token):
        return type("K", (), {"key": KEY.public_key()})()


def make_token(key=KEY, **overrides) -> str:
    now = int(time.time())
    claims = {
        "iss": ISSUER, "sub": "user-1", "azp": CLIENT_ID, "aud": "account",
        "iat": now, "exp": now + 300, "preferred_username": "jakob",
        "realm_access": {"roles": ["fahrzeugbuch-user"]},
        "groups": ["/fahrzeugbuch/privat", "/fahrzeugbuch/firma/lesen", "/andere-app/x"],
    }
    claims.update(overrides)
    return jwt.encode(claims, key, algorithm="RS256")


@pytest.fixture(autouse=True)
def fake_jwks(monkeypatch):
    monkeypatch.setattr(auth, "jwks_client", lambda issuer: FakeJWKS())


@pytest.fixture
def client():
    Base.metadata.drop_all(engine)
    with TestClient(app) as c:
        c.headers["Authorization"] = f"Bearer {make_token()}"
        yield c


import uuid  # noqa: E402

T = "/api/t/privat"


def uid() -> str:
    return str(uuid.uuid4())


def op(entity, id_, data=None, action="upsert", base=None, op_id=None):
    return {"op_id": op_id or uid(), "entity": entity, "id": id_, "action": action,
            "base_version": base, "data": data or {}, "client_ts": "2026-11-25T10:00:00+01:00"}


def sync(client, *ops, tenant="privat", expect=200):
    r = client.post(f"/api/t/{tenant}/sync", json={"ops": list(ops)})
    assert r.status_code == expect, r.text
    return r.json()


def new_vehicle(client, name="Golf", initial_km=10000):
    vid = uid()
    res = sync(client, op("vehicle", vid, {"name": name, "plate": "ZH 123", "initial_km": initial_km}))
    assert res["results"][0]["status"] == "applied", res
    return vid


def bearer_token(**claims) -> dict:
    return {"Authorization": f"Bearer {make_token(**claims)}"}
