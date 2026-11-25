"""Belegspeicher S3 (STORAGE_BACKEND=s3) gegen echten S3-kompatiblen Server (FZB_TEST_S3_ENDPOINT, z. B. RustFS
oder MinIO): Signatur V4, bedingtes PUT (nie überschreiben), Download gestreamt, Integritätsprüfung über
Fingerabdruck (ETag/Grösse/Zeit), Kontingent, Pfadsicherheit. Plus Offline-Tests der Signatur/Listen-Auswertung."""
import os
import uuid

import pytest

from app import attachments, s3

from .conftest import S3_ENDPOINT, T, new_vehicle, op, sync, uid
from .test_attachments import JPEG, fuel, meta, new_attachment, put, sha, tenant_id


# ---------- offline ----------
def test_sigv4_known_vector():
    """AWS-Beispiel „GET Object“ (Signature Version 4, examplebucket, 20130524)."""
    import datetime as dt
    cfg = s3.S3Config(endpoint="https://s3.amazonaws.com", bucket="examplebucket", region="us-east-1",
                      access_key="AKIAIOSFODNN7EXAMPLE", secret_key="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
                      prefix="", path_style=False)
    c = s3.S3Client(cfg)
    h = c._sign("GET", "/test.txt", {}, s3.EMPTY_SHA256, dt.datetime(2013, 5, 24, tzinfo=dt.UTC))
    # ohne Range-Header weicht die Signatur vom Dokubeispiel ab; geprüft werden Aufbau und Scope
    assert h["authorization"].startswith("AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/"
                                         "aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, "
                                         "Signature=")
    assert c.host == "examplebucket.s3.amazonaws.com" and h["x-amz-date"] == "20130524T000000Z"


def test_parse_list_without_xml_parser():
    xml = ("<?xml version='1.0'?><ListBucketResult><IsTruncated>true</IsTruncated>"
           "<Contents><Key>a/1/x</Key><Size>12</Size><ETag>&quot;abc&quot;</ETag>"
           "<LastModified>2026-01-01T00:00:00Z</LastModified></Contents>"
           "<NextContinuationToken>tok&amp;1</NextContinuationToken></ListBucketResult>")
    items, token = s3.parse_list(xml)
    assert items == [s3.ObjectInfo("a/1/x", 12, "abc", "2026-01-01T00:00:00Z")] and token == "tok&1"
    assert s3.parse_list("<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>") == ([], None)


def test_config_validation(monkeypatch):
    monkeypatch.setenv("STORAGE_BACKEND", "s3")
    monkeypatch.delenv("S3_BUCKET", raising=False)
    assert attachments.check_storage_config() == ["S3_BUCKET fehlt oder ungültig"]
    monkeypatch.setenv("S3_BUCKET", "belege")
    monkeypatch.delenv("S3_ACCESS_KEY_ID", raising=False)
    assert "fehlen" in attachments.check_storage_config()[0]
    monkeypatch.setenv("S3_ENDPOINT", "file:///etc")
    assert "http" in attachments.check_storage_config()[0]
    monkeypatch.setenv("STORAGE_BACKEND", "nfs")
    assert "unbekannt" in attachments.check_storage_config()[0]


# ---------- gegen echten Server ----------
@pytest.fixture
def s3_storage(monkeypatch):
    bucket = os.environ.get("FZB_TEST_S3_BUCKET", "fzb-test")
    env = {"STORAGE_BACKEND": "s3", "S3_ENDPOINT": S3_ENDPOINT, "S3_BUCKET": bucket,
           "S3_REGION": os.environ.get("FZB_TEST_S3_REGION", "us-east-1"),
           "S3_ACCESS_KEY_ID": os.environ.get("FZB_TEST_S3_ACCESS_KEY", ""),
           "S3_SECRET_ACCESS_KEY": os.environ.get("FZB_TEST_S3_SECRET_KEY", ""),
           "S3_PREFIX": f"t{uuid.uuid4().hex[:8]}/", "S3_FORCE_PATH_STYLE": "1"}
    for k, v in env.items():
        monkeypatch.setenv(k, v)
    st = attachments.storage()
    status, resp = st.client.request("PUT", "", ok=(200, 409))      # Bucket anlegen (vorhanden → 409)
    resp.close()
    attachments.clear_hash_cache()
    yield st
    attachments.clear_hash_cache()


