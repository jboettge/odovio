# TestFlight – odovio (iOS)

## Ablauf

- Workflow: `.github/workflows/ios-testflight.yml`
- Start: Tag `ios-vX.Y.Z` pushen (Version = Tag) **oder** Actions → *ios-testflight* → *Run workflow* (optional Eingabe «version»).
- Schritte: Secrets prüfen → Xcode 26 → XcodeGen (gepinntes Release-Zip, Version + SHA-256) + `xcodegen generate` → **erst dann** API-Key ablegen, Zertifikat in temporären Schlüsselbund, App-Store-Profil installieren → Archive (Release, **manuell** signiert mit Apple Distribution) → IPA direkt aus dem Archiv → Signaturprüfung → Upload per `xcrun altool` (API-Key).
- Härtung (Review 27.11.2026, X11): Job im Environment `testflight` (Freigabe, s. unten); Checkout mit `persist-credentials: false`; XcodeGen nicht per `brew` (ungepinnt), sondern `xcodegen.zip` von GitHub-Release `2.46.0` (Tag-Commit `8445e778451c7e44237b90281bde622d764b0084`) mit geprüfter SHA-256 – und vor dem Import der Schlüssel ausgeführt; `security import` nur mit `-T /usr/bin/codesign` (ohne `-T /usr/bin/security`, sonst könnte jeder Prozess des Runners den privaten Schlüssel per `security export` auslesen). XcodeGen-Update: Version und SHA-256 im Workflow anpassen (`shasum -a 256 xcodegen.zip`, Release mindestens zwei Wochen alt).
- Build-Nummer: `run_number*10 + run_attempt`. Version: aus dem Tag (`ios-v1.0.0` → 1.0.0); Rückfall `MARKETING_VERSION` in `ios/project.yml`.
- Nach dem Upload ist der Build nach 5–30 min in App Store Connect → TestFlight sichtbar.

## Eingerichtet (25.11.2026)

| Punkt | Stand |
|---|---|
| Bundle-ID | `ch.odovio` (App in App Store Connect angelegt) |
| Team-ID | `Q66V4Q95B4` (`project.yml`, Secret `TEAM_ID`) |
| Secrets | `ASC_ISSUER_ID`, `ASC_KEY_ID`, `ASC_PRIVATE_KEY` (base64), `TEAM_ID`, `DIST_CERT_P12` (base64), `DIST_CERT_PASSWORD`, `ASC_PROFILE` (base64) |
| Capabilities (App ID) | keine nötig. Background Mode `location` ist Info.plist, Mitteilungen nur lokal (kein Push) |
| Anzeigename | `odovio` |
| Privacy-Manifest | `ios/Fahrzeugbuch/PrivacyInfo.xcprivacy`: kein Tracking; erhoben (verknüpft, App-Funktion): genauer Standort, Fotos, Nutzerinhalte, User-ID, Name, E-Mail; UserDefaults (CA92.1), Datei-Zeitstempel (C617.1) |
| Export-Compliance | `ITSAppUsesNonExemptEncryption = NO` (nur HTTPS/CryptoKit) |
| App-Icon | 1024×1024 RGB ohne Alpha ✔ |

## Signierung: eigenes Zertifikat statt Cloud-Signing

**Warum:** Beim Export (`xcodebuild -exportArchive`, auch bei Cloud-Signing) erzwingt Xcode die Designated Requirement
`certificate leaf[subject.CN] = "Apple Distribution: Jakob-Matthias Böttger (Q66V4Q95B4)"`. Der Abgleich mit dem
Umlaut im Zertifikatsnamen schlägt fehl (`codesign`: «does not satisfy its designated Requirement») → Upload
«Invalid Signature» (90035). Der Workflow signiert deshalb beim Archivieren selbst (Standard-Requirement über die
Team-ID, ohne Namen) und packt die IPA direkt aus dem Archiv.

**Einmalig erstellen** (jährlich wiederholen; ohne Mac möglich, z. B. auf der Docker-VM):

1. Schlüssel + CSR erzeugen:
   ```bash
   openssl genrsa -out odovio-dist.key 2048
   openssl req -new -key odovio-dist.key -out odovio-dist.csr -subj "/emailAddress=<deine Apple-ID>/CN=odovio Distribution/C=CH"
   ```
2. developer.apple.com → Certificates → «+» → **Apple Distribution** → `odovio-dist.csr` hochladen → `distribution.cer` laden.
3. `.p12` bauen (Format, das der macOS-Schlüsselbund importiert):
   ```bash
   openssl x509 -inform DER -in distribution.cer -out odovio-dist.pem
   openssl pkcs12 -export -legacy -inkey odovio-dist.key -in odovio-dist.pem -out odovio-dist.p12 -name "odovio Distribution"
   ```
   (Passwort vergeben → Secret `DIST_CERT_PASSWORD`; OpenSSL < 3: ohne `-legacy`.)
4. developer.apple.com → Profiles → «+» → **App Store Connect** → App ID `ch.odovio` → das neue Zertifikat → Name z. B. «odovio App Store» → `.mobileprovision` laden.
5. Secrets setzen:
   ```bash
   base64 -w0 odovio-dist.p12            # → DIST_CERT_P12
   base64 -w0 odovio_App_Store.mobileprovision   # → ASC_PROFILE
   ```
   (macOS: `base64 -i <datei>`.) Danach `odovio-dist.key`/`.p12` sicher ablegen (Passwortmanager) und lokal löschen.

