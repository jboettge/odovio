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

## Fahrtenbuch

Konzept und Entscheidungen: [docs/KONZEPT-FAHRTENBUCH.md](docs/KONZEPT-FAHRTENBUCH.md) (Empfehlungen Kap. 9 umgesetzt).

- **Erfassung**: Start/Stopp-Knopf, Siri/Kurzbefehle („Fahrt starten/beenden“, Automation „CarPlay verbunden“), optional Automatik (Bewegung + Standort); manuell und Lücken als Fahrt
- **Tacho massgebend**: km-Kette je Fahrzeug, GPS/OSRM nur Kontrolle; Lückenerkennung + Abgleich mit km-Ständen/Tankungen
- **Vorschläge** (immer bestätigen): Regeln → Kalender → Muster → lokales LLM (vLLM, nie Privatfahrten, nie Koordinaten); Orte und Regeln werden gelernt
- **Review**: Karte für Karte, „alle Arbeitswege bestätigen“
- **Monatsabschluss**: sperrt Fahrten, signierter Anker, Fahrtenbuch-PDF, optional n8n-Webhook → Paperless; danach nur Storno/Korrektur mit Begründung
- **Berichte**: Fahrtenbuch-PDF, CSV, Jahresbericht (Privatanteil pauschal 0.9 %/Monat vs. effektiv, Kilometerentschädigung, Arbeitsweg-Abzug Bund/Kanton) – Parameter je Jahr/Kanton/Mandant, als Annahmen markiert
- **Datenschutz**: Privatmodus (nur km/Zeit, Gemeinde optional), GPS-Tracks nur auf dem iPhone (30 Tage nach Bestätigung gelöscht, nur Hash im Journal), Wohnort-Koordinaten nie auf dem Server

Server-Umgebung zusätzlich: `OSRM_URL`, `PHOTON_URL` (optionaler Dienst `photon`, Profil `geo`), `VLLM_URL`, `VLLM_MODEL`, `N8N_WEBHOOK_URL`, `TAX_CANTON` (z. B. `ZH`). Ohne diese Dienste funktioniert alles ausser Distanz-/Adress-Kontrolle und LLM-Vorschlag.

Auf echtem Gerät zu testen: Hintergrund-Aufzeichnung, Automatik, Wecken nach Beenden, Kurzbefehle, Akku.

## Struktur

| Pfad | Inhalt |
|---|---|
| `server/` | FastAPI-App (OIDC-Resource-Server), Dockerfile, Tests |
| `keycloak/` | `setup-client.sh`: Keycloak-Client anlegen (idempotent) |
| `docker-compose.yml` | Portainer-Stack (API + Postgres) |
| `ios/` | SwiftUI-App (iOS 17+), XcodeGen-Projekt |
| `web/` | Web-Frontend (Vue 3, TypeScript, Vite) – wird ins API-Image gebaut und unter `/` ausgeliefert |
| `deploy/` | `Caddyfile.example`, CrowdSec- und fail2ban-Beispiele |

## Betriebsarten (App)

- **Nur auf diesem iPhone**: ohne Konto/Server; Daten + lokales Hash-Ketten-Journal in Application Support, Berichte/PDF/CSV und Monatsabschluss lokal (ohne signierten Server-Anker), Sicherung per Export/Import. Später per Assistent auf einen Server übertragbar.
- **Mit Server (gemeinsam)**: Fahrzeugbücher mit mehreren Personen, Rollen *Verwalten / Bearbeiten / Nur lesen*, „erfasst/geändert von“, Aktivität, signierte Anker, KI-Funktionen.
- **Administration nur im Webfrontend**: Mitglieder und Steuerparameter ändert der Server nur mit Tokens des Web-Clients (`azp = fahrzeugbuch-web`); die App zeigt sie lesend an.

## Web-Frontend

Ansicht und Verwaltung je Rolle: Übersicht, Fahrzeuge (Fahrten, Tanken, Wartungen, km-Stände, Berichte), Monatsabschluss, Aktivität, Integrität, Stammdaten; Mitglieder nur für *Verwalten*. Keycloak-Client `fahrzeugbuch-web` (public, PKCE) legt `setup-client.sh` mit `WEB_URL=https://fahrzeugbuch.j-mb.net` an. Tokens nur in `sessionStorage`, Abmeldung nach 30 min Inaktivität. Entwicklung, Mock-Server und Tests: [web/README.md](web/README.md), Screenshots: `docs/screenshots/web/`.

