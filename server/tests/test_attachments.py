import hashlib
import io
import json
import os
import stat

import pytest
from sqlalchemy import text

from app import attachments, trips
from app.db import engine

from .conftest import T, bearer_token, new_vehicle, op, sync, uid
from .test_trips import FIRMA, firma_sync, pdf_text

JPEG = b"\xff\xd8\xff\xe0" + os.urandom(2000)
READER = bearer_token(groups=["/fahrzeugbuch/privat/lesen"], sub="user-3")


@pytest.fixture(autouse=True)
def blob_dir(tmp_path, monkeypatch):
    d = tmp_path / "attachments"
    monkeypatch.setenv("ATTACHMENT_DIR", str(d))
    monkeypatch.delenv("N8N_WEBHOOK_URL", raising=False)
    attachments.clear_hash_cache()
    yield d
    attachments.clear_hash_cache()


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def fuel(client, vid, full_tank=True, date="2026-03-01", km=10500):
    fid = uid()
    res = sync(client, op("fuel", fid, {"vehicle_id": vid, "date": date, "km": km, "liters": 40.0,
                                        "price_total": 70.0, "full_tank": full_tank}))
    assert res["results"][0]["status"] == "applied", res
    return fid


def meta(body=JPEG, **kw):
    return {"kind": "receipt", "sha256": sha(body), "mime": "image/jpeg", "size": len(body), **kw}


def new_attachment(client, data, aid=None):
    aid = aid or uid()
    r = sync(client, op("attachment", aid, data))["results"][0]
    assert r["status"] == "applied", r
    return aid


def put(client, aid, body=JPEG, ctype="image/jpeg", tenant="privat", headers=None):
    return client.put(f"/api/t/{tenant}/attachments/{aid}/blob", content=body,
                      headers={"Content-Type": ctype, **(headers or {})})


def tenant_id(slug="privat") -> int:
    with engine.connect() as conn:
        return conn.execute(text("SELECT id FROM tenants WHERE slug = :s"), {"s": slug}).scalar()


# ---------- Metadaten (Sync) ----------
def test_sync_metadata_refs_and_normalisation(client):
    vid = new_vehicle(client)
    fid = fuel(client, vid)
    mid = uid()
    sync(client, op("maintenance", mid, {"vehicle_id": vid, "date": "2026-03-02", "title": "Service"}))
    a1 = new_attachment(client, meta(fuel_id=fid, vehicle_id=vid, sha256=sha(JPEG).upper(),
                                     taken_at="2026-03-01T10:15:30.123+01:00", note="Shell"))
    a2 = new_attachment(client, meta(maintenance_id=mid, kind="other", mime="application/pdf"))
    a3 = new_attachment(client, meta(kind="odometer", vehicle_id=vid, mime="image/heic"))
    ch = client.get(f"{T}/changes").json()
    by_id = {a["id"]: a for a in ch["attachments"]}
    assert set(by_id) == {a1, a2, a3}
    a = by_id[a1]
    assert a["sha256"] == sha(JPEG) and a["taken_at"] == "2026-03-01T10:15:30+01:00"
    assert a == {"id": a1, "version": 1, "fuel_id": fid, "maintenance_id": None, "vehicle_id": vid,
                 "kind": "receipt", "sha256": sha(JPEG), "mime": "image/jpeg", "size": len(JPEG),
                 "taken_at": "2026-03-01T10:15:30+01:00", "note": "Shell", "deleted": False}
    hist = client.get(f"{T}/history/attachment/{a1}").json()
    assert hist[0]["action"] == "create" and hist[0]["data"]["sha256"] == sha(JPEG)


