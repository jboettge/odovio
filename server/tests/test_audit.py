import pytest
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError

from app.db import engine

from .conftest import T, new_vehicle, op, sync, uid


def _disable_triggers(conn):
    if engine.dialect.name == "postgresql":
        conn.execute(text("ALTER TABLE revisions DISABLE TRIGGER USER"))
    else:
        conn.execute(text("DROP TRIGGER fzb_revisions_no_update"))
        conn.execute(text("DROP TRIGGER fzb_revisions_no_delete"))


def _seed(client):
    vid = new_vehicle(client)
    fid = uid()
    sync(client, op("fuel", fid, {"vehicle_id": vid, "date": "2026-01-01", "km": 10100, "liters": 40,
                                  "price_total": 70}))
    sync(client, op("fuel", fid, {"vehicle_id": vid, "date": "2026-01-01", "km": 10100, "liters": 41,
                                  "price_total": 70}, base=1))
    return vid, fid


def test_chain_ok(client):
    _seed(client)
    v = client.get(f"{T}/audit/verify").json()
    assert v["ok"] and v["count"] == 3 and len(v["head_hash"]) == 64


def test_db_trigger_blocks_update_and_delete(client):
    _seed(client)
    for stmt in ("UPDATE revisions SET data = '{}' WHERE seq = 2", "DELETE FROM revisions WHERE seq = 3"):
        with pytest.raises(DBAPIError):
            with engine.begin() as conn:
                conn.exec_driver_sql(stmt)
    assert client.get(f"{T}/audit/verify").json()["ok"]


@pytest.mark.parametrize("stmt,broken_at", [
    ("UPDATE revisions SET data = REPLACE(data, '\"liters\":40.0', '\"liters\":4.0') WHERE seq = 2", 2),
    ("UPDATE revisions SET actor_name = 'mallory' WHERE seq = 1", 1),
    ("DELETE FROM revisions WHERE seq = 2", 2),
    ("DELETE FROM revisions WHERE seq = 3", 3),
])
def test_tampering_detected(client, stmt, broken_at):
    _seed(client)
    with engine.begin() as conn:
        _disable_triggers(conn)
        conn.exec_driver_sql(stmt)
    v = client.get(f"{T}/audit/verify").json()
    assert v["ok"] is False and v["broken_at"] == broken_at, v


def test_concurrent_syncs_keep_chain_intact(client):
    from concurrent.futures import ThreadPoolExecutor

    vid = new_vehicle(client)

    def worker(n):
        ops = [op("odometer", uid(), {"vehicle_id": vid, "date": "2026-03-01", "km": 10000 + n * 100 + i})
               for i in range(10)]
        return sync(client, *ops)

    with ThreadPoolExecutor(8) as ex:
        results = list(ex.map(worker, range(8)))
    assert all(r["status"] == "applied" for res in results for r in res["results"])
    v = client.get(f"{T}/audit/verify").json()
    assert v["ok"] and v["count"] == 81, v
