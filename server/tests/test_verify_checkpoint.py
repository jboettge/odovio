"""Inkrementelle Integritätsprüfung ab dem bestätigten Prüfstand (verify_checkpoints, Alembic 0004):
Cache-Treffer, inkrementeller Abgleich, Manipulation alter Revisionen (erst die Vollprüfung), Invalidierung,
monotones Fortschreiben (mehrere Worker) und ehrlicher PDF-Integritätsabschnitt."""
import base64
import datetime as dt
import json
import logging
import os

import pytest
from sqlalchemy import select, text

from app import integrity, jobs, models, security
from app.db import SessionLocal, engine, snapshot_session
from app.report import integrity_section

from .conftest import T, new_vehicle, op, sync, uid
from .test_audit import _disable_triggers
from .test_audit import _seed as fuel_seed
from .test_integrity import _rewrite_chain

KEY = base64.b64encode(os.urandom(32)).decode()


def _seed(client, n=3) -> str:
    vid = new_vehicle(client)
    for i in range(n):
        sync(client, op("odometer", uid(), {"vehicle_id": vid, "date": f"2026-02-{i + 1:02d}", "km": 10000 + i}))
    return vid


def _cp() -> models.VerifyCheckpoint | None:
    with SessionLocal() as db:
        tid = db.scalar(select(models.Tenant.id).where(models.Tenant.slug == "privat"))
        return db.get(models.VerifyCheckpoint, tid)


def _verify(client, full=False) -> dict:
    return client.get(f"{T}/audit/verify" + ("?full=1" if full else "")).json()


def _section() -> tuple[str, dict]:
    with snapshot_session() as s:
        tenant = s.scalar(select(models.Tenant).where(models.Tenant.slug == "privat"))
        story, audit, _ = integrity_section(s, tenant)
    return " ".join(p.getPlainText() for p in story if hasattr(p, "getPlainText")), audit


# ---------- Cache-Treffer / inkrementell ----------
def test_first_check_full_then_cache_hit_without_write(client):
    _seed(client)
    v = _verify(client)
    assert v["ok"] and v["incremental_from"] is None and v["full_seq"] == v["count"] == 4
    cp = _cp()
    assert (cp.seq, cp.full_seq, cp.head_hash) == (4, 4, v["head_hash"]) and cp.full_at
    assert json.loads(cp.counts)["odometer"] == 3 and json.loads(cp.counts)["vehicle"] == 1
    v = _verify(client)
    assert v["ok"] and v["incremental_from"] == 4 and v["count"] == 4 and v["full_at"] == cp.full_at
    assert _cp().verified_at == cp.verified_at               # nichts Neues → kein Schreibzugriff


def test_incremental_checks_only_new_revisions_and_advances(client):
    vid = _seed(client)
    full_at = _verify(client)["full_at"]
    oid = uid()
    sync(client, op("odometer", oid, {"vehicle_id": vid, "date": "2026-02-10", "km": 10010}))
    sync(client, op("odometer", oid, {"vehicle_id": vid, "date": "2026-02-10", "km": 10011}, base=1))
    v = _verify(client)
    assert v["ok"] and v["incremental_from"] == 4 and v["count"] == 6
    assert v["full_seq"] == 4 and v["full_at"] == full_at       # Vollprüfung bleibt die alte
    cp = _cp()
    assert (cp.seq, cp.full_seq, cp.full_at) == (6, 4, full_at)
    assert _verify(client)["incremental_from"] == 6


def test_incremental_detects_tampering_of_changed_record(client):
    vid = _seed(client)
    _verify(client)
    oid = uid()
    sync(client, op("odometer", oid, {"vehicle_id": vid, "date": "2026-02-10", "km": 10010}))
    with engine.begin() as conn:
        conn.execute(text("UPDATE odometer_readings SET km = 1 WHERE id = :i"), {"i": oid})
    v = _verify(client)
    assert v["incremental_from"] == 4 and not v["state_ok"] and any(oid in p for p in v["problems"])


def test_incremental_detects_rows_inserted_or_removed_outside_journal(client):
    vid = _seed(client)
    _verify(client)
    with engine.begin() as conn:
        tid = conn.execute(text("SELECT id FROM tenants WHERE slug='privat'")).scalar()
        conn.execute(text("INSERT INTO odometer_readings (id, tenant_id, version, deleted, last_seq, vehicle_id, "
                          "date, km) VALUES (:i, :t, 1, false, 0, :v, '2026-01-01', 1)"),
                     {"i": uid(), "t": tid, "v": vid})
    v = _verify(client)
    assert v["incremental_from"] == 4 and not v["ok"]
    assert any("odometer: 4 Datensätze statt 3" in p for p in v["problems"]), v["problems"]