def test_sync_metadata_rejections(client):
    vid = new_vehicle(client)
    other = new_vehicle(client, name="Polo")
    fid = fuel(client, vid)
    foreign_fuel = uid()
    fv = uid()
    firma_sync(client, op("vehicle", fv, {"name": "Firmenauto"}),
               op("fuel", foreign_fuel, {"vehicle_id": fv, "date": "2026-03-01", "km": 1, "liters": 1,
                                         "price_total": 1}))
    cases = [
        meta(),                                                    # kein Bezug
        meta(kind="odometer"),                                     # Tacho ohne Fahrzeug
        meta(fuel_id=uid()),                                       # Tankvorgang fehlt
        meta(fuel_id=foreign_fuel),                                # fremder Mandant
        meta(fuel_id=fid, vehicle_id=other),                       # Fahrzeug passt nicht
        meta(fuel_id=fid, size=0),
        meta(fuel_id=fid, size=8 * 1024 * 1024 + 1),
        meta(fuel_id=fid, sha256="z" * 64),
        meta(fuel_id=fid, sha256="a" * 63),
        meta(fuel_id=fid, mime="image/png"),
        meta(fuel_id=fid, kind="selfie"),
        meta(fuel_id=fid, note="x" * 301),
        meta(fuel_id=fid, taken_at="2026-03-01T10:00:00"),          # ohne Offset
    ]
    res = sync(client, *[op("attachment", uid(), c) for c in cases])
    assert [r["status"] for r in res["results"]] == ["rejected"] * len(cases), res
    assert "Referenziertes Objekt (fuel_id) fehlt" in res["results"][2]["error"]
    assert "Referenziertes Objekt (fuel_id) fehlt" in res["results"][3]["error"]
    assert "vehicle_id passt nicht" in res["results"][4]["error"]
    ok = sync(client, op("attachment", uid(), meta(fuel_id=fid, size=8 * 1024 * 1024, note="x" * 300)))
    assert ok["results"][0]["status"] == "applied"
    # Payload ohne inf/NaN
    body = ('{"ops":[{"op_id":"%s","entity":"attachment","id":"%s","action":"upsert","data":'
            '{"fuel_id":"%s","kind":"receipt","sha256":"%s","mime":"image/jpeg","size":NaN}}]}'
            % (uid(), uid(), fid, sha(JPEG)))
    r = client.post(f"{T}/sync", content=body, headers={"Content-Type": "application/json"}).json()
    assert r["results"][0]["status"] == "rejected"


def test_metadata_immutable_after_upload(client, blob_dir):
    vid = new_vehicle(client)
    fid = fuel(client, vid)
    aid = new_attachment(client, meta(fuel_id=fid, sha256="0" * 64))
    # vor dem Upload: Korrektur erlaubt
    r = sync(client, op("attachment", aid, meta(fuel_id=fid), base=1))["results"][0]
    assert r["status"] == "applied"
    assert put(client, aid).status_code == 201
    r = sync(client, op("attachment", aid, meta(b"anders", fuel_id=fid), base=2))["results"][0]
    assert r["status"] == "rejected" and "unveränderlich" in r["error"]
    r = sync(client, op("attachment", aid, meta(fuel_id=fid, note="Quittung Shell"), base=2))["results"][0]
    assert r["status"] == "applied"


# ---------- Upload ----------
def test_upload_ok_idempotent_and_download(client, blob_dir):
    vid = new_vehicle(client)
    aid = new_attachment(client, meta(fuel_id=fuel(client, vid)))
    r = put(client, aid, ctype="image/jpeg; charset=binary")
    assert r.status_code == 201, r.text
    assert r.json() == {"stored": True, "existing": False}
    path = blob_dir / str(tenant_id()) / aid
    assert path.read_bytes() == JPEG
    assert stat.S_IMODE(path.stat().st_mode) == 0o640
    assert [p.name for p in path.parent.iterdir()] == [aid]          # keine tmp-Reste
    r = put(client, aid)
    assert r.status_code == 200 and r.json() == {"stored": True, "existing": True}

    r = client.get(f"{T}/attachments/{aid}/blob")
    assert r.status_code == 200 and r.content == JPEG
    assert r.headers["content-type"] == "image/jpeg"
    assert r.headers["content-disposition"].startswith(f'inline; filename="Beleg_receipt_{aid[:8]}.jpg"')
    assert r.headers["x-content-type-options"] == "nosniff"
    assert client.get(f"{T}/attachments/{aid.upper()}/blob").status_code == 200
    # Leserolle darf lesen, nicht schreiben
    assert client.get(f"{T}/attachments/{aid}/blob", headers=READER).content == JPEG
    assert put(client, aid, headers=READER).status_code == 403


