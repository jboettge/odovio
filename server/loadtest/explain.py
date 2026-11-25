"""EXPLAIN (ANALYZE, BUFFERS) der Hot-Queries gegen eine mit loadtest.seed gefüllte PostgreSQL-Datenbank.

  python -m loadtest.explain --database-url postgresql+psycopg://fzb:fzb@127.0.0.1:55441/fzbload [--plans]
Ausgabe je Abfrage: Ausführungszeit, gelesene Puffer und die verwendeten Indizes/Scans.
"""
import argparse
import re

import psycopg

QUERIES = {
    "changes_incremental (je Tabelle, Stufe 1)":
        "SELECT last_seq FROM trips WHERE tenant_id = %(t)s AND last_seq > %(seq_hi)s ORDER BY last_seq LIMIT 2001",
    "changes_full_sync (since=0, Stufe 1)":
        "SELECT last_seq FROM trips WHERE tenant_id = %(t)s AND last_seq > 0 ORDER BY last_seq LIMIT 2001",
    "changes_rows (Stufe 2)":
        "SELECT * FROM trips WHERE tenant_id = %(t)s AND last_seq > 0 AND last_seq <= %(seq_page)s "
        "ORDER BY last_seq",
    "changes_small_table (fuel)":
        "SELECT last_seq FROM fuel_entries WHERE tenant_id = %(t)s AND last_seq > %(seq_hi)s "
        "ORDER BY last_seq LIMIT 2001",
    "verify_chain (seq-Bereich)":
        "SELECT seq, hash, prev_hash FROM revisions WHERE tenant_id = %(t)s AND seq > %(seq_mid)s ORDER BY seq "
        "LIMIT 2000",
    "activity before_seq":
        "SELECT * FROM revisions WHERE tenant_id = %(t)s AND seq < %(seq_hi)s ORDER BY seq DESC LIMIT 51",
    "trips je Fahrzeug + Monat (trips_between)":
        "SELECT * FROM trips WHERE tenant_id = %(t)s AND vehicle_id = %(v)s AND start_at >= '2026-03-01' "
        "AND start_at < '2026-04-02' AND deleted = false",
    "letzte Fahrt vor Datum (previous_trip)":
        "SELECT * FROM trips WHERE tenant_id = %(t)s AND vehicle_id = %(v)s AND deleted = false "
        "AND start_at < '2026-03-02' ORDER BY start_at DESC LIMIT 200",
    "fuel je Fahrzeug + Zeitraum (load_vehicle)":
        "SELECT * FROM fuel_entries WHERE vehicle_id = %(v)s AND deleted = false AND date >= '2026-01-01' "
        "AND date <= '2026-12-31'",
    "maintenance je Fahrzeug": "SELECT * FROM maintenance WHERE vehicle_id = %(v)s AND deleted = false",
    "attachments je Tankvorgang":
        "SELECT DISTINCT fuel_id FROM attachments WHERE tenant_id = %(t)s AND deleted = false "
        "AND fuel_id IN (%(f)s)",
    "letzter Anker (maybe_anchor)":
        "SELECT * FROM anchors WHERE tenant_id = %(t)s ORDER BY seq DESC LIMIT 1",
    "Historie eines Objekts":
        "SELECT * FROM revisions WHERE tenant_id = %(t)s AND entity = 'trip' AND entity_id = %(trip)s ORDER BY seq",
    "verify_state: letzte Revision je Objekt (Block)":
        "SELECT r.entity_id, r.seq, r.version FROM revisions r JOIN (SELECT entity_id, max(seq) AS seq "
        "FROM revisions WHERE tenant_id = %(t)s AND entity = 'trip' AND entity_id = ANY(%(ids)s) "
        "GROUP BY entity_id) l ON r.tenant_id = %(t)s AND r.seq = l.seq",
    "verify_state: Revision ohne Datensatz (Anti-Join)":
        "SELECT DISTINCT entity_id FROM revisions WHERE tenant_id = %(t)s AND entity = 'trip' AND NOT EXISTS "
        "(SELECT 1 FROM trips WHERE trips.tenant_id = %(t)s AND trips.id = revisions.entity_id) LIMIT 1000",
    "Mitglieder: letzte Aktivität je Akteur":
        "SELECT actor_sub, max(seq) FROM revisions WHERE tenant_id = %(t)s GROUP BY actor_sub",
    "Fahrzeugliste: km je Fahrzeug":
        "SELECT vid, max(km) FROM (SELECT vehicle_id AS vid, km FROM odometer_readings WHERE tenant_id = %(t)s "
        "AND deleted = false UNION ALL SELECT vehicle_id, km FROM fuel_entries WHERE tenant_id = %(t)s "
        "AND deleted = false) u GROUP BY vid",
}


def params(cur) -> dict:
    cur.execute("SELECT id, seq FROM tenants WHERE slug = 'last1'")
    t, seq = cur.fetchone()
    cur.execute("SELECT id FROM vehicles WHERE tenant_id = %s LIMIT 1", (t,))
    v = cur.fetchone()[0]
    cur.execute("SELECT id FROM trips WHERE vehicle_id = %s LIMIT 1", (v,))
    trip = cur.fetchone()[0]
    cur.execute("SELECT id FROM trips WHERE tenant_id = %s LIMIT 1000", (t,))
    ids = [r[0] for r in cur.fetchall()]
    cur.execute("SELECT last_seq FROM trips WHERE tenant_id = %s ORDER BY last_seq OFFSET 1999 LIMIT 1", (t,))
    seq_page = cur.fetchone()[0]
    return {"t": t, "v": v, "trip": trip, "ids": ids, "seq_hi": seq - 50, "seq_mid": seq // 2,
            "seq_page": seq_page, "f": "'00000000-0000-0000-0000-000000000000'"}


def run(url: str, show_plans: bool) -> list[tuple[str, float, str]]:
    out = []
    with psycopg.connect(url.replace("+psycopg", "")) as conn, conn.cursor() as cur:
        p = params(cur)
        for name, sql in QUERIES.items():
            sql = sql.replace("%(f)s", p["f"])
            cur.execute("EXPLAIN (ANALYZE, BUFFERS) " + sql, p)
            plan = "\n".join(r[0] for r in cur.fetchall())
            ms = float(re.search(r"Execution Time: ([\d.]+) ms", plan).group(1))
            scans = sorted(set(re.findall(r"((?:Index Only Scan|Index Scan|Seq Scan|Bitmap Index Scan)"
                                          r"(?: Backward)?(?: using \w+)? on \w+)", plan)))
            out.append((name, ms, "; ".join(scans)))
            if show_plans:
                print(f"--- {name}\n{plan}\n")
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--database-url", required=True)
    ap.add_argument("--plans", action="store_true")
    args = ap.parse_args()
    for name, ms, scans in run(args.database_url, args.plans):
        print(f"{ms:9.2f} ms  {name:50s} {scans}")


if __name__ == "__main__":
    main()
