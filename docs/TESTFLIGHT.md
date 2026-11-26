# TestFlight – odovio (iOS)

## Ablauf

- Workflow: `.github/workflows/ios-testflight.yml`
- Start: Tag `ios-vX.Y.Z` pushen (Version = Tag) **oder** Actions → *ios-testflight* → *Run workflow* (optional Eingabe «version»).
- Schritte: Secrets prüfen → Xcode 26 → Zertifikat in temporären Schlüsselbund, App-Store-Profil installieren → `xcodegen generate` → Archive (Release, **manuell** signiert mit Apple Distribution) → IPA direkt aus dem Archiv → Signaturprüfung → Upload per `xcrun altool` (API-Key).
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

## Checkliste Nutzer

- [x] Gerät registriert (für Tests auf dem iPhone; für TestFlight nicht mehr nötig).
- [x] API-Key (Rolle Admin) als Secrets.
- [ ] **Distribution-Zertifikat + App-Store-Profil** erstellen und als Secrets hinterlegen (Abschnitt unten). Jährlich erneuern.
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
