# Lasttest und Testdaten

Werkzeuge (nur Test-/Entwicklungsabhängigkeiten: `httpx`, `psycopg`, `pyjwt` aus der Lock-Datei bzw.
`requirements-test.txt`; nichts davon kommt zusätzlich ins Image):

| Skript | Zweck |
|---|---|
| `python -m loadtest.seed` | Testdaten per COPY: 3 Mandanten `last1..3`, 20 Fahrzeuge, 200 000 Fahrten × 5 Revisionen (≈ 1 Mio. Revisionen, gültige Hash-Kette) |
| `python -m loadtest.explain` | `EXPLAIN (ANALYZE, BUFFERS)` der Hot-Queries, Zeit + verwendete Indizes |
| `python -m loadtest.issuer` | lokaler OIDC-Test-Issuer (Discovery + JWKS über http) und Token-Erzeugung |
| `python -m loadtest.run` | Lasttest (httpx async, geschlossenes Modell) mit RPS und p50/p95/p99 je Szenario |

Alle Befehle aus `server`.

## 1. Datenbank, Valkey, Testdaten

```sh
docker run -d --rm --name fzbpg --network host -e POSTGRES_USER=fzb -e POSTGRES_PASSWORD=fzb \
  -e POSTGRES_DB=fzb -e PGPORT=55441 postgres:17-alpine
docker run -d --rm --name fzbvalkey --network host valkey/valkey:8-alpine \
  valkey-server --port 56380 --requirepass vpw123 --save "" --appendonly no
docker exec fzbpg psql -U fzb -p 55441 -c "CREATE DATABASE fzbload"
python -m loadtest.seed --database-url postgresql+psycopg://fzb:fzb@127.0.0.1:55441/fzbload   # ≈ 2 min
python -m loadtest.explain --database-url postgresql+psycopg://fzb:fzb@127.0.0.1:55441/fzbload
# App-Rolle wie in Produktion (Owner migriert, App-Rolle ohne DDL):
docker run --rm --network host -e MIGRATION_DATABASE_URL=postgresql+psycopg://fzb:fzb@127.0.0.1:55441/fzbload \
  -e DATABASE_URL=postgresql+psycopg://fzbapp@127.0.0.1:55441/fzbload -e DATABASE_PASSWORD=apppw \
  fahrzeugbuch-api:latest python -m app.migrate
```

## 2. API mit CPU-Limit starten

Token: Der Lasttest startet den Test-Issuer selbst auf `--issuer-port` (Default 8899) mit dem Schlüssel aus
`--key-file` (wird beim ersten Lauf angelegt; die API cached JWKS bis 1 h je `kid`, daher denselben Schlüssel
wiederverwenden). Die API braucht dafür `OIDC_ALLOW_HTTP=1` – **nur im Test**. Rate-Limits für den Lasttest hoch:

```sh
cat > /tmp/api.env <<'EOF'
DATABASE_URL=postgresql+psycopg://fzbapp@127.0.0.1:55441/fzbload
DATABASE_PASSWORD=apppw
AUTO_MIGRATE=0
OIDC_ISSUER=http://127.0.0.1:8899/realms/test
OIDC_ALLOW_HTTP=1
OIDC_CLIENT_ID=fahrzeugbuch-ios
ALLOWED_HOSTS=127.0.0.1,localhost
STATE_BACKEND=redis
REDIS_URL=redis://127.0.0.1:56380/0
REDIS_PASSWORD=vpw123
PORT=8085
HOST=127.0.0.1
RATE_IP_PER_MIN=10000000
RATE_IP_BURST=10000000
RATE_USER_PER_MIN=10000000
RATE_USER_BURST=10000000
RATE_REPORTS=10000000
RATE_FULL_SYNC=10000000
METRICS_TOKEN=metricsmetricsmetricsmetricsmetrics42
ANCHOR_SIGNING_KEY=ZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWU=
DB_POOL_SIZE=10
DB_MAX_OVERFLOW=10
EOF
docker run -d --name fzbapi --network host --read-only --tmpfs /tmp:size=16m --cap-drop ALL \
  --cpus 2 --memory 2g --env-file /tmp/api.env -e WEB_CONCURRENCY=4 fahrzeugbuch-api:latest
```

## 3. Lauf

```sh
python -m loadtest.run --base http://127.0.0.1:8085 --key-file /tmp/fzb-issuer.pem \
  --duration 40 --concurrency 32 --scenarios changes,sync,stats,check --json w4.json
python -m loadtest.run ... --concurrency 6 --scenarios pdf        # PDF getrennt (sehr teuer, s. u.)
```

Szenarien: `changes` = `/changes` inkrementell (since = Cursor − 50), `sync` = `/sync` mit 5 Ops,
`stats` = Fahrzeugstatistik, `check` = `/trips/check` eines Monats, `pdf` = Fahrtenbuch-PDF eines Monats.
Prometheus-Sicht während des Laufs: `curl -H "Authorization: Bearer $METRICS_TOKEN" :8085/metrics`.

## Messung (2026-11-25)

Umgebung: Sandbox mit **4 vCPU / 15 GB** (Lastgenerator, PostgreSQL 17 mit Default-Tuning und Valkey 8 auf
demselben Host), API-Container `--cpus 2`, 1 Mio. Revisionen, 32 gleichzeitige virtuelle Benutzer, 40 s nach
5 s Aufwärmen, Mix ohne PDF.

