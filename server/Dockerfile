# Build-Kontext: Repo-Root  (docker build -f server/Dockerfile .  bzw. docker compose, siehe .dockerignore)
#
# Stufe 1: Web-Frontend (Vue/Vite) → /web/dist. Image per Digest gepinnt (node:22-alpine). Aktualisieren:
#   docker pull node:22-alpine && docker image inspect --format '{{index .RepoDigests 0}}' node:22-alpine
FROM node:22-alpine@sha256:1314fb30ec37592d5845e5a160d522c0e680972aa534549940b8d73bde88481a AS web
WORKDIR /web
COPY web/package.json web/package-lock.json ./
# exakt nach Lock-Datei, ohne Install-Skripte der Abhängigkeiten
RUN npm ci --ignore-scripts --no-audit --no-fund
COPY web/ ./
RUN npm run build

# Stufe 2: API. Basis-Image per Digest gepinnt (python:3.12-slim). Aktualisieren:
#   docker pull python:3.12-slim && docker image inspect --format '{{index .RepoDigests 0}}' python:3.12-slim
FROM python:3.12-slim@sha256:191083cdf6c7bda8c76158983163ead5d5cf7b77cf3033e805bb0f5296f51b4b

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 FORWARDED_ALLOW_IPS=127.0.0.1
WORKDIR /app

# requirements.txt = vollständige Lock-Datei mit Hashes (pip-compile --generate-hashes, siehe requirements.in)
COPY server/requirements.txt .
RUN pip install --no-cache-dir --require-hashes --no-deps -r requirements.txt

COPY server/alembic.ini ./
COPY server/alembic ./alembic
COPY server/app ./app
# Web-Frontend (SPA) – app/web.py liefert es unter "/" aus (WEB_DIST); vorkomprimierte <datei>.br/.gz aus dem
# Web-Build werden bei passendem Accept-Encoding ausgeliefert
COPY --from=web /web/dist /app/web
ENV WEB_DIST=/app/web
# Feste UID/GID 10001 (Kubernetes runAsUser/runAsGroup/fsGroup, runAsNonRoot). Root-Dateisystem read-only
# betreibbar: beschreibbar sind nur /tmp (tmpfs/emptyDir) und – bei STORAGE_BACKEND=fs – FILES_DIR
# (/data/attachments, Volume; ein leeres benanntes Volume übernimmt beim ersten Mount Besitzer/Rechte).
# /app/data nur für den SQLite-Default (Entwicklung).
RUN groupadd -g 10001 app && useradd -r -u 10001 -g 10001 -M -d /nonexistent -s /usr/sbin/nologin app \
    && mkdir -p /app/data /data/attachments \
    && chown 10001:10001 /app/data /data/attachments && chmod 750 /data/attachments
ENV FILES_DIR=/data/attachments ATTACHMENT_DIR=/data/attachments
USER 10001:10001

EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health/live', timeout=4)" || exit 1
# Start über app.serve (liest Env, prüft und ersetzt sich per exec durch uvicorn):
#   WEB_CONCURRENCY      Worker (1 | N | auto = min(2 × CPU-Quota der cgroup, 16)); > 1 nur mit
#                        STATE_BACKEND=redis + PostgreSQL, sonst Abbruch mit Meldung
#   UVICORN_LIMIT_CONCURRENCY  gleichzeitige Verbindungen JE WORKER (→ 503), Default 200
#   UVICORN_LIMIT_MAX_REQUESTS (+ _JITTER)  Worker-Recycling, nur bei > 1 Worker, Default aus
#   GRACEFUL_TIMEOUT_S   SIGTERM: laufende Anfragen fertigstellen, Default 25
#   fest: --proxy-headers (FORWARDED_ALLOW_IPS), --no-server-header, --timeout-keep-alive 5 (Slowloris),
#         --h11-max-incomplete-event-size 16 KiB (Header)
# Migration als eigener Befehl im selben Image: python -m app.migrate (Exit ≠ 0 bei Fehler; --check → 3 = nötig)
# Zugriffslog ohne Query-Strings: app.logfilter (beim Import von app.main am Logger uvicorn.access).
ENV WEB_CONCURRENCY=1 UVICORN_LIMIT_CONCURRENCY=200 GRACEFUL_TIMEOUT_S=25
STOPSIGNAL SIGTERM
CMD ["python", "-m", "app.serve"]
