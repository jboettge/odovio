# Review Fahrzeugbuch (Fable) – Sicherheit, Code/Effizienz, UX

Stand: 25.11.2026 · Commit `3311f81` · unabhängiges Review, nur lesend.
Grundlage: Code-Lektüre Server + iOS, 18 Screenshots, Server-Experimente gegen die App (SQLite, Test-Helfer aus `tests/conftest.py`; Skripte `exp1.py`–`exp3.py` im selben Ordner). Server-Tests: 152 grün, 3 übersprungen.
Legende: **[V]** im Experiment verifiziert · **[C]** aus Code belegt · **[A]** Annahme. Aufwand: S < ½ Tag, M 1–3 Tage, L > 3 Tage.

Nicht geprüft: PostgreSQL-Verhalten (Rollen, Sperren – kein PG verfügbar), iOS-Laufzeit (kein Xcode; alle iOS-Befunde sind Code-Pfade), echte OSRM/Photon/vLLM-Dienste.

## Kurzurteil

| Bereich | Urteil | Kurz |
|---|---|---|
| Sicherheit | gut, mit Lücken beim Datenschutz und beim Monatsabschluss | AuthN/AuthZ, Mandantentrennung, SSRF-, Pfad-, Upload- und Injection-Schutz tragen; die früheren Fixes halten. Offen: Leserolle sieht Privatfahrten über `/changes`, Privatmodus und Wohnort-Schutz sind nur clientseitig, der Monatsabschluss ist nachträglich veränderbar. |
| Effizienz / Code | befriedigend | Server sauber und gut getestet. iOS: ein funktionaler Fehler im Monatsabschluss, Voll-Persistenz bei jeder Änderung, teure Sortierung in View-Bodies, praktisch keine Tests ausser dem Scan-Parser. |
| UX | befriedigend | Erfassung und Review sind durchdacht. Schwach: irreversibler Monatsabschluss ohne Rückfrage, vergessene/automatische Fahrten ohne Mitteilung, geschätzte km-Stände wirken wie abgelesene, überladene Navigation, Kontrast. |

Kein kritischer Befund (kein Zugriff ohne Anmeldung, kein Mandantenausbruch gefunden).

---

## 1. Sicherheit

### Hoch

**S1 – Leserolle umgeht die Privat-Maskierung über `/changes` und `/history`** [V]
`server/app/main.py:239-242, 450-460`, `sync.py:235-242`, Maskierung nur in `logbook.py:52-53`
PDF und CSV maskieren Privatfahrten für die Leserolle (Treuhand). `/changes` und `/history/trip/{id}` liefern derselben Rolle alles im Klartext.
Szenario: Token mit `/fahrzeugbuch/firma/lesen` → `GET /changes` liefert `purpose: "Arzt Dr. Muster"`, `start_label: "Praxis Onkologie"`, auch für `private_mode`-Fahrten. Die App nutzt genau diesen Endpoint, die Daten liegen also auf jedem Lese-Gerät.
Fix: Maskierung zentral in `entity_out`/History für Rolle `read` (Labels, Orts-IDs, Zweck, Kunde, Notiz, Vorschlagsfelder; private Orte). Test ergänzen. Aufwand M.

**S2 – Wohnadresse gelangt entgegen der Zusage auf den Server und in Logs** [C]
`ios/…/Trips/TripCoordinator.swift:489-498`, `GeoClient.swift:97-104`, `server/app/intel.py:243-250`, `server/Dockerfile:21`
README: „Wohnort-Koordinaten nie auf dem Server“. Tatsächlich:
- Reverse-Geocoding läuft als `GET /api/geo/reverse?lat=…&lon=…`. uvicorn loggt Zugriffe mit Query-String (kein `--no-access-log`), der Reverse Proxy ebenfalls.
- Solange kein Ort „Wohnort“ angelegt ist (erste Fahrten), wird der Startpunkt zu Hause als Strassenadresse aufgelöst und als `start_label` im unveränderlichen Journal gespeichert – nicht mehr löschbar.
- `/api/geo/match` erhält den ganzen reduzierten Track inkl. Start/Ziel zu Hause (nicht gespeichert, aber übertragen).
Auswirkung: Bei geteilten Mandanten (Firma) sehen andere Schreiber/Leser die Wohnadresse; der Betreiber hat sie in Logs.
Fix: Reverse als POST; Access-Log aus oder Query filtern; Track-Enden im Wohnort-Radius bzw. die ersten/letzten ~200 m kappen; Wohnort vor der ersten Aufzeichnung abfragen; README präzisieren. Aufwand M.

