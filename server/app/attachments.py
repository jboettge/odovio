"""Belegdateien (Fotos/PDF) ausserhalb der Datenbank.

Env:
  ATTACHMENT_DIR    Ablage, Default ./data/attachments → <dir>/<tenant_id>/<attachment_id> (ohne Endung;
                    der Inhaltstyp steht in den Metadaten)
  MAX_UPLOAD_BYTES  Body-Limit für …/blob (RequestGuard), Default 8 MiB

Die Metadaten (inkl. `sha256`) laufen über den Sync und damit durch die Revisionskette; die Datei ist
über die Prüfsumme daran gebunden. Dateien werden nie überschrieben oder gelöscht (Storno = Soft-Delete
der Metadaten), atomar geschrieben (tmp + rename) und von der Integritätsprüfung nachgerechnet.
"""
import hashlib
import logging
import os
import tempfile
import threading
import uuid
from pathlib import Path

from sqlalchemy import select
from sqlalchemy.orm import Session

from . import models
from .schemas import MAX_ATTACHMENT_BYTES

log = logging.getLogger("fahrzeugbuch.attachments")

FILE_MODE = 0o640
DIR_MODE = 0o750
EXTENSIONS = {"image/jpeg": "jpg", "image/heic": "heic", "application/pdf": "pdf"}
_CHUNK = 1024 * 1024


def max_upload() -> int:
    try:
        v = int(os.environ.get("MAX_UPLOAD_BYTES") or MAX_ATTACHMENT_BYTES)
    except ValueError:
        return MAX_ATTACHMENT_BYTES
    return v if v > 0 else MAX_ATTACHMENT_BYTES


def blob_dir() -> Path:
    return Path(os.environ.get("ATTACHMENT_DIR") or "./data/attachments")


def blob_path(tenant_id: int, attachment_id: str) -> Path:
    """Pfad nur aus Mandanten-ID (int) und UUID → kein Path-Traversal möglich."""
    return blob_dir() / str(int(tenant_id)) / str(uuid.UUID(attachment_id))


# ---------- Prüfsummen ----------
# Cache je Datei-Identität (Inode, Grösse, mtime, ctime): ctime lässt sich ohne Root nicht zurücksetzen,
# daher wird jede Änderung erkannt, ohne bei jedem PDF-Bericht alle Belege neu einzulesen.
_hash_cache: dict[tuple, str] = {}
_cache_lock = threading.Lock()
_CACHE_MAX = 50_000


def file_sha256(path: Path) -> str:
    st = path.stat()
    key = (str(path), st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns)
    with _cache_lock:
        hit = _hash_cache.get(key)
    if hit is not None:
        return hit
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(_CHUNK):
            h.update(chunk)
    digest = h.hexdigest()
    with _cache_lock:
        if len(_hash_cache) >= _CACHE_MAX:
            _hash_cache.clear()
        _hash_cache[key] = digest
    return digest


def clear_hash_cache() -> None:
    with _cache_lock:
        _hash_cache.clear()


def store_blob(path: Path, data: bytes) -> None:
    """Atomar schreiben: temporäre Datei im Zielverzeichnis, fsync, chmod 0640, rename."""
    path.parent.mkdir(mode=DIR_MODE, parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".tmp-")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, FILE_MODE)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# ---------- Abfragen ----------
def active_attachments(db: Session, tenant_id: int):
    return db.scalars(select(models.Attachment).where(models.Attachment.tenant_id == tenant_id,
                                                      models.Attachment.deleted.is_(False))
                      .order_by(models.Attachment.id))


def fuel_with_receipt(db: Session, tenant_id: int, fuel_ids: list[str]) -> set[str]:
    """Tankvorgänge mit mindestens einem nicht stornierten Beleg."""
    if not fuel_ids:
        return set()
    return set(db.scalars(select(models.Attachment.fuel_id).distinct().where(
        models.Attachment.tenant_id == tenant_id, models.Attachment.deleted.is_(False),
        models.Attachment.fuel_id.in_(fuel_ids))))


def verify_blobs(db: Session, tenant: models.Tenant) -> dict:
    """SHA-256 jeder vorhandenen Datei nicht stornierter Belege gegen die Metadaten.
    Fehlende Dateien (noch nicht hochgeladen) sind kein Fehler, werden aber gezählt."""
    problems, checked, missing = [], 0, 0
    for att in active_attachments(db, tenant.id):
        path = blob_path(tenant.id, att.id)
        if not path.is_file():
            missing += 1
            continue
        try:
            digest = file_sha256(path)
        except OSError:
            log.warning("Beleg %s: Datei nicht lesbar", att.id)
            problems.append(f"Beleg {att.id}: Datei nicht lesbar")
            continue
        checked += 1
        if digest != att.sha256:
            problems.append(f"Beleg {att.id}: Datei verändert")
    return {"problems": problems, "checked": checked, "missing": missing}
