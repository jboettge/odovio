"""Testdaten für EXPLAIN ANALYZE und Lasttest (nur PostgreSQL; schnell per COPY).

Standard: 3 Mandanten (last1..last3), 20 Fahrzeuge, 200 000 Fahrten mit je 5 Revisionen (≈ 1 Mio. Revisionen,
gültige Hash-Kette, Datensatz = letzte Revision → /audit/verify ist ok), Tankvorgänge und km-Stände.

  python -m loadtest.seed --database-url postgresql+psycopg://fzb:fzb@127.0.0.1:55441/fzb [--trips 200000]
Das Schema wird bei Bedarf angelegt (app.migrate.create_schema). Vorhandene Mandanten last1..3 → Abbruch.
"""
import argparse
import datetime as dt
import random
import sys
import time
import uuid
from zoneinfo import ZoneInfo

import psycopg
from sqlalchemy import create_engine

from app import models
from app.audit import HASHED_FIELDS, canonical, compute_hash
from app.migrate import create_schema
from app.sync import ENTITIES, snapshot

TZ = ZoneInfo("Europe/Zurich")
START = dt.datetime(2024, 1, 1, tzinfo=TZ)
DAYS = 1035
SYNCED_COLS = ("id", "tenant_id", "version", "deleted", "last_seq", "created_by", "updated_by")


class Journal:
    """Revisionen eines Mandanten fortlaufend mit Hash-Kette erzeugen."""

    def __init__(self, tenant_id: int):
        self.tenant_id, self.seq, self.head = tenant_id, 0, models.GENESIS
        self.rows: list[tuple] = []
        self.clock = START.astimezone(dt.UTC)

    def add(self, entity: str, obj, action: str) -> None:
        self.seq += 1
        self.clock += dt.timedelta(seconds=7)
        obj.version = (obj.version or 0) + 1
        rev = models.Revision(tenant_id=self.tenant_id, seq=self.seq, entity=entity, entity_id=obj.id,
                              version=obj.version, action=action, data=canonical(snapshot(obj, ENTITIES[entity][1])),
                              actor_sub="seed", actor_name="seed", recorded_at=self.clock.isoformat(
                                  timespec="milliseconds"), client_ts=None, op_id=str(uuid.uuid4()), conflict=False,
                              prev_hash=self.head)
        rev.hash = compute_hash(self.head, rev)
        self.head = rev.hash
        obj.last_seq = self.seq
        self.rows.append(tuple(getattr(rev, f) for f in (*HASHED_FIELDS, "prev_hash", "hash")))


def _defaults(obj, schema) -> None:
    for name, field in schema.model_fields.items():
        if getattr(obj, name, None) is None and field.default is not None and not callable(field.default):
            setattr(obj, name, field.default)
    obj.deleted = False


def _copy(cur, table: str, cols: tuple[str, ...], rows) -> None:
    with cur.copy(f"COPY {table} ({', '.join(cols)}) FROM STDIN") as cp:
        for r in rows:
            cp.write_row(r)


def _obj_rows(objs, entity: str):
    schema = ENTITIES[entity][1]
    cols = (*SYNCED_COLS, *schema.model_fields)
    return cols, [tuple(getattr(o, c) for c in cols) for o in objs]


