# Fahrzeugbuch – Web-Frontend

Vue 3 + TypeScript + Vite + vue-router, Anmeldung über Keycloak mit `oidc-client-ts` (Authorization Code + PKCE S256).
Keine UI-Bibliothek, keine externen Ressourcen (alles gebündelt), eigenes CSS mit Hell/Dunkel (`prefers-color-scheme`),
Deutsch (Schweizer Schreibweise, `53’410 km`, `CHF 1’234.50`, `25.11.2026`).

## Seiten und Rollen

| Pfad | Inhalt | Mindestrolle |
|---|---|---|
| `/` | Anmelden, Fahrzeugbuch wählen (Rolle sichtbar) | – |
| `/uebersicht` | Fahrzeug-Kacheln (km, Ø Verbrauch, Kosten, Fälligkeiten), offene Bestätigungen/Lücken, letzte Aktivität | Lesen |
| `/fahrzeuge/:id` (+ `/fahrten`, `/tanken`, `/wartungen`, `/kilometerstaende`, `/berichte`) | Kennzahlen, Diagramme, Tabellen, Belege, Berichte/Downloads, Jahresbericht | Lesen |
| `/fahrzeuge/:id/monatsabschluss` | Prüfung + Abschluss mit Bestätigung | Bearbeiten |
| `/aktivitaet` | Feed mit Filter und Nachladen, Verlauf je Eintrag (Seitenpanel) | Lesen |
| `/integritaet` | Prüfung, Ergebnis, Anker, Grenzen | Lesen |
| `/stammdaten/{fahrzeuge,orte,kunden,regeln,steuerparameter,material}` | ansehen (Lesen) bzw. erfassen/bearbeiten/stornieren (Bearbeiten) | Lesen |
| `/verwaltung/mitglieder` | Mitglieder einladen, Rolle ändern (Auswahl → «Übernehmen»; eigene Herabstufung/Entfernung mit zusätzlicher Bestätigung, eigene Zeile «(du)»), entfernen | Verwalten |
| `/konto` | Name, Fahrzeugbücher/Rollen, Begriffe, Abmelden | angemeldet |

Rollen: `admin` (Verwalten) ⊇ `write` (Bearbeiten) ⊇ `read` (Lesen). Router-Guards prüfen die Mindestrolle; nicht erlaubte
Seiten erscheinen nicht in der Navigation (direkter Aufruf → «Kein Zugriff»). Deep-Links funktionieren auch vor dem
Login (Rücksprung über den OIDC-`state`), optional mit Fahrzeugbuch: `/verwaltung/mitglieder?buch=privat`,
`/stammdaten/steuerparameter?buch=privat`.

Schreibaktionen laufen über `POST /api/t/{t}/sync` (eine Op je Aktion, Feldgrenzen wie die Server-Schemas, ganzes
Objekt wird gesendet), danach wird inkrementell ab Cursor neu geladen. Stornos in abgeschlossenen Monaten verlangen
eine Begründung (≥ 10 Zeichen). Der Editor legt `id` (Neuanlage) und `op_id` beim Öffnen fest: ein erneutes «Speichern»
nach einem Verbindungsfehler sendet dieselbe Op (Server dedupliziert über `op_id`, keine Doppelanlage); nach Erfolg oder
geändertem Inhalt gibt es eine neue `op_id`. Der Fahrzeugbuch-Wechsler wechselt per Maus/Touch sofort, per Tastatur erst
mit Enter bzw. «Wechseln» (Pfeiltasten wählen nur vor). Fehler-Toasts schliessen sich nicht automatisch.

## Entwicklung

Voraussetzung: Node.js 24 (`engines.node` `>=24`), npm 11. Werkzeuge: Vite 8 (Rolldown), Vitest 5, TypeScript 6,
vue-tsc 3, ESLint 10 (Flat Config), Playwright 1.65 (Chromium-Revision 1255).

```bash
npm ci
npm run mock          # Mock-API + Mock-Keycloak auf http://127.0.0.1:8787
npm run dev           # Vite auf http://localhost:5173 (Proxy /api, /auth/config, /oidc → Mock)
```

