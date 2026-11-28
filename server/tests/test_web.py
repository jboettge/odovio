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
    assert "worker-src 'self'" in csp                   # Web Worker aus /assets (gleiche Origin)
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


def test_auth_callback_and_client_routes_serve_index(client, tmp_path, monkeypatch):
    _dist(tmp_path, monkeypatch)
    for path in ("/auth/callback?code=x&state=y", "/auth/logout", "/uebersicht", "/"):
        r = client.get(path, headers={"Authorization": ""})
        assert r.status_code == 200 and "FZB" in r.text, path
    assert client.get("/auth/config", headers={"Authorization": ""}).json()["client_id"]
    for path in ("/api/unbekannt", "/openapi.json", "/docs", "/docs/x"):
        assert client.get(path, headers={"Authorization": ""}).status_code in (401, 404), path


def test_without_dist_404(client, monkeypatch, tmp_path):
    monkeypatch.setenv("WEB_DIST", str(tmp_path / "fehlt"))
    assert client.get("/", headers={"Authorization": ""}).status_code == 404


# ---------- vorkomprimierte Auslieferung (Vertrag mit dem Web-Build: <datei>.br / <datei>.gz) ----------
import gzip  # noqa: E402

from app.web import accepted_encodings, pick_encoding  # noqa: E402

JS = b"console.log('fahrzeugbuch');" * 100


def _compressed_dist(tmp_path, monkeypatch):
    _dist(tmp_path, monkeypatch)
    js = tmp_path / "assets" / "big-1a2b.js"
    js.write_bytes(JS)
    (tmp_path / "assets" / "big-1a2b.js.br").write_bytes(b"BROTLI-FAKE")      # Inhalt egal (nicht dekodiert)
    (tmp_path / "assets" / "big-1a2b.js.gz").write_bytes(gzip.compress(JS))
    return js


def _get(client, path, enc=None, **headers):
    h = {"Authorization": "", **headers}
    if enc is not None:
        h["Accept-Encoding"] = enc
    return client.get(path, headers=h)


def test_precompressed_variants(client, tmp_path, monkeypatch):
    _compressed_dist(tmp_path, monkeypatch)
    br = _get(client, "/assets/big-1a2b.js", "gzip, deflate, br")
    assert br.headers["content-encoding"] == "br" and br.headers["vary"] == "Accept-Encoding"
    assert br.headers["content-type"].startswith("text/javascript")
    assert "immutable" in br.headers["cache-control"] and br.headers["etag"].endswith('-br"')
    gz = _get(client, "/assets/big-1a2b.js", "gzip")
    assert gz.headers["content-encoding"] == "gzip" and gz.content == JS      # httpx2 dekodiert gzip
    ident = _get(client, "/assets/big-1a2b.js", "identity")
    assert "content-encoding" not in ident.headers and ident.content == JS and ident.headers["vary"]
    # q-Werte: br ausgeschlossen → gzip; gzip bevorzugt → gzip
    assert _get(client, "/assets/big-1a2b.js", "br;q=0, gzip").headers["content-encoding"] == "gzip"
    assert _get(client, "/assets/big-1a2b.js", "br;q=0.5, gzip;q=0.9").headers["content-encoding"] == "gzip"
    assert _get(client, "/assets/big-1a2b.js", "*").headers["content-encoding"] == "br"
    # direkte Anfragen auf die Varianten → 404
    for suffix in (".br", ".gz"):
        assert _get(client, f"/assets/big-1a2b.js{suffix}").status_code == 404
    # ohne Variante: unverändert, ohne Vary
    plain = _get(client, "/assets/app-abc123.js", "br, gzip")
    assert "content-encoding" not in plain.headers and "vary" not in plain.headers


def test_etag_and_last_modified_304(client, tmp_path, monkeypatch):
    _compressed_dist(tmp_path, monkeypatch)
    r = _get(client, "/assets/big-1a2b.js", "br")
    etag, lm = r.headers["etag"], r.headers["last-modified"]
    nm = _get(client, "/assets/big-1a2b.js", "br", **{"If-None-Match": etag})
    assert nm.status_code == 304 and nm.content == b"" and nm.headers["etag"] == etag
    assert nm.headers["cache-control"] == r.headers["cache-control"]
    # andere Kodierung → andere ETag → kein 304
    assert _get(client, "/assets/big-1a2b.js", "gzip", **{"If-None-Match": etag}).status_code == 200
    assert _get(client, "/assets/big-1a2b.js", "br", **{"If-Modified-Since": lm}).status_code == 304
    assert _get(client, "/assets/big-1a2b.js", "br",
                **{"If-Modified-Since": "Mon, 01 Jan 2001 00:00:00 GMT"}).status_code == 200
    idx = _get(client, "/")
    assert _get(client, "/", **{"If-None-Match": idx.headers["etag"]}).status_code == 304


def test_accept_encoding_parsing():
    assert accepted_encodings("gzip;q=0.5, br, x;q=abc") == {"gzip": 0.5, "br": 1.0, "x": 0.0}
    assert pick_encoding("", ["br", "gzip"]) is None
    assert pick_encoding("identity", ["br", "gzip"]) is None
    assert pick_encoding("gzip, br", ["gzip"]) == "gzip"
