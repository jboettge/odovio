"""Startprüfungen für das Prozessmodell (app.serve vor dem Start der Worker, app.main im Lifespan).

Fehler (Abbruch): mehrere Prozesse (WEB_CONCURRENCY × REPLICAS_HINT > 1) ohne gemeinsamen Zustand
(STATE_BACKEND=memory: Rate-Limits/Sperren würden je Prozess gelten) oder mit SQLite (ein Schreiber, Datei
je Container).
Warnungen (Sicherheits-Log config_warning; STRICT_CONFIG=1 → Abbruch):
  - PostgreSQL-Verbindungen: Prozesse × (DB_POOL_SIZE + DB_MAX_OVERFLOW) + DB_CONNECTION_RESERVE (10)
    > PG_MAX_CONNECTIONS (100)
  - mehrere Replikas mit STORAGE_BACKEND=fs: nur mit gemeinsamem RWX-Volume korrekt (FILES_SHARED=1 bestätigt
    das gemeinsame Volume → keine Warnung)
"""
import os

from . import config, state


class StartupError(RuntimeError):
    pass


def database_url() -> str:
    return os.environ.get("DATABASE_URL", "sqlite:///./data/fahrzeugbuch.db")


def errors() -> list[str]:
    out = []
    try:
        state.check_config()
    except state.StateConfigError as e:
        out.append(str(e))
    n, w, r = config.processes(), config.workers(), config.replicas()
    if n > 1 and state.backend_name() != "redis":
        out.append(f"{w} Worker × {r} Replika(s) ohne gemeinsamen Zustand: STATE_BACKEND=redis und REDIS_URL "
                   "setzen (Rate-Limits/Brute-Force-Sperren würden sonst je Prozess gelten) oder WEB_CONCURRENCY=1")
    if n > 1 and database_url().startswith("sqlite"):
        out.append("Mehrere Worker/Replikas mit SQLite: PostgreSQL verwenden (DATABASE_URL) oder WEB_CONCURRENCY=1")
    from .attachments import check_storage_config
    return out + check_storage_config()


def connection_budget() -> tuple[int, int]:
    """(benötigt, erlaubt) an PostgreSQL-Verbindungen."""
    per_proc = config.env_int("DB_POOL_SIZE", 5, minimum=1) + config.env_int("DB_MAX_OVERFLOW", 10)
    need = config.processes() * per_proc + config.env_int("DB_CONNECTION_RESERVE", 10)
    return need, config.env_int("PG_MAX_CONNECTIONS", 100, minimum=1)


def warnings() -> list[str]:
    out = []
    if database_url().startswith("postgresql"):
        need, allowed = connection_budget()
        if need > allowed:
            out.append(f"DB-Verbindungen: {config.workers()} Worker × {config.replicas()} Replika(s) × (DB_POOL_SIZE + "
                       f"DB_MAX_OVERFLOW) + Reserve = {need} > PG_MAX_CONNECTIONS {allowed}")
    storage = (os.environ.get("STORAGE_BACKEND") or "fs").strip().lower()
    if storage == "fs" and config.replicas() > 1 and os.environ.get("FILES_SHARED") != "1":
        out.append("STORAGE_BACKEND=fs mit REPLICAS_HINT > 1: Belegverzeichnis muss ein gemeinsames RWX-Volume sein "
                   "(dann FILES_SHARED=1) – sonst STORAGE_BACKEND=s3")
    return out


def check() -> None:
    if errs := errors():
        raise StartupError("; ".join(errs))