def test_upload_errors(client, blob_dir):
    vid = new_vehicle(client)
    aid = new_attachment(client, meta(fuel_id=fuel(client, vid)))
    r = put(client, aid, body=JPEG[:-1] + b"\x00")
    assert r.status_code == 422 and r.json()["detail"] == "Prüfsumme stimmt nicht"
    r = put(client, aid, body=JPEG + b"\x00")
    assert r.status_code == 422 and r.json()["detail"] == "Grösse stimmt nicht"
    assert put(client, aid, ctype="image/heic").status_code == 415
    assert put(client, aid, ctype="application/octet-stream").status_code == 415
    assert client.put(f"{T}/attachments/{aid}/blob", content=JPEG).status_code == 415   # ohne Content-Type
    assert put(client, uid()).status_code == 404                                       # ohne Metadaten
    assert put(client, "../../etc/passwd").status_code == 404
    assert put(client, "kein-uuid").status_code == 404
    assert put(client, aid, tenant="fremd").status_code == 403
    assert not (blob_dir / str(tenant_id()) / aid).exists()
    assert client.get(f"{T}/attachments/{aid}/blob").status_code == 404                # Datei fehlt
    assert client.get(f"{T}/attachments/{uid()}/blob").status_code == 404              # Metadaten fehlen
    del client.headers["Authorization"]
    assert put(client, aid).status_code == 401


def test_tenant_isolation(client, blob_dir):
    vid = new_vehicle(client)
    aid = new_attachment(client, meta(fuel_id=fuel(client, vid)))
    assert put(client, aid).status_code == 201
    # anderer Benutzer mit Schreibrecht auf "firma": ID aus "privat" ist dort unbekannt
    assert put(client, aid, tenant="firma", headers=FIRMA).status_code == 404
    assert client.get(f"/api/t/firma/attachments/{aid}/blob", headers=FIRMA).status_code == 404
    # gleiche ID im anderen Mandanten kann nicht angelegt werden
    r = firma_sync(client, op("attachment", aid, meta(kind="odometer", vehicle_id=uid())))
    assert r["results"][0]["status"] == "rejected"


def test_storno_keeps_file(client, blob_dir):
    vid = new_vehicle(client)
    aid = new_attachment(client, meta(fuel_id=fuel(client, vid)))
    assert put(client, aid).status_code == 201
    r = sync(client, op("attachment", aid, action="delete"))["results"][0]
    assert r["status"] == "applied"
    assert (blob_dir / str(tenant_id()) / aid).read_bytes() == JPEG
    assert client.get(f"{T}/attachments/{aid}/blob").content == JPEG
    assert put(client, aid).status_code == 200                       # idempotent auch nach Storno
    # Storno vor dem Upload: Upload wird abgelehnt
    other = new_attachment(client, meta(fuel_id=fuel(client, vid, km=10600)))
    sync(client, op("attachment", other, action="delete"))
    r = put(client, other)
    assert r.status_code == 409 and r.json()["detail"] == "Beleg storniert"


# ---------- Body-Limit ----------
def test_body_limits(client, blob_dir):
    vid = new_vehicle(client)
    big = b"\xff\xd8\xff" + os.urandom(2 * 1024 * 1024)            # > Standardlimit 1 MiB
    aid = new_attachment(client, meta(big, fuel_id=fuel(client, vid)))
    assert put(client, aid, body=big).status_code == 201
    too_big = b"\0" * (8 * 1024 * 1024 + 1)
    r = put(client, uid(), body=too_big)
    assert r.status_code == 413 and r.json()["detail"] == "Anfrage zu gross"
    # andere Pfade bleiben beim Standardlimit (1 MiB)
    r = client.post(f"{T}/sync", content=b"{" + b" " * (1024 * 1024) + b"}",
                    headers={"Content-Type": "application/json"})
    assert r.status_code == 413
    r = client.put(f"{T}/attachments/{aid}/blobx", content=b"\0" * (1024 * 1024 + 1))
    assert r.status_code == 413
    # ohne Token: 401 vor dem Body-Limit
    r = client.put(f"{T}/attachments/{aid}/blob", content=too_big, headers={"Authorization": ""})
    assert r.status_code == 401