## Sicherheit

| Massnahme | Umsetzung / Env |
|---|---|
| Rate-Limiting | Token-Bucket je IP (`RATE_IP_PER_MIN` 600, öffentlich 120, Web 3000) und je Benutzer (`RATE_USER_PER_MIN` 1200); 429 + `Retry-After`; dazu spezifische Limits (Sync, Scan, KI) |
| Brute-Force | gehäufte 401 je IP bzw. 403/404 je IP+Benutzer → IP-Sperre 5/15/60 min (`BRUTE_*`); Ausnahmen `SECURITY_ALLOWLIST` |
| Sicherheits-Log | JSON-Zeilen `fahrzeugbuch.security` (auth_failed, rate_limited, brute_force_block, forbidden_tenant, admin_action …) → CrowdSec/fail2ban (`deploy/`) |
| CORS / CSRF | Default keine Cross-Origin-Freigabe; `CORS_ORIGINS` = exakte Allowlist; schreibende Requests mit fremder `Origin` → 403 |
| Host / Transport | `ALLOWED_HOSTS`, HSTS hinter TLS (`FORCE_HSTS`), CSP fürs Web, nosniff/CORP/no-store, `X-Request-ID`, kein `Server`-Header |
| Eingaben | Body-Limits, JSON-Tiefe/-Elemente (`JSON_MAX_*`), Header-/Token-Längen, Unicode-NFC, Steuer-/Bidi-Zeichen entfernt, strikte Pfadparameter |
| Injection | nur ORM/gebundene Parameter; CSV-Formelschutz (inkl. Unicode-Varianten), PDF-Escaping, RFC-6266-Dateinamen, URL-kodierte Keycloak-Admin-Aufrufe, Log-Bereinigung |
| Tokens | Signatur/Issuer/azp, `exp`/`iat`/`nbf`, max. Lebensdauer (`MAX_TOKEN_LIFETIME_S`), JWKS nur HTTPS |
| Konfiguration | Startprüfung unsicherer Werte (Warnung; `STRICT_CONFIG=1` → Abbruch) |
| Container | read-only, `cap_drop: ALL`, `init`, ulimits, Healthcheck, uvicorn 1 Worker + `--limit-concurrency` |
| Lieferkette | Lock-Dateien mit Hashes, gepinnte Images/Actions, `pip-audit`, `bandit`, `npm audit` in der CI |
| Keycloak (realmweit, nur per Flag) | `ENABLE_BRUTE_FORCE=1`, `SET_PASSWORD_POLICY=1`, `REQUIRE_ADMIN_OTP=1` |

Hinweise: Limits/Sperren liegen im Speicher (ein Prozess, Reset bei Neustart). `FORWARDED_ALLOW_IPS` muss die Proxy-IP sein, sonst teilen sich alle Clients eine IP. Reverse Proxy: `deploy/Caddyfile.example` (TLS, Header, Body-Grössen, Logs ohne Query).

## Keycloak

```bash
# im Keycloak-Container (Image hat kein awk/jq – Skript ist reines Bash)
docker exec -i -e KC_URL=http://localhost:8080 -e REALM=<realm> -e KC_ADMIN=admin \
  -e KC_ADMIN_PASSWORD=... -e ASSIGN_USERS="jakob" <keycloak-container> bash -s < keycloak/setup-client.sh
```

Legt an bzw. aktualisiert:
- Client `fahrzeugbuch-ios`: public, nur Standard Flow, PKCE S256 erzwungen, Redirect `ch.odovio:/oauth2redirect`
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

Dienste: `db` (PostgreSQL), `migrate` (einmalig je Deploy: Schema, Trigger, App-Rolle), `api` (read-only Container, ohne Capabilities, Port nur an `API_BIND`).

1. Geheimnisse erzeugen: `openssl rand -hex 32` (`DB_PASSWORD`, `APP_DB_PASSWORD`), `openssl rand -base64 32` (`ANCHOR_SIGNING_KEY`)
2. Portainer → **Stacks → Add stack → Repository**
   - Compose path: `docker-compose.yml`
   - Environment variables:

| Variable | Pflicht | Beispiel / Default |
|---|---|---|
| `DB_PASSWORD` | ja | Owner-Rolle (nur Migration/Backup) |
| `APP_DB_PASSWORD` | ja | App-Rolle `fahrzeugbuch_app`: kein Owner/Superuser, kein DELETE, Journal nur SELECT/INSERT |
| `ANCHOR_SIGNING_KEY` | empfohlen | Ed25519-Seed (Base64) für signierte Kettenanker – nicht in der DB, sichern! |
| `ANCHOR_INTERVAL_MIN` | – | `60` (Anker nach Änderungen höchstens stündlich, zusätzlich bei jedem PDF) |
| `API_BIND` | – | `127.0.0.1`; für Caddy auf OPNsense: IP der Docker-VM + Firewall nur OPNsense |
| `FORWARDED_ALLOW_IPS` | – | IP des Reverse Proxy |
| `OIDC_ALLOWED_AZP` | – | weitere Clients, z. B. für n8n-Skripte |
| `MAX_BODY_BYTES` | – | `1048576` |
| `DOCS_ENABLED` | – | `0` (API-Doku `/docs` nur bei Bedarf) |
| `OIDC_ISSUER` | ja | `https://id.j-mb.net/realms/<realm>` |
| `OIDC_CLIENT_ID` | – | `fahrzeugbuch-ios` (Token wird über `azp` geprüft) |
| `OIDC_REQUIRED_ROLE` | – | `fahrzeugbuch-user` (Realm-/Client-Rolle oder Gruppe); leer = jeder Realm-Benutzer |
| `OIDC_AUDIENCE` | – | statt `azp` die `aud` prüfen (Audience-Mapper nötig) |
| `TENANT_GROUP_PREFIX` | – | `/fahrzeugbuch/` |
| `DEFAULT_TENANT` | – | Mandant für alle berechtigten Benutzer (Einzelbetrieb ohne Gruppen) |
| `API_PORT` | – | `8085` |

3. Prüfen: `curl http://<docker-vm>:8085/health` und `/auth/config`
   Der Container muss den Issuer erreichen (Discovery/JWKS).
4. **HTTPS** über Reverse Proxy (z. B. Caddy auf OPNsense), z. B. `fahrzeugbuch.j-mb.net → <docker-vm>:8085`. Die App akzeptiert nur HTTPS.
   - Request-Grössen: `…/blob` bis 8 MiB (Belege), `…/scan` bis ~3 MB, sonst 1 MiB
   - Access-Logs des Proxys ohne Query-Strings (Datenschutz)
5. **Backup**: Datenbank **und** Volume `fahrzeugbuch-files` (Belege) gemeinsam sichern; `ANCHOR_SIGNING_KEY` separat aufbewahren.

Alle Variablen mit Kommentaren: `.env.example` (u. a. Rate-Limits `RATE_*`/`INTEL_RATE_*`, `UPSTREAM_*`, `ATTACHMENT_QUOTA_MB`, `ANCHOR_PUBLIC_KEYS` für Schlüsselwechsel, `N8N_WEBHOOK_SECRET` für HMAC-signierte Webhooks, `APP_TIMEZONE`).

**Schema-Migrationen**: Alembic (`server/alembic/`). Der Dienst `migrate` bringt neue und bestehende Datenbanken bei jedem Deploy auf den aktuellen Stand (bestehende ohne Alembic-Version werden automatisch nachgerüstet und gestempelt).

Optionen:
- **Bestehende PostgreSQL** statt eigener DB: Service `db` entfernen, `DATABASE_URL=postgresql+psycopg://user:pw@host:5432/fahrzeugbuch` setzen.
- **Eigene Checklisten-Vorlagen**: JSON (`[{"title": "...", "items": ["..."]}]`) mounten und `CHECKLIST_FILE` setzen (siehe Kommentar im Compose).
- **Backup**: `docker exec fahrzeugbuch-db pg_dump -U fahrzeugbuch fahrzeugbuch > fzb.sql`
- **Anker extern archivieren** (empfohlen): täglich `GET /api/t/<mandant>/audit/anchors` z. B. per n8n nach Paperless-ngx – enthält Public Key, Signaturen und Nachrichtenformat
- API-Doku: `DOCS_ENABLED=1` → `/docs`