Mit Mac alternativ: Schlüsselbundverwaltung → Zertifikatsassistent → «Zertifikat einer Zertifizierungsinstanz anfordern» (CSR), Zertifikat laden, doppelklicken, im Schlüsselbund mit privatem Schlüssel als `.p12` exportieren.

## CarPlay (Fahrt starten/beenden, Tanken)

- Umsetzung: `ios/Fahrzeugbuch/CarPlay/CarPlaySceneDelegate.swift` – Raster mit drei Kacheln; Start/Stopp mit dem
  Standardfahrzeug (wie Siri/Kurzbefehle), «Tanken» merkt den Tankvorgang vor (Mitteilung, Formular beim nächsten
  Öffnen auf dem iPhone – CarPlay erlaubt keine Texteingabe).
- Kategorie **Driving Task** (`com.apple.developer.carplay-driving-task`). Die Berechtigung vergibt Apple auf Antrag:
  developer.apple.com/contact/carplay → App «odovio», Bundle-ID `ch.odovio`, Kategorie «Driving Task»,
  Begründung: Fahrtenbuch – Fahrt starten/beenden und Tankvorgang vormerken während der Fahrt.
- Bis zur Freischaltung: Entitlement nur in Debug (`project.yml` → `configs.Debug`), testbar im Simulator
  (Xcode → I/O → External Displays → CarPlay). TestFlight-Builds zeigen in CarPlay noch nichts.
- Nach der Freischaltung:
  1. developer.apple.com → Identifiers → `ch.odovio` → Capability «CarPlay Driving Task» aktivieren.
  2. App-Store-Profil neu erzeugen → Secret `ASC_PROFILE` ersetzen.
  3. In `ios/project.yml` `CODE_SIGN_ENTITLEMENTS` von `configs.Debug` nach `base` verschieben.

## Environment `testflight` und Tag-Schutz (in GitHub einzurichten)

Der Workflow läuft im Environment `testflight`. Solange es in GitHub nicht eingerichtet ist, legt GitHub es beim
ersten Lauf **ohne Schutz** an – die Härtung greift erst mit diesen Einstellungen:

1. Repo → *Settings* → *Environments* → `testflight` (anlegen bzw. öffnen):
   - **Required reviewers**: sich selbst (bzw. eine zweite Person) eintragen; *Prevent self-review* nur, wenn eine
     zweite Person freigibt.
   - **Deployment branches and tags** → *Selected branches and tags* → Regel **Tag** `ios-v*` (für manuelle
     Starts zusätzlich **Branch** `main`).
   - **Environment secrets**: `ASC_ISSUER_ID`, `ASC_KEY_ID`, `ASC_PRIVATE_KEY`, `TEAM_ID`, `DIST_CERT_P12`,
     `DIST_CERT_PASSWORD`, `ASC_PROFILE` hierher verschieben und die gleichnamigen **Repository-Secrets löschen**
     (sonst sind sie weiterhin jedem Workflow zugänglich).
2. Repo → *Settings* → *Rules* → *Rulesets* → *New tag ruleset*: Ziel `ios-v*`, Regeln *Restrict creations*,
   *Restrict updates*, *Restrict deletions*; Bypass nur für Repository-Admins. So kann niemand sonst einen
   Release-Tag setzen oder umhängen.
3. Danach einen Lauf starten: der Job wartet auf «Review deployments» → freigeben.

## Checkliste Nutzer

- [x] Gerät registriert (für Tests auf dem iPhone; für TestFlight nicht mehr nötig).
- [x] API-Key (Rolle Admin) als Secrets.
- [ ] **Distribution-Zertifikat + App-Store-Profil** erstellen und als Secrets hinterlegen (Abschnitt unten). Jährlich erneuern.
- [ ] Environment `testflight` (Required Reviewers, nur Tag `ios-v*`/`main`, Environment-Secrets) und Tag-Ruleset `ios-v*` einrichten (Abschnitt oben).
- [ ] Ersten Lauf starten und Ergebnis prüfen.
- [ ] App Store Connect → App → **App-Datenschutz** ausfüllen, passend zum Manifest: Genauer Standort, Fotos oder Videos, Sonstige Nutzerinhalte, Benutzer-ID, Name, E-Mail-Adresse – jeweils «mit Identität verknüpft», «nicht für Tracking», Zweck «App-Funktionalität». Datenschutzerklärung-URL (z. B. https://www.odovio.ch/datenschutz) nötig.
- [ ] TestFlight → **Testinformationen**: Beta-Beschreibung, Feedback-E-Mail, Kontakt.
- [ ] Interne Tester (Team-Mitglieder) hinzufügen → sofort verfügbar.
- [ ] Externe Tester: Beta-App-Review nötig. Prüfer können den Modus «Nur auf diesem iPhone» ohne Login nutzen → in den Review-Notizen erwähnen, sonst Demo-Zugang für einen Server angeben.
- [ ] Echte Geräte-Tests (Hintergrund-Aufzeichnung, Automatik, Kurzbefehle, Akku, Kamera-Scan).

## Entscheide (25.11.2026)

1. Anzeigename `odovio` ✔
2. Identity Provider: Keycloak bleibt. Redirect `ch.odovio:/oauth2redirect` im Client `fahrzeugbuch-ios` eintragen (`keycloak/setup-client.sh` erneut ausführen oder manuell). Mitgliederverwaltung nur im Web.
3. Entwickler-Server unter https://www.odovio.ch → Daten gelten als erhoben (Manifest + App-Datenschutz) ✔
4. Version aus Tag `ios-vX.Y.Z` ✔