| | RPS | p50 | p95 | p99 | Fehler |
|---|---:|---:|---:|---:|---:|
| `WEB_CONCURRENCY=1` | 41.7 | 593 ms | 2136 ms | 3295 ms | 0 |
| `WEB_CONCURRENCY=4` | 87.3 | 171 ms | 1591 ms | 3140 ms | 0 |

Je Szenario (RPS / p50 / p95), 1 → 4 Worker:

| Szenario | 1 Worker | 4 Worker |
|---|---|---|
| changes | 17.4 / 668 / 887 ms | 35.6 / 206 / 489 ms |
| sync | 6.3 / 1729 / 3529 ms | 13.7 / 1208 / 3485 ms |
| stats | 9.5 / 433 / 645 ms | 18.6 / 85 / 272 ms |
| check | 8.6 / 490 / 774 ms | 19.5 / 117 / 326 ms |

Einordnung: Mit 1 Worker ist genau ein Kern ausgelastet (Python/GIL); 4 Worker nutzen das CPU-Limit von 2 aus
(×2.1 Durchsatz, p50 ÷3.5). `sync` bleibt im p95 hoch, weil Schreibvorgänge je Mandant über die Sperre der
Mandantenzeile strikt sequenziell laufen (Hash-Kette) – bei 3 Mandanten ist das die Obergrenze, nicht die CPU.
Auf dem Ziel-Host (32 Kerne) skaliert der Lese-Anteil etwa linear mit den Workern, solange PostgreSQL genug
Kerne/Verbindungen hat (`.env.example`, Tabelle 8/16/32 GB).

PDF (`pdf`, 4 Worker, 6 gleichzeitig), vor der inkrementellen Prüfung: ≈ 0.2 PDF/s, p50 ≈ 28 s. Jeder Bericht
enthielt den Integritätsabschnitt mit Abgleich ALLER Datensätze mit dem Journal (≈ 6.5 s bei 67 000 Fahrten je
Mandant; der erste Bericht je Worker prüfte zusätzlich die ganze Kette, ≈ 7 s). PDF_CONCURRENCY (2 je Worker)
begrenzt die Speicherspitzen, darüber nach PDF_WAIT_S 503 mit Retry-After. Die Testdaten sind ungünstig (jede
Fahrt viermal geändert → langes Änderungsprotokoll im PDF).

### Inkrementelle Integritätsprüfung (Alembic 0004, 2026-11-25)

PDFs prüfen nur noch ab dem bestätigten Prüfstand je Mandant (`verify_checkpoints`, `app/integrity.py`). Messung
in einer zweiten Sandbox (4 vCPU / 15 GB, PostgreSQL 16 lokal, Redis, API `python -m app.serve` mit
`WEB_CONCURRENCY=4` per `taskset` auf 2 Kerne, Lastgenerator auf den anderen 2; Mandant `last1`, 335 500
Revisionen, 66 661 Fahrten). In-Process (`verify_all` bzw. `build_logbook` eines Monats, je eigener Snapshot):

| | vorher | nachher |
|---|---:|---:|
| Prüfung, erster Aufruf je Prozess | 8.45 s | 0.04 s (Prüfstand in der DB; nur einmalig je Mandant voll: 7.7 s) |
| Prüfung, weitere Aufrufe | 3.67 s | 0.04 s (keine neuen Revisionen) · 0.26 s (3 865 neue Revisionen) |
| Vollprüfung `full=True` | 8.34 s | 7.79 s |
| Fahrtenbuch-PDF 1 Monat | 5.1 s | 1.3 s (Rest = Laden + Rendern) |

HTTP (`loadtest.run`, 60 s, 6 gleichzeitig, nur `pdf`, warm) bzw. Mix (40 s, 32 VU, alle Szenarien inkl. `pdf`):

| | vorher | nachher |
|---|---|---|
| nur PDF | 0.4 PDF/s, p50 14.9 s, p95 20.8 s | 1.3 PDF/s, p50 4.2 s, p95 6.7 s, 0 Fehler |
| Mix gesamt | 14.5 RPS, p50 292 ms, 16 Fehler (503) | 18.4 RPS, p50 374 ms, 5 Fehler (503) |
| Mix `pdf` | 0.6 PDF/s, p50 26.5 s | 1.1 PDF/s, p50 13.8 s |

Im Mix bestimmen jetzt CPU (Rendern ≈ 1.3 s/PDF bei 2 Kernen für alles) und das Warten auf die Mandantensperre für
den Anker vor dem PDF (`_anchor_and_release`, hinter seriellen Syncs) die PDF-Latenz, nicht mehr die Prüfung.

## Hot-Queries (loadtest.explain, 1 Mio. Revisionen)

Alle Hot-Queries nutzen Indizes (< 2 ms): `/changes` je Tabelle (Index-Only-Scan `ix_*_tenant_last_seq`), Kette
(`uq_revision_seq`), Aktivität `before_seq` (Backward-Scan `uq_revision_seq`), Fahrten je Fahrzeug + Zeitraum
(`ix_trips_vehicle_start`), Tank/Wartung je Fahrzeug, Belege je Tankvorgang, Historie (`ix_revisions_tenant_entity`).
Neu (Alembic 0003): `ix_anchors_tenant_seq` – letzter Anker bei jedem Sync: 4.2 ms → 0.03 ms bei 10 000 Ankern.
Geprüft und verworfen: `(tenant_id, entity, entity_id, seq)` (Block der Integritätsprüfung unverändert ≈ 12 ms),
`(tenant_id, actor_sub, seq)` für die Mitgliederliste (90 → 24 ms, aber zusätzlicher Index auf der
Schreib-Hot-Tabelle `revisions` für einen seltenen, ratenbegrenzten Aufruf).