Gegen einen echten Server: `FZB_API=https://fahrzeugbuch.example.ch npm run dev` (der Keycloak-Client braucht dann
zusätzlich `http://localhost:5173/auth/callback` als Redirect und `http://localhost:5173` als Web Origin).

### Mock (`mock/`)

`mock/server.mjs` (nur Node, keine Abhängigkeiten) bildet ab: OIDC-Issuer `…/oidc/realms/demo` (Discovery, Code + PKCE,
Refresh, Revoke, end_session), alle verwendeten API-Endpunkte mit Rollen, Maskierung der Privatfahrten für die
Leserolle, Hash-Kette/Verlauf, Monatsabschluss inkl. 409/422, Mitglieder inkl. 409 (letzter Verwalter) und
«Verwaltung nur im Webfrontend» (Mitglieder-Mutationen und `tax_param`-Ops nur mit `azp=fahrzeugbuch-web`).
Mit `--static dist` liefert er die gebaute SPA mit denselben Sicherheits-Headern (CSP) aus wie in Produktion.

Demo-Benutzer (Auswahl auf der Mock-Anmeldeseite):

| Benutzer | Fahrzeugbücher |
|---|---|
| `jakob` Jakob Muster | privat: admin, muster-ag: admin |
| `anna` Anna Beispiel | privat: write |
| `treuhand` Treuhand Keller | privat: read, muster-ag: read |
| `lea` Lea Fischer | muster-ag: write |
| `neu` Nora Neu | – (zum Einladen) |

Teststeuerung: `POST /__mock/reset`, `POST /__mock/config` (`{"members501":true}`, `{"rate429":"verify"}`,
`{"tokenTtl":30}`, `{"dropResponseOnce":true}` = nächsten Sync anwenden, Antwort aber abbrechen), `POST /__mock/expire-tokens`.
Mitglieds-IDs entsprechen wie beim Server der Keycloak-Benutzer-ID (`sub`). Umgebungsvariablen: `MOCK_TOKEN_TTL`, `MOCK_PAGE_MAX`, `MOCK_SEED`.
`--seed large` (bzw. `npm run mock:large`) ersetzt «privat» durch einen Lasttest-Bestand (siehe Skalierung).

## Build, Tests

```bash
npm ci && npm run lint && npm run typecheck && npm test && npm run build && npm run size && npm run e2e
npm run audit         # npm audit --omit=dev --audit-level=high
npm run size          # Bundle-Budget (gzip), keine Source-Maps, .br/.gz vollständig und verlustfrei
npm run e2e:perf      # nur der Lasttest (grosser Datenbestand)
npm run screenshots   # screenshots/*.png (hell + dunkel, 1440×900) – nach npm run build
npm run preview       # dist/ über den Mock (http://127.0.0.1:4319)
```

- `npm test`: vitest (Rollen-Gating, Formatierung, API-Client inkl. 401-Refresh/429/409-Detail, Maskierung,
  Feldvalidierung, Fahrtenbuch-Logik, Sicherheits-Helfer, Idle-Timeout, Komponententest Fahrtentabelle; Skalierung:
  Parallelitätsgrenze/Zusammenlegen/Abbruch/Retry im API-Client, Store-Indizes/Paging/Abbruch, Worker-Auswertungen
  inkl. Fallback, virtuelles Scrollen mit ARIA, Seitenwahl, Entprellung, Diagramm-Verdichtung, Beleg-Cache,
  Vorkomprimierung und Budget-Skript).
- `npm run e2e`: Playwright-Projekt `functional` gegen `mock/server.mjs --static dist` (Login mit PKCE, Deep-Links,
  Rollen, Monatsabschluss, Stammdaten-Sync inkl. verlorener Antwort, Mitglieder inkl. Übernehmen/Selbst-Herabstufung,
  Fahrzeugbuch-Wechsler per Tastatur, Reflow 390 px ohne horizontales Scrollen, 401-Refresh, 429, Downloads, Belege,
  vorkomprimierte Assets)
  und Projekt `perf` gegen `--seed large` (`tests/e2e/large-data.perf.spec.ts`). Jeder Test schlägt fehl, wenn die
  Konsole einen CSP-Verstoss oder einen Seitenfehler meldet.

