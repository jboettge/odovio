# TestFlight – odovio (iOS)

## Ablauf

- Workflow: `.github/workflows/ios-testflight.yml`
- Start: Tag `ios-vX.Y.Z` pushen (Version = Tag) **oder** Actions → *ios-testflight* → *Run workflow* (optional Eingabe «version»).
- Schritte: Secrets prüfen → Xcode 26 → `xcodegen generate` → Archive (Release, automatische Signierung über API-Key) → Export + Upload (`ExportOptions.plist`, `destination=upload`).
- Build-Nummer: `run_number*10 + run_attempt`. Version: aus dem Tag (`ios-v1.0.0` → 1.0.0); Rückfall `MARKETING_VERSION` in `ios/project.yml`.
- Nach dem Upload ist der Build nach 5–30 min in App Store Connect → TestFlight sichtbar.

## Eingerichtet (25.11.2026)

| Punkt | Stand |
|---|---|
| Bundle-ID | `ch.odovio` (App in App Store Connect angelegt) |
| Team-ID | `Q66V4Q95B4` (`project.yml`, `ExportOptions.plist`, Secret `TEAM_ID`) |
| Secrets | `ASC_ISSUER_ID`, `ASC_KEY_ID`, `ASC_PRIVATE_KEY` (base64), `TEAM_ID` |
| Capabilities (App ID) | keine nötig. Background Mode `location` ist Info.plist, Mitteilungen nur lokal (kein Push) |
| Anzeigename | `odovio` |
| Privacy-Manifest | `ios/Fahrzeugbuch/PrivacyInfo.xcprivacy`: kein Tracking; erhoben (verknüpft, App-Funktion): genauer Standort, Fotos, Nutzerinhalte, User-ID, Name, E-Mail; UserDefaults (CA92.1), Datei-Zeitstempel (C617.1) |
| Export-Compliance | `ITSAppUsesNonExemptEncryption = NO` (nur HTTPS/CryptoKit) |
| App-Icon | 1024×1024 RGB ohne Alpha ✔ |

## Checkliste Nutzer

- [ ] **API-Key-Rolle**: Cloud-Signing (Xcode erzeugt Distribution-Zertifikat/Profil selbst) braucht einen Team-Key mit Rolle **Admin**. Schlägt der Archive-/Export-Schritt mit «No signing certificate» / «not allowed to create certificates» fehl → Key mit Rolle Admin neu erzeugen und Secrets ersetzen.
- [ ] Ersten Lauf starten und Ergebnis prüfen (erster Build mit Xcode 26 – bisher nur mit Xcode 16 getestet).
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
