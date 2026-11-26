"""Lasttest (httpx2 async, geschlossenes Modell: N gleichzeitige virtuelle Benutzer ohne Denkzeit).

  python -m loadtest.run --base http://127.0.0.1:8085 --issuer-port 8899 --key-file /tmp/fzb-issuer.pem \\
      --duration 60 --concurrency 64 [--scenarios changes,sync,stats,check,pdf] [--json out.json]

Startet den lokalen Test-Issuer (loadtest.issuer) im selben Prozess; die API muss mit OIDC_ALLOW_HTTP=1 und
OIDC_ISSUER=http://127.0.0.1:<issuer-port>/realms/test laufen und die Mandanten last1..3 kennen (loadtest.seed).
Szenarien (Gewichte):  changes = /changes inkrementell (40), sync = /sync 5 Ops (15), stats = Fahrzeugstatistik
(20), check = /trips/check eines Monats (20), pdf = Fahrtenbuch-PDF eines Monats (5).
Ausgabe: RPS, p50/p95/p99 je Szenario und gesamt, Fehler (Status ≠ 2xx) je Szenario.
"""
import argparse
import asyncio
import json
import random
import statistics
import time
import uuid

import httpx2

from .issuer import Issuer

WEIGHTS = {"changes": 40, "sync": 15, "stats": 20, "check": 20, "pdf": 5}
TENANTS = ("last1", "last2", "last3")


def pct(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    values = sorted(values)
    k = max(0, min(len(values) - 1, round(p / 100 * (len(values) - 1))))
    return values[k]


class Load:
    def __init__(self, base: str, issuer: Issuer, scenarios: list[str], users: int):
        self.base = base.rstrip("/")
        groups = tuple(f"/fahrzeugbuch/{t}" for t in TENANTS)
        self.tokens = [issuer.token(sub=f"load-{i}", groups=groups) for i in range(users)]
        self.scenarios = scenarios
        self.weights = [WEIGHTS[s] for s in scenarios]
        self.lat: dict[str, list[float]] = {s: [] for s in scenarios}
        self.errors: dict[str, dict[str, int]] = {s: {} for s in scenarios}
        self.vehicles: dict[str, list[str]] = {}
        self.cursor: dict[str, int] = {}

    async def prepare(self, client: httpx2.AsyncClient) -> None:
        h = {"Authorization": f"Bearer {self.tokens[0]}"}
        for t in TENANTS:
            r = await client.get(f"{self.base}/api/t/{t}/vehicles", headers=h)
            r.raise_for_status()
            self.vehicles[t] = [v["id"] for v in r.json()]
            page = (await client.get(f"{self.base}/api/t/{t}/changes", params={"since": 10**9}, headers=h)).json()
            self.cursor[t] = page["cursor"]

    async def one(self, client: httpx2.AsyncClient, vu: int) -> None:
        name = random.choices(self.scenarios, self.weights)[0]
        t = random.choice(TENANTS)
        vid = random.choice(self.vehicles[t])
        h = {"Authorization": f"Bearer {self.tokens[vu % len(self.tokens)]}"}
        url = f"{self.base}/api/t/{t}"
        start = time.perf_counter()
        try:
            if name == "changes":
                r = await client.get(f"{url}/changes", params={"since": max(0, self.cursor[t] - 50)}, headers=h)
            elif name == "sync":
                ops = [{"op_id": str(uuid.uuid4()), "entity": "odometer", "id": str(uuid.uuid4()), "action": "upsert",
                        "data": {"vehicle_id": vid, "date": "2026-10-01", "km": random.randint(10_000, 900_000)}}
                       for _ in range(5)]
                r = await client.post(f"{url}/sync", json={"ops": ops}, headers=h)
            elif name == "stats":
                r = await client.get(f"{url}/vehicles/{vid}/stats", headers=h)
            elif name == "check":
                r = await client.get(f"{url}/vehicles/{vid}/trips/check",
                                     params={"month": f"2026-{random.randint(1, 9):02d}"}, headers=h)
            else:
                r = await client.get(f"{url}/vehicles/{vid}/logbook.pdf",
                                     params={"month": f"2026-{random.randint(1, 9):02d}"}, headers=h)
            await r.aread()
            code = r.status_code
        except httpx2.HTTPError as e:
            code = type(e).__name__
        self.lat[name].append(time.perf_counter() - start)
        if not (isinstance(code, int) and 200 <= code < 300):
            self.errors[name][str(code)] = self.errors[name].get(str(code), 0) + 1

    async def vu(self, client: httpx2.AsyncClient, i: int, until: float) -> None:
        while time.monotonic() < until:
            await self.one(client, i)


async def main_async(args) -> dict:
    issuer = Issuer(port=args.issuer_port, key_file=args.key_file).start()
    scenarios = [s for s in args.scenarios.split(",") if s]
    load = Load(args.base, issuer, scenarios, users=args.users)
    limits = httpx2.Limits(max_connections=args.concurrency, max_keepalive_connections=args.concurrency)
    async with httpx2.AsyncClient(timeout=args.timeout, limits=limits) as client:
        await load.prepare(client)
        if args.warmup:
            until = time.monotonic() + args.warmup
            await asyncio.gather(*(load.vu(client, i, until) for i in range(args.concurrency)))
            load.lat = {s: [] for s in scenarios}
            load.errors = {s: {} for s in scenarios}
        t0 = time.monotonic()
        until = t0 + args.duration
        await asyncio.gather(*(load.vu(client, i, until) for i in range(args.concurrency)))
        elapsed = time.monotonic() - t0
    issuer.stop()
    total = [x for v in load.lat.values() for x in v]
    report = {"duration_s": round(elapsed, 1), "concurrency": args.concurrency, "requests": len(total),
              "rps": round(len(total) / elapsed, 1),
              "p50_ms": round(pct(total, 50) * 1000, 1), "p95_ms": round(pct(total, 95) * 1000, 1),
              "p99_ms": round(pct(total, 99) * 1000, 1),
              "errors": sum(sum(e.values()) for e in load.errors.values()), "scenarios": {}}
    for s, v in load.lat.items():
        report["scenarios"][s] = {"requests": len(v), "rps": round(len(v) / elapsed, 1),
                                  "p50_ms": round(pct(v, 50) * 1000, 1), "p95_ms": round(pct(v, 95) * 1000, 1),
                                  "p99_ms": round(pct(v, 99) * 1000, 1),
                                  "mean_ms": round(statistics.fmean(v) * 1000, 1) if v else 0,
                                  "errors": load.errors[s]}
    return report


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", default="http://127.0.0.1:8085")
    ap.add_argument("--issuer-port", type=int, default=8899)
    ap.add_argument("--key-file", default="/tmp/fzb-loadtest-issuer.pem")
    ap.add_argument("--duration", type=float, default=60)
    ap.add_argument("--warmup", type=float, default=5)
    ap.add_argument("--concurrency", type=int, default=64)
    ap.add_argument("--users", type=int, default=50)
    ap.add_argument("--timeout", type=float, default=60)
    ap.add_argument("--scenarios", default=",".join(WEIGHTS))
    ap.add_argument("--json", help="Bericht zusätzlich als JSON-Datei")
    args = ap.parse_args()
    report = asyncio.run(main_async(args))
    print(json.dumps(report, indent=2, ensure_ascii=False))
    if args.json:
        with open(args.json, "w") as f:
            json.dump(report, f, indent=2, ensure_ascii=False)


if __name__ == "__main__":
    main()
