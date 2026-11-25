# Basis-Image per Digest gepinnt (python:3.12-slim). Aktualisieren:
#   docker pull python:3.12-slim && docker image inspect --format '{{index .RepoDigests 0}}' python:3.12-slim
FROM python:3.12-slim@sha256:191083cdf6c7bda8c76158983163ead5d5cf7b77cf3033e805bb0f5296f51b4b

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 FORWARDED_ALLOW_IPS=127.0.0.1
WORKDIR /app

# requirements.txt = vollständige Lock-Datei mit Hashes (pip-compile --generate-hashes, siehe requirements.in)
COPY requirements.txt .
RUN pip install --no-cache-dir --require-hashes --no-deps -r requirements.txt

COPY alembic.ini ./
COPY alembic ./alembic
COPY app ./app
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
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--no-server-header"]
