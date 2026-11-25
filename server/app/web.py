"""Auslieferung des Web-Frontends (Vue-SPA aus web/dist) unter "/" auf derselben Origin wie die API.

- Statische Dateien aus WEB_DIST (Default /app/web); fehlt index.html, ist das Frontend aus.
- SPA-Fallback: unbekannte Nicht-API-Pfade → index.html (Client-Routing, Deep-Links).
- Sicherheits-Header für alle Nicht-API-Antworten: strikte CSP (nur eigene Origin + Issuer),
  kein Framing, kein Referrer, nosniff. Gehashte Assets langfristig cachebar, index.html nie.
"""
import os
from pathlib import Path
from urllib.parse import urlsplit

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import FileResponse

router = APIRouter(include_in_schema=False)

# Nicht vom SPA-Fallback bedient: API und die exakten Server-Pfade. /auth/callback (OIDC-Redirect des
# Web-Frontends) und übrige /auth/*-Pfade sind Client-Routen → index.html.
_RESERVED_PREFIXES = ("api/", "docs/")
_RESERVED_EXACT = frozenset({"auth/config", "health", "docs", "openapi.json"})


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
           f"font-src 'self'; connect-src {connect}; frame-src 'none'; frame-ancestors 'none'; "
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


@router.api_route("/{path:path}", methods=["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"])
def spa(path: str, request: Request):
    # Alle Methoden annehmen, damit unbekannte Pfade 404 (nicht 405) liefern; ausgeliefert wird nur GET/HEAD
    root = web_dist()
    if request.method not in ("GET", "HEAD") or root is None or _reserved(path):
        raise HTTPException(404, "Nicht gefunden")
    base = root.resolve()
    if path:
        candidate = (root / path).resolve()
        if candidate.is_file() and base in candidate.parents:
            cache = ("public, max-age=31536000, immutable" if path.startswith("assets/")
                     else "no-cache")
            return FileResponse(candidate, headers={"Cache-Control": cache})
        if Path(path).suffix:   # fehlende Datei (z. B. .js/.png) → echtes 404 statt index.html
            raise HTTPException(404, "Nicht gefunden")
    return FileResponse(base / "index.html", headers={"Cache-Control": "no-cache"})