**S3 – Monatsabschluss ist nachträglich veränderbar bzw. zu früh möglich** [V]
`sync.py:106-122`, `trips.py:170-228`, `logbook.py:31-49`, `main.py:301-322`
- a) Storno gesperrter Fahrten ohne Begründung (`sync.py:109-110`). README verlangt eine Begründung. Die Summen im `trip_period` bleiben danach stehen (im Test: 3 Fahrten/50 km trotz Storno).
- b) PDF/CSV lösen Orts- und Kundennamen live auf. Umbenennen nach dem Abschluss ändert den Bericht des abgeschlossenen Monats, ohne Eintrag im Fahrten-Änderungsprotokoll.
- c) Abschluss gelingt mit geschäftlichen Fahrten ohne Zweck, ohne km-Stand und ohne Endzeit (`_mismatches` blockiert nicht).
- d) Der laufende Monat ist abschliessbar (`main.py:307` sperrt nur künftige). Spätere Fahrten brauchen dann eine Notiz und sind sofort gesperrt.
- e) Tank-/km-Stände im abgeschlossenen Monat bleiben frei änderbar → der Odometer-Abgleich im Bericht ändert sich. [C]
- f) Ein storniertes Fahrzeug liefert für alle Berichte 404 – auch für abgeschlossene Monate.
- g) Monatszuordnung über `start_at[:7]` mit frei wählbarem Offset: `2026-11-01T12:30+14:00` zählt als November, obwohl in MEZ noch Oktober. Niedrig.
Fix: Storno in abgeschlossenen Monaten nur mit `reason` (Feld in der Op); Namen beim Abschluss in die Fahrt bzw. den Period-Snapshot schreiben; Abschluss blockieren bei Mismatches (oder nur mit `force` + Begründung) und für den laufenden Monat; Berichte für stornierte Fahrzeuge erlauben. Aufwand M.

### Mittel

**S4 – Privatmodus und Wohnort-Regel werden serverseitig nicht durchgesetzt** [V]
`sync.py:106-128`, `schemas.py:160-188`
`private_mode: true` mit `start_label: "Geheimadresse 5"`, Zweck und Orts-IDs wird unverändert gespeichert und journalisiert. Die Wohnort-Sperre greift nur bei `kind == "home"`; „Zuhause“ als `other` mit Koordinaten wird angenommen.
Auswirkung: Ein Client-Fehler oder Fremdclient (`OIDC_ALLOWED_AZP`) schreibt private Orte dauerhaft ins Journal.
Fix: Im Trip-Hook bei `private_mode` Orts-IDs, Zweck, Kunde und `track_hash` ablehnen oder leeren, Labels auf kurze Gemeinde begrenzen. Aufwand S.

**S5 – Integritätsprüfung: Fehlalarm bei parallelem Sync, Mandantensperre während PDF-Erzeugung** [C, Fehlalarm simuliert V]
`main.py:180-184, 463-466`, `audit.py:72-88`, `integrity.py:127-131`
- `verify_all` läuft in mehreren Abfragen ohne konsistenten Snapshot. Committet ein Sync dazwischen, meldet die Prüfung „Kettenende stimmt nicht … (Revisionen entfernt?)“ – im PDF steht dann „Integrität: FEHLER“. Mit veraltetem Mandantenstand reproduziert.
- `_anchored_tenant` nimmt `FOR UPDATE` und committet nur, wenn ein neuer Anker entsteht. Sonst bleibt die Sperre bis zum Ende des PDF-Aufbaus → alle Syncs des Mandanten warten (gemessen: Fahrtenbuch über 10 Jahre mit 4000 Fahrten = 6.5 s).
Fix: Prüfung in einer `REPEATABLE READ`-Transaktion, Mandantenstand im selben Snapshot lesen; Sperre vor dem Rendern freigeben. Aufwand S–M.

