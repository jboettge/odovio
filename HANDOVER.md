# Übergabe Fahrzeugbuch (odovio)

Stand: 25.11.2026. Herkunft: `jboettge/DroidSim`, Branch `claude/digitales-fahrzeugbuch-app-pn3461`, Ordner `fahrzeugbuch/` – mit Historie hierher verschoben (Pfade auf Repo-Root umgeschrieben).

## Architektur / Ordner

| Pfad | Inhalt |
|---|---|
| `server/` | FastAPI, SQLAlchemy 2, Alembic (0001–0005), PostgreSQL (Prod) / SQLite (Tests), reportlab-PDF. Dockerfile mehrstufig (Web-Build + API), Build-Kontext = Repo-Root |
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
- **VIN/Fahrgestellnummer** (27.11.2026): Feld `vin` am Fahrzeug (Server: `models.Vehicle.vin` String(17), Alembic 0005 idempotent, `schemas.normalize_vin` → abgelehnt/422 «VIN ungültig: genau 17 Zeichen …»; Web: Stammdaten-Formular mit Normalisierung beim Verlassen, Fahrzeugdetails, `web/src/lib/vin.ts`; iOS: Formular «Identifikation» mit «VIN scannen» (`Scan/VINScannerView.swift`, VisionKit Code 39/Data Matrix/QR + Text, OCR-Korrektur I/O/Q → 1/0/0, Logik `Shared/VIN.swift`), Anzeige in der Übersicht). PDF/CSV/Jahresbericht zeigen die VIN (CSV: neue Spalte «VIN» vor «ID», auch lokal in iOS). Prüfziffer nur Hinweis (nordamerikanische VINs). Hash-Kette: Altrevisionen ohne `vin` gelten beim Abgleich als gleich, solange der Datensatz `vin = NULL` hat (`integrity._same`, wie `article_id`); iOS kodiert `nil` nicht → lokale Journal-Hashes bestehender Fahrzeuge unverändert. Web-Scan bewusst weggelassen (Permissions-Policy `camera=()`, `BarcodeDetector` auf Desktop-Browsern meist nicht vorhanden).
- **Helm**: Chart mit HPA/VPA, Valkey optional, Migrations-Hook-Job, NetworkPolicy, ServiceMonitor. Nicht in echtem Cluster installiert (kind lief in der Sandbox nicht); Image mit Chart-Settings in Docker geprüft.

## Teststatus (letzter Stand)

| Komponente | Ergebnis |
|---|---|
| Server SQLite | 351 bestanden, 31 übersprungen (Valkey/S3/PG-spezifisch; Stand 27.11. inkl. VIN) |
| Server PG 16 + Valkey (ohne S3, lokal 25.11.) | 352 bestanden, 5 übersprungen (S3) |
| Server PG + Valkey + S3 (RustFS) | 342 bestanden (lokal); in CI als Services |
| Web | 79 Unit, 24 E2E funktional (27.11. inkl. VIN) + 1 Perf (90k Fahrten), `npm audit` 0 |
| iOS | 87 XCTests grün (CI macOS-15, Simulator) |
| Helm | `test-chart.sh` 48/48 (lint, template, kubeconform, 20 Negativtests) |
| Lint/Security | ruff, bandit, pip-audit sauber |

## CI-Workflows (`.github/workflows/`)

- `fahrzeugbuch.yml`: Job `server` (Lock-Hashes, ruff, bandit, pip-audit, Tests SQLite + PG/Valkey/S3, Docker-Build), Job `ios` (xcodegen + xcodebuild test, ohne Signierung).
- `fahrzeugbuch-web.yml`: lint, typecheck, unit, build, size-Budget, audit, E2E, Perf.
- `fahrzeugbuch-helm.yml`: Chart-Tests (helm aus Go-Modul gebaut, da get.helm.sh im Sandbox-Proxy gesperrt; `HELM_SHA256` setzen → offizielles Tarball).
- `fahrzeugbuch-screenshots.yml`: Demo-Screenshots, committet nach `docs/screenshots`; **nur manuell** (*Run workflow* auf einem Feature-Branch, nie `main`), um macOS-Minuten zu sparen.
- Alle Actions per SHA gepinnt, Basis-Images per Digest.

## iOS / TestFlight

| Punkt | Stand |
|---|---|
| Projekt/Scheme | `ios/project.yml` → `xcodegen generate` → `Fahrzeugbuch.xcodeproj`, Scheme `Fahrzeugbuch`, Test-Target `FahrzeugbuchTests` |
| Bundle-ID | **`ch.odovio`** (Nutzerentscheid 25.11.2026; vorher `net.jmb.fahrzeugbuch`), Tests `ch.odovio.tests`, Extensions künftig `ch.odovio.<name>`; OIDC-Redirect `ch.odovio:/oauth2redirect` (Keycloak-Client `fahrzeugbuch-ios` mit `setup-client.sh` neu einrichten bzw. Redirect anpassen), Quick Actions `ch.odovio.addFuel/startTrip`, Setup-URL-Schema `fahrzeugbuch://` |
| Team-ID | `Q66V4Q95B4`, Signing `Automatic` (Cloud-Signing per API-Key in CI) |
| Version | `MARKETING_VERSION 1.0`, `CURRENT_PROJECT_VERSION 1` |
| Toolchain | CI `macos-15` (Xcode 16.x Default), `SWIFT_VERSION 5.0` (Swift-5-Modus), iOS 17.0 Deployment Target, nur iPhone, Portrait |
| Capabilities | Background Mode `location`; Usage-Strings: Location (WhenInUse/Always), Motion, Kalender, Kamera |
| App-Icon | `ios/Fahrzeugbuch/Assets.xcassets/AppIcon.appiconset/AppIcon.png` (Single-Size) |
| Privacy-Manifest | `ios/Fahrzeugbuch/PrivacyInfo.xcprivacy` (UserDefaults CA92.1, File-Timestamp C617.1, kein Tracking) |
| Secrets/Workflows | Secrets `ASC_ISSUER_ID`, `ASC_KEY_ID`, `ASC_PRIVATE_KEY` (base64), `TEAM_ID`; Workflow `ios-testflight.yml` (ohne Fastlane), siehe `docs/TESTFLIGHT.md` |
| Export-Compliance | `ITSAppUsesNonExemptEncryption = NO` gesetzt |

