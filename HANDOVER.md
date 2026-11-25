# Übergabe Fahrzeugbuch (odovio)

Stand: 25.11.2026. Herkunft: `jboettge/DroidSim`, Branch `claude/digitales-fahrzeugbuch-app-pn3461`, Ordner `fahrzeugbuch/` – mit Historie hierher verschoben (Pfade auf Repo-Root umgeschrieben).

## Architektur / Ordner

| Pfad | Inhalt |
|---|---|
| `server/` | FastAPI, SQLAlchemy 2, Alembic (0001–0003), PostgreSQL (Prod) / SQLite (Tests), reportlab-PDF. Dockerfile mehrstufig (Web-Build + API), Build-Kontext = Repo-Root |
| `web/` | Vue 3 + TS + Vite, oidc-client-ts; wird ins API-Image gebaut und unter `/` ausgeliefert. Mock-Server `web/mock/` |
| `ios/` | SwiftUI (iOS 17+), XcodeGen (`project.yml`), Unit-Tests `ios/Tests/FahrzeugbuchTests` |
| `keycloak/setup-client.sh` | Clients `fahrzeugbuch-ios` / `fahrzeugbuch-web`, Gruppen je Mandant (write, `/lesen`, `/admin`), optionale Realm-Härtung |
| `deploy/` | `Caddyfile.example`, CrowdSec, fail2ban, Helm-Chart `deploy/helm/fahrzeugbuch` |
| `docker-compose.yml`, `.env.example` | Portainer-Stack (db, migrate, api, optional photon/valkey) |
| `docs/` | Konzept Fahrtenbuch, Reviews, Screenshots (iOS + `web/`) |

Kernprinzipien: local-first App mit Outbox/Sync (`/sync`, `/changes`), revisionssicheres Journal (SHA-256-Kette je Mandant, DB-Trigger append-only, Ed25519-Anker), Mandanten/Rollen über Keycloak-Gruppen, Administration (Mitglieder, Steuerparameter) nur über den Web-Client (`azp`).

## Stand je Komponente

- **Server**: vollständig (Fahrzeuge, km, Tanken, Wartung+Material, Fahrtenbuch mit Monatsabschluss, Belege fs|s3, PDF/CSV/Jahresbericht, Mitglieder via Keycloak-Admin-API, Aktivität). Security-Härtung (Rate-Limit, Brute-Force, CORS/CSRF, Header, Injection, STRICT_CONFIG). Skalierung: `WEB_CONCURRENCY`, Valkey-State, Advisory-Locks, Probes, Metriken.
- **Web**: Ansicht + Verwaltung je Rolle, Monatsabschluss, Stammdaten, Mitglieder (admin). Skalierung: Lazy-Routen, vorkomprimierte Assets, virtuelles Scrollen, Web Worker.
- **iOS**: Betriebsarten „Nur auf diesem iPhone“ (lokales Journal, Berichte, Backup) und „Mit Server“; Fahrtenbuch (CoreLocation/CoreMotion), Scan (Vision), Belege, Mitglieder/Aktivität nur lesend. Demo-Modus für Screenshots (`-demo -screen <name>`).
- **Helm**: Chart mit HPA/VPA, Valkey optional, Migrations-Hook-Job, NetworkPolicy, ServiceMonitor. Nicht in echtem Cluster installiert (kind lief in der Sandbox nicht); Image mit Chart-Settings in Docker geprüft.

## Teststatus (letzter Stand)

| Komponente | Ergebnis |
|---|---|
| Server SQLite | 311 bestanden, 31 übersprungen (Valkey/S3/PG-spezifisch) |
| Server PG + Valkey + S3 (RustFS) | 342 bestanden (lokal); in CI als Services |
| Web | 75 Unit, 22 E2E funktional + 1 Perf (90k Fahrten), `npm audit` 0 |
| iOS | 87 XCTests grün (CI macOS-15, Simulator) |
| Helm | `test-chart.sh` 48/48 (lint, template, kubeconform, 20 Negativtests) |
| Lint/Security | ruff, bandit, pip-audit sauber |

## CI-Workflows (`.github/workflows/`)

- `fahrzeugbuch.yml`: Job `server` (Lock-Hashes, ruff, bandit, pip-audit, Tests SQLite + PG/Valkey/S3, Docker-Build), Job `ios` (xcodegen + xcodebuild test, ohne Signierung).
- `fahrzeugbuch-web.yml`: lint, typecheck, unit, build, size-Budget, audit, E2E, Perf.
- `fahrzeugbuch-helm.yml`: Chart-Tests (helm aus Go-Modul gebaut, da get.helm.sh im Sandbox-Proxy gesperrt; `HELM_SHA256` setzen → offizielles Tarball).
- `fahrzeugbuch-screenshots.yml`: Demo-Screenshots, committet nach `docs/screenshots`; **`branches-ignore: [main]`** → läuft hier auf `main` nicht (bewusst: schreibt zurück). Anpassen, falls gewünscht.
- Alle Actions per SHA gepinnt, Basis-Images per Digest.