def test_incremental_detects_row_with_bumped_last_seq(client):
    _seed(client)
    _verify(client)
    sync(client, op("customer", uid(), {"name": "neu"}))       # Seq 5
    with engine.begin() as conn:
        conn.execute(text("UPDATE odometer_readings SET km = 7, last_seq = 5 WHERE km = 10000"))
    v = _verify(client)
    assert v["incremental_from"] == 4 and any("odometer" in p and "weicht" in p for p in v["problems"])


# ---------- Manipulation alter Revisionen ----------
def test_old_revision_tampering_needs_full_check_then_sticks(client):
    _seed(client)
    _verify(client)
    with engine.begin() as conn:
        _disable_triggers(conn)
        conn.execute(text("UPDATE revisions SET data = REPLACE(data, '10001', '19999') WHERE seq = 3"))
    v = _verify(client)
    assert v["ok"] and v["incremental_from"] == 4          # bewusst: inkrementell nicht gesehen
    text_, audit = _section()
    assert audit["ok"] and "seither inkrementell bis Revision 4" in text_
    v = _verify(client, full=True)
    assert not v["chain_ok"] and v["broken_at"] == 3 and v["incremental_from"] is None
    cp = _cp()
    assert cp.full_at is None and cp.signature is None and cp.failed_seq == 4
    # Prüfstand entwertet → jede weitere Prüfung (auch der PDF-Abschnitt) wieder vollständig
    text_, audit = _section()
    assert audit["incremental_from"] is None and "FEHLER ab Seq 3" in text_
    assert _verify(client)["chain_ok"] is False


def test_rewritten_chain_invalidates_checkpoint(client):
    """Neu berechnete Kette (DB-Vollzugriff): Hash am bestätigten Stand stimmt nicht mehr → Vollprüfung."""
    fuel_seed(client)
    assert _verify(client)["incremental_from"] is None
    assert _verify(client)["incremental_from"] == 3
    _rewrite_chain()
    v = _verify(client)
    assert v["incremental_from"] is None and v["chain_ok"]  # ohne Anker nicht erkennbar (bekannte Grenze)


def test_signed_anchors_still_detect_rewrite_after_checkpoint(client, monkeypatch):
    monkeypatch.setenv("ANCHOR_SIGNING_KEY", KEY)
    monkeypatch.setenv("ANCHOR_INTERVAL_MIN", "0")
    fuel_seed(client)
    assert _verify(client)["ok"] and _verify(client)["incremental_from"] == 3
    _rewrite_chain()
    v = _verify(client)
    assert v["incremental_from"] is None and not v["ok"]
    assert any("nachträglich verändert" in p for p in v["problems"])
    assert _cp().full_at is None                               # Anker-Befund entwertet den Prüfstand


def test_incremental_checks_only_new_anchors(client, monkeypatch):
    monkeypatch.setenv("ANCHOR_SIGNING_KEY", KEY)
    monkeypatch.setenv("ANCHOR_INTERVAL_MIN", "0")
    vid = _seed(client)
    v = _verify(client)
    assert v["anchors"] == v["anchors_checked"] == 4
    sync(client, op("odometer", uid(), {"vehicle_id": vid, "date": "2026-02-11", "km": 10020}))
    v = _verify(client)
    assert v["ok"] and v["incremental_from"] == 4 and v["anchors"] == 5 and v["anchors_checked"] == 1


# ---------- Invalidierung ----------
def _set_cp(**values) -> None:
    sets = ", ".join(f"{k} = :{k}" for k in values)
    with engine.begin() as conn:
        conn.execute(text(f"UPDATE verify_checkpoints SET {sets}"), values)  # nosec B608 – Testspalten


def test_forged_checkpoint_is_ignored_with_signing_key(client, monkeypatch):
    monkeypatch.setenv("ANCHOR_SIGNING_KEY", KEY)
    _seed(client)
    _verify(client)
    cp = _cp()
    assert cp.key_id == integrity.key_id(integrity.signing_key()) and len(cp.signature) == 128
    assert _verify(client)["incremental_from"] == 4
    later = (dt.datetime.now(dt.UTC) + dt.timedelta(minutes=1)).isoformat(timespec="seconds")
    _set_cp(full_at=later)                                       # Vollprüfung „verlängern“ → Signatur ungültig
    assert _verify(client)["incremental_from"] is None
    assert _verify(client)["incremental_from"] == 4              # neu signiert
    _set_cp(signature=None, key_id=None)
    assert _verify(client)["incremental_from"] is None
    monkeypatch.setenv("ANCHOR_SIGNING_KEY", base64.b64encode(os.urandom(32)).decode())   # Schlüsselwechsel
    assert _verify(client)["incremental_from"] is None