**S6 – Teure Endpoints ohne Rate-Limit, Prüfaufwand wächst mit der gesamten Historie** [V gemessen]
`integrity.py:81-99`, `report.py:121-123`, `main.py:193-200`
Jedes PDF und `/audit/verify` rechnet die ganze Kette und gleicht alle Fachzeilen ab: 0.5 s bei 8000 Revisionen (SQLite), linear. `/changes?since=0` lieferte 4.6 MB. Zeitraum bis 3700 Tage erlaubt. Jeder Benutzer mit Leserolle kann das beliebig oft auslösen; der Rate-Limiter gilt nur für Geo/LLM/Scan.
Fix: vorhandenen `RateLimiter` auf PDF/verify/changes anwenden; inkrementell ab letztem geprüftem Anker prüfen; Fahrtenbuch-Zeitraum auf ≤ 366 Tage begrenzen. Aufwand M.

**S7 – Hängender Geo-/LLM-Dienst kann die API blockieren** [C]
`intel.py:95-100, 220-250, 278`, `geo.py:466-474`
Synchrone Handler im Threadpool (40 Threads). 300 Geo-Anfragen/min je Benutzer × 5 s Timeout (Match bis 15 s) belegen bei hängendem OSRM dauerhaft 25+ Threads; Leserecht in irgendeinem Mandanten genügt. Limiter je Prozess. Bei `/scan` greift das Limit erst nach dem Parsen von 2.8 MB.
Fix: Semaphore je Upstream (z. B. 4), Geo-Limit auf ~30/min, kurzer Circuit-Breaker. Aufwand S.

**S8 – iOS: Issuer-Pin führt nach Serverwechsel in eine Sackgasse; Token wird nicht widerrufen** [C]
`ios/…/Views/SettingsView.swift:121-127`, `AuthManager.swift:142-151, 205-208`
Serverwechsel ruft `clearSession()`; der Pin (`pinnedIssuer`) bleibt. Hat der neue Server einen anderen Issuer, scheitert jede Anmeldung mit „Anmeldeserver hat sich geändert … bitte abmelden“ – Abmelden ist aber nur angemeldet erreichbar. Gleiches nach Sitzungsablauf plus Realm-Umzug. Ausweg nur Neuinstallation. Zudem bleibt das Offline-Token bei Keycloak gültig (kein `/revoke`).
Fix: Beim Serverwechsel `logout()` (mit Revoke) statt `clearSession()`; im Login „Anmeldeserver zurücksetzen“ mit Warnung. Aufwand S.

**S9 – iOS: API-Antworten können im URL-Cache liegen bleiben** [A für Umfang, C für fehlendes Löschen]
`APIClient.swift:88`, `GeoClient.swift:148`, `AppSettings.swift:122-132`, `main.py:440-446`
Alle Aufrufe über `URLSession.shared` mit Standard-`URLCache`. Belege kommen mit `ETag` und `Cache-Control: private, max-age=0` (cachebar), JSON ohne Cache-Header. `resetLocalData()` leert den Cache nicht → Daten von Benutzer A können nach Abmelden/Benutzerwechsel in `Caches/…/Cache.db` verbleiben.
Fix: eigene Session mit `.ephemeral` bzw. `urlCache = nil`; Server `Cache-Control: no-store` für `/api/*`. Aufwand S.

**S10 – Abhängigkeiten rund zwei Jahre alt, nichts gepinnt** [C, Range-Verhalten V]
`server/requirements.txt`, `Dockerfile:1`, `docker-compose.yml:35, 133`
fastapi 0.115.6 zieht starlette 0.41.3. Für dessen `FileResponse`-Range-Verarbeitung ist eine DoS-Schwachstelle bekannt (CVE-2025-62727, behoben in 0.49.1 – ID bitte gegenprüfen). Gemessen am Beleg-Endpoint: Range-Header mit 8000 Bereichen = 2.2 s CPU und 765 KB Antwort. `cryptography` nur transitiv, keine Hashes, Basis-Images und `photon:latest` ohne Digest, Actions per Tag.
Fix: aktualisieren, `pip-compile --generate-hashes`, Renovate/Dependabot, Digests. Aufwand S–M.

### Niedrig

