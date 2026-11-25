# Fahrzeugbuch

Digitales Fahrzeugbuch: iOS-App (SwiftUI) + REST-Server (FastAPI/PostgreSQL, Docker via Portainer). Anmeldung via **OIDC/Keycloak** (Authorization Code + PKCE).

## Funktionen

- **Fahrzeuge**: mehrere, mit Kennzeichen, Treibstoff, Start-km
- **Kilometerstände**: manuell; Tankvorgänge und Wartungen zählen ebenfalls → aktueller Stand = Maximum
- **Tankvorgänge**: Datum, km, Liter, Betrag, voll/teil, Tankstelle → Preis/Liter
- **Verbrauch** (Voll-zu-voll): l/100 km, l/km, CHF/km je Etappe + Durchschnitt, Diagramm
- **Wartungen**: Checklisten zum Abhaken, Vorlagen (Service, Reifenwechsel, MFK), Kosten, nächste Fälligkeit nach km/Datum mit Überfällig-Warnung
- **Offline**: alle Eingaben ohne Verbindung; Outbox wird bei nächster Verbindung synchronisiert (Netzwechsel, App-Start, Pull-to-Refresh, Sync-Symbol)
- **Revisionssicher**: jede Erfassung/Änderung/Stornierung als unveränderliche Revision in einer SHA-256-Hash-Kette; Löschen = Stornieren; Verlauf je Eintrag; Integritätsprüfung
- **Mandanten**: über Keycloak-Gruppen, Rollen Schreiben/Lesen, strikt getrennte Daten und Revisionsketten
- **PDF-Export** je Fahrzeug und Zeitraum: Übersicht, Tankvorgänge, Wartungen inkl. Checkliste, km-Stände, Änderungsprotokoll, Kettenkopf-Hash

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
- Mapper `groups` (volle Gruppenpfade im Access-Token)
- Mandantengruppen `/fahrzeugbuch/<mandant>` (Schreiben) und `/fahrzeugbuch/<mandant>/lesen` (Lesen) aus `TENANTS`, Mitglieder aus `MEMBERS` / `READERS`

```bash
... -e TENANTS="privat b-re.ch" -e MEMBERS="privat=jakob,anna b-re.ch=jakob" -e READERS="b-re.ch=treuhand" ...
```

Mandanten werden beim ersten Zugriff automatisch angelegt. Gruppen können auch aus UCS/LDAP föderiert sein – entscheidend ist der Pfad.

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
| `TENANT_GROUP_PREFIX` | – | `/fahrzeugbuch/` |
| `DEFAULT_TENANT` | – | Mandant für alle berechtigten Benutzer (Einzelbetrieb ohne Gruppen) |
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
Offline: Daten liegen je Mandant lokal (Application Support, Dateischutz). Neue Einträge erhalten sofort eine UUID, ausstehende Änderungen zeigt das Wolken-Symbol (Zahl = Outbox). Abmelden oder Serverwechsel löscht lokale Daten (mit Warnung bei ausstehenden Änderungen). PDF und Verlauf benötigen eine Verbindung.
Mandantenwechsel über das Gebäude-Symbol (bei mehreren Mandanten); Lesezugriff blendet Erfassen/Bearbeiten aus.

Login läuft über `ASWebAuthenticationSession` (Safari-Session → SSO mit bestehendem Keycloak-Login). Refresh-Token in der Keychain, Access-Token nur im Speicher; bei 401 einmal Refresh + Wiederholung, bei abgelaufener Sitzung zurück zum Login.
Andere Bundle-ID → `AuthManager.callbackScheme/redirectURI` und `REDIRECT` im Keycloak-Skript anpassen.
HTTP ohne TLS funktioniert nur im lokalen Netz (`NSAllowsLocalNetworking`).

## API (Auszug)

Alle `/api/*`-Aufrufe mit `Authorization: Bearer <Keycloak-Access-Token>`. Öffentlich: `/health`, `/auth/config`.
Schreiben ausschliesslich über `/sync` → jede Änderung läuft durch das Revisionsjournal.