`npm run build` erzeugt `dist/` mit Basis `/` (keine Inline-Skripte/-Styles, kein `eval`, keine Source-Maps, Assets mit
Hash unter `/assets/`) und danach mit `scripts/compress.mjs` die vorkomprimierten Varianten. Laufzeit-Konfiguration ausschliesslich über `GET /auth/config`. Build-Variable (optional):
`VITE_IDLE_TIMEOUT_MIN` (Abmeldung nach Inaktivität, Standard 30).

## Auslieferung durch den Server

- `dist/` statisch unter `/`; vorkomprimierte Varianten `<datei>.br`/`<datei>.gz` bei passendem `Accept-Encoding`
  ausliefern (`Content-Encoding`, `Vary: Accept-Encoding`, Content-Type der Originaldatei); SPA-Fallback auf `index.html` für alle Nicht-API-Pfade **ohne Dateiendung**
  (inkl. `/auth/callback`), nicht für `/api/*`, `/auth/config`, `/health`, `/docs`. `index.html` mit
  `Cache-Control: no-cache`, `/assets/*` mit `public, max-age=31536000, immutable`.
- Header für die SPA:
  `Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' blob: data:; connect-src 'self' <issuer-origin>; frame-ancestors 'none'; base-uri 'self'; form-action 'self'; object-src 'none'`,
  `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`.
- `GET /auth/config` → `{issuer, client_id, scopes, web_client_id}`; das Frontend verwendet `web_client_id`
  (Fallback `client_id`) und fordert selbst nur `openid profile` an (kein `offline_access`).

## Skalierung/Performance

Ausgelegt auf viele Jahre, viele Fahrzeuge und 100k+ Fahrten je Fahrzeugbuch, bei wenig Last auf dem Server.

**Bundle und Auslieferung**
- Alle Routen lazy (`() => import(…)`). Stabile Chunks (`vite.config.ts`, Rolldown `codeSplitting.groups` mit
  Prioritäten): `vendor-vue`, `vendor-router`,
  `vendor-oidc` (Hash ändert sich nur bei Updates der Abhängigkeit → bleiben über App-Releases im Browser-Cache),
  `core` (alles statisch vom Entry Erreichbare), `charts` (SVG-Diagramme, Ausdünnung), `export` (PDF/CSV/Belege,
  Beleg-Cache), `lists` (virtuelles Scrollen, Seitenwahl). `index.html` lädt nur den Startpfad; Routen-Chunks erst bei
  Bedarf. Vue ohne Options-API (`__VUE_OPTIONS_API__: false`).
- Budgets in `package.json` → `budgets` (KiB, gzip), geprüft mit `npm run size` (auch in CI): Startpfad-JS ≤ 72,
  Pfad bis Übersicht ≤ 85, CSS ≤ 8, jeder Chunk ≤ 32, Worker ≤ 8. Stand: Startpfad 65.9 KiB gzip (59.3 KiB brotli),
  bis Übersicht 77.7 KiB, CSS 5.6 KiB, grösster Chunk `vendor-vue` 24.9 KiB.
- Vorkomprimierung (Vertrag mit dem Server): `npm run build` erzeugt für jede Text-Datei in `dist/` ab 1 KiB
  (`.html .js .css .svg .json .txt …`) `<datei>.br` (Brotli Q11) und `<datei>.gz` (gzip 9). `npm run size` prüft
  Vollständigkeit und verlustfreie Dekomprimierung; der Mock liefert sie wie der Server mit `Content-Encoding`/`Vary`
  aus (direkte Anfragen auf `*.br`/`*.gz` → 404).