| ID | Datei:Zeile | Befund | Fix | Aufw. | St. |
|---|---|---|---|---|---|
| S11 | `TripCoordinator.swift:611-622` | LLM-Kontext `recent` enthält Fahrten der Kategorie „privat“ (ohne Privatmodus) mit Labels und Zweck – README: „nie Privatfahrten“ | Kategorie privat ausfiltern | S | C |
| S12 | `TenantStore.swift:882-887` | Mandanten-JSON (alle Daten inkl. Wohnort-Koordinaten) landet im iCloud-/Finder-Backup; Tracks und Belege sind ausgeschlossen | bewusst entscheiden, sonst `isExcludedFromBackup` | S | C |
| S13 | `AppSettings.swift:135-145`, `DueNotifications.swift:18-21`, `Helpers.swift:107-113` | Nach Abmelden bleiben CSV-Exporte (Cleanup nur `*.pdf`) und geplante Mitteilungen mit Fahrzeug-/Wartungsnamen; Exporte ohne expliziten Dateischutz | alle `Fahrzeugbuch_*` löschen, Mitteilungen entfernen, `.completeFileProtection` | S | C |
| S14 | `trips.py:235-243` | Webhook ohne Signatur/Secret, folgt Weiterleitungen, loggt die URL (ggf. mit Token) | HMAC-Header, `_NoRedirect`-Opener, URL nicht loggen | S | C |
| S15 | `schemas.py:162-163, 178` | `driver_sub`, `driver_name`, `source` kommen vom Client → Fahrer im Fahrtenbuch fälschbar | Fahrer serverseitig aus dem Token setzen | S | C |
| S16 | `integrity.py:114-116` | Kein Schlüsselwechsel: nach neuem `ANCHOR_SIGNING_KEY` gelten alle alten Anker als Problem, `ok` dauerhaft false | Liste alter Public Keys zur Verifikation | S | C |
| S17 | `main.py:393-429` | Kein Speicherkontingent für Belege (8 MiB je Beleg, beliebig viele); Inhalt wird nicht gegen den MIME-Typ geprüft | Kontingent je Mandant, Magic-Bytes | S | C |
| S18 | `ios/project.yml:30-31` | `NSAllowsLocalNetworking` ist überflüssig, seit die App HTTPS erzwingt; README nennt noch HTTP im LAN | entfernen, README anpassen | S | C |
| S19 | `TenantStore.swift:121-126` | Heruntergeladener Beleg wird bei abweichender SHA-256 trotzdem angezeigt | verwerfen und Hinweis | S | C |
| S20 | `sync.py:158-164` | Wiederverwendete `op_id` mit anderem Inhalt/Objekt → stilles `duplicate` | Entity/ID der Revision vergleichen, sonst `rejected` | S | V |

### Geprüft und unauffällig

- Jeder `/api/*`-Endpoint verlangt ein Token; Schreibrolle für Sync, Abschluss, Beleg-Upload, Scan, Suggest. Mandantenprüfung überall, auch bei Eltern-Referenzen aller neuen Entities; fremde Belege → 404.
- SSRF: Upstream-URLs nur aus der Umgebung, Schema-Prüfung, keine Weiterleitungen, kein Proxy, Antwortgrösse begrenzt.
- Upload: Pfad nur aus Mandanten-ID und UUID, atomar, nie überschrieben, Grösse/Prüfsumme/MIME gegen Metadaten, `nosniff` + CSP.
- Body-Limit vor Auth und im Stream; `NaN`/`inf`, einzelnes Surrogat [V], Emoji/„Š“ im PDF [V], CSV-Formeln (`=+-@`) abgefangen.
- JWT: Algorithmen-Liste, `iss`, `exp/iat/sub`, `typ`, `azp`; JWKS-Cache mit Refetch-Limit.
- iOS: PKCE S256 + `state`, ephemere Web-Sitzung, Keychain `ThisDeviceOnly`, Tracks mit Schutzklasse `complete` und ohne Backup, Benutzerwechsel löscht lokale Daten, Demo nur in Debug.
- Kein Zertifikats-Pinning – für selbst gehostete Server mit öffentlichem Zertifikat vertretbar.

---

## 2. Effizienz / Code

### Hoch

**E1 – iOS: Monatsabschluss meldet nach Erfolg einen Fehler (falsches Antwortformat)** [C]
`ios/…/Views/TripCloseViews.swift:518-520` gegen `server/app/trips.py:225-228`
Der Server antwortet `{"period": {…}, "locked_trips": …}`. Die App dekodiert die Antwort direkt als `TripPeriod`; `vehicle_id` fehlt auf oberster Ebene → `DecodingError` → Meldung „Abschluss nur online möglich: …“. Der Monat ist serverseitig aber abgeschlossen; der folgende Sync entfällt, ein zweiter Versuch ergibt 409.
Fix: Wrapper-Struct `{period, lockedTrips, gaps, forced, cursor}` dekodieren; Unit-Test mit echter Server-Antwort. Aufwand S.

