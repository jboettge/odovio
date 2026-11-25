"""Belegdateien (Fotos/PDF) ausserhalb der Datenbank.

Env:
  ATTACHMENT_DIR    Ablage, Default ./data/attachments → <dir>/<tenant_id>/<attachment_id> (ohne Endung;
                    der Inhaltstyp steht in den Metadaten)
  MAX_UPLOAD_BYTES  Body-Limit für …/blob (RequestGuard), Default 8 MiB
  ATTACHMENT_QUOTA_MB  Speicherkontingent je Mandant (Summe der Dateien), Default 2048

Die Metadaten (inkl. `sha256`) laufen über den Sync und damit durch die Revisionskette; die Datei ist
über die Prüfsumme daran gebunden. Dateien werden nie überschrieben oder gelöscht (Storno = Soft-Delete
der Metadaten), atomar geschrieben (tmp + rename) und von der Integritätsprüfung nachgerechnet.
Der Inhalt muss zum Typ passen (Magic Bytes: JPEG, HEIC/HEIF, PDF).

Prüfsummen-Cache: im Prozess und persistent (Tabelle blob_checks, je Datei-Fingerabdruck) → nach einem
Neustart liest das erste PDF nicht alle Belege des Mandanten neu.
"""
import datetime as dt
import hashlib
import logging
import os
import tempfile
import threading
import uuid
from pathlib import Path

from sqlalchemy import select
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from . import models
from .db import SessionLocal
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


def quota_bytes() -> int:
    try:
        mb = float(os.environ.get("ATTACHMENT_QUOTA_MB") or 2048)
    except ValueError:
        mb = 2048
    return int(mb * 1024 * 1024) if mb > 0 else 2048 * 1024 * 1024


def tenant_usage(tenant_id: int) -> int:
    """Belegter Speicher eines Mandanten (Summe der gespeicherten Dateien)."""
    d = blob_dir() / str(int(tenant_id))
    try:
        with os.scandir(d) as it:
            return sum(e.stat().st_size for e in it if e.is_file() and not e.name.startswith(".tmp-"))
    except FileNotFoundError:
        return 0


def content_matches(mime: str, body: bytes) -> bool:
    """Magic Bytes: JPEG FF D8 FF, HEIC/HEIF ISO-BMFF (`ftyp` an Offset 4), PDF `%PDF`."""
    if mime == "image/jpeg":
        return body[:3] == b"\xff\xd8\xff"
    if mime == "image/heic":
        return body[4:8] == b"ftyp"
    if mime == "application/pdf":
        return body[:4] == b"%PDF"
    return False


def blob_path(tenant_id: int, attachment_id: str) -> Path:
    """Pfad nur aus Mandanten-ID (int) und UUID → kein Path-Traversal möglich."""
    return blob_dir() / str(int(tenant_id)) / str(uuid.UUID(attachment_id))


# ---------- Prüfsummen ----------
# Cache je Datei-Identität (Inode, Grösse, mtime, ctime): ctime lässt sich ohne Root nicht zurücksetzen,
# daher wird jede Änderung erkannt, ohne bei jedem PDF-Bericht alle Belege neu einzulesen.
_hash_cache: dict[tuple, str] = {}
_cache_lock = threading.Lock()
_CACHE_MAX = 50_000


def fingerprint(path: Path) -> str:
    st = path.stat()
    return f"{st.st_dev}:{st.st_ino}:{st.st_size}:{st.st_mtime_ns}:{st.st_ctime_ns}"


def file_sha256(path: Path, known: tuple[str, str] | None = None) -> str:
    """SHA-256 der Datei. `known` = (Fingerabdruck, Prüfsumme) aus blob_checks: gilt, wenn der
    Fingerabdruck unverändert ist."""
    fp = fingerprint(path)
    key = (str(path), fp)
    with _cache_lock:
        hit = _hash_cache.get(key)
    if hit is not None:
        return hit
    if known is not None and known[0] == fp:
        with _cache_lock:
            _hash_cache[key] = known[1]
        return known[1]
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


def verify_blobs(db: Session, tenant: models.Tenant, use_cache: bool = True) -> dict:
    """SHA-256 jeder vorhandenen Datei nicht stornierter Belege gegen die Metadaten.
    Fehlende Dateien (noch nicht hochgeladen) sind kein Fehler, werden aber gezählt.
    `updates` = neu berechnete (Beleg, Fingerabdruck, Prüfsumme) für persist_blob_checks."""
    if not use_cache:          # Vollprüfung: jede Datei neu lesen
        clear_hash_cache()
    known = {c.attachment_id: (c.fingerprint, c.sha256) for c in db.scalars(
        select(models.BlobCheck).where(models.BlobCheck.tenant_id == tenant.id))} if use_cache else {}
    problems, checked, missing, updates = [], 0, 0, []
    for att in active_attachments(db, tenant.id):
        path = blob_path(tenant.id, att.id)
        if not path.is_file():
            missing += 1
            continue
        try:
            fp = fingerprint(path)
            digest = file_sha256(path, known.get(att.id))
        except OSError:
            log.warning("Beleg %s: Datei nicht lesbar", att.id)
            problems.append(f"Beleg {att.id}: Datei nicht lesbar")
            continue
        checked += 1
        if known.get(att.id) != (fp, digest):
            updates.append((att.id, fp, digest))
        if digest != att.sha256:
            problems.append(f"Beleg {att.id}: Datei verändert")
    return {"problems": problems, "checked": checked, "missing": missing, "updates": updates}


def persist_blob_checks(tenant_id: int, updates: list[tuple[str, str, str]]) -> None:
    """Prüfsummen-Cache speichern (eigene, kurze Transaktion; Fehler sind unkritisch)."""
    now = dt.datetime.now(dt.UTC).isoformat(timespec="seconds")
    try:
        with SessionLocal() as db:
            for aid, fp, digest in updates:
                row = db.get(models.BlobCheck, aid)
                if row is None:
                    db.add(models.BlobCheck(attachment_id=aid, tenant_id=tenant_id, fingerprint=fp,
                                            sha256=digest, checked_at=now))
                elif row.tenant_id == tenant_id:
                    row.fingerprint, row.sha256, row.checked_at = fp, digest, now
            db.commit()
    except SQLAlchemyError as e:
        log.warning("Prüfsummen-Cache nicht gespeichert (%s)", type(e).__name__)