## Skalierung

**Vertikal (Docker/Portainer)**: mehr Kerne/RAM für einen Host.
- `WEB_CONCURRENCY` = Anzahl uvicorn-Worker (`auto` = min(2 × CPU-Quota, 16)); >1 nur mit `STATE_BACKEND=redis` und Valkey (`docker compose --profile scale up -d`, `VALKEY_PASSWORD` setzen). Rate-Limits, Brute-Force-Sperren und Circuit-Breaker sind dann worker-übergreifend.
- Anker, Migration und Vollprüfung laufen per PostgreSQL-Advisory-Lock nur einmal.
- DB-Pool je Worker (`DB_POOL_SIZE`, `DB_MAX_OVERFLOW`); Startprüfung: Worker × (Pool + Overflow) + Reserve ≤ `PG_MAX_CONNECTIONS`. PostgreSQL-Tuning (`PG_*`) mit Tabelle für 8/16/32 GB in `.env.example`.
- Ressourcen je Dienst: `API_CPUS`, `API_MEMORY`, `DB_CPUS`, `DB_MEMORY`.
- Metriken: `/metrics` (Prometheus, nur mit `METRICS_TOKEN` oder aus `METRICS_ALLOW`); Probes `/health/live`, `/health/ready`.
- Lasttest: `server/loadtest/README.md` (4 vCPU, 1 Mio. Revisionen: 1 Worker 42 RPS → 4 Worker 87 RPS, p50 593 → 171 ms). PDF: Integritätsprüfung inkrementell ab dem bestätigten Prüfstand (≈ 0.04 s statt 3.7–8 s bei 67k Fahrten), Rendern begrenzt per `PDF_CONCURRENCY`. Engpass bleibt das Schreiben je Mandant (seriell).

**Kubernetes**: Helm-Chart `deploy/helm/fahrzeugbuch` – vertikal per VPA (Worker folgen dem CPU-Limit), horizontal per HPA (dann Valkey + Belege in S3 oder RWX-Volume, `STORAGE_BACKEND=s3|fs`). Migration als Helm-Hook-Job, Geheimnisse als `*_FILE`. Details: [deploy/helm/fahrzeugbuch/README.md](deploy/helm/fahrzeugbuch/README.md).

**Web-Frontend**: Lazy-Routen, vorkomprimierte Assets, virtuelles Scrollen, Web Worker; getestet mit 90k Fahrten (Details `web/README.md`).

## iOS-App

Voraussetzung: Mac mit Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
cd ios
xcodegen generate
open Fahrzeugbuch.xcodeproj
```

In Xcode: Target → *Signing & Capabilities* → Team wählen (ggf. Bundle-ID anpassen) → auf iPhone ausführen.
Mit kostenlosem Apple-Account läuft die Signatur 7 Tage; für Dauerbetrieb Developer-Account oder TestFlight.

Erster Start: nur Server-URL eingeben → *Verbindung testen* (zeigt Issuer/Client) → *Sichern* → *Mit Keycloak anmelden*.
Sicherheit: nur HTTPS (Debug: zusätzlich `http://localhost`); Issuer/Client werden nach der ersten Anmeldung gepinnt und die Discovery geprüft (Issuer gleich, Endpoints HTTPS auf dem Issuer-Host). Anmeldung in ephemerer Browser-Sitzung (kein geteiltes SSO-Cookie). Refresh-Token in der Keychain „nur dieses Gerät“. Meldet sich ein anderer Benutzer an, werden lokale Daten des Vorgängers vorher entfernt.