**Daten im Client** (`src/store/data.ts`, nur im Speicher – keine Persistenz von Fachdaten)
- `/changes` seitenweise (`has_more`, Cursor; nächste Seite wird schon angefordert, während die aktuelle verarbeitet
  wird), danach nur Deltas ab Cursor. Abbruch per `AbortController` bei Mandantenwechsel und Abmelden. Das erste Laden
  füllt einen neuen Bestand, der erst am Ende sichtbar wird (keine halben Stände, keine doppelten Folge-Anfragen).
- Normalisiert (Map je Objekttyp) mit Indizes je Fahrzeug, je Fahrzeug+Monat und je Elternobjekt (Wartungsposten,
  Belege), bei Deltas inkrementell nachgeführt. Bestand ist `markRaw` (nicht tief reaktiv); Reaktivität grob je
  Objekttyp über Zähler, abgeleitete Listen je Stand zwischengespeichert (eingefroren).
- Rechenintensives im Web Worker (`src/workers/analytics.worker.ts`, Vite `?worker`, eigene Datei): Kilometerkette,
  offene Bestätigungen, geschätzte km (Übersicht/Fahrzeug), Filter/Suche/Summen der Fahrtentabelle,
  Monatsübersicht (Monatsabschluss). Ohne Worker (Tests, Fehler) dieselbe Engine im Hauptthread.

**Grosse Listen**
- Fahrten und Tankvorgänge: virtuelles Scrollen (`src/use/virtualRows.ts`) – gleichartige Tabellenzeilen, sehr grosse
  Mengen, Seite scrollt normal (Tastatur unverändert). Nur sichtbare Zeilen + Puffer im DOM; Zeilenhöhe gemessen
  (laufender Mittelwert); Platzhalter als `<svg height>` (kein Inline-Style, CSP). Native Tabelle mit
  `aria-rowcount`/`aria-rowindex`. Unter 150 Zeilen wird alles gerendert.
- Wartungen (aufklappbare Karten), Zeitachse km-Stände, Aktivität, Stammdaten: Seitenaufteilung 50/100/200 (variable
  Zeilenhöhen, wenige hundert bis tausend Einträge). Suche entprellt (200 ms), Sortierung stabil (Tie-Breaker ID).
- Diagramme mit vielen Werten werden verdichtet (LTTB, ≈ 1 Punkt je 4 px); die Datentabelle rendert erst beim Öffnen
  und seitenweise.

**Netzwerk** (`src/api/client.ts`)
- Höchstens 4 parallele Anfragen; gleichzeitige identische GETs werden zusammengelegt; GETs einer Seite werden beim
  Routenwechsel abgebrochen (`src/api/navigation.ts`), Kennzahlen beim Mandantenwechsel.
- Wiederholung nur für GET bei 502/503/504, höchstens 2× mit Backoff `500 ms · 2^n` + Jitter (Retry-After ≤ 10 s wird
  respektiert, länger → Fehlermeldung). 429 nie automatisch (Meldung mit Retry-After). POST/PATCH/DELETE nie.
- Belege erst laden, wenn sichtbar (IntersectionObserver), `loading="lazy"`; Beleg-Cache LRU (24 Dateien / 20 MB),
  verdrängte `blob:`-URLs werden freigegeben, Cache wird beim Mandantenwechsel/Abmelden geleert.

**Messung** (`tests/e2e/large-data.perf.spec.ts`, Mock `--seed large`: 3 Fahrzeuge × 30'000 Fahrten über 13.7 Jahre,
5'000 Tankvorgänge, ~500 abgeschlossene Monate, 200 Kunden, > 96'000 Journal-Einträge)
- Budgets: Anmeldung → Übersicht vollständig < 15 s, Klick «Fahrten» → Tabelle bedienbar < 3 s, Long Tasks beim
  Scrollen und Suchen < 200 ms, < 200 `<tr>` im DOM, nie leerer Bereich beim Scrollen, Suche < 3 s, Worker aktiv.
