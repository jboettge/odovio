"""Laufzeit-Konfiguration, die mehrere Module brauchen (ohne App-Importe, keine Zirkel).

Geheimnisse aus Dateien (Docker/Kubernetes-Secrets): Ist `<NAME>_FILE` gesetzt, wird der Inhalt der Datei
(ohne abschliessenden Zeilenumbruch) als `<NAME>` übernommen – beim Import des Pakets `app`, also vor allen
anderen Modulen. `<NAME>` und `<NAME>_FILE` zugleich → Abbruch (eindeutige Quelle).
Passwörter getrennt von der URL: DATABASE_PASSWORD(_FILE) bzw. MIGRATION_DATABASE_PASSWORD(_FILE) und
REDIS_PASSWORD(_FILE) werden in DATABASE_URL / MIGRATION_DATABASE_URL / REDIS_URL eingesetzt.

Prozessmodell (siehe app/serve.py): WEB_CONCURRENCY Worker je Container/Pod, REPLICAS_HINT Container/Pods
(nur für Startprüfungen; Default 1).
"""
import math
import os
from pathlib import Path
from urllib.parse import quote, urlsplit, urlunsplit

SECRET_NAMES = (
    "DATABASE_URL", "MIGRATION_DATABASE_URL", "DATABASE_PASSWORD", "MIGRATION_DATABASE_PASSWORD",
    "DB_PASSWORD", "APP_DB_PASSWORD", "ANCHOR_SIGNING_KEY", "ANCHOR_PUBLIC_KEYS",
    "KC_ADMIN_CLIENT_ID", "KC_ADMIN_CLIENT_SECRET", "N8N_WEBHOOK_URL", "N8N_WEBHOOK_SECRET", "VLLM_API_KEY",
    "REDIS_URL", "REDIS_PASSWORD", "VALKEY_PASSWORD", "METRICS_TOKEN",
    "S3_ACCESS_KEY_ID", "S3_SECRET_ACCESS_KEY", "S3_SESSION_TOKEN",
)
MAX_SECRET_BYTES = 64 * 1024


class ConfigError(RuntimeError):
    pass


def load_secret_files(environ=os.environ) -> list[str]:
    """`<NAME>_FILE` → `<NAME>`; liefert die gesetzten Namen (nie Werte)."""
    loaded = []
    for name in SECRET_NAMES:
        path = environ.get(f"{name}_FILE")
        if not path:
            continue
        if environ.get(name):
            raise ConfigError(f"{name} und {name}_FILE sind beide gesetzt – nur eines verwenden")
        try:
            raw = Path(path).read_bytes()[:MAX_SECRET_BYTES + 1]
        except OSError as e:
            raise ConfigError(f"{name}_FILE nicht lesbar ({type(e).__name__})") from None
        if len(raw) > MAX_SECRET_BYTES:
            raise ConfigError(f"{name}_FILE zu gross")
        environ[name] = raw.decode("utf-8").rstrip("\r\n")
        loaded.append(name)
    _inject_password(environ, "DATABASE_URL", "DATABASE_PASSWORD")
    _inject_password(environ, "MIGRATION_DATABASE_URL", "MIGRATION_DATABASE_PASSWORD")
    _inject_password(environ, "REDIS_URL", "REDIS_PASSWORD")
    return loaded


def _inject_password(environ, url_name: str, password_name: str) -> None:
    url, password = environ.get(url_name), environ.get(password_name)
    if not url or not password:
        return
    parts = urlsplit(url)
    if parts.password:          # URL enthält bereits ein Passwort → unverändert
        return
    host = parts.netloc.rsplit("@", 1)[-1]
    user = parts.username or ""
    netloc = f"{quote(user, safe='')}:{quote(password, safe='')}@{host}"
    environ[url_name] = urlunsplit((parts.scheme, netloc, parts.path, parts.query, parts.fragment))


# ---------- Zahlen aus Env ----------
def env_int(name: str, default: int, minimum: int = 0, maximum: int | None = None) -> int:
    try:
        v = int(os.environ.get(name) or default)
    except ValueError:
        return default
    if v < minimum or (maximum is not None and v > maximum):
        return default
    return v


def env_float(name: str, default: float, minimum: float = 0.0) -> float:
    try:
        v = float(os.environ.get(name) or default)
    except ValueError:
        return default
    return v if v >= minimum else default


# ---------- CPU-Quota (cgroup v2/v1) ----------
def cpu_quota(root: str = "/sys/fs/cgroup") -> float | None:
    """Verfügbare CPUs laut cgroup-Limit (Docker `cpus`, Kubernetes limits.cpu/VPA), sonst None."""
    base = Path(root)
    try:
        quota, period = (base / "cpu.max").read_text().split()[:2]     # v2: "max 100000" | "200000 100000"
        if quota != "max" and int(period) > 0:
            return int(quota) / int(period)
        return None
    except (OSError, ValueError):
        pass
    try:                                                               # v1
        quota = int((base / "cpu" / "cpu.cfs_quota_us").read_text())
        period = int((base / "cpu" / "cpu.cfs_period_us").read_text())
        return quota / period if quota > 0 and period > 0 else None
    except (OSError, ValueError):
        return None


def available_cpus(root: str = "/sys/fs/cgroup") -> float:
    """min(cgroup-Quota, CPU-Affinität) – nicht os.cpu_count() (das sieht alle Kerne des Hosts)."""
    try:
        affinity = len(os.sched_getaffinity(0))
    except (AttributeError, OSError):
        affinity = os.cpu_count() or 1
    quota = cpu_quota(root)
    return min(quota, affinity) if quota else float(affinity)


AUTO_MAX_WORKERS = 16


def resolve_workers(value: str | None, root: str = "/sys/fs/cgroup") -> int:
    """WEB_CONCURRENCY: Zahl ≥ 1 oder "auto" = min(2 × CPU-Quota, 16), mind. 1 (Empfehlung: 1 Worker je
    0.5–1 vCPU). Ungültig → ValueError."""
    value = (value or "1").strip().lower()
    if value == "auto":
        return max(1, min(math.floor(2 * available_cpus(root)), AUTO_MAX_WORKERS))
    n = int(value)
    if n < 1 or n > 256:
        raise ValueError("WEB_CONCURRENCY ausserhalb 1–256")
    return n


def workers() -> int:
    """Anzahl Worker dieses Containers (app.serve setzt WEB_CONCURRENCY auf die aufgelöste Zahl)."""
    try:
        return resolve_workers(os.environ.get("WEB_CONCURRENCY"))
    except ValueError:
        return 1


def replicas() -> int:
    return env_int("REPLICAS_HINT", 1, minimum=1)


def processes() -> int:
    """Prozesse insgesamt, die sich DB, Limits und Belegspeicher teilen."""
    return workers() * replicas()


def per_worker(total: int) -> int:
    """Anteil eines Workers an einem Gesamtbudget (aufgerundet, mind. 1)."""
    return max(1, math.ceil(total / workers()))
