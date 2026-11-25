# Fahrzeugbuch

Digitales Fahrzeugbuch: iOS-App (SwiftUI) + REST-Server (FastAPI/PostgreSQL, Docker via Portainer).

## Funktionen

- **Fahrzeuge**: mehrere, mit Kennzeichen, Treibstoff, Start-km
- **Kilometerstände**: manuell; Tankvorgänge und Wartungen zählen ebenfalls → aktueller Stand = Maximum
- **Tankvorgänge**: Datum, km, Liter, Betrag, voll/teil, Tankstelle → Preis/Liter
- **Verbrauch** (Voll-zu-voll): l/100 km, l/km, CHF/km je Etappe + Durchschnitt, Diagramm
- **Wartungen**: Checklisten zum Abhaken (live), Vorlagen (Service, Reifenwechsel, MFK), Kosten, nächste Fälligkeit nach km/Datum mit Überfällig-Warnung

## Struktur

| Pfad | Inhalt |
|---|---|
| `server/` | FastAPI-App, Dockerfile, Tests |
| `docker-compose.yml` | Portainer-Stack (API + Postgres) |
| `ios/` | SwiftUI-App (iOS 17+), XcodeGen-Projekt |

## Server (Portainer)

1. Secrets erzeugen: `openssl rand -hex 32` (je für `API_TOKEN`, `DB_PASSWORD`)
2. Portainer → **Stacks → Add stack → Repository**
   - Repository: dieses Repo, Branch wählen
   - Compose path: `fahrzeugbuch/docker-compose.yml`
   - Environment variables: `API_TOKEN`, `DB_PASSWORD`, optional `API_PORT` (Default `8085`)
3. Prüfen: `curl http://<docker-vm>:8085/health` → `{"status":"ok"}`
4. **HTTPS** über Reverse Proxy (z. B. Caddy auf OPNsense), z. B. `fahrzeugbuch.j-mb.net → <docker-vm>:8085`. iOS verlangt HTTPS ausserhalb des LAN.

Optionen:
- **Bestehende PostgreSQL** statt eigener DB: Service `db` entfernen, `DATABASE_URL=postgresql+psycopg://user:pw@host:5432/fahrzeugbuch` setzen.
- **Eigene Checklisten-Vorlagen**: JSON (`[{"title": "...", "items": ["..."]}]`) mounten und `CHECKLIST_FILE` setzen (siehe Kommentar im Compose).
- **Backup**: `docker exec fahrzeugbuch-db pg_dump -U fahrzeugbuch fahrzeugbuch > fzb.sql`
- API-Doku: `http://<host>:8085/docs`

## iOS-App

Voraussetzung: Mac mit Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
cd fahrzeugbuch/ios
xcodegen generate
open Fahrzeugbuch.xcodeproj
```

In Xcode: Target → *Signing & Capabilities* → Team wählen (ggf. Bundle-ID anpassen) → auf iPhone ausführen.
Mit kostenlosem Apple-Account läuft die Signatur 7 Tage; für Dauerbetrieb Developer-Account oder TestFlight.

Erster Start: Server-URL + `API_TOKEN` eingeben → *Verbindung testen* → *Sichern*. Token liegt in der Keychain.
HTTP ohne TLS funktioniert nur im lokalen Netz (`NSAllowsLocalNetworking`).

## API (Auszug)

Alle `/api/*`-Aufrufe mit `Authorization: Bearer <API_TOKEN>`.

| Methode | Pfad | Zweck |
|---|---|---|
| GET/POST | `/api/vehicles` | Fahrzeuge |
| GET/PUT/DELETE | `/api/vehicles/{id}` | Fahrzeug (DELETE löscht alle Einträge) |
| GET | `/api/vehicles/{id}/stats` | Verbrauch, Kosten, Fälligkeiten |
| GET/POST | `/api/vehicles/{id}/odometer` · PUT/DELETE `/api/odometer/{id}` | Kilometerstände |
| GET/POST | `/api/vehicles/{id}/fuel` · PUT/DELETE `/api/fuel/{id}` | Tankvorgänge |
| GET/POST | `/api/vehicles/{id}/maintenance` · GET/PUT/DELETE `/api/maintenance/{id}` | Wartungen inkl. Checkliste |
| PATCH | `/api/maintenance-items/{id}` `{"done": true}` | Checkpunkt abhaken |
| GET | `/api/checklist-templates` | Vorlagen |

## Verbrauchsberechnung

Voll-zu-voll: Liter aller Tankvorgänge nach einer Volltankung bis inkl. der nächsten Volltankung ÷ gefahrene km dazwischen. Teilbetankungen werden mitgezählt, ergeben aber keinen eigenen Wert. Die erste Volltankung ist der Startpunkt.

## Entwicklung

```bash
cd fahrzeugbuch/server
pip install -r requirements-test.txt
pytest -q                                  # SQLite
API_TOKEN=dev uvicorn app.main:app --reload
```

CI (`.github/workflows/fahrzeugbuch.yml`): Tests gegen SQLite + PostgreSQL, Docker-Build, iOS-Simulator-Build.
