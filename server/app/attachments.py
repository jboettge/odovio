"""Belegdateien (Fotos/PDF) ausserhalb der Datenbank.

Env:
  STORAGE_BACKEND   fs (Default) | s3 (S3-kompatibel, siehe app/s3.py: S3_ENDPOINT, S3_BUCKET, S3_REGION,
                    S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY, S3_PREFIX, S3_FORCE_PATH_STYLE)
  FILES_DIR         fs: Ablage (Alias ATTACHMENT_DIR), Default ./data/attachments → <dir>/<tenant_id>/<attachment_id>
                    (ohne Endung; der Inhaltstyp steht in den Metadaten). Mehrere Replikas: nur mit RWX-Volume.
                    s3: Objekt <S3_PREFIX><tenant_id>/<attachment_id>, PUT mit If-None-Match: * (nie überschrieben)
  MAX_UPLOAD_BYTES  Body-Limit für …/blob (RequestGuard), Default 8 MiB
  ATTACHMENT_QUOTA_MB  Speicherkontingent je Mandant (Summe der Dateien), Default 2048

Die Metadaten (inkl. `sha256`) laufen über den Sync und damit durch die Revisionskette; die Datei ist
über die Prüfsumme daran gebunden. Dateien werden nie überschrieben oder gelöscht (Storno = Soft-Delete
der Metadaten), atomar geschrieben (tmp + rename) und von der Integritätsprüfung nachgerechnet.
Der Inhalt muss zum Typ passen (Magic Bytes: JPEG, HEIC/HEIF, PDF).

Prüfsummen-Cache: im Prozess und persistent (Tabelle blob_checks, je Datei-Fingerabdruck) → nach einem
Neustart liest das erste PDF nicht alle Belege des Mandanten neu. Eine Zeile in blob_checks belegt zugleich,
dass die Datei existiert hat (beim Upload angelegt, von jeder Prüfung bestätigt): fehlt die Datei später, ist
das ein Befund «Datei fehlt» (inkrementell und voll). Nur nie hochgeladene Belege gelten als ausstehend.
"""
import datetime as dt
import hashlib
import logging
import os
import tempfile
import threading
import uuid
from functools import lru_cache
from pathlib import Path

from fastapi import HTTPException
from fastapi.responses import FileResponse, StreamingResponse
from sqlalchemy import select
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from . import models, s3
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
    return Path(os.environ.get("FILES_DIR") or os.environ.get("ATTACHMENT_DIR") or "./data/attachments")


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


HEIF_BRANDS = frozenset({b"heic", b"heix", b"heim", b"heis", b"hevc", b"hevx", b"mif1", b"msf1"})


def _heif(body: bytes) -> bool:
    """ISO-BMFF mit `ftyp`-Box an Offset 0 und HEIF-Brand (Major-Brand oder kompatible Brand) – andere ISO-BMFF
    wie MP4/MOV (isom, mp42, qt …) nicht (Review X13)."""
    if body[4:8] != b"ftyp":
        return False
    size = int.from_bytes(body[0:4], "big")
    if size < 16 or size > len(body) or size % 4:
        size = min(len(body), 16)          # unplausible Boxgrösse: nur Major-Brand werten
    brands = [body[8:12]] + [body[i:i + 4] for i in range(16, size, 4)]
    return any(b in HEIF_BRANDS for b in brands)


def content_matches(mime: str, body: bytes) -> bool:
    """Magic Bytes: JPEG FF D8 FF, HEIC/HEIF ISO-BMFF (`ftyp` an Offset 4 und HEIF-Brand), PDF `%PDF`."""
    if mime == "image/jpeg":
        return body[:3] == b"\xff\xd8\xff"
    if mime == "image/heic":
        return _heif(body)
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


# ---------- Speicher-Backends ----------
class StorageError(Exception):
    """Belegspeicher nicht erreichbar (→ 503)."""


