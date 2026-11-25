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
| `/verwaltung/mitglieder` | Mitglieder einladen, Rolle ändern, entfernen | Verwalten |
| `/konto` | Name, Fahrzeugbücher/Rollen, Begriffe, Abmelden | angemeldet |

Rollen: `admin` (Verwalten) ⊇ `write` (Bearbeiten) ⊇ `read` (Lesen). Router-Guards prüfen die Mindestrolle; nicht erlaubte
Seiten erscheinen nicht in der Navigation (direkter Aufruf → «Kein Zugriff»). Deep-Links funktionieren auch vor dem
Login (Rücksprung über den OIDC-`state`), optional mit Fahrzeugbuch: `/verwaltung/mitglieder?buch=privat`,
`/stammdaten/steuerparameter?buch=privat`.

Schreibaktionen laufen über `POST /api/t/{t}/sync` (eine Op je Aktion, Feldgrenzen wie die Server-Schemas, ganzes
Objekt wird gesendet), danach wird inkrementell ab Cursor neu geladen. Stornos in abgeschlossenen Monaten verlangen
eine Begründung (≥ 10 Zeichen).

## Entwicklung

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
`{"tokenTtl":30}`), `POST /__mock/expire-tokens`. Umgebungsvariablen: `MOCK_TOKEN_TTL`, `MOCK_PAGE_MAX`.

## Build, Tests

```bash
npm ci && npm run lint && npm run typecheck && npm test && npm run build && npm run e2e
npm run audit         # npm audit --omit=dev --audit-level=high
npm run screenshots   # screenshots/*.png (hell + dunkel, 1440×900) – nach npm run build
npm run preview       # dist/ über den Mock (http://127.0.0.1:4319)
```

- `npm test`: vitest (Rollen-Gating, Formatierung, API-Client inkl. 401-Refresh/429/409-Detail, Maskierung,
  Feldvalidierung, Fahrtenbuch-Logik, Sicherheits-Helfer, Idle-Timeout, Komponententest Fahrtentabelle).
- `npm run e2e`: Playwright gegen `mock/server.mjs --static dist` (Login mit PKCE, Deep-Links, Rollen, Monatsabschluss,
  Stammdaten-Sync, Mitglieder, 401-Refresh, 429, Downloads, Belege). Jeder Test schlägt fehl, wenn die Konsole einen
  CSP-Verstoss oder einen Seitenfehler meldet.

`npm run build` erzeugt `dist/` mit Basis `/` (keine Inline-Skripte/-Styles, kein `eval`, Assets mit Hash unter
`/assets/`). Laufzeit-Konfiguration ausschliesslich über `GET /auth/config`. Build-Variable (optional):
`VITE_IDLE_TIMEOUT_MIN` (Abmeldung nach Inaktivität, Standard 30).

## Auslieferung durch den Server

- `dist/` statisch unter `/`; SPA-Fallback auf `index.html` für alle Nicht-API-Pfade **ohne Dateiendung**
  (inkl. `/auth/callback`), nicht für `/api/*`, `/auth/config`, `/health`, `/docs`. `index.html` mit
  `Cache-Control: no-cache`, `/assets/*` mit `public, max-age=31536000, immutable`.
- Header für die SPA:
  `Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' blob: data:; connect-src 'self' <issuer-origin>; frame-ancestors 'none'; base-uri 'self'; form-action 'self'; object-src 'none'`,
  `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`.
- `GET /auth/config` → `{issuer, client_id, scopes, web_client_id}`; das Frontend verwendet `web_client_id`
  (Fallback `client_id`) und fordert selbst nur `openid profile` an (kein `offline_access`).

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