## iOS / TestFlight

| Punkt | Stand |
|---|---|
| Projekt/Scheme | `ios/project.yml` → `xcodegen generate` → `Fahrzeugbuch.xcodeproj`, Scheme `Fahrzeugbuch`, Test-Target `FahrzeugbuchTests` |
| Bundle-ID | **`ch.odovio`** (Nutzerentscheid 25.11.2026; vorher `net.jmb.fahrzeugbuch`), Tests `ch.odovio.tests`, Extensions künftig `ch.odovio.<name>`; OIDC-Redirect `ch.odovio:/oauth2redirect` (Keycloak-Client `fahrzeugbuch-ios` mit `setup-client.sh` neu einrichten bzw. Redirect anpassen), Quick Actions `ch.odovio.addFuel/startTrip`, Setup-URL-Schema `fahrzeugbuch://` |
| Team-ID | **leer** (`DEVELOPMENT_TEAM: ""`), Signing `Automatic` |
| Version | `MARKETING_VERSION 1.0`, `CURRENT_PROJECT_VERSION 1` |
| Toolchain | CI `macos-15` (Xcode 16.x Default), `SWIFT_VERSION 5.0` (Swift-5-Modus), iOS 17.0 Deployment Target, nur iPhone, Portrait |
| Capabilities | Background Mode `location`; Usage-Strings: Location (WhenInUse/Always), Motion, Kalender, Kamera |
| App-Icon | `ios/Fahrzeugbuch/Assets.xcassets/AppIcon.appiconset/AppIcon.png` (Single-Size) |
| Privacy-Manifest | **fehlt** (`PrivacyInfo.xcprivacy`) – nötig für App Store: Required-Reason-APIs (UserDefaults, File-Timestamps, ggf. SystemBootTime), keine Tracking-Domains |
| Secrets/Workflows | keine Signing-Secrets, kein Fastlane, kein TestFlight-Workflow vorhanden |
| Export-Compliance | nur Standard-Krypto (HTTPS, CryptoKit SHA-256) → `ITSAppUsesNonExemptEncryption = NO` prüfen/setzen |

## Offene Punkte (priorisiert)

1. **TestFlight**: Team-ID, Privacy-Manifest, Export-Compliance, App-Store-Connect-API-Key als Secret, Signing-Workflow (z. B. `xcodebuild archive` + `altool`/`notarytool` bzw. Fastlane), Build-Nummer automatisch.
2. **Echte Geräte-Tests**: Hintergrund-Aufzeichnung, Automatik, Kurzbefehle, Akku, Scan mit Kamera.
3. **PDF-Last**: jedes PDF gleicht alle Datensätze ab (Integritätsabschnitt) → bei ~67k Fahrten p50 ≈ 28 s, ~0.2 PDF/s; begrenzt per `PDF_CONCURRENCY` (503 + Retry-After). Abhilfe (z. B. inkrementeller Abgleich / Cache je Kettenkopf) ändert Semantik → Nutzerentscheid.
4. **Sync** schreibt je Mandant seriell (Mandantenzeilen-Lock) → p95 hoch unter Last; bewusst wegen Hash-Kette.
5. **Helm** in echtem Cluster installieren (k3s/Proxmox), Valkey-/S3-Pfad in CI verifizieren.
6. Lasttest auf Ziel-Hardware (EPYC) wiederholen (`server/loadtest/README.md`).
7. Caddy/CrowdSec/fail2ban live testen.
8. Screenshot-Workflow für `main` klären (s. o.).

## Bekannte Probleme / Grenzen

- Lasttest (4 vCPU, 1 Mio. Revisionen, 32 Nutzer): 1 Worker 42 RPS / p95 2.1 s, 4 Worker 87 RPS / p95 1.6 s; PDF siehe oben.
- Rate-Limits/Sperren ohne Valkey nur im Prozess (1 Worker, Reset bei Neustart); `FORWARDED_ALLOW_IPS` muss die Proxy-IP sein.
- Web: Voll-Sync hält alle Fachdaten im Tab (~130 MB bei 100k Fahrten).
- Lokalmodus iOS: Journal-Abgleich kann bei Zeitzonenwechsel falsch-positiv melden.
- Valkey-Passwort in Prozessargumenten sichtbar (nur internes Netz).

## Offene Nutzerentscheide

- PDF-Integritätsabschnitt vereinfachen/cachen?
- Screenshot-Workflow auf `main` zulassen?
- Valkey standardmässig aktivieren oder Profil `scale` belassen?
- Belege: fs (RWX) oder S3 (MinIO/RustFS/Ceph) im Zielbetrieb?
- Apple-Developer-Team (Bundle-ID `ch.odovio` entschieden).