class FsStorage:
    """Verzeichnis (FILES_DIR/ATTACHMENT_DIR); atomar geschrieben (tmp + rename)."""

    name = "fs"

    def exists(self, tenant_id: int, aid: str) -> bool:
        return blob_path(tenant_id, aid).is_file()

    def fingerprints(self, tenant_id: int) -> dict[str, str]:
        d = blob_dir() / str(int(tenant_id))
        out = {}
        try:
            with os.scandir(d) as it:
                for e in it:
                    if e.is_file() and not e.name.startswith(".tmp-"):
                        try:
                            out[e.name] = fingerprint(Path(e.path))
                        except OSError:
                            out[e.name] = "unreadable"
        except FileNotFoundError:
            pass
        return out

    def sha256(self, tenant_id: int, aid: str, fp: str | None = None, known: tuple[str, str] | None = None) -> str:
        return file_sha256(blob_path(tenant_id, aid), known)

    def put(self, tenant_id: int, aid: str, data: bytes, mime: str, sha256: str) -> bool:
        store_blob(blob_path(tenant_id, aid), data)
        return True

    def usage(self, tenant_id: int) -> int:
        return tenant_usage(tenant_id)

    def response(self, tenant_id: int, aid: str, media_type: str, headers: dict):
        path = blob_path(tenant_id, aid)
        if not path.is_file():
            raise HTTPException(404, "Datei nicht vorhanden")
        return FileResponse(path, media_type=media_type, headers=headers)

    def ping(self) -> None:
        if not blob_dir().is_dir():
            raise StorageError("Belegverzeichnis fehlt")


class S3Storage:
    """S3-kompatibel; Fingerabdruck = ETag + Grösse + Last-Modified (jede Änderung des Objekts ändert ihn)."""

    name = "s3"

    def __init__(self, cfg: s3.S3Config):
        self.client = s3.S3Client(cfg)

    @staticmethod
    def _name(tenant_id: int, aid: str) -> str:
        return f"{int(tenant_id)}/{uuid.UUID(aid)}"

    def _call(self, fn, *args):
        try:
            return fn(*args)
        except s3.S3Error as e:
            log.warning("Belegspeicher (S3): %s", e)
            raise StorageError(str(e)) from None

    def exists(self, tenant_id: int, aid: str) -> bool:
        return self._call(self.client.head, self._name(tenant_id, aid)) is not None

    def fingerprints(self, tenant_id: int) -> dict[str, str]:
        return {o.key.rsplit("/", 1)[-1]: o.fingerprint
                for o in self._call(self.client.list, f"{int(tenant_id)}/")}

    def sha256(self, tenant_id: int, aid: str, fp: str | None = None, known: tuple[str, str] | None = None) -> str:
        name = self._name(tenant_id, aid)
        if fp is None:
            info = self._call(self.client.head, name)
            if info is None:
                raise StorageError("Objekt fehlt")
            fp = info.fingerprint
        key = ("s3", name, fp)
        with _cache_lock:
            hit = _hash_cache.get(key)
        if hit is not None:
            return hit
        if known is not None and known[0] == fp:
            digest = known[1]
        else:
            resp = self._call(self.client.get, name)
            if resp is None:
                raise StorageError("Objekt fehlt")
            h = hashlib.sha256()
            try:
                with resp:
                    while chunk := resp.read(_CHUNK):
                        h.update(chunk)
            except OSError as e:
                raise StorageError(type(e).__name__) from None
            digest = h.hexdigest()
        with _cache_lock:
            if len(_hash_cache) >= _CACHE_MAX:
                _hash_cache.clear()
            _hash_cache[key] = digest
        return digest

    def put(self, tenant_id: int, aid: str, data: bytes, mime: str, sha256: str) -> bool:
        return self._call(self.client.put, self._name(tenant_id, aid), data, mime, sha256)

    def usage(self, tenant_id: int) -> int:
        return sum(o.size for o in self._call(self.client.list, f"{int(tenant_id)}/"))

    def response(self, tenant_id: int, aid: str, media_type: str, headers: dict):
        resp = self._call(self.client.get, self._name(tenant_id, aid))
        if resp is None:
            raise HTTPException(404, "Datei nicht vorhanden")
        length = resp.headers.get("Content-Length")

        def chunks():
            with resp:
                while chunk := resp.read(256 * 1024):
                    yield chunk
        return StreamingResponse(chunks(), media_type=media_type,
                                 headers={**headers, **({"Content-Length": length} if length else {})})

    def ping(self) -> None:
        self._call(self.client.ping)


