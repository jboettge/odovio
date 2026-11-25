import base64
import os

import pytest
from sqlalchemy import select, text

from app import models
from app.audit import compute_hash
from app.db import SessionLocal, engine
from app.models import GENESIS

from .conftest import T, new_vehicle, op, sync, uid
from .test_audit import _disable_triggers, _seed

KEY = base64.b64encode(os.urandom(32)).decode()


def test_state_tampering_in_business_table_detected(client):
    vid, fid = _seed(client)
    with engine.begin() as conn:
        conn.execute(text("UPDATE fuel_entries SET price_total = 9999 WHERE id = :i"), {"i": fid})
    v = client.get(f"{T}/audit/verify").json()
    assert v["chain_ok"] is True and v["state_ok"] is False and v["ok"] is False
    assert any(fid in p for p in v["problems"])
    pdf = client.get(f"{T}/vehicles/{vid}/report.pdf").content
    assert pdf.startswith(b"%PDF")


def test_row_without_revision_detected(client):
    vid = new_vehicle(client)
    with engine.begin() as conn:
        tid = conn.execute(text("SELECT id FROM tenants WHERE slug='privat'")).scalar()
        conn.execute(text("INSERT INTO odometer_readings (id, tenant_id, version, deleted, last_seq, vehicle_id, "
                          "date, km) VALUES (:i, :t, 1, false, 0, :v, '2026-01-01', 1)"),
                     {"i": uid(), "t": tid, "v": vid})
    v = client.get(f"{T}/audit/verify").json()
    assert not v["ok"] and "ohne Revision" in v["problems"][0]


def _rewrite_chain(liters_from="40.0", liters_to="4.0"):
    """Angreifer mit DB-Vollzugriff: Daten ändern und die gesamte Kette konsistent neu berechnen."""
    with engine.begin() as conn:
        _disable_triggers(conn)
        conn.exec_driver_sql(f"UPDATE revisions SET data = REPLACE(data, '\"liters\":{liters_from}', "
                             f"'\"liters\":{liters_to}')")
    with SessionLocal() as db:
        tenant = db.scalar(select(models.Tenant).where(models.Tenant.slug == "privat"))
        prev = GENESIS
        for rev in db.scalars(select(models.Revision).where(models.Revision.tenant_id == tenant.id)
                              .order_by(models.Revision.seq)):
            rev.prev_hash = prev
            rev.hash = prev = compute_hash(prev, rev)
        tenant.head_hash = prev
        db.commit()


def test_full_chain_rewrite_undetected_without_anchor(client):
    _seed(client)
    _rewrite_chain()
    v = client.get(f"{T}/audit/verify").json()
    assert v["chain_ok"] is True and v["signed"] is False  # ohne Anker nicht erkennbar (dokumentierte Grenze)


def test_signed_anchor_detects_full_chain_rewrite(client, monkeypatch):
    monkeypatch.setenv("ANCHOR_SIGNING_KEY", KEY)
    monkeypatch.setenv("ANCHOR_INTERVAL_MIN", "0")
    vid, fid = _seed(client)
    a = client.get(f"{T}/audit/anchors").json()
    assert a["anchors"] and a["public_key"] and len(a["anchors"][0]["signature"]) == 128
    assert client.get(f"{T}/audit/verify").json()["ok"] is True
    _rewrite_chain()
    v = client.get(f"{T}/audit/verify").json()
    assert v["chain_ok"] is True and v["ok"] is False
    assert any("nachträglich verändert" in p for p in v["problems"])


def test_anchor_interval_and_report_forces_anchor(client, monkeypatch):
    monkeypatch.setenv("ANCHOR_SIGNING_KEY", KEY)
    vid = new_vehicle(client)
    sync(client, op("odometer", uid(), {"vehicle_id": vid, "date": "2026-01-01", "km": 1}))
    assert len(client.get(f"{T}/audit/anchors").json()["anchors"]) == 1   # Intervall 60 min
    client.get(f"{T}/vehicles/{vid}/report.pdf")
    anchors = client.get(f"{T}/audit/anchors").json()["anchors"]
    assert len(anchors) == 2 and anchors[-1]["seq"] == 2


def test_anchor_signature_tamper_detected(client, monkeypatch):
    monkeypatch.setenv("ANCHOR_SIGNING_KEY", KEY)
    _seed(client)
    with engine.begin() as conn:
        _disable_triggers(conn)
        conn.exec_driver_sql("UPDATE anchors SET created_at = '2020-01-01T00:00:00+00:00'")
    assert any("Signatur ungültig" in p for p in client.get(f"{T}/audit/verify").json()["problems"])


@pytest.mark.skipif(engine.dialect.name != "postgresql", reason="nur PostgreSQL")
def test_app_role_cannot_tamper(client):
    from sqlalchemy import create_engine
    from sqlalchemy.exc import DBAPIError

    from app.migrate import setup_app_role

    _seed(client)
    setup_app_role(engine, "fzb_app_test", "pw-test")
    url = engine.url.set(username="fzb_app_test", password="pw-test")
    app_engine = create_engine(url)
    with app_engine.connect() as conn:
        assert conn.execute(text("SELECT count(*) FROM revisions")).scalar() == 3
    for stmt in ("ALTER TABLE revisions DISABLE TRIGGER USER",
                 "UPDATE revisions SET data = '{}'",
                 "DELETE FROM revisions",
                 "DELETE FROM fuel_entries",
                 "SET session_replication_role = replica",
                 "DROP TABLE revisions"):
        with pytest.raises(DBAPIError):
            with app_engine.begin() as conn:
                conn.exec_driver_sql(stmt)
    with app_engine.begin() as conn:   # erlaubte DML
        conn.exec_driver_sql("UPDATE tenants SET name = name")
    app_engine.dispose()