Offline: Daten liegen je Mandant lokal (Application Support, Dateischutz `completeUnlessOpen`). Neue Einträge erhalten sofort eine UUID, ausstehende Änderungen zeigt das Wolken-Symbol (Zahl = Outbox). Abmelden oder Serverwechsel löscht lokale Daten (mit Warnung bei ausstehenden Änderungen). PDF und Verlauf benötigen eine Verbindung.
Bedienung: Fahrzeug nach rechts wischen oder lange drücken → direkt tanken; Übersicht mit Schnellerfassung (Tanken, km-Stand, Wartung); Plausibilitätswarnungen beim Tanken; Fälligkeiten als Badges und lokale Erinnerungen (14 Tage vorher, am Stichtag). Mandantenwechsel über das Menü oben links (bei mehreren Mandanten); Lesezugriff wird angezeigt und blendet Erfassen aus. Screenshots: `docs/screenshots/`, Reviews: `docs/REVIEW.md`, `docs/REVIEW-FABLE.md`.

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
| GET | `/api/t/{mandant}/audit/verify[?full=1]` | Kette + Abgleich Datenstand + signierte Anker prüfen (inkrementell; `full=1` vollständig) |
| GET | `/api/t/{mandant}/audit/anchors` | Signierte Anker zur externen Archivierung |

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
- `hash = SHA256(prev_hash + kanonisches JSON)` je Mandant → Ändern, Löschen, Einfügen oder Umordnen bricht die Kette
- **Abgleich Datenstand**: jeder Datensatz muss exakt seiner letzten Revision entsprechen – direkte DB-Änderungen an Fachtabellen werden erkannt
- **Signierte Anker** (Ed25519, Schlüssel ausserhalb der DB): erkennen auch ein vollständiges Neuberechnen der Kette; externe Ablage der Anker schützt zusätzlich gegen Löschen
- **DB-Rollen**: API läuft als `fahrzeugbuch_app` (kein Owner/Superuser): kann Trigger nicht deaktivieren, Journal/Anker nicht ändern, nichts löschen. Trigger sperren `UPDATE/DELETE/TRUNCATE` auf `revisions` und `anchors`
- `/audit/verify` und jedes PDF zeigen: Kette, Datenstand, Anker; PDF enthält Kettenkopf und letzten signierten Anker
- **Inkrementelle Prüfung** (Tabelle `verify_checkpoints`, Alembic 0004): je Mandant gilt der zuletzt bestätigte Stand (Seq + Kettenkopf, mit `ANCHOR_SIGNING_KEY` Ed25519-signiert) für alle Worker. PDFs und `/audit/verify` prüfen nur neue Revisionen (Kette), seither geänderte Datensätze, die Anzahl Datensätze je Typ und neue Anker. Vollprüfung mit `?full=1`, ohne gültigen Prüfstand und sobald die letzte älter als `VERIFY_FULL_INTERVAL_S` (24 h) ist. Das PDF nennt Zeitpunkt/Stand der letzten Vollprüfung und den inkrementellen Bereich. Bis zur nächsten Vollprüfung unentdeckt bleiben direkte DB-Änderungen an bereits bestätigten Revisionen (ohne Neuberechnen der Kette) und an seither unveränderten Datensätzen – Empfehlung: täglich `GET /audit/verify?full=1` (z. B. n8n) zusätzlich zur Anker-Archivierung
- Grenzen: Wer Owner-Passwort **und** Signaturschlüssel besitzt, kann weiterhin manipulieren – erkennbar nur über extern archivierte Anker/PDFs. Keine zertifizierte GeBüV-/GoBD-Lösung.

## Verbrauchsberechnung

Voll-zu-voll: Liter aller Tankvorgänge nach einer Volltankung bis inkl. der nächsten Volltankung ÷ gefahrene km dazwischen. Teilbetankungen werden mitgezählt, ergeben aber keinen eigenen Wert. Die erste Volltankung ist der Startpunkt.

## Entwicklung

```bash
cd server
pip install --require-hashes --no-deps -r requirements.txt && pip install -r requirements-test.txt   # Lock-Datei mit Hashes
ruff check app tests alembic
pytest -q                                  # SQLite, JWTs mit lokalem Testschlüssel
FZB_TEST_DATABASE_URL=postgresql+psycopg://u:p@localhost/db pytest -q   # PostgreSQL (Trigger, Locks)
OIDC_ISSUER=https://id.j-mb.net/realms/<realm> OIDC_CLIENT_ID=fahrzeugbuch-ios uvicorn app.main:app --reload
```

CI (`.github/workflows/fahrzeugbuch.yml`, liegt im Repo-Root unter `.github/` – beim Umzug mitnehmen und Pfade `fahrzeugbuch/` anpassen): Tests gegen SQLite + PostgreSQL, Docker-Build, iOS-Simulator-Build.
