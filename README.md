# Fahrzeugbuch

Digitales Fahrzeugbuch: iOS-App (SwiftUI) + REST-Server (FastAPI/PostgreSQL, Docker via Portainer). Anmeldung via **OIDC/Keycloak** (Authorization Code + PKCE).

## Funktionen

- **Fahrzeuge**: mehrere, mit Kennzeichen, Treibstoff, Start-km
- **Kilometerstände**: manuell; Tankvorgänge und Wartungen zählen ebenfalls → aktueller Stand = Maximum
- **Tankvorgänge**: Datum, km, Liter, Betrag, voll/teil, Tankstelle → Preis/Liter
- **Verbrauch** (Voll-zu-voll): l/100 km, l/km, CHF/km je Etappe + Durchschnitt, Diagramm
- **Wartungen**: Checklisten zum Abhaken (live), Vorlagen (Service, Reifenwechsel, MFK), Kosten, nächste Fälligkeit nach km/Datum mit Überfällig-Warnung

## Struktur

| Pfad | Inhalt |
|---|---|
| `server/` | FastAPI-App (OIDC-Resource-Server), Dockerfile, Tests |
| `keycloak/` | `setup-client.sh`: Keycloak-Client anlegen (idempotent) |
| `docker-compose.yml` | Portainer-Stack (API + Postgres) |
| `ios/` | SwiftUI-App (iOS 17+), XcodeGen-Projekt |

## Keycloak

```bash
# im Keycloak-Container (Image hat kein awk/jq – Skript ist reines Bash)
docker exec -i -e KC_URL=http://localhost:8080 -e REALM=<realm> -e KC_ADMIN=admin \
  -e KC_ADMIN_PASSWORD=... -e ASSIGN_USERS="jakob" <keycloak-container> bash -s < keycloak/setup-client.sh
```

Legt an bzw. aktualisiert:
- Client `fahrzeugbuch-ios`: public, nur Standard Flow, PKCE S256 erzwungen, Redirect `net.jmb.fahrzeugbuch:/oauth2redirect`
- optionaler Scope `offline_access` → Refresh-Token übersteht SSO-Session-Timeout (kein Login alle 30 min)
- Client-Rolle `fahrzeugbuch-user`, zugewiesen an `ASSIGN_USERS`

Abmelden in der App widerruft das Offline-Token (`/revoke`).

## Server (Portainer)

1. DB-Passwort erzeugen: `openssl rand -hex 32`
2. Portainer → **Stacks → Add stack → Repository**
   - Compose path: `fahrzeugbuch/docker-compose.yml`
   - Environment variables:

| Variable | Pflicht | Beispiel / Default |
|---|---|---|
| `DB_PASSWORD` | ja | – |
| `OIDC_ISSUER` | ja | `https://id.j-mb.net/realms/<realm>` |
| `OIDC_CLIENT_ID` | – | `fahrzeugbuch-ios` (Token wird über `azp` geprüft) |
| `OIDC_REQUIRED_ROLE` | – | `fahrzeugbuch-user` (Realm-/Client-Rolle oder Gruppe); leer = jeder Realm-Benutzer |
| `OIDC_AUDIENCE` | – | statt `azp` die `aud` prüfen (Audience-Mapper nötig) |
| `API_PORT` | – | `8085` |

3. Prüfen: `curl http://<docker-vm>:8085/health` und `/auth/config`
   Der Container muss den Issuer erreichen (Discovery/JWKS).
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

Erster Start: nur Server-URL eingeben → *Verbindung testen* (zeigt Issuer/Client) → *Sichern* → *Mit Keycloak anmelden*.
Login läuft über `ASWebAuthenticationSession` (Safari-Session → SSO mit bestehendem Keycloak-Login). Refresh-Token in der Keychain, Access-Token nur im Speicher; bei 401 einmal Refresh + Wiederholung, bei abgelaufener Sitzung zurück zum Login.
Andere Bundle-ID → `AuthManager.callbackScheme/redirectURI` und `REDIRECT` im Keycloak-Skript anpassen.
HTTP ohne TLS funktioniert nur im lokalen Netz (`NSAllowsLocalNetworking`).

## API (Auszug)

Alle `/api/*`-Aufrufe mit `Authorization: Bearer <Keycloak-Access-Token>`. Öffentlich: `/health`, `/auth/config`. Alle berechtigten Benutzer sehen dieselben Fahrzeuge (Haushalt).

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
| GET | `/api/me` | angemeldeter Benutzer |

## Verbrauchsberechnung

Voll-zu-voll: Liter aller Tankvorgänge nach einer Volltankung bis inkl. der nächsten Volltankung ÷ gefahrene km dazwischen. Teilbetankungen werden mitgezählt, ergeben aber keinen eigenen Wert. Die erste Volltankung ist der Startpunkt.

## Entwicklung

```bash
cd fahrzeugbuch/server
pip install -r requirements-test.txt
pytest -q                                  # SQLite, JWTs mit lokalem Testschlüssel
OIDC_ISSUER=https://id.j-mb.net/realms/<realm> OIDC_CLIENT_ID=fahrzeugbuch-ios uvicorn app.main:app --reload
```

CI (`.github/workflows/fahrzeugbuch.yml`, liegt im Repo-Root unter `.github/` – beim Umzug mitnehmen und Pfade `fahrzeugbuch/` anpassen): Tests gegen SQLite + PostgreSQL, Docker-Build, iOS-Simulator-Build.