| Methode | Pfad | Zweck |
|---|---|---|
| GET | `/api/me` | Benutzer + Mandanten/Rollen |
| GET | `/api/checklist-templates` | Vorlagen |
| POST | `/api/t/{mandant}/sync` | Ops aus der Outbox anwenden (Schreibrolle) |
| GET | `/api/t/{mandant}/changes?since=<cursor>` | Änderungen seit Cursor (inkl. Stornos) |
| GET | `/api/t/{mandant}/vehicles` · `/vehicles/{id}/stats` | Übersicht, Verbrauch, Fälligkeiten |
| GET | `/api/t/{mandant}/vehicles/{id}/report.pdf?from=&to=` | PDF-Export |
| GET | `/api/t/{mandant}/history/{entity}/{id}` | Revisionen eines Eintrags |
| GET | `/api/t/{mandant}/audit/verify` | Hash-Kette prüfen |

### Sync-Protokoll

```json
POST /api/t/privat/sync
{"ops": [{"op_id": "<uuid>", "entity": "fuel", "id": "<uuid>", "action": "upsert",
          "base_version": null, "client_ts": "2026-11-25T10:00:00+01:00",
          "data": {"vehicle_id": "<uuid>", "date": "2026-11-25", "km": 50600, "liters": 44.8, "price_total": 80.2}}]}
```

- `entity`: `vehicle`, `odometer`, `fuel`, `maintenance`, `maintenance_item`; `action`: `upsert` | `delete` (= Storno)
- IDs erzeugt die App (UUID); `op_id` macht Wiederholungen idempotent (`duplicate`)
- `base_version` ≠ Serverversion → `conflict`: letzte Änderung gewinnt, überschriebene Version bleibt im Verlauf
- Ungültige Ops → `rejected` mit Grund, restliche Ops des Batches werden trotzdem angewendet; App gleicht danach vollständig ab

## Revisionssicherheit

- Tabelle `revisions`: je Änderung Version, Aktion, vollständiger Datenstand, Benutzer (`sub`, Name), Serverzeit (UTC), Erfassungszeit auf dem Gerät, `op_id`, Konfliktflag
- `hash = SHA256(prev_hash + kanonisches JSON)` je Mandant → Ändern, Löschen, Einfügen oder Umordnen bricht die Kette (`/audit/verify` meldet die Seq)
- DB-Trigger verhindert `UPDATE`/`DELETE`/`TRUNCATE` auf `revisions` (PostgreSQL), Fachtabellen nur Soft-Delete
- Kettenkopf-Hash steht in jedem PDF → externer Anker: ein späteres Verify muss denselben oder einen Nachfolger-Stand bestätigen
- Grenzen: Ein DB-Superuser kann Trigger deaktivieren und die Kette komplett neu berechnen. Schutz dagegen: PDFs/Kettenkopf extern ablegen (z. B. Paperless-ngx), DB-Backups. Keine zertifizierte GeBüV-/GoBD-Lösung.

## Verbrauchsberechnung

Voll-zu-voll: Liter aller Tankvorgänge nach einer Volltankung bis inkl. der nächsten Volltankung ÷ gefahrene km dazwischen. Teilbetankungen werden mitgezählt, ergeben aber keinen eigenen Wert. Die erste Volltankung ist der Startpunkt.

## Entwicklung

```bash
cd fahrzeugbuch/server
pip install -r requirements-test.txt
pytest -q                                  # SQLite, JWTs mit lokalem Testschlüssel
FZB_TEST_DATABASE_URL=postgresql+psycopg://u:p@localhost/db pytest -q   # PostgreSQL (Trigger, Locks)
OIDC_ISSUER=https://id.j-mb.net/realms/<realm> OIDC_CLIENT_ID=fahrzeugbuch-ios uvicorn app.main:app --reload
```

CI (`.github/workflows/fahrzeugbuch.yml`, liegt im Repo-Root unter `.github/` – beim Umzug mitnehmen und Pfade `fahrzeugbuch/` anpassen): Tests gegen SQLite + PostgreSQL, Docker-Build, iOS-Simulator-Build.
