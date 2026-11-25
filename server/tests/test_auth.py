import time

from cryptography.hazmat.primitives.asymmetric import rsa

from .conftest import CLIENT_ID, ISSUER, make_token


def bearer(t):
    return {"Authorization": f"Bearer {t}"}


def test_missing_token(client):
    assert client.get("/api/me", headers={"Authorization": ""}).status_code == 401


def test_public_endpoints(client):
    assert client.get("/health", headers={"Authorization": ""}).status_code == 200
    cfg = client.get("/auth/config", headers={"Authorization": ""}).json()
    assert cfg["issuer"] == ISSUER and cfg["client_id"] == CLIENT_ID
    assert "offline_access" in cfg["scopes"]


def test_valid_token(client):
    me = client.get("/api/me").json()
    assert me["sub"] == "user-1" and me["name"] == "jakob"
    assert me["tenants"] == [{"slug": "firma", "role": "read"}, {"slug": "privat", "role": "write"}]


def test_default_tenant(client, monkeypatch):
    monkeypatch.setenv("DEFAULT_TENANT", "Haushalt")
    t = make_token(groups=[])
    assert client.get("/api/me", headers=bearer(t)).json()["tenants"] == [{"slug": "haushalt", "role": "write"}]


def test_rejects_bad_tokens(client):
    other = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    cases = [
        make_token(key=other),                      # falsche Signatur
        make_token(exp=int(time.time()) - 120),     # abgelaufen
        make_token(iss="https://evil.test/realms/x"),
        make_token(azp="anderer-client"),
    ]
    for t in cases:
        assert client.get("/api/me", headers=bearer(t)).status_code == 401, t


def test_audience_mode(client, monkeypatch):
    monkeypatch.setenv("OIDC_AUDIENCE", "fahrzeugbuch-api")
    assert client.get("/api/me", headers=bearer(make_token(aud="fahrzeugbuch-api", azp="x"))).status_code == 200
    assert client.get("/api/me", headers=bearer(make_token(aud="account"))).status_code == 401


def test_required_role(client, monkeypatch):
    monkeypatch.setenv("OIDC_REQUIRED_ROLE", "fahrzeugbuch-user")
    assert client.get("/api/me").status_code == 200
    t = make_token(realm_access={"roles": []})
    assert client.get("/api/me", headers=bearer(t)).status_code == 403
    t = make_token(realm_access={}, resource_access={CLIENT_ID: {"roles": ["fahrzeugbuch-user"]}})
    assert client.get("/api/me", headers=bearer(t)).status_code == 200
