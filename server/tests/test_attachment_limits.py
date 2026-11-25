"""S17 Kontingent je Mandant + Magic Bytes, E18 persistenter Prüfsummen-Cache, S9 Beleg ohne Cache."""
import types

import pytest
from sqlalchemy import select

from app import attachments, models
from app.db import SessionLocal

from .conftest import T, new_vehicle
from .test_attachments import (
    JPEG,
    blob_dir,  # noqa: F401  (Fixture)
    fuel,
    meta,
    new_attachment,
    put,
    sha,
    tenant_id,
)

PDF = b"%PDF-1.7\n" + b"x" * 500
HEIC = b"\x00\x00\x00\x18ftypheic" + b"\x00" * 500


def test_magic_bytes_checked(client):
    vid = new_vehicle(client)
    fid = fuel(client, vid)
    for mime, good, bad in (("image/jpeg", JPEG, PDF), ("application/pdf", PDF, JPEG), ("image/heic", HEIC, JPEG)):
        a_bad = new_attachment(client, meta(bad, fuel_id=fid, mime=mime))
        r = put(client, a_bad, bad, ctype=mime)
        assert r.status_code == 415 and "Magic Bytes" in r.json()["detail"], mime
        a_good = new_attachment(client, meta(good, fuel_id=fid, mime=mime))
        assert put(client, a_good, good, ctype=mime).status_code == 201, mime


def test_quota_per_tenant(client, monkeypatch):
    monkeypatch.setenv("ATTACHMENT_QUOTA_MB", str(3000 / 1024 / 1024))        # ≈ 3000 Byte
    vid = new_vehicle(client)
    fid = fuel(client, vid)
    a1 = new_attachment(client, meta(JPEG, fuel_id=fid))
    assert put(client, a1).status_code == 201                                  # 2004 Byte
    other = JPEG[:3] + b"\x01" * 1500
    a2 = new_attachment(client, meta(other, fuel_id=fid))
    r = put(client, a2, other)
    assert r.status_code == 507 and "Speicherkontingent" in r.json()["detail"]
    assert put(client, a1).status_code == 200                                  # idempotent bleibt möglich
    monkeypatch.delenv("ATTACHMENT_QUOTA_MB")
    assert put(client, a2, other).status_code == 201


def test_download_not_cacheable(client):
    vid = new_vehicle(client)
    aid = new_attachment(client, meta(fuel_id=fuel(client, vid)))
    put(client, aid)
    r = client.get(f"{T}/attachments/{aid}/blob")
    assert r.status_code == 200 and r.headers["cache-control"] == "no-store" and r.headers["etag"]


def test_persistent_hash_cache(client, blob_dir, monkeypatch):  # noqa: F811
    vid = new_vehicle(client)
    aid = new_attachment(client, meta(fuel_id=fuel(client, vid)))
    put(client, aid)
    attachments.clear_hash_cache()
    assert client.get(f"{T}/audit/verify").json()["blobs_checked"] == 1
    tid = tenant_id()
    with SessionLocal() as db:
        row = db.scalar(select(models.BlobCheck).where(models.BlobCheck.attachment_id == aid))
    assert row.sha256 == sha(JPEG) and row.tenant_id == tid
    # „Neustart“: Prozess-Cache leer, Datei unverändert → kein erneutes Lesen nötig
    attachments.clear_hash_cache()
    real = attachments.hashlib

    def no_hashing(*a, **kw):
        raise AssertionError("Datei wurde neu gelesen")

    monkeypatch.setattr(attachments, "hashlib", types.SimpleNamespace(sha256=no_hashing))
    v = client.get(f"{T}/audit/verify").json()
    assert v["ok"] and v["blobs_checked"] == 1
    # Datei verändert → Fingerabdruck anders → neu berechnet → erkannt
    monkeypatch.setattr(attachments, "hashlib", real)
    path = blob_dir / str(tid) / aid
    path.chmod(0o640)
    path.write_bytes(JPEG[:-1] + b"\x00")
    v = client.get(f"{T}/audit/verify").json()
    assert not v["ok"] and any("Datei verändert" in p for p in v["problems"])
    # Vollprüfung liest alle Dateien unabhängig vom Cache
    monkeypatch.setattr(attachments, "hashlib", types.SimpleNamespace(sha256=no_hashing))
    with pytest.raises(AssertionError, match="neu gelesen"):
        client.get(f"{T}/audit/verify?full=1")