- Gemessen (Chromium headless, Entwicklungsrechner): Übersicht 1.5–2.0 s (inkl. Laden von 96k Datensätzen in
  20 Seiten), Fahrtentabelle bedienbar ~0.1 s (vorher 10.7 s, Long Task 8.8 s, 30'001 `<tr>`), max. 48 `<tr>`,
  keine Long Tasks beim Laden und Suchen, beim Scrollen über 30k Zeilen meist keine (vereinzelt bis ~120 ms; vorher
  ein Long Task von 8.8 s beim Öffnen), Suche ~0.3 s (vorher 2.1 s, Long Task 0.9 s), JS-Heap 131 MB (vorher 703 MB).

**Grenzen**
- Alle Fachdaten des Fahrzeugbuchs liegen im Speicher des Tabs (bei 100k Fahrten ~100–150 MB); sehr grosse Mandanten
  (Millionen Datensätze) bräuchten serverseitiges Paging/Filtern statt Voll-Sync.
- Zeilenhöhe der virtuellen Tabellen ist ein Mittelwert: bei stark unterschiedlich hohen Zeilen kann der Scrollbalken
  leicht springen; fokussierte Zeilen, die weit aus dem Bild gescrollt werden, werden aus dem DOM entfernt.
- Seitenaufteilte Listen zeigen nicht alle Einträge gleichzeitig (Browser-Suche nur auf der aktuellen Seite).
- CSP: Der Worker wird über `worker-src` → `script-src 'self'` erlaubt (kein `blob:`); empfohlen ist trotzdem ein
  explizites `worker-src 'self'` in der Server-CSP.

## Keycloak-Client `fahrzeugbuch-web`

- Client type OpenID Connect, **public** (keine Client-Authentifizierung), nur *Standard Flow*
- PKCE erzwingen: *Proof Key for Code Exchange Code Challenge Method* = `S256`
- Valid redirect URIs: `https://<host>/auth/callback`
- Valid post logout redirect URIs: `https://<host>/`
- Web origins: `https://<host>` (CORS für Discovery/Token/Revoke)
- Front channel logout aus, kein Implicit/Direct Access/Service Account; Scope `offline_access` nicht zuweisen
- Gleiche Mapper wie `fahrzeugbuch-ios`: `groups` (volle Gruppenpfade im Access-Token) und die Client-/Realm-Rolle
  `fahrzeugbuch-user` (bzw. `OIDC_REQUIRED_ROLE`); der Server muss `azp=fahrzeugbuch-web` akzeptieren
  (`OIDC_ALLOWED_AZP`).
- Empfohlen: Access-Token-Lebensdauer 5 min, SSO Session Idle ≥ 30 min.

## Sicherheit

- Token nur im `sessionStorage` (oidc-client-ts User- und State-Store), nie in `localStorage`, URLs oder Logs;
  Erneuerung per Refresh-Token (`automaticSilentRenew`), kein iframe/Session-Monitor (CSP). API-Aufrufe mit
  `Authorization: Bearer`, `credentials: 'omit'` – keine Cookies (kein CSRF-Angriffsfläche).
- 401 → einmal erneuern und wiederholen, sonst neue Anmeldung mit Rücksprung; 429 zeigt `Retry-After` an, keine
  automatischen Wiederholungen; 5xx und unerwartete Fehler ohne technische Details.
- Abmelden: Refresh-Token widerrufen, `sessionStorage` leeren, Keycloak `end_session` (`id_token_hint`);
  automatische Abmeldung nach 30 min Inaktivität.
- Benutzerdaten nur über Text-Bindings (`vue/no-v-html`, kein `innerHTML`/`eval`/`new Function` – ESLint inkl.
  `eslint-plugin-security`); Links aus Daten nur `https:` oder relative Pfade, externe Links mit
  `rel="noopener noreferrer"`; Download-Dateinamen aus `Content-Disposition` werden bereinigt.
- Belege und PDFs werden mit Bearer geladen und als `blob:`-URL angezeigt/gespeichert (nie direkt verlinkt).
- Abhängigkeiten exakt gepinnt (`package-lock.json`), keine CDNs, kein Tracking. Das Lockfile wurde mit
  `npx npm@11.6.2 install` erzeugt (npm 10.9 bricht beim Auflösen von vitest 4.1 mit «edgesOut» ab);
  `npm ci` funktioniert mit npm 10 und 11.
