# Build-Kontext: fahrzeugbuch/  (docker build -f server/Dockerfile .  bzw. docker compose, siehe .dockerignore)
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
# Web-Frontend (SPA) – app/web.py liefert es unter "/" aus (WEB_DIST)
COPY --from=web /web/dist /app/web
ENV WEB_DIST=/app/web
# /data/attachments: Mountpunkt des Beleg-Volumes; ein leeres benanntes Volume übernimmt beim ersten
# Mount Besitzer/Rechte dieses Verzeichnisses → User app kann trotz read_only-Container schreiben.
RUN useradd -r -u 10001 app && mkdir -p /app/data /data/attachments \
    && chown app /app/data /data/attachments && chmod 750 /data/attachments
ENV ATTACHMENT_DIR=/data/attachments
USER app

EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health')" || exit 1
# FORWARDED_ALLOW_IPS (Env) = IP des Reverse Proxy; uvicorn liest die Variable selbst.
# Zugriffslog ohne Query-Strings: app.logfilter wird beim Import von app.main am Logger uvicorn.access
# installiert (Koordinaten/Zeiträume gelangen nicht ins Log).
# Genau 1 Worker: Rate-Limits, Brute-Force-Sperren und Caches sind In-Memory je Prozess (mehrere Worker
# würden die Limits vervielfachen). Skalierung nur mit gemeinsamem Speicher (z. B. Redis) – nicht vorgesehen.
#   --limit-concurrency  gleichzeitige Verbindungen/Tasks (Env UVICORN_LIMIT_CONCURRENCY, Default 200) → 503
#   --timeout-keep-alive 5 s (Slowloris/Keep-Alive-Halden), --h11-max-incomplete-event-size 16 KiB (Header)
ENV UVICORN_LIMIT_CONCURRENCY=200
CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port 8000 --proxy-headers --no-server-header --workers 1 --limit-concurrency \"${UVICORN_LIMIT_CONCURRENCY:-200}\" --timeout-keep-alive 5 --h11-max-incomplete-event-size 16384"]