# ---------- Webhook ----------
class _Resp(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def test_upload_webhook(client, monkeypatch):
    calls = []

    def fake_urlopen(req, timeout=None):
        calls.append((req.full_url, req.get_method(), json.loads(req.data), timeout))
        return _Resp(b"ok")

    monkeypatch.setattr(trips, "_open", fake_urlopen)
    vid = new_vehicle(client)
    fid = fuel(client, vid)
    aid = new_attachment(client, meta(fuel_id=fid, kind="pump"))
    monkeypatch.setenv("N8N_WEBHOOK_URL", "https://n8n.example.test/webhook/beleg")
    assert put(client, aid).status_code == 201
    assert calls == [("https://n8n.example.test/webhook/beleg", "POST", {
        "event": "attachment.uploaded", "tenant": "privat", "attachment_id": aid, "kind": "pump",
        "fuel_id": fid, "maintenance_id": None, "mime": "image/jpeg", "sha256": sha(JPEG),
        "download_path": f"/api/t/privat/attachments/{aid}/blob"}, 5)]
    assert put(client, aid).status_code == 200                       # bereits vorhanden → kein 2. Aufruf
    assert len(calls) == 1

    def broken(req, timeout=None):
        raise OSError("n8n down")

    monkeypatch.setattr(trips, "_open", broken)
    other = new_attachment(client, meta(fuel_id=fid))
    assert put(client, other).status_code == 201                     # Fehler nur geloggt


# ---------- Integrität ----------
def test_verify_detects_changed_file_and_counts_missing(client, blob_dir):
    vid = new_vehicle(client)
    fid = fuel(client, vid)
    aid = new_attachment(client, meta(fuel_id=fid))
    pending = new_attachment(client, meta(b"noch nicht hochgeladen", fuel_id=fid))
    v = client.get(f"{T}/audit/verify").json()
    assert v["ok"] is True and v["blobs_checked"] == 0 and v["blobs_missing"] == 2
    assert put(client, aid).status_code == 201
    v = client.get(f"{T}/audit/verify").json()
    assert v["ok"] is True and v["blobs_checked"] == 1 and v["blobs_missing"] == 1
    path = blob_dir / str(tenant_id()) / aid
    path.write_bytes(JPEG + b"manipuliert")
    v = client.get(f"{T}/audit/verify").json()
    assert v["ok"] is False and v["chain_ok"] is True and v["state_ok"] is True
    assert f"Beleg {aid}: Datei verändert" in v["problems"]
    assert v["blobs_checked"] == 1
    # gleiche Grösse, anderer Inhalt (Cache darf das nicht verdecken)
    path.write_bytes(JPEG[:-1] + b"\x01")
    v = client.get(f"{T}/audit/verify").json()
    assert f"Beleg {aid}: Datei verändert" in v["problems"]
    pdf = client.get(f"{T}/vehicles/{vid}/report.pdf?from=2026-01-01&to=2026-12-31")
    assert pdf.status_code == 200 and "Datei ver" in pdf_text(pdf.content)
    # verändert + Upload → nicht überschreiben
    assert put(client, aid).status_code == 409
    # stornierte Belege werden nicht geprüft
    sync(client, op("attachment", aid, action="delete"), op("attachment", pending, action="delete"))
    v = client.get(f"{T}/audit/verify").json()
    assert v["ok"] is True and v["blobs_checked"] == 0 and v["blobs_missing"] == 0


def test_metadata_tampering_in_db_detected(client, blob_dir):
    vid = new_vehicle(client)
    aid = new_attachment(client, meta(fuel_id=fuel(client, vid)))
    assert put(client, aid).status_code == 201
    with engine.begin() as conn:
        conn.execute(text("UPDATE attachments SET sha256 = :s WHERE id = :i"), {"s": "0" * 64, "i": aid})
    v = client.get(f"{T}/audit/verify").json()
    assert v["state_ok"] is False and any(aid in p for p in v["problems"])


# ---------- PDF ----------
def test_report_marks_fuel_with_receipt(client):
    vid = new_vehicle(client)
    with_receipt = fuel(client, vid, full_tank=False, date="2026-03-01", km=10500)
    fuel(client, vid, full_tank=False, date="2026-03-05", km=10900)
    aid = new_attachment(client, meta(fuel_id=with_receipt))
    url = f"{T}/vehicles/{vid}/report.pdf?from=2026-01-01&to=2026-12-31"
    txt = pdf_text(client.get(url).content)
    assert "(Beleg)" in txt and txt.count("(ja)") == 1
    sync(client, op("attachment", aid, action="delete"))
    txt = pdf_text(client.get(url).content)
    assert txt.count("(ja)") == 0
    assert "Storniert" in txt and "Quittung, image/jpeg" in txt          # Änderungsprotokoll
