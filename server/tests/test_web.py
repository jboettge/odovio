def _dist(tmp_path, monkeypatch):
    (tmp_path / "assets").mkdir()
    (tmp_path / "index.html").write_text("<!doctype html><title>FZB</title>")
    (tmp_path / "assets" / "app-abc123.js").write_text("console.log(1)")
    monkeypatch.setenv("WEB_DIST", str(tmp_path))


def test_spa_served_with_security_headers(client, tmp_path, monkeypatch):
    _dist(tmp_path, monkeypatch)
    r = client.get("/", headers={"Authorization": ""})
    assert r.status_code == 200 and "FZB" in r.text
    csp = r.headers["content-security-policy"]
    assert "default-src 'self'" in csp and "frame-ancestors 'none'" in csp
    assert "https://id.example.test" in csp            # Issuer-Origin für OIDC
    assert r.headers["x-frame-options"] == "DENY" and r.headers["cache-control"] == "no-cache"


def test_deep_link_and_assets(client, tmp_path, monkeypatch):
    _dist(tmp_path, monkeypatch)
    r = client.get("/verwaltung/mitglieder", headers={"Authorization": ""})
    assert r.status_code == 200 and "FZB" in r.text
    a = client.get("/assets/app-abc123.js", headers={"Authorization": ""})
    assert a.status_code == 200 and "immutable" in a.headers["cache-control"]
    assert client.get("/assets/missing.js", headers={"Authorization": ""}).status_code == 404


def test_no_traversal_and_api_untouched(client, tmp_path, monkeypatch):
    _dist(tmp_path, monkeypatch)
    secret = tmp_path.parent / "secret.txt"
    secret.write_text("geheim")
    r = client.get("/..%2Fsecret.txt", headers={"Authorization": ""})
    assert "geheim" not in r.text
    assert client.get("/api/me", headers={"Authorization": ""}).status_code == 401
    assert "content-security-policy" not in client.get("/api/me").headers
    assert client.get("/health", headers={"Authorization": ""}).json() == {"status": "ok"}


def test_without_dist_404(client, monkeypatch, tmp_path):
    monkeypatch.setenv("WEB_DIST", str(tmp_path / "fehlt"))
    assert client.get("/", headers={"Authorization": ""}).status_code == 404