def seed(url: str, tenants: int, vehicles: int, trips: int, revisions_per_trip: int, rnd: random.Random) -> dict:
    engine = create_engine(url)
    create_schema(engine)
    engine.dispose()
    t0 = time.monotonic()
    stats = {"tenants": tenants, "vehicles": vehicles, "trips": trips, "revisions": 0}
    with psycopg.connect(url.replace("+psycopg", "")) as conn, conn.cursor() as cur:
        for ti in range(tenants):
            slug = f"last{ti + 1}"
            cur.execute("SELECT 1 FROM tenants WHERE slug = %s", (slug,))
            if cur.fetchone():
                raise SystemExit(f"Mandant {slug} existiert bereits – leere Datenbank verwenden")
            cur.execute("INSERT INTO tenants (slug, name, seq, head_hash) VALUES (%s, %s, 0, %s) RETURNING id",
                        (slug, slug, models.GENESIS))
            tid = cur.fetchone()[0]
            j = Journal(tid)
            n_veh = vehicles // tenants + (1 if ti < vehicles % tenants else 0)
            n_trips = trips // tenants + (1 if ti < trips % tenants else 0)
            vs, ts, fuels, odos = [], [], [], []
            for vi in range(n_veh):
                v = models.Vehicle(id=str(uuid.uuid4()), tenant_id=tid, name=f"Auto {ti + 1}-{vi + 1}",
                                   plate=f"ZH {rnd.randint(1000, 999999)}", initial_km=10_000, version=0,
                                   created_by="seed", updated_by="seed")
                _defaults(v, ENTITIES["vehicle"][1])
                j.add("vehicle", v, "create")
                vs.append(v)
            per_vehicle = max(1, n_trips // max(1, n_veh))
            for v in vs:
                km = v.initial_km
                for k in range(per_vehicle):
                    day = START + dt.timedelta(days=DAYS * k / per_vehicle, minutes=rnd.randint(0, 600))
                    dist = rnd.randint(3, 80)
                    t = models.Trip(id=str(uuid.uuid4()), tenant_id=tid, vehicle_id=v.id, version=0,
                                    start_at=day.isoformat(timespec="seconds"),
                                    end_at=(day + dt.timedelta(minutes=dist)).isoformat(timespec="seconds"),
                                    km_start=km, km_end=km + dist, category="business", status="draft",
                                    source="auto", driver_name="seed", created_by="seed", updated_by="seed")
                    _defaults(t, ENTITIES["trip"][1])
                    j.add("trip", t, "create")
                    for step in range(1, revisions_per_trip):
                        t.status = "suggested" if step == 1 else "confirmed"
                        t.purpose = f"Kunde {rnd.randint(1, 300)}" if step >= 2 else None
                        t.note = f"Änderung {step}" if step >= 3 else None
                        j.add("trip", t, "update")
                    ts.append(t)
                    km += dist
                    if k % 40 == 0:
                        f = models.FuelEntry(id=str(uuid.uuid4()), tenant_id=tid, vehicle_id=v.id, version=0,
                                             date=day.date(), km=km, liters=round(rnd.uniform(20, 60), 2),
                                             price_total=round(rnd.uniform(40, 110), 2), created_by="seed",
                                             updated_by="seed")
                        _defaults(f, ENTITIES["fuel"][1])
                        j.add("fuel", f, "create")
                        fuels.append(f)
                    if k % 300 == 0:
                        o = models.OdometerReading(id=str(uuid.uuid4()), tenant_id=tid, vehicle_id=v.id, version=0,
                                                   date=day.date(), km=km, created_by="seed", updated_by="seed")
                        _defaults(o, ENTITIES["odometer"][1])
                        j.add("odometer", o, "create")
                        odos.append(o)
            for table, entity, objs in (("vehicles", "vehicle", vs), ("trips", "trip", ts),
                                        ("fuel_entries", "fuel", fuels), ("odometer_readings", "odometer", odos)):
                cols, rows = _obj_rows(objs, entity)
                _copy(cur, table, cols, rows)
            _copy(cur, "revisions", (*HASHED_FIELDS, "prev_hash", "hash"), j.rows)
            cur.execute("UPDATE tenants SET seq = %s, head_hash = %s WHERE id = %s", (j.seq, j.head, tid))
            conn.commit()
            stats["revisions"] += len(j.rows)
            print(f"{slug}: {len(vs)} Fahrzeuge, {len(ts)} Fahrten, {len(fuels)} Tankvorgänge, "
                  f"{len(j.rows)} Revisionen ({time.monotonic() - t0:.0f} s)", flush=True)
        conn.autocommit = True
        cur.execute("ANALYZE")
    stats["seconds"] = round(time.monotonic() - t0, 1)
    return stats


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--database-url", required=True)
    ap.add_argument("--tenants", type=int, default=3)
    ap.add_argument("--vehicles", type=int, default=20)
    ap.add_argument("--trips", type=int, default=200_000)
    ap.add_argument("--revisions-per-trip", type=int, default=5)
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()
    if not args.database_url.startswith("postgresql"):
        sys.exit("nur PostgreSQL")
    print(seed(args.database_url, args.tenants, args.vehicles, args.trips, args.revisions_per_trip,
               random.Random(args.seed)))


if __name__ == "__main__":
    main()