**E2 – iOS: gesamter Mandant wird bei jeder Änderung neu kodiert und geschrieben (Main-Thread)** [C]
`TenantStore.swift:561-565, 841-854`
Jede Mutation ruft `persist()` (vollständiges JSON, atomar) und startet einen Sync-Task. Eine Wartung mit 10 Checkpunkten = 11+ Vollschreibungen; „alle Arbeitswege bestätigen“ = N. Bei einigen MB (6000 Fahrten ≈ 4.6 MB Nutzdaten) ruckelt jede Eingabe.
Fix: kurzfristig `persist()` bündeln (Debounce ~300 ms, Kodieren ausserhalb des Main-Actors, Batch-API für Mehrfachänderungen); mittelfristig SQLite/GRDB. Aufwand M (L für DB).

**E3 – iOS: Fahrtenliste sortiert bei jedem Render dreimal mit Datums-Parsing im Vergleich** [C]
`Models.swift:540`, `TenantStore.swift:193-241`, `Views/TripViews.swift:62-64, 246-252`, `Views/OverviewView.swift:10-12`
`startDate` parst den ISO-String bei jedem Zugriff; `chronological` tut das zweimal je Vergleich. `TripsListView.body` ruft `trips`, `reviewTrips` und `gaps` (je filtern + sortieren) und liest `coordinator.liveDistanceKm` – während einer Aufzeichnung wird also bei jedem 10-m-Schritt alles neu sortiert. Bei 1500 Fahrten rund 100 000 Parse-Vorgänge je Render.
Fix: Datum einmal beim Dekodieren ablegen; abgeleitete Listen je Fahrzeug cachen; Aufzeichnungsbanner als eigene View. Aufwand M.

### Mittel

| ID | Datei:Zeile | Befund / Auswirkung | Fix | Aufw. | St. |
|---|---|---|---|---|---|
| E4 | `TenantStore.swift:856-858` | Scheitert das Laden (defekte Datei, neues Pflichtfeld), startet der Store leer; das nächste `persist()` überschreibt Datei samt Outbox → unsynchronisierte Einträge still verloren | Datei als `.corrupt` sichern, Hinweis, Snapshot-Version, Test | S | C |
| E5 | `TenantStore.swift:612-626`, `Helpers.swift:276-289` | Abgelehnte Ops verschwinden nach dem Vollabgleich; nur ein flüchtiger Alert auf der Fahrzeugliste. Server-Grenzen (Notiz 2000, Namen, Begründung im abgeschlossenen Monat) werden in Formularen nicht geprüft | Liste „Abgelehnt“ mit Bearbeiten/Erneut senden; Grenzen spiegeln | M | C |
| E6 | `sync.py:235-242`, `TenantStore.swift:634-675` | `/changes` ohne Paging (4.6 MB bei 6000 Fahrten [V]); jede einzelne Ablehnung löst einen Vollabgleich ab 0 aus | `limit` + `has_more`; bei Ablehnung nur betroffene Objekte holen | M | V/C |
| E7 | `sync.py:226-231` | Jeder `SQLAlchemyError` wird zu `rejected` – auch vorübergehende (Verbindungsabbruch, Serialisierung). Die App verwirft die Op endgültig | nur Integrity-/DataError ablehnen, sonst Batch mit 503 abbrechen | S | C |
| E8 | `models.py:32-35, 275-278`, `migrate.py:32-53` | Keine zusammengesetzten Indizes: `(tenant_id, last_seq)` für 14 Pull-Abfragen, `(tenant_id, entity, entity_id)` für Verlauf, `(vehicle_id, start_at)` für Fahrten. Kein Migrationswerkzeug: Pflichtspalten, Indizes, Constraints lassen sich nicht nachrüsten | Indizes ergänzen, Alembic einführen | M | C |
| E9 | `main.py:256-263`, `stats.py:42-63` | N+1: `list_vehicles` lädt je Fahrzeug die gesamte Historie (5 Abfragen) nur für den km-Stand; `load_vehicle` lädt auch für Monatscheck/Abschluss alles | `MAX(km)` aggregiert; Zeitraumfilter | S | C |
| E10 | `integrity.py:83-86`, `audit.py:74` | Prüfung lädt alle Revisionen zweimal als ORM-Objekte in den Speicher | letzte Revision je Objekt per SQL, `yield_per`, inkrementell (siehe S6) | M | C |
| E11 | `stats.py` ↔ `Stats.swift`, `trips.py` ↔ `TenantStore.swift:232-242`, `tax.py` ↔ `Models.swift:1113`, `GeoClient.swift:132-155` ↔ `APIClient.swift:72-99` | Doppelte Fachlogik Server/App (Verbrauch, Lücken, Review-Status, Jahresbericht) und doppelter Request-Code; drei ISO-Formatter | gemeinsame JSON-Testvektoren in beiden Suiten; GeoClient auf `rawResponse` | M | C |
| E12 | `ios/Tests/` | iOS-Tests nur für den Scan-Parser (18). Nichts zu Store/Sync/Merge, Dekodierung der Server-Antworten (E1), Regeln, Ortslernen, Statistik, Track-Aufbewahrung. Server: es fehlen Tests zu S1, S3a, S5. CI ohne Linter | Store hinter Protokoll testen; ruff/SwiftLint in CI | M | C |

