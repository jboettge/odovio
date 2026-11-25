FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 FORWARDED_ALLOW_IPS=127.0.0.1
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

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
# FORWARDED_ALLOW_IPS (Env) = IP des Reverse Proxy; uvicorn liest die Variable selbst
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--no-server-header"]
