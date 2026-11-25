import SwiftUI

/// Begriffe der App (einheitlich in allen Ansichten verwendet).
enum Glossary {
    struct Entry: Identifiable {
        let term: String
        let text: String
        var id: String { term }
    }

    static let entries: [Entry] = [
        Entry(term: "Betriebsart",
              text: "Wie die App arbeitet: «Nur auf diesem iPhone» (lokal, ohne Konto) oder «Mit Server (gemeinsam)». "
                + "Wechsel in den Einstellungen: lokal → «Auf Server übertragen», Server → «Nur noch lokal verwenden»."),
        Entry(term: "Lokal (Nur auf diesem iPhone)",
              text: "Betriebsart ohne Server und ohne Anmeldung. Alle Daten bleiben auf dem Gerät; Berichte entstehen "
                + "auf dem iPhone. Sichern per Datensicherung (Export) und iCloud-Backup. Keine KI-Funktionen, keine "
                + "signierten Server-Anker."),
        Entry(term: "Mit Server (gemeinsam)",
              text: "Betriebsart mit Konto bei deinem Fahrzeugbuch-Server. Mehrere Personen bewirtschaften dieselben "
                + "Fahrzeuge; die App funktioniert dank lokaler Kopie auch offline."),
        Entry(term: "Fahrzeugbuch",
              text: "Gemeinsamer Datenbestand (z. B. «privat» oder eine Firma) mit Fahrzeugen, Fahrten, Tankvorgängen "
                + "und Wartungen. Du kannst Zugriff auf mehrere Fahrzeugbücher haben – lesend oder bearbeitend."),
        Entry(term: "Mitglied",
              text: "Person mit Zugriff auf ein Fahrzeugbuch (Servermodus). Die Mitgliederliste zeigt Rolle und "
                + "letzte Aktivität. Wer einen Eintrag erfasst hat, steht in der Zeile («von Anna»)."),
        Entry(term: "Rolle",
              text: "Recht eines Mitglieds: «Verwalten» (Mitglieder und Einstellungen verwalten, bearbeiten), "
                + "«Bearbeiten» (erfassen und ändern) oder «Nur lesen» (ansehen)."),
        Entry(term: "Verwalter",
              text: "Mitglied mit der Rolle «Verwalten». Lädt Personen ein, ändert Rollen und pflegt "
                + "Steuerparameter – im Webfrontend des Servers."),
        Entry(term: "Aktivität",
              text: "Verlauf, wer wann was erfasst, geändert oder storniert hat – für das ganze Fahrzeugbuch oder "
                + "ein Fahrzeug (Servermodus)."),
        Entry(term: "Webfrontend",
              text: "Weboberfläche deines Servers (im Browser unter der Server-Adresse). Dort verwalten Verwalter "
                + "Mitglieder und Rollen und pflegen die Steuerparameter; in der App sind diese nur einsehbar."),
        Entry(term: "Datensicherung",
              text: "Datei mit allen lokalen Daten inkl. Änderungsprotokoll (Lokalmodus). Exportieren, z. B. in "
                + "iCloud Drive ablegen, und bei Bedarf wieder importieren – der Import ersetzt die lokalen Daten."),
        Entry(term: "Kilometerstand",
              text: "Gesamtkilometer laut Tacho des Fahrzeugs. Er ist für Fahrtenbuch und Verbrauch massgebend; "
                + "GPS- und Routendistanz dienen nur der Kontrolle."),
        Entry(term: "ca. / geschätzt",
              text: "Aus der GPS-Distanz berechneter Kilometerstand einer aufgezeichneten Fahrt. Bitte beim "
                + "Bestätigen den Tacho ablesen und eintragen – sonst ist der Monatsabschluss nicht möglich."),
        Entry(term: "Kilometerkette / Lücke",
              text: "Der Kilometerstand am Ende einer Fahrt muss dem Beginn der nächsten entsprechen. "
                + "Fehlende Kilometer sind eine Lücke und werden als Fahrt erfasst oder korrigiert."),
        Entry(term: "Tankvorgang",
              text: "Eine Betankung mit Kilometerstand, Liter und Betrag. Der Verbrauch wird von Volltankung zu "
                + "Volltankung berechnet; Teilbetankungen entsprechend markieren."),
        Entry(term: "Bestätigen",
              text: "Aufgezeichnete oder erfasste Fahrten erhalten eine Kategorie (und bei geschäftlichen Fahrten "
                + "einen Zweck). Erst bestätigte Fahrten zählen im Fahrtenbuch."),
        Entry(term: "Vorschlag",
              text: "Kategorie und Zweck, die die App aus Regeln, Kalender, Wiederholungen oder KI vorschlägt. "
                + "Ein Vorschlag wird nie ohne deine Bestätigung übernommen."),
        Entry(term: "Regel",
              text: "«Wenn Start/Ziel/Wochentag/Zeit … dann Kategorie/Zweck/Kunde». Regeln erzeugen Vorschläge; "
                + "nur ausdrücklich markierte Regeln bestätigen automatisch."),
        Entry(term: "Privatfahrt",
              text: "Kategorie einer Fahrt: privat gefahren. Zählt für den Privatanteil."),
        Entry(term: "Privatmodus",
              text: "Aufzeichnung ohne Orte und ohne GPS-Track – gespeichert werden nur Zeit und Kilometer."),
        Entry(term: "Privatfahrzeug / Geschäftsfahrzeug",
              text: "Halter des Fahrzeugs. Bestimmt, ob ein Privatanteil (Geschäftsfahrzeug) oder eine "
                + "Kilometerentschädigung (Privatfahrzeug) berechnet wird."),
        Entry(term: "Vertraulicher Ort",
              text: "Ort, der in Berichten ohne Adresse erscheint (z. B. Arzt). Der Wohnort bleibt mit seinen "
                + "Koordinaten nur auf diesem Gerät."),
        Entry(term: "Monatsabschluss",
              text: "Sperrt alle Fahrten eines abgelaufenen Monats unveränderlich. Korrekturen sind danach nur per "
                + "Storno bzw. neuer Fahrt mit Begründung möglich und werden protokolliert."),
        Entry(term: "Stornieren",
              text: "Einträge werden nie gelöscht, sondern als storniert markiert und bleiben im "
                + "Änderungsprotokoll sichtbar."),
        Entry(term: "Änderungsprotokoll",
              text: "Jede Änderung wird unveränderlich in einer Hash-Kette gespeichert – mit Server zusätzlich "
                + "regelmässig signiert (Anker), lokal nur auf dem iPhone. Integritätsprüfung in den Einstellungen."),
        Entry(term: "Abgelehnte Änderung",
              text: "Eine Änderung, die der Server nicht übernommen hat (z. B. abgeschlossener Monat oder ungültige "
                + "Werte). Sie bleibt sichtbar, bis du sie korrigierst, erneut sendest oder verwirfst."),
    ]
}

struct GlossaryView: View {
    @State private var search = ""

    private var filtered: [Glossary.Entry] {
        let q = search.trimmed
        guard !q.isEmpty else { return Glossary.entries }
        return Glossary.entries.filter {
            $0.term.localizedCaseInsensitiveContains(q) || $0.text.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        List {
            ForEach(filtered) { e in
                VStack(alignment: .leading, spacing: 4) {
                    Text(e.term).font(.headline)
                    Text(e.text).font(.subheadline).foregroundStyle(Color.neutralText)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }
        }
        .searchable(text: $search, prompt: "Begriff suchen")
        .navigationTitle("Begriffe")
    }
}
