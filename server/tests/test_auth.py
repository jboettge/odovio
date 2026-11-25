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
    assert client.get("/api/me", headers=bearer(make_token(aud="fahrzeugbuch-api"))).status_code == 200
    assert client.get("/api/me", headers=bearer(make_token(aud="fahrzeugbuch-api", azp="x"))).status_code == 401
    assert client.get("/api/me", headers=bearer(make_token(aud="account"))).status_code == 401


def test_required_role(client, monkeypatch):
    monkeypatch.setenv("OIDC_REQUIRED_ROLE", "fahrzeugbuch-user")
    assert client.get("/api/me").status_code == 200
    t = make_token(realm_access={"roles": []})
    assert client.get("/api/me", headers=bearer(t)).status_code == 403
    t = make_token(realm_access={}, resource_access={CLIENT_ID: {"roles": ["fahrzeugbuch-user"]}})
    assert client.get("/api/me", headers=bearer(t)).status_code == 200


def test_id_token_and_foreign_client_roles_rejected(client, monkeypatch):
    assert client.get("/api/me", headers=bearer(make_token(typ="ID"))).status_code == 401
    monkeypatch.setenv("OIDC_REQUIRED_ROLE", "fahrzeugbuch-user")
    t = make_token(realm_access={}, resource_access={"anderer-client": {"roles": ["fahrzeugbuch-user"]}})
    assert client.get("/api/me", headers=bearer(t)).status_code == 403


def test_allowed_azp(client, monkeypatch):
    monkeypatch.setenv("OIDC_ALLOWED_AZP", "n8n-skript")
    assert client.get("/api/me", headers=bearer(make_token(azp="n8n-skript"))).status_code == 200


def test_unknown_kid_and_generic_errors(client):
    import jwt as pyjwt
    t = pyjwt.encode({"sub": "x"}, "secret", algorithm="HS256", headers={"kid": "fremd"})
    r = client.get("/api/me", headers=bearer(t))
    assert r.status_code == 401 and r.json()["detail"] == "Token ungültig"


def test_body_limit_and_auth_before_parse(client, monkeypatch):
    r = client.post("/api/t/privat/sync", content=b"{kaputt", headers={"Authorization": ""})
    assert r.status_code == 401
    big = b'{"ops":[]' + b" " * (1024 * 1024 + 10) + b"}"
    r = client.post("/api/t/privat/sync", content=big, headers={"Content-Type": "application/json"})
    assert r.status_code == 413


def test_docs_disabled(client):
    assert client.get("/docs", headers={"Authorization": ""}).status_code == 404
    assert client.get("/openapi.json", headers={"Authorization": ""}).status_code == 404


def test_jwks_cache_rate_limit(monkeypatch):
    from app.auth import JWKSCache, UnknownKey
    calls = []
    cache = JWKSCache("https://issuer.test")

    def fake_get(url):
        calls.append(url)
        if url.endswith("openid-configuration"):
            return {"jwks_uri": "https://issuer.test/certs"}
        return {"keys": []}

    monkeypatch.setattr(cache, "_get_json", fake_get)
    for _ in range(20):
        try:
            cache.key_for("unbekannt")
        except UnknownKey:
            pass
    assert len(calls) == 2   # ein Abruf (Discovery + JWKS), danach Rate-Limit