@lru_cache(maxsize=4)
def _s3_storage(cfg: s3.S3Config) -> S3Storage:
    return S3Storage(cfg)


def storage_backend() -> str:
    return (os.environ.get("STORAGE_BACKEND") or "fs").strip().lower()


def storage() -> FsStorage | S3Storage:
    if storage_backend() == "s3":
        try:
            return _s3_storage(s3.S3Config.from_env())
        except s3.S3Error as e:
            raise StorageError(str(e)) from None
    return FsStorage()


def check_storage_config() -> list[str]:
    name = storage_backend()
    if name not in ("fs", "s3"):
        return [f"STORAGE_BACKEND={name} unbekannt (fs | s3)"]
    if name == "s3":
        try:
            cfg = s3.S3Config.from_env()
        except s3.S3Error as e:
            return [str(e)]
        if not cfg.access_key or not cfg.secret_key:
            return ["S3_ACCESS_KEY_ID/S3_SECRET_ACCESS_KEY fehlen"]
    return []


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
    Fehlende Dateien: nie hochgeladen → kein Fehler, gezählt (`missing`); belegt vorhanden gewesen (Zeile in
    blob_checks: Upload bzw. frühere Prüfung) → Befund «Datei fehlt» (gelöscht/verloren).
    `updates` = neu berechnete (Beleg, Fingerabdruck, Prüfsumme) für persist_blob_checks."""
    if not use_cache:          # Vollprüfung: jede Datei neu lesen
        clear_hash_cache()
    seen = {c.attachment_id: (c.fingerprint, c.sha256) for c in db.scalars(
        select(models.BlobCheck).where(models.BlobCheck.tenant_id == tenant.id))}
    known = seen if use_cache else {}
    problems, checked, missing, updates = [], 0, 0, []
    try:
        st = storage()
        present = st.fingerprints(tenant.id)
    except StorageError:
        return {"problems": ["Belegspeicher nicht erreichbar"], "checked": 0, "missing": 0, "updates": []}
    for att in active_attachments(db, tenant.id):
        try:
            fp = present.get(str(uuid.UUID(att.id)))
        except ValueError:
            fp = None
        if fp is None:
            if att.id in seen:
                problems.append(f"Beleg {att.id}: Datei fehlt (war vorhanden)")
            else:
                missing += 1
            continue
        try:
            digest = st.sha256(tenant.id, att.id, fp, known.get(att.id))
            if st.name == "fs":
                fp = fingerprint(blob_path(tenant.id, att.id))
        except (OSError, StorageError):
            log.warning("Beleg %s: Datei nicht lesbar", att.id)
            problems.append(f"Beleg {att.id}: Datei nicht lesbar")
            continue
        checked += 1
        if known.get(att.id) != (fp, digest):
            updates.append((att.id, fp, digest))
        if digest != att.sha256:
            problems.append(f"Beleg {att.id}: Datei verändert")
    return {"problems": problems, "checked": checked, "missing": missing, "updates": updates}


UPLOADED = "upload"        # Fingerabdruck-Platzhalter: Datei beim Upload gespeichert, noch nicht nachgerechnet


def mark_uploaded(db: Session, tenant_id: int, aid: str, digest: str) -> None:
    """Nach dem Speichern (in der Sitzung der Anfrage, beendet deren Transaktion): Existenz der Datei in
    blob_checks festhalten, falls noch keine Zeile. Der Platzhalter-Fingerabdruck passt zu keiner Datei → die
    nächste Prüfung rechnet die Prüfsumme nach."""
    try:
        if db.get(models.BlobCheck, aid) is None:
            db.add(models.BlobCheck(attachment_id=aid, tenant_id=tenant_id, fingerprint=UPLOADED, sha256=digest,
                                    checked_at=dt.datetime.now(dt.UTC).isoformat(timespec="seconds")))
        db.commit()
    except SQLAlchemyError as e:
        db.rollback()
        log.warning("Beleg %s: Upload-Vermerk nicht gespeichert (%s)", aid, type(e).__name__)


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
