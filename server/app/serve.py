"""Start der API (Docker-CMD): `python -m app.serve` → prüft die Konfiguration und ersetzt sich durch uvicorn.

Env (Default):
  WEB_CONCURRENCY (1)                Worker-Prozesse; "auto" = min(2 × CPU-Quota der cgroup, 16) – Empfehlung
                                     1 Worker je 0.5–1 vCPU; bei Kubernetes/VPA beim Neustart neu berechnet
  PORT (8000), HOST (0.0.0.0)
  UVICORN_LIMIT_CONCURRENCY (200)    gleichzeitige Verbindungen/Tasks JE WORKER, darüber 503
  UVICORN_LIMIT_MAX_REQUESTS (0)     Worker nach so vielen Anfragen ersetzen (0 = nie; nur bei > 1 Worker)
  UVICORN_LIMIT_MAX_REQUESTS_JITTER  Zufallsaufschlag, damit nicht alle Worker gleichzeitig neu starten
                                     (Default 10 % von MAX_REQUESTS)
  GRACEFUL_TIMEOUT_S (25)            SIGTERM: laufende Anfragen so lange fertigstellen (Kubernetes:
                                     terminationGracePeriodSeconds > GRACEFUL_TIMEOUT_S + preStop)
  UVICORN_TIMEOUT_KEEP_ALIVE (5), UVICORN_BACKLOG (2048)
  FORWARDED_ALLOW_IPS                von uvicorn selbst gelesen (--proxy-headers)
Abbruch (Exit 2) bei mehreren Workern ohne STATE_BACKEND=redis oder mit SQLite, bei STRICT_CONFIG=1 und
Warnungen sowie bei ungültigem WEB_CONCURRENCY.
"""
import os
import sys
import uuid

from . import config, runtime


def build_args(env=os.environ) -> list[str]:
    workers = config.resolve_workers(env.get("WEB_CONCURRENCY"))

    def num(name: str, default: int) -> int:
        try:
            v = int(env.get(name) or default)
        except ValueError:
            return default
        return v if v >= 0 else default

    # im Container auf allen Schnittstellen (Port nur über Compose/Service veröffentlicht)
    host = env.get("HOST") or "0.0.0.0"  # nosec B104
    args = ["app.main:app", "--host", host, "--port", str(num("PORT", 8000)),
            "--proxy-headers", "--no-server-header", "--workers", str(workers),
            "--limit-concurrency", str(max(1, num("UVICORN_LIMIT_CONCURRENCY", 200))),
            "--timeout-keep-alive", str(num("UVICORN_TIMEOUT_KEEP_ALIVE", 5)),
            "--timeout-graceful-shutdown", str(num("GRACEFUL_TIMEOUT_S", 25)),
            "--backlog", str(max(64, num("UVICORN_BACKLOG", 2048))),
            "--h11-max-incomplete-event-size", "16384"]
    max_requests = num("UVICORN_LIMIT_MAX_REQUESTS", 0)
    if max_requests and workers > 1:     # mit 1 Worker würde der ganze Server enden
        jitter = num("UVICORN_LIMIT_MAX_REQUESTS_JITTER", max_requests // 10)
        args += ["--limit-max-requests", str(max_requests), "--limit-max-requests-jitter", str(jitter)]
    return args


def prepare(env=os.environ) -> list[str]:
    """Prüfen und Env für die Worker setzen; liefert die uvicorn-Argumente. Fehler → SystemExit(2)."""
    try:
        workers = config.resolve_workers(env.get("WEB_CONCURRENCY"))
    except ValueError:
        raise SystemExit(f"Start abgebrochen: WEB_CONCURRENCY={env.get('WEB_CONCURRENCY')!r} ungültig "
                         "(Zahl ≥ 1 oder auto)") from None
    env["WEB_CONCURRENCY"] = str(workers)          # Worker sehen die aufgelöste Zahl (Budget-Aufteilung)
    env.setdefault("FZB_INSTANCE_ID", uuid.uuid4().hex[:16])   # Gruppe der Worker dieses Containers/Pods
    if errs := runtime.errors():
        raise SystemExit("Start abgebrochen: " + "; ".join(errs))
    from . import security  # Logging + Warnungen (STRICT_CONFIG=1 → Abbruch), einmal statt je Worker
    security.install_logging()
    try:
        security.check_config()
    except security.InsecureConfig as e:
        raise SystemExit(f"Start abgebrochen: {e}") from None
    env["FZB_SERVE"] = "1"
    return build_args(env)


def main() -> None:
    args = prepare()
    print(f"fahrzeugbuch: uvicorn mit {os.environ['WEB_CONCURRENCY']} Worker(n)", file=sys.stderr, flush=True)
    # feste Argumente, kein Shell-Aufruf
    os.execvp(sys.executable, [sys.executable, "-m", "uvicorn", *args])  # nosec B606


if __name__ == "__main__":
    try:
        main()
    except SystemExit as e:
        if isinstance(e.code, str):
            print(e.code, file=sys.stderr, flush=True)
            sys.exit(2)
        raise