### Niedrig

| ID | Datei:Zeile | Befund | Fix | St. |
|---|---|---|---|---|
| E13 | `TenantStore.swift:393` | `isPending` durchsucht die Outbox linear, je Zeile und je gemergtem Objekt | `Set` der IDs | C |
| E14 | `VehicleListView.swift:103, 113` | `stats(for:)` je Zeile plus `dueSignature` im Body (alle Fahrzeuge filtern/sortieren) – heute unkritisch | memoisieren | C |
| E15 | `TripCoordinator.swift:338-351` | Checkpoint schreibt alle 30 s den gesamten Track neu (quadratisch über lange Fahrten) | anhängendes Log | C |
| E16 | `TenantStore.swift:596-610` | Push-Batch (200 Ops) wird bei 413 nicht geteilt → Outbox hängt | bei 413 halbieren | C |
| E17 | `SettingsView.swift:207-209` | Integritätsanzeige meldet „Kette gebrochen ab Seq 0“, auch wenn nur Datenstand/Anker abweichen | `problems` anzeigen | C |
| E18 | `attachments.py:59-75` | Kalter Hash-Cache (Neustart): erstes PDF liest alle Belege des Mandanten | Hash mit Fingerprint persistieren oder Hintergrundprüfung | C |

---

## 3. UX

### Hoch

**U1 – Monatsabschluss: irreversibel, aber ohne Rückfrage und mit roter Checkliste auslösbar** [C, Screenshot `month-close`]
`TripCloseViews.swift:371-373, 440-449`
„Monat abschliessen“ löst sofort aus. Der Knopf ist aktiv, obwohl die Checkliste offene Punkte zeigt; der laufende Monat ist wählbar (nur Fusszeile als Hinweis). Dazu kommt die falsche Fehlermeldung aus E1.
Fix: Bestätigungsdialog mit Zusammenfassung (Fahrten, km je Kategorie, Lücken); Knopf erst bei erfüllter Checkliste; laufenden Monat sperren. Aufwand S.

**U2 – Vergessene und automatisch erkannte Fahrten bleiben unbemerkt** [C]
`TripDetector.swift:111-122`, `TripCoordinator.swift:410-413`; Mitteilungen nur in `DueNotifications.swift`
Die Stopp-Erkennung gilt nur für automatisch gestartete Fahrten. Eine per Knopf oder Kurzbefehl gestartete Fahrt läuft weiter, bis jemand stoppt (GPS, Akku, unbrauchbare Fahrt). Für erkannte Fahrten und offene Bestätigungen gibt es keine Mitteilung.
Fix: Bei 10 min Stillstand „Fahrt beenden?“ als Mitteilung; nach Auto-Fahrt „18 km erkannt – Geschäftlich / Privat“ mit Aktionen; wöchentliche Erinnerung an offene Bestätigungen; evtl. Live Activity. Aufwand M.

