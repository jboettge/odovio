# TestFlight – odovio (iOS)

## Ablauf

- Workflow: `.github/workflows/ios-testflight.yml`
- Start: Actions → *ios-testflight* → *Run workflow* (Branch wählen) **oder** Tag `ios-vX.Y.Z` pushen.
- Schritte: Secrets prüfen → Xcode 26 → `xcodegen generate` → Archive (Release, automatische Signierung über API-Key) → Export + Upload (`ExportOptions.plist`, `destination=upload`).
- Build-Nummer: `run_number*10 + run_attempt`. Version: `MARKETING_VERSION` in `ios/project.yml` (vor Release erhöhen).
- Nach dem Upload ist der Build nach 5–30 min in App Store Connect → TestFlight sichtbar.

## Eingerichtet (25.11.2026)

| Punkt | Stand |
|---|---|
| Bundle-ID | `ch.odovio` (App in App Store Connect angelegt) |
| Team-ID | `Q66V4Q95B4` (`project.yml`, `ExportOptions.plist`, Secret `TEAM_ID`) |
| Secrets | `ASC_ISSUER_ID`, `ASC_KEY_ID`, `ASC_PRIVATE_KEY` (base64), `TEAM_ID` |
| Capabilities (App ID) | keine nötig. Background Mode `location` ist Info.plist, Mitteilungen nur lokal (kein Push) |
| Privacy-Manifest | `ios/Fahrzeugbuch/PrivacyInfo.xcprivacy`: kein Tracking, UserDefaults (CA92.1), Datei-Zeitstempel (C617.1) |
| Export-Compliance | `ITSAppUsesNonExemptEncryption = NO` (nur HTTPS/CryptoKit) |
| App-Icon | 1024×1024 RGB ohne Alpha ✔ |

## Checkliste Nutzer

- [ ] **API-Key-Rolle**: Cloud-Signing (Xcode erzeugt Distribution-Zertifikat/Profil selbst) braucht einen Team-Key mit Rolle **Admin**. Schlägt der Archive-/Export-Schritt mit «No signing certificate» / «not allowed to create certificates» fehl → Key mit Rolle Admin neu erzeugen und Secrets ersetzen.
- [ ] Ersten Lauf starten und Ergebnis prüfen (erster Build mit Xcode 26 – bisher nur mit Xcode 16 getestet).
- [ ] App Store Connect → App → **App-Datenschutz** ausfüllen (siehe Entscheid 3).
- [ ] TestFlight → **Testinformationen**: Beta-Beschreibung, Feedback-E-Mail, Kontakt.
- [ ] Interne Tester (Team-Mitglieder) hinzufügen → sofort verfügbar.
- [ ] Externe Tester: Beta-App-Review nötig. Prüfer können den Modus «Nur auf diesem iPhone» ohne Login nutzen → in den Review-Notizen erwähnen, sonst Demo-Zugang für einen Server angeben.
- [ ] Echte Geräte-Tests (Hintergrund-Aufzeichnung, Automatik, Kurzbefehle, Akku, Kamera-Scan).

## Offene Entscheide

1. **Anzeigename** unter dem Icon: aktuell `Fahrzeugbuch` (`CFBundleDisplayName`) – auf `odovio` ändern?
2. **Identity Provider**: Code/Doku setzen Keycloak voraus (`keycloak/setup-client.sh`); im Betrieb läuft Authentik? Redirect-URI `ch.odovio:/oauth2redirect` muss beim IdP-Client `fahrzeugbuch-ios` (PKCE, public) eingetragen sein.
3. **Datenerhebung**: Wird ein vom Entwickler betriebener Server (z. B. `fahrzeugbuch.j-mb.net`) Dritten angeboten? Dann gelten Standort, Fotos, Nutzerinhalte als «erhoben» → `NSPrivacyCollectedDataTypes` und App-Datenschutz-Angaben ergänzen. Nur Self-Hosting durch Nutzer → «Keine Daten erhoben» möglich.
4. **Versionierung**: `MARKETING_VERSION` manuell in `project.yml` pflegen oder aus Tag `ios-vX.Y.Z` ableiten?
