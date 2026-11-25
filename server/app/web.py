"""Auslieferung des Web-Frontends (Vue-SPA aus web/dist) unter "/" auf derselben Origin wie die API.

- Statische Dateien aus WEB_DIST (Default /app/web); fehlt index.html, ist das Frontend aus.
- SPA-Fallback: unbekannte Nicht-API-Pfade → index.html (Client-Routing, Deep-Links).
- Sicherheits-Header für alle Nicht-API-Antworten: strikte CSP (nur eigene Origin + Issuer),
  kein Framing, kein Referrer, nosniff. Gehashte Assets langfristig cachebar, index.html nie.
- Vorkomprimiert (Vertrag mit dem Web-Build): liegt neben einer Datei `<datei>.br` bzw. `<datei>.gz` (Build legt
  sie für Dateien ≥ 1 KiB an), wird sie bei passendem Accept-Encoding ausgeliefert (br vor gzip, q-Werte; q=0
  schliesst aus) – mit Content-Encoding, Vary: Accept-Encoding, Content-Type und Cache-Headern des Originals.
  Direkte Anfragen auf *.br/*.gz → 404.
- ETag/Last-Modified je ausgelieferter Variante; If-None-Match bzw. If-Modified-Since → 304.
"""
import email.utils
import hashlib
import mimetypes
import os
from pathlib import Path
from urllib.parse import urlsplit

from fastapi import APIRouter, HTTPException, Request, Response
from fastapi.responses import FileResponse

router = APIRouter(include_in_schema=False)

# Nicht vom SPA-Fallback bedient: API und die exakten Server-Pfade. /auth/callback (OIDC-Redirect des
# Web-Frontends) und übrige /auth/*-Pfade sind Client-Routen → index.html.
_RESERVED_PREFIXES = ("api/", "docs/")
_RESERVED_EXACT = frozenset({"auth/config", "health", "health/live", "health/ready", "metrics", "docs",
                             "openapi.json"})


def _reserved(path: str) -> bool:
    return path.startswith(_RESERVED_PREFIXES) or path in _RESERVED_EXACT


def web_dist() -> Path | None:
    root = Path(os.environ.get("WEB_DIST", "/app/web"))
    return root if (root / "index.html").is_file() else None


def _issuer_origin() -> str:
    issuer = os.environ.get("OIDC_ISSUER", "")
    parts = urlsplit(issuer)
    return f"{parts.scheme}://{parts.netloc}" if parts.scheme in ("http", "https") and parts.netloc else ""


def security_headers() -> list[tuple[bytes, bytes]]:
    issuer = _issuer_origin()
    connect = "'self'" + (f" {issuer}" if issuer else "")
    csp = ("default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' blob: data:; "
           f"font-src 'self'; connect-src {connect}; worker-src 'self'; frame-src 'none'; frame-ancestors 'none'; "
           "object-src 'none'; base-uri 'none'; form-action 'self'")
    return [
        (b"content-security-policy", csp.encode()),
        (b"x-frame-options", b"DENY"),
        (b"x-content-type-options", b"nosniff"),
        (b"referrer-policy", b"no-referrer"),
        (b"permissions-policy", b"camera=(), microphone=(), geolocation=(), payment=()"),
        (b"cross-origin-opener-policy", b"same-origin"),
    ]


class WebSecurityHeaders:
    """ASGI: Sicherheits-Header für alles ausser /api/* (API hat eigene Header)."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope["path"].startswith("/api/"):
            return await self.app(scope, receive, send)
        extra = security_headers()

        async def wrapped(msg):
            if msg["type"] == "http.response.start":
                names = {k.lower() for k, _ in msg.get("headers", [])}
                msg = {**msg, "headers": [*msg.get("headers", []), *[h for h in extra if h[0] not in names]]}
            await send(msg)

        await self.app(scope, receive, wrapped)


ENCODINGS = (("br", ".br"), ("gzip", ".gz"))
_COMPRESSED_SUFFIXES = (".br", ".gz")


def accepted_encodings(header: str | None) -> dict[str, float]:
    """Accept-Encoding → {coding: q}; ungültige q-Werte → 0."""
    out: dict[str, float] = {}
    for part in (header or "").split(","):
        token, _, params = part.strip().partition(";")
        token = token.strip().lower()
        if not token:
            continue
        q = 1.0
        for p in params.split(";"):
            k, _, v = p.strip().partition("=")
            if k.strip().lower() == "q":
                try:
                    q = min(1.0, max(0.0, float(v)))
                except ValueError:
                    q = 0.0
        out[token] = q
    return out


def pick_encoding(header: str | None, available: list[str]) -> str | None:
    """Beste verfügbare Kodierung (höchstes q, bei Gleichstand br vor gzip) oder None (identity)."""
    acc = accepted_encodings(header)
    best, best_q = None, 0.0
    for coding in available:
        q = acc.get(coding, acc.get("*", 0.0))
        if q > best_q:
            best, best_q = coding, q
    return best


def _etag(st: os.stat_result, encoding: str | None) -> str:
    base = hashlib.md5(f"{st.st_mtime_ns}-{st.st_size}".encode(), usedforsecurity=False).hexdigest()
    return f'"{base}{"-" + encoding if encoding else ""}"'


def _not_modified(request: Request, etag: str, mtime: float) -> bool:
    inm = request.headers.get("if-none-match")
    if inm is not None:
        tags = {t.strip().removeprefix("W/") for t in inm.split(",")}
        return "*" in tags or etag in tags
    ims = request.headers.get("if-modified-since")
    if ims:
        try:
            since = email.utils.parsedate_to_datetime(ims)
        except (TypeError, ValueError):
            return False
        return since is not None and int(mtime) <= int(since.timestamp())
    return False


def serve_file(request: Request, path: Path, cache: str) -> Response:
    variants = [(c, path.with_name(path.name + suf)) for c, suf in ENCODINGS]
    variants = [(c, p) for c, p in variants if p.is_file()]
    encoding = pick_encoding(request.headers.get("accept-encoding"), [c for c, _ in variants])
    served = dict(variants)[encoding] if encoding else path
    st = served.stat()
    etag = _etag(st, encoding)
    headers = {"Cache-Control": cache, "ETag": etag,
               "Last-Modified": email.utils.formatdate(st.st_mtime, usegmt=True)}
    if variants:
        headers["Vary"] = "Accept-Encoding"
    if _not_modified(request, etag, st.st_mtime):
        return Response(status_code=304, headers=headers)
    media_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    if encoding:
        headers["Content-Encoding"] = encoding
    return FileResponse(served, media_type=media_type, headers=headers)


@router.api_route("/{path:path}", methods=["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"])
def spa(path: str, request: Request):
    # Alle Methoden annehmen, damit unbekannte Pfade 404 (nicht 405) liefern; ausgeliefert wird nur GET/HEAD
    root = web_dist()
    if request.method not in ("GET", "HEAD") or root is None or _reserved(path):
        raise HTTPException(404, "Nicht gefunden")
    base = root.resolve()
    if path:
        if path.endswith(_COMPRESSED_SUFFIXES):   # nur über Accept-Encoding, nie direkt
            raise HTTPException(404, "Nicht gefunden")
        candidate = (root / path).resolve()
        if candidate.is_file() and base in candidate.parents:
            cache = ("public, max-age=31536000, immutable" if path.startswith("assets/")
                     else "no-cache")
            return serve_file(request, candidate, cache)
        if Path(path).suffix:   # fehlende Datei (z. B. .js/.png) → echtes 404 statt index.html
            raise HTTPException(404, "Nicht gefunden")
    return serve_file(request, base / "index.html", "no-cache")
