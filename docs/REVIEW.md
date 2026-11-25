# Review Fahrzeugbuch – Design, UX, Sicherheit

Stand: 25.11.2026 · Grundlage: Screenshots `docs/screenshots/` (iPhone 16 Pro, iOS 18.5, de-CH, Demo-Daten), Code-Review, Security-Review mit Experimenten.
Legende: **[V]** verifiziert (ausprobiert) · **[C]** aus Code belegt · **[A]** Annahme

## Gesamturteil

| Bereich | Note | Kurz |
|---|---|---|
| Design | gut | Native iOS-Optik, Dark Mode sauber, CH-Formate korrekt (53'410 km, CHF, Datum). Einige Farb-/Ikonografie-Fehler. |
| UX | befriedigend | Alle Funktionen erreichbar, aber Hauptanwendungsfall „an der Tankstelle erfassen“ braucht 4 Taps; Fälligkeiten und Rollen zu versteckt. |
| Sicherheit | befriedigend | Auth, PKCE, Mandantentrennung solide. 1 hoher Befund (Revisionssicherheit deckt Fachtabellen nicht ab), mehrere DoS-/Robustheitslücken. |

---

## 1. Design

| # | Befund | Screen | Prio | Fix |
|---|---|---|---|---|
| D1 | Checklisten-Punkte erscheinen in Akzentblau, erledigte blau durchgestrichen – wirken wie Links | maintenance-detail | Hoch | `.buttonStyle(.plain)` bzw. `.tint(.primary)` am Button, erledigt = `.secondary` |
| D2 | Mandanten-Slug als Large Title („privat“, klein geschrieben) | list | Mittel | Titel „Fahrzeuge“, Mandant als Untertitel/Menü-Label mit Anzeigename |
| D3 | Icons ohne Bedeutung: Gebäude (Mandant), `doc.richtext` (PDF) | list, Detail | Mittel | Mandant als Text-Menü im Titel; PDF als `square.and.arrow.up` / Menü „Exportieren“ |
| D4 | Ausstehend-Badge (kleine orange Wolke) kaum sichtbar | fuel | Niedrig | Grösser, oder Zeilen-Hintergrund/Untertitel „nicht synchronisiert“ |
| D5 | Diagramm: X-Achse abgeschnitten („N…“), keine Einheit am Punkt | overview | Niedrig | `.chartXAxis { AxisMarks(values: .stride(by: .month, count: 2)) }`, Durchschnittslinie (`RuleMark`) |
| D6 | Kein App-Icon (AssetCatalog fehlt) | – | Mittel | `Assets.xcassets/AppIcon` ergänzen |
| D7 | Formularfelder ohne Einheit (`53410` statt `53'410 km`), kein Tausendertrenner beim Tippen | fuel-form | Niedrig | Suffix-Label „km“, „l“, „CHF“ rechts vom Feld |
| D8 | Dark Mode: Kontraste ok; Chart-Linie/Punkte ok | dark-* | – | – |

## 2. UX

| # | Befund | Prio | Vorschlag |
|---|---|---|---|
| U1 | **Tanken erfassen = 4 Taps** (Fahrzeug → Tanken → + → Formular). Häufigster Anwendungsfall, oft mit kalten Händen an der Säule | Hoch | Schnellaktion: „Tanken“-Button direkt in Fahrzeugzeile (Swipe leading/Kontextmenü), Home-Screen-Quick-Action, App-Intent/Siri-Kurzbefehl, zuletzt genutztes Fahrzeug merken |
| U2 | Formular: Reihenfolge Datum/km/Liter/Betrag; Säule zeigt Betrag + Liter, km steht im Cockpit. „Sichern“ bleibt grau ohne Hinweis, was fehlt | Mittel | Fokus direkt auf „Liter“, km vorbelegt (ist so), Inline-Validierung (z. B. „km kleiner als letzter Stand 53'410“) |
| U3 | Fälligkeiten nur in Übersicht; in „Wartung“ fehlt die Überfällig-Markierung (MFK überfällig, Liste zeigt nichts) | Mittel | Badge „überfällig“ in Wartungsliste + Fahrzeugliste; lokale Benachrichtigung bei Fälligkeit (km/Datum) |
| U4 | Plausibilitätsprüfung fehlt: km-Stand rückläufig, Verbrauch > 30 l/100 km, Literpreis > 5 CHF | Mittel | Warnung (nicht Blockade) im Formular |
| U5 | „km-Stand“-Tab zeigt nur manuelle Einträge, obwohl Tank-/Wartungs-km zählen | Niedrig | Zeitachse aller km-Quellen (Typ-Icon) |
| U6 | Leserolle nur an fehlendem „+“ erkennbar | Niedrig | Hinweisleiste „Nur Lesezugriff“ |
| U7 | Login-Button „Mit Keycloak anmelden“ – Fachbegriff | Niedrig | „Anmelden“ + Hostname darunter |
| U8 | Einstellungen als Sheet mit „Sichern“ oben rechts, obwohl nur die URL gespeichert wird | Niedrig | URL-Änderung separat bestätigen, Sheet mit „Fertig“ |
| U9 | PDF: nur freie Datumsauswahl | Niedrig | Presets „Dieses Jahr“, „Vorjahr“, „Letzte 12 Monate“ |
| U10 | Barrierefreiheit: Icon-Buttons ohne `accessibilityLabel` (Zahnrad, Gebäude, Wolke, +, PDF) | Mittel | Labels ergänzen; VoiceOver-Test |
| U11 | Gut: Offline-Hinweis im PDF-Export, Storno-Dialog erklärt Revisionssicherheit, Empty States, Vorbelegung km | – | – |

## 3. Sicherheit

Server-Tests grün (25). Experimente: Security-Review-Agent + eigene Nachprüfung von S2/S4.

### Hoch

**S1 – Revisionsschutz deckt die angezeigten Daten nicht ab** [V]
`audit.py` `verify_chain` prüft nur `revisions`; PDF/Statistik lesen `fuel_entries` usw. `UPDATE fuel_entries SET price_total=9999` → `/audit/verify` ok, PDF „Integrität: OK“ mit falschem Betrag. Zudem ist der App-DB-User Postgres-Superuser (`POSTGRES_USER`) und Tabellen-Owner → kann Trigger deaktivieren und Kette neu rechnen; `INSERT` auf `revisions` ungesperrt.
Fix: (a) Verify gleicht letzten Revisionsstand je Objekt mit Fachtabellen ab (oder Report direkt aus Revisionen), (b) eigene DB-Rolle ohne Owner/Superuser (nur SELECT/INSERT auf `revisions`, DML auf Fachtabellen), Schema durch Migrationsrolle, (c) Kettenkopf extern verankern (signierter Zeitstempel/RFC 3161 oder periodische Signatur mit Schlüssel ausserhalb der DB, z. B. Ablage in Paperless-ngx).

### Mittel

| # | Befund | Fix |
|---|---|---|
| S2 | **`Infinity`/`1e309` in Liter/Betrag** wird angenommen [V] → `/stats` 500, `/changes` liefert `null` → iOS-Decode scheitert → **Pull für alle Geräte des Mandanten dauerhaft kaputt** | `model_config = ConfigDict(allow_inf_nan=False)` + Obergrenzen (`le=`) für km, Liter, Beträge |
| S3 | Body wird vor Auth geparst, kein Grössenlimit, `note` ohne `max_length`, Port 8085 umgeht Proxy [V] → Speicher-DoS anonym möglich | Body-Limit im Proxy + Middleware, `max_length` überall |
| S4 | **PDF 500** bei Fahrzeugname mit Nicht-Latin-1 („Škoda“) [V] im `Content-Disposition`; sehr lange Notiz/Checkliste → `LayoutError` [V] | `filename*=UTF-8''…` + ASCII-Fallback; Notizen begrenzen, `LayoutError` abfangen |
| S5 | iOS: nach Sitzungsablauf meldet sich Benutzer B an → sieht lokale Daten von A, A’s Outbox wird unter B’s Identität revisionssicher gebucht [C] | `sub` mit lokalen Daten speichern, bei Wechsel `resetLocalData()` (Outbox vorher anzeigen); nach Login immer `loadTenants()` |
| S6 | Klartext-Pfad: `8085` auf allen Interfaces, `--forwarded-allow-ips "*"`, `NSAllowsLocalNetworking`; App übernimmt Issuer/Token-Endpoint ungeprüft vom API-Server → MITM im LAN kann Offline-Refresh-Token abgreifen (public Client) [C/A] | Port an 127.0.0.1/Proxy-Netz binden, Proxy-IP statt `*`; App: https erzwingen (Release), Issuer pinnen, Discovery validieren (issuer gleich, Endpoints https + gleicher Host) |
| S7 | Unbekannte `kid` → JWKS-Abruf bei jedem Request (30 s Timeout), anonym auslösbar, 503 mit internen Details [V] | Refetch-Rate-Limit (60 s), kurzer Timeout, unbekannte `kid` → 401, generische Meldungen |

### Niedrig

- **S8** ID-Token wird als Access-Token akzeptiert; bei gesetztem `OIDC_AUDIENCE` entfällt `azp`-Prüfung → `typ == "Bearer"` und `azp`-Allowlist.
- **S9** `OIDC_REQUIRED_ROLE` greift auch bei gleichnamiger Rolle anderer Clients → nur Realm-Rolle oder `resource_access[client_id]`.
- **S10** Ganzzahl-Überlauf (km, position) → 500 für ganzen Batch, iOS-Outbox hängt → `le=`, DB-Fehler je Op als `rejected`.
- **S11** Doppelte `op_id`: Version ohne Mandantenprüfung zurückgegeben; Fehlermeldung verrät Existenz fremder UUID (erfordert bekannte UUID).
- **S12** iOS: Keychain `AfterFirstUnlock` ohne `ThisDeviceOnly` (Token wandert in Backups); Dateischutz Klasse C; PDFs in `tmp` nach Logout nicht gelöscht.
- **S13** Logout ohne `end_session`, Safari-SSO-Cookie bleibt → auf geteilten Geräten Login ohne Passwort → `prefersEphemeralWebBrowserSession` oder End-Session.
- **S14** Container: kein `read_only`, `cap_drop`, `no-new-privileges`, Ressourcenlimits; Images ohne Digest; `/docs` öffentlich; `DEFAULT_TENANT` + leere Pflichtrolle = jeder Realm-User schreibt.
- **S15** Screenshot-Workflow hat `contents: write` (nur Nicht-`main`-Branches) – nach Umzug ins neue Repo prüfen/auf `workflow_dispatch` beschränken.

### Geprüft und unauffällig

JWT: Algorithmus-Allowlist (kein `none`/HS), `iss` exakt, `exp/iat/sub` Pflicht, kein `jku`/`x5u`. Mandantentrennung in allen Endpoints inkl. `history`, `report`, `changes` und Eltern-Referenzen im Sync. Hash-Kette: Kanonisierung und Sperren korrekt, Nebenläufigkeit getestet. Keine SQL-Injection (ORM), reportlab-Markup escaped. iOS: PKCE S256 + `state` korrekt, Callback via ASWebAuthenticationSession nicht durch fremdes URL-Schema kaperbar. Demo-Modus nur in `DEBUG`.

---

## Empfohlene Reihenfolge

1. **S2, S4, S10** – Robustheit (ein Eintrag darf nie den Mandanten lahmlegen) · klein
2. **S1** – Verify gegen Fachtabellen + DB-Rollen · mittel
3. **S5, S6, S12, S13** – iOS-Sitzung/Transport · mittel
4. **D1, U1, U3, U10** – sichtbare UX-Verbesserungen · klein–mittel
5. **S3, S7, S14** – Betriebshärtung (Proxy-Limits, Compose) · klein
6. Rest nach Bedarf