**U3 – Geschätzte km-Stände sehen aus wie abgelesene** [C, Screenshot `trip-review`]
`TripCoordinator.swift:458-463, 539-545`, `TripReviewView` (Karte, `confirm`)
Aufgezeichnete Fahrten erhalten km-Beginn = letzter Stand und km-Ende = Beginn + GPS-Distanz. Die Review-Karte zeigt „53'312 km → 53'340 km“ ohne Kennzeichnung; „OK“ oder eine Auto-Bestätigungsregel übernimmt das. Die km-Kette ist damit immer lückenlos, die Abweichung zum Tacho fällt erst im Monatsabgleich auf. Das widerspricht „Tacho massgebend“.
Fix: Schätzwerte kennzeichnen („ca.“), Tachostand mindestens bei der letzten Fahrt des Tages oder beim Tanken abfragen, Abweichung im Review zeigen. Aufwand M.

### Mittel

| ID | Datei / Screen | Befund | Vorschlag | Aufw. | St. |
|---|---|---|---|---|---|
| U4 | `VehicleDetailView.swift:7-31`, `TripViews.swift:105-125`; `trips`, `overview` | 5 Segmente auf 390 pt (Schrift sehr klein, „km“ unklar, skaliert kaum mit Dynamic Type). Im Bereich Fahrten drei Symbole; „Teilen“ exportiert das Fahrzeug-PDF, nicht das Fahrtenbuch. Kernfunktionen (Bestätigen, Lücken, Monatsabschluss, Berichte) im „…“-Menü mit 8 Einträgen; Stammdaten doppelt (Menü und Einstellungen) | km-Stände in die Übersicht (4 Segmente) oder Tab-Leiste; Teilen kontextabhängig; Stammdaten nur an einem Ort | M | C/A |
| U5 | `TripViews.swift` (TripRow), `Helpers.swift:321-336`; `trips`, `fuel` | Kontrast: orange Kleinschrift auf Weiss für Vorschläge/Warnungen (≈ 2:1), `StatusTag` in `caption2` farbig auf 15 %-Tönung; Status nur über Farbe + „?“; Zeilen mit `lineLimit(1)` schneiden bei grosser Schrift ab | dunklere Warnfarbe (≥ 4.5:1), mindestens `footnote`, `ViewThatFits`, Test mit AX-Schriftgrössen und VoiceOver | S–M | C/A |
| U6 | `Helpers.swift:204-225`, `FuelViews.swift` (prefill) | Kein Formular hat `interactiveDismissDisabled` → Wischen verwirft Eingaben. Der km-Stand ist mit dem letzten Wert vorbelegt und wird ohne Warnung unverändert gespeichert | Schutz bei geänderten Feldern; Warnung „km-Stand unverändert“ bzw. Vorbelegung als Platzhalter | S | C |
| U7 | `APIClient.swift:3-13`, `TripReviewView` (`requestSuggestion`), `ReportView.swift:116` | Fehlerzustände: roher Servertext im Alert („Serverfehler 502: <html>…“); „Vorschlag holen“ ohne Rückmeldung bei Fehler; „PDF nur online verfügbar“ auch bei 403/500; abgelehnte Änderungen siehe E5 | Fehler auf verständliche Texte abbilden, Inline-Rückmeldung | S | C |
| U8 | `SettingsView.swift:152-178`, `DueNotifications.swift:21-24`, `TripCoordinator.swift:177-199` | Berechtigungen: ein Knopf fragt Standort → Immer → Bewegung → Kalender nacheinander ab, ohne Erklärung und ohne Statusanzeige; Mitteilungen werden unvermittelt beim Öffnen der Liste angefragt; der Automatik-Schalter fragt nicht selbst | Einrichtung in Schritten mit Zweck und Status je Berechtigung; Kalender erst bei Nutzung | M | C |
| U9 | alle Screens | Begriffe uneinheitlich: Kilometerstand / km-Stand / km / Tacho; Tanken / Tankvorgang; Regeln / Zweckregeln; Bestätigen / Review; „privat“ in vier Bedeutungen (Kategorie, Privatmodus, Halter, privater Ort). Fachjargon für Endnutzer: Mandant, Keycloak, OIDC, Issuer, Client-ID. Login nennt fest „j-mb.net-Konto“ | Glossar festlegen; Technik in „Details“ | S | C |
| U10 | `VehicleListView.swift:37-70` | Tanken: Schnellzugriff nur über versteckte Geste (Wischen/Langdruck) mit Hinweistext; Home-Screen-Aktion und App-Intent „Tanken erfassen“ weiterhin offen | sichtbarer Tanken-Knopf in der Zeile, Quick Action, Intent | S | C |
| U11 | `TripReviewView` (`confirm`) | Geschäftliche Fahrt lässt sich ohne Zweck/Kunde bestätigen; der Mangel erscheint erst im Monatscheck | Inline-Hinweis oder Pflicht | S | C |