def test_unsigned_checkpoint_rejects_future_and_ahead_of_tenant(client):
    _seed(client)
    _verify(client)
    _set_cp(full_at=(dt.datetime.now(dt.UTC) + dt.timedelta(days=30)).isoformat(timespec="seconds"))
    assert _verify(client)["incremental_from"] is None
    _set_cp(seq=99)
    assert _verify(client)["incremental_from"] is None
    _set_cp(counts="kaputt")
    assert _verify(client)["incremental_from"] is None
    _set_cp(counts='{"vehicle": 1}')                            # Objekttyp ohne Zählstand (z. B. neu)
    assert _verify(client)["incremental_from"] is None
    assert _verify(client)["incremental_from"] == 4


def test_full_check_due_after_interval(client, monkeypatch):
    _seed(client)
    first = _verify(client)["full_at"]
    _set_cp(full_at=(dt.datetime.now(dt.UTC) - dt.timedelta(hours=25)).isoformat(timespec="seconds"))
    v = _verify(client)
    assert v["incremental_from"] is None and v["full_at"] >= first
    assert _verify(client)["incremental_from"] == 4
    monkeypatch.setenv("VERIFY_FULL_INTERVAL_S", "0")
    assert _verify(client)["incremental_from"] is None


@pytest.fixture
def held_full_lock(monkeypatch):
    """try-Lock "verify_full" dauerhaft belegt (z. B. von jemandem mit DB-Zugang festgehalten)."""
    real = jobs.xact_lock

    def fake(db, name, *parts, wait=True):
        if name == "verify_full" and not wait:
            return False
        return real(db, name, *parts, wait=wait)
    monkeypatch.setattr(jobs, "xact_lock", fake)


@pytest.fixture
def sec_events():
    out: list[tuple[int, dict]] = []

    class H(logging.Handler):
        def emit(self, record):
            out.append((record.levelno, record.security))
    h = H()
    security.log.addHandler(h)
    yield out
    security.log.removeHandler(h)


def _ago(hours: float) -> str:
    return (dt.datetime.now(dt.UTC) - dt.timedelta(hours=hours)).isoformat(timespec="seconds")


def test_blocked_full_check_becomes_overdue_not_ok(client, held_full_lock, sec_events):
    """X2: fällige Vollprüfung, die nicht laufen kann → bis 2× Intervall weiter inkrementell «OK», danach
    «Vollprüfung überfällig» (ok=false) in API und PDF + Sicherheits-Log."""
    _seed(client)
    _verify(client)
    _set_cp(full_at=_ago(25))                                    # fällig, Lock belegt → inkrementell
    v = _verify(client)
    assert v["ok"] and not v["full_overdue"] and v["incremental_from"] == 4
    _set_cp(full_at=_ago(49))                                    # > 2 × 24 h
    v = _verify(client)
    assert v["ok"] is False and v["full_overdue"] and v["incremental_from"] == 4
    assert v["chain_ok"] and v["state_ok"] and any(p.startswith("Vollprüfung überfällig") for p in v["problems"])
    text_, audit = _section()
    assert not audit["ok"] and "NICHT BESTÄTIGT – Vollprüfung überfällig" in text_ and "– OK" not in text_
    ev = [(lvl, e) for lvl, e in sec_events if e["event"] == "integrity_full_overdue"]
    assert ev and ev[0][0] == logging.WARNING and ev[0][1]["tenant"] == "privat" and ev[0][1]["age_h"] >= 49
    assert not any(e["event"] == "integrity_failed" for _, e in sec_events)


def test_overdue_cleared_by_full_check(client, sec_events):
    _seed(client)
    _verify(client)
    _set_cp(full_at=_ago(49))
    v = _verify(client)                                          # Lock frei → Vollprüfung läuft
    assert v["ok"] and not v["full_overdue"] and v["incremental_from"] is None


def test_repeated_409_on_full_logged(client, held_full_lock, sec_events):
    _seed(client)
    for _ in range(3):
        r = client.get(f"{T}/audit/verify?full=1")
        assert r.status_code == 409 and r.headers["retry-after"] == "30"
    busy = [(lvl, e) for lvl, e in sec_events if e["event"] == "verify_full_busy"]
    assert [e["count"] for _, e in busy] == [1, 2, 3] and busy[0][1]["status"] == 409
    assert [lvl for lvl, _ in busy] == [logging.INFO, logging.INFO, logging.WARNING]