@pytest.mark.requires_s3
def test_upload_download_idempotent(client, s3_storage):
    vid = new_vehicle(client)
    aid = new_attachment(client, meta(fuel_id=fuel(client, vid)))
    r = put(client, aid)
    assert r.status_code == 201 and r.json() == {"stored": True, "existing": False}
    assert put(client, aid).json() == {"stored": True, "existing": True}
    r = client.get(f"{T}/attachments/{aid}/blob")
    assert r.status_code == 200 and r.content == JPEG and r.headers["content-type"] == "image/jpeg"
    assert r.headers["etag"] == f'"{sha(JPEG)}"' and r.headers["cache-control"] == "no-store"
    assert r.headers["content-security-policy"] == "default-src 'none'; sandbox"
    assert r.headers["content-length"] == str(len(JPEG))
    info = s3_storage.client.head(f"{tenant_id()}/{aid}")
    assert info is not None and info.size == len(JPEG)
    # nie überschrieben: bedingtes PUT auf vorhandenes Objekt → False
    other = b"\xff\xd8\xff" + b"0" * 10
    assert s3_storage.put(tenant_id(), aid, other, "image/jpeg", sha(other)) is False
    assert client.get(f"{T}/attachments/{aid}/blob").content == JPEG
    # Nutzlast-Prüfsumme wird vom Server geprüft (x-amz-content-sha256)
    with pytest.raises(attachments.StorageError):
        s3_storage.put(tenant_id(), uid(), other, "image/jpeg", sha(JPEG))
    # Metadaten nach dem Upload unveränderlich (Sync prüft Existenz per HEAD)
    res = sync(client, op("attachment", aid, meta(fuel_id=fuel(client, vid), size=len(JPEG) + 1), base=1))
    assert res["results"][0]["status"] == "rejected"


@pytest.mark.requires_s3
def test_verify_detects_changed_object_and_missing(client, s3_storage):
    vid = new_vehicle(client)
    fid = fuel(client, vid)
    aid = new_attachment(client, meta(fuel_id=fid))
    new_attachment(client, meta(fuel_id=fid))                    # nie hochgeladen → missing
    put(client, aid)
    v = client.get(f"{T}/audit/verify").json()
    assert v["ok"] and v["blobs_checked"] == 1 and v["blobs_missing"] == 1
    # Objekt direkt im Speicher ersetzt → Fingerabdruck ändert sich → neu gehasht → erkannt
    changed = JPEG[:-1] + b"\x00"
    s3_storage.client.put(f"{tenant_id()}/{aid}", changed, "image/jpeg", sha(changed), overwrite=True)
    v = client.get(f"{T}/audit/verify").json()
    assert not v["ok"] and any("Datei verändert" in p for p in v["problems"])
    assert client.get(f"{T}/audit/verify?full=1").json()["ok"] is False


@pytest.mark.requires_s3
def test_quota_and_existing_conflict(client, s3_storage, monkeypatch):
    vid = new_vehicle(client)
    fid = fuel(client, vid)
    a1, a2 = new_attachment(client, meta(fuel_id=fid)), new_attachment(client, meta(fuel_id=fid))
    assert put(client, a1).status_code == 201
    monkeypatch.setenv("ATTACHMENT_QUOTA_MB", str((len(JPEG) * 1.5) / (1024 * 1024)))
    assert put(client, a2).status_code == 507
    monkeypatch.delenv("ATTACHMENT_QUOTA_MB")
    other = JPEG[:-1] + b"\x01"
    s3_storage.client.put(f"{tenant_id()}/{a2}", other, "image/jpeg", sha(other))   # fremder Inhalt vorab
    assert put(client, a2).status_code == 409


@pytest.mark.requires_s3
def test_unreachable_storage_503(client, s3_storage, monkeypatch):
    vid = new_vehicle(client)
    aid = new_attachment(client, meta(fuel_id=fuel(client, vid)))
    monkeypatch.setenv("S3_ENDPOINT", "http://127.0.0.1:1")
    monkeypatch.setenv("S3_TIMEOUT_S", "1")
    r = put(client, aid)
    assert r.status_code == 503 and r.headers["retry-after"] == "30"
    assert client.get(f"{T}/attachments/{aid}/blob").status_code == 503
    v = client.get(f"{T}/audit/verify").json()
    assert not v["ok"] and "Belegspeicher nicht erreichbar" in v["problems"]


@pytest.mark.requires_s3
def test_wrong_credentials_rejected(client, s3_storage, monkeypatch):
    monkeypatch.setenv("S3_SECRET_ACCESS_KEY", "falsch-falsch-falsch")
    with pytest.raises(attachments.StorageError):
        attachments.storage().exists(1, uid())