### Niedrig

- U12 Fahrten- und Tankliste ohne Suche, Filter oder Monatssprung. [C]
- U13 Einstellungen sind der erste Bildschirm (URL eintippen); QR-Code oder Link zur Einrichtung wäre freundlicher. [C]
- U14 Gut gelöst: Review Karte für Karte mit Sammelbestätigung, Lückenansicht mit zwei klaren Aktionen, Plausibilitätswarnungen beim Tanken, Leerzustände, Dark Mode, Storno-Dialoge, rund 96 Accessibility-Annotationen.

---

## Top 10 zuerst umsetzen

1. **E1** Antwort des Monatsabschlusses korrekt dekodieren (S) – Hauptpfad heute fehlerhaft.
2. **S1** Privat-Maskierung für die Leserolle in `/changes` und `/history` (M).
3. **S3 + U1** Monatsabschluss härten: Storno mit Begründung, Namen einfrieren, Mismatches und laufenden Monat blockieren, Rückfrage in der App (M).
4. **S2** Wohnadresse schützen: Reverse per POST, Access-Log, Track-Enden kappen, Wohnort zuerst erfassen (M).
5. **S4** Privatmodus serverseitig durchsetzen (S).
6. **S5** Integritätsprüfung im konsistenten Snapshot, Sperre vor dem PDF freigeben (S–M).
7. **E2 + E3** `persist()` bündeln, Datum cachen, Aufzeichnungsbanner entkoppeln (M).
8. **E4 + E5 + E7** Kein stiller Datenverlust: Ladefehler sichern, abgelehnte Ops sichtbar halten, vorübergehende DB-Fehler nicht ablehnen (M).
9. **U2 + U3** Mitteilungen für vergessene/erkannte Fahrten; geschätzte km kennzeichnen (M).
10. **S8 + S9 + S10** Issuer-Pin-Sackgasse beheben, URL-Cache abschalten, Abhängigkeiten aktualisieren und pinnen (S–M).

Danach: S6/S7 (Rate-Limits, Upstream-Semaphore), E8 (Indizes, Alembic), E12 (iOS-Tests), U4/U5 (Navigation, Kontrast).


---

## Umsetzungsstand (25.11.2026)

Alle Befunde umgesetzt (Server: Commit `acc24f3`, iOS: `2c23f28` + `0bb9132`). CI grün: Server SQLite/PostgreSQL (203/206 Tests), ruff, Lock-Datei mit Hashes, Docker-Build, iOS-Build + 63 Unit-Tests.

| Bereich | Befunde | Status |
|---|---|---|
| Sicherheit Server | S1, S2 (Server), S3a–g, S4, S5, S6, S7, S9, S10, S14–S17, S20 | ✅ |
| Sicherheit iOS | S2 (Client), S8, S9, S11, S12, S13, S18, S19 | ✅ |
| Effizienz/Code | E1–E18 | ✅ (E2: gebündelte Persistenz statt SQLite/GRDB – bei Bedarf später) |
| UX | U1–U13 | ✅ |

Offen/zu beobachten:
- Nur auf echtem iPhone prüfbar: Hintergrund-Aufzeichnung, Mitteilungs-Aktionen, Quick Actions/Intents, QR-Live-Scan, Dynamic Type in AX-Grössen.
- Reverse Proxy: Query-Strings nicht loggen; GET `/api/geo/reverse` im nächsten Release entfernen.
- Inkrementelle Integritätsprüfung: Manipulation an bereits bestätigten alten Revisionen erkennt die Vollprüfung (`?full=1`, automatisch alle 24 h).
- CVE-Nummer der Starlette-Range-Schwachstelle nicht gegengeprüft (Verhalten gemessen behoben).
- Dependabot/Renovate noch nicht eingerichtet.