def test_failed_seq_is_signed_and_old_format_rechecked_once(client, monkeypatch):
    monkeypatch.setenv("ANCHOR_SIGNING_KEY", KEY)
    _seed(client)
    _verify(client)
    assert _verify(client)["incremental_from"] == 4
    _set_cp(failed_seq=2)                                        # nicht signierte Änderung → verworfen
    assert _verify(client)["incremental_from"] is None
    assert _cp().failed_seq is None and _verify(client)["incremental_from"] == 4
    # Prüfstand mit Signatur im alten Format (ohne failed_seq, vor v2) → einmalig Vollprüfung, dann v2
    row = _cp()
    old = integrity.signing_key().sign(integrity.checkpoint_message("privat", row, version=1)).hex()
    _set_cp(signature=old)
    assert _verify(client)["incremental_from"] is None
    assert _verify(client)["incremental_from"] == 4
    assert _cp().signature != old


def test_full_parameter_always_full(client):
    _seed(client)
    _verify(client)
    assert _verify(client, full=True)["incremental_from"] is None


def test_fixed_finding_without_new_writes_restores_incremental(client):
    """S10: Befund behoben (Datensatz zurückgesetzt), keine neuen Schreibvorgänge → die nächste fehlerfreie
    Vollprüfung, die nach dem Befund begann, setzt den Prüfstand wieder (statt dauerhaft Vollprüfung)."""
    _seed(client)
    _verify(client)
    with engine.begin() as conn:
        conn.execute(text("UPDATE odometer_readings SET km = 1 WHERE km = 10001"))
    assert not _verify(client, full=True)["state_ok"]
    cp = _cp()
    assert cp.full_at is None and cp.failed_seq == 4 and cp.verified_at
    with engine.begin() as conn:
        conn.execute(text("UPDATE odometer_readings SET km = 10001 WHERE km = 1"))
        # Befund «vor» dieser Prüfung erfasst (Sekundenauflösung; im Test sonst dieselbe Sekunde)
        conn.execute(text("UPDATE verify_checkpoints SET verified_at = '2000-01-01T00:00:00+00:00'"))
    v = _verify(client)
    assert v["ok"] and v["incremental_from"] is None
    cp = _cp()
    assert cp.failed_seq is None and cp.full_at and cp.seq == 4
    assert _verify(client)["incremental_from"] == 4


# ---------- monotones Fortschreiben (mehrere Worker) ----------
def _tenant():
    with SessionLocal() as db:
        t = db.scalar(select(models.Tenant).where(models.Tenant.slug == "privat"))
        db.expunge(t)
        return t


def test_persist_is_monotonic(client):
    vid = _seed(client)
    _verify(client)
    sync(client, op("odometer", uid(), {"vehicle_id": vid, "date": "2026-02-12", "km": 10030}))
    _verify(client)
    cp = _cp()
    assert (cp.seq, cp.full_seq) == (5, 4)
    t = _tenant()
    old = integrity.Checkpoint(4, "x" * 64, {}, 4, cp.full_at)
    integrity._persist_checkpoint(t, old, full=False, seq=4)             # älterer inkrementeller Stand
    integrity._persist_checkpoint(t, integrity.Checkpoint(6, "y" * 64, {}, 3, cp.full_at), full=False, seq=6)
    integrity._persist_checkpoint(t, integrity.Checkpoint(3, "z" * 64, {}, 3, cp.full_at), full=True, seq=3)
    assert (_cp().seq, _cp().head_hash) == (5, cp.head_hash)
    # Befund auf Stand 5 → nur eine Vollprüfung mit grösserem Stand setzt den Prüfstand wieder
    integrity._persist_checkpoint(t, None, full=True, seq=5)
    integrity._persist_checkpoint(t, integrity.Checkpoint(6, "a" * 64, {}, 4, cp.full_at), full=False, seq=6)
    integrity._persist_checkpoint(t, integrity.Checkpoint(5, "b" * 64, {}, 5, cp.full_at), full=True, seq=5)
    assert _cp().full_at is None and _cp().failed_seq == 5
    integrity._persist_checkpoint(t, integrity.Checkpoint(6, "c" * 64, {}, 6, cp.full_at), full=True, seq=6)
    assert (_cp().seq, _cp().head_hash, _cp().failed_seq) == (6, "c" * 64, None)


# ---------- PDF ----------
def test_pdf_section_states_scope(client):
    vid = _seed(client)
    text_, audit = _section()
    assert audit["incremental_from"] is None and "Geprüft: vollständig am" in text_ and "– OK" in text_
    sync(client, op("odometer", uid(), {"vehicle_id": vid, "date": "2026-02-13", "km": 10040}))
    text_, audit = _section()
    assert audit["incremental_from"] == 4
    assert "vollständig am" in text_ and "(Revision 1–4), seither inkrementell bis Revision 5" in text_
    assert "ab Revision 5" in text_ and "nächsten Vollprüfung" in text_ and "fällig 24 h" in text_
    text_, _ = _section()
    assert "keine neuen Revisionen" in text_
    r = client.get(f"{T}/vehicles/{vid}/logbook.pdf?month=2026-02")
    assert r.status_code == 200 and r.content.startswith(b"%PDF")