## Offene Punkte (priorisiert)

1. **TestFlight**: vorbereitet (`docs/TESTFLIGHT.md`); erster Lauf mit Xcode 26 ausstehend.
2. **Echte Geräte-Tests**: Hintergrund-Aufzeichnung, Automatik, Kurzbefehle, Akku, Scan mit Kamera (inkl. VIN-Scan: Strichcode im Türrahmen, Aufdruck Windschutzscheibe, Fahrzeugausweis). Hinweis VIN: ältere App-/Web-Stände ohne Feld `vin` senden es beim Bearbeiten eines Fahrzeugs nicht mit → Server setzt es auf NULL (Upsert ersetzt alle Felder); nach dem Rollout App/Web aktualisieren.
3. **PDF-Last** – *umgesetzt (Nutzerentscheid: Semantik darf sich ändern)*: Integritätsprüfung inkrementell ab dem bestätigten Prüfstand je Mandant (Tabelle `verify_checkpoints`, Alembic 0004, signiert mit `ANCHOR_SIGNING_KEY`, gemeinsam für alle Worker). PDF-Integritätsabschnitt 3.7 s (warm) bzw. 8.5 s (erster Bericht je Worker) → 0.04 s bei 67k Fahrten; PDF-only-Lasttest 0.4 → 1.3 PDF/s, p50 14.9 → 4.2 s (Details `server/loadtest/README.md`). Vollprüfung per `?full=1` bzw. automatisch nach `VERIFY_FULL_INTERVAL_S`; das PDF weist «vollständig am … (Revision 1–F), seither inkrementell bis Revision N» aus. Offen: täglichen Vollprüfungs-Aufruf (n8n) einrichten; ohne Signaturschlüssel ist der Prüfstand unsigniert. Rest-Engpass im Mischbetrieb: Rendern (CPU) und Mandantensperre für den Anker vor dem PDF.
4. **Sync** schreibt je Mandant seriell (Mandantenzeilen-Lock) → p95 hoch unter Last; bewusst wegen Hash-Kette.
5. **Helm** in echtem Cluster installieren (k3s/Proxmox), Valkey-/S3-Pfad in CI verifizieren.
6. Lasttest auf Ziel-Hardware (EPYC) wiederholen (`server/loadtest/README.md`).
7. Caddy/CrowdSec/fail2ban live testen.
8. ~~Screenshot-Workflow für `main`~~ – nur manuell auf Branches (Entscheid).

## Bekannte Probleme / Grenzen

- Lasttest (4 vCPU, 1 Mio. Revisionen, 32 Nutzer): 1 Worker 42 RPS / p95 2.1 s, 4 Worker 87 RPS / p95 1.6 s; PDF siehe oben.
- Inkrementelle Integritätsprüfung: Manipulationen bereits bestätigter Revisionen (ohne Neuberechnen der Kette) bzw. unveränderter Datensätze erkennt erst die nächste Vollprüfung (≤ `VERIFY_FULL_INTERVAL_S` nach der letzten, sofern ein Bericht/Verify sie auslöst).
- Rate-Limits/Sperren ohne Valkey nur im Prozess (1 Worker, Reset bei Neustart); `FORWARDED_ALLOW_IPS` muss die Proxy-IP sein.
- Web: Voll-Sync hält alle Fachdaten im Tab (~130 MB bei 100k Fahrten).
- Lokalmodus iOS: Journal-Abgleich kann bei Zeitzonenwechsel falsch-positiv melden.
- Valkey-Passwort in Prozessargumenten sichtbar (nur internes Netz).

## Offene Nutzerentscheide

Entschieden 25.11.2026: PDF-Integritätsprüfung inkrementell (umgesetzt, siehe Punkt 3); Screenshot-Workflow nur manuell auf Branches (nicht `main`); Valkey standardmässig aktiv (Compose, `STATE_BACKEND=redis`); Belege im Dateisystem (`STORAGE_BACKEND=fs`); Betrieb unter https://www.odovio.ch als Neustart (keine Datenübernahme); IdP bleibt Keycloak (ein Realm, Clients `fahrzeugbuch-ios`/`fahrzeugbuch-web`), Mitgliederverwaltung nur im Web; iOS-Anzeigename `odovio`, Version aus Tag `ios-vX.Y.Z`.
Entschieden 26.11.2026: Python 3.14 (Image `python:3.14-slim`, CI, ruff py314), PostgreSQL 18 (Volume jetzt `/var/lib/postgresql`, PGDATA `/var/lib/postgresql/18/docker`), Valkey 9.2; Node 24; Screenshots nur manuell.
- Apple-Developer-Team `Q66V4Q95B4`, Bundle-ID `ch.odovio` (entschieden). Weitere iOS-Entscheide: `docs/TESTFLIGHT.md`.
