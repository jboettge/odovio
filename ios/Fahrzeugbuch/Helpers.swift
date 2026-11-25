import SwiftUI

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { trimmed.isEmpty ? nil : trimmed }
    /// Akzeptiert "1.5" und "1,5"
    var asDouble: Double? { Double(trimmed.replacingOccurrences(of: ",", with: ".")) }
    /// Akzeptiert Tausendertrenner wie 12'345 oder 12.345
    var asInt: Int? { Int(trimmed.filter(\.isNumber)) }
}

enum Fmt {
    static func km(_ v: Int) -> String { v.formatted(.number) + " km" }
    static func chf(_ v: Double) -> String { v.formatted(.currency(code: "CHF")) }
    static func num(_ v: Double, _ digits: Int = 2) -> String {
        v.formatted(.number.precision(.fractionLength(digits)))
    }
    static func day(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .omitted) }
    /// Für Eingabefelder: ohne Tausendertrenner, damit es wieder geparst werden kann
    static func edit(_ v: Double) -> String { v.formatted(.number.grouping(.never).precision(.fractionLength(2))) }
    /// Mengen: nur nötige Nachkommastellen (1, 4.5, 0.25)
    static func qty(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...3))) }
    static func editQty(_ v: Double) -> String {
        v.formatted(.number.grouping(.never).precision(.fractionLength(0...3)))
    }
    /// km mit höchstens einer Nachkommastelle (18 km, 18.4 km)
    static func kmD(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...1))) + " km" }
    static func pct(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0))) + " %" }
    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
    /// "Di. 24.11."
    static func weekdayDay(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.abbreviated).day().month(.twoDigits))
    }
    static func dateTime(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }
}

/// Demo-Modus (nur Debug): Geräte-Funktionen (GPS, Bewegung) nicht starten.
enum AppMode {
    static var isDemo: Bool {
        #if DEBUG
        return Demo.isActive
        #else
        return false
        #endif
    }
}

/// Monatsschlüssel "YYYY-MM" (wie Server) und Anzeige.
enum TripMonth {
    static func key(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04ld-%02ld", c.year ?? 2000, c.month ?? 1)
    }

    static func date(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: 1))
    }

    /// "November 2026"
    static func label(_ key: String) -> String {
        guard let d = date(key) else { return key }
        return d.formatted(.dateTime.month(.wide).year())
    }

    static func current() -> String { key(Date()) }

    static func previous(_ from: Date = Date()) -> String {
        key(Calendar.current.date(byAdding: .month, value: -1, to: from) ?? from)
    }

    /// Aktueller und die `count - 1` vorherigen Monate, neueste zuerst.
    static func recent(_ count: Int, from: Date = Date()) -> [String] {
        (0..<max(count, 1)).compactMap { i in
            Calendar.current.date(byAdding: .month, value: -i, to: from).map { key($0) }
        }
    }

    /// Erster und letzter Tag des Monats.
    static func bounds(_ key: String) -> (first: Date, last: Date)? {
        guard let first = date(key),
              let next = Calendar.current.date(byAdding: .month, value: 1, to: first),
              let last = Calendar.current.date(byAdding: .day, value: -1, to: next) else { return nil }
        return (first: first, last: last)
    }
}

/// Uhrzeit "HH:MM" ↔ Date (heutiges Datum).
enum TimeOfDay {
    static func date(_ value: String?, fallback: String = "08:00") -> Date {
        let text = value ?? fallback
        let parts = text.split(separator: ":").compactMap { Int($0) }
        let hour = parts.count > 0 ? parts[0] : 8
        let minute = parts.count > 1 ? parts[1] : 0
        return Calendar.current.date(bySettingHour: min(max(hour, 0), 23), minute: min(max(minute, 0), 59),
                                     second: 0, of: Date()) ?? Date()
    }

    static func string(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02ld:%02ld", c.hour ?? 0, c.minute ?? 0)
    }
}

/// Exportdateien (PDF/CSV) im temporären Verzeichnis.
enum ExportFile {
    static func write(_ data: Data, name: String) throws -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "_")
        let url = FileManager.default.temporaryDirectory.appending(path: safe)
        // Dateischutz: nur bei entsperrtem Gerät lesbar (S13)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}

extension APIError {
    /// Detail-Objekt des Servers (z. B. 409 beim Monatsabschluss: {message, gaps, trips}).
    var detailObject: [String: Any]? {
        guard let data = message.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let detail = obj["detail"] as? [String: Any] { return detail }
        return obj["message"] != nil ? obj : nil
    }

    /// Lesbare Meldung inkl. Anzahl offener Fahrten bzw. Lücken.
    var detailText: String {
        guard let d = detailObject else { return message }
        var text = d["message"] as? String ?? message
        if let trips = d["trips"] as? [Any], !trips.isEmpty {
            text += " (\(trips.count) Fahrt(en))"
        }
        if let gaps = d["gaps"] as? [[String: Any]], !gaps.isEmpty {
            let km = gaps.compactMap { ($0["km"] as? NSNumber)?.intValue }.reduce(0, +)
            text += " – \(gaps.count) Lücke(n), \(km) km"
        }
        return text
    }

    var detailHasGaps: Bool {
        guard let gaps = detailObject?["gaps"] as? [Any] else { return false }
        return !gaps.isEmpty
    }
}

/// Inhalt eines Sheets mit eigenem NavigationStack und „Fertig“-Knopf.
struct ModalNavigation<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        NavigationStack {
            content()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Fertig") { dismiss() }
                    }
                }
        }
    }
}

/// Wrapper für `.sheet(item:)` – `value == nil` bedeutet "neu anlegen".
struct EditTarget<T>: Identifiable {
    let id = UUID()
    let value: T?
}

extension View {
    func errorAlert(_ error: Binding<String?>) -> some View {
        alert("Fehler", isPresented: Binding(
            get: { error.wrappedValue != nil },
            set: { if !$0 { error.wrappedValue = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error.wrappedValue ?? "")
        }
    }

    /// Standard-Toolbar für Formulare in Sheets (Speichern wirkt sofort lokal).
    /// `hasChanges`: Wischen zum Schliessen sperren und beim Abbrechen nachfragen.
    func formToolbar(canSave: Bool, hasChanges: Bool = false, save: @escaping () -> Void) -> some View {
        modifier(FormToolbar(canSave: canSave, hasChanges: hasChanges, save: save))
    }

    /// Schutz vor verlorenen Eingaben: sperrt das Wegwischen des Sheets bei Änderungen und zeigt
    /// die Rückfrage „Änderungen verwerfen?“, sobald `isAsking` gesetzt wird.
    func discardGuard(hasChanges: Bool, isAsking: Binding<Bool>) -> some View {
        modifier(DiscardGuard(hasChanges: hasChanges, isAsking: isAsking))
    }

    /// Bestätigung für Stornierungen (revisionssicher: nichts wird physisch gelöscht).
    func stornoDialog<T>(_ item: Binding<T?>, title: String, action: @escaping (T) -> Void) -> some View {
        confirmationDialog(
            title,
            isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: item.wrappedValue
        ) { value in
            Button("Stornieren", role: .destructive) { action(value) }
        } message: { _ in
            Text("Der Eintrag wird als storniert markiert und bleibt im Änderungsprotokoll erhalten.")
        }
    }
}

private struct FormToolbar: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    let canSave: Bool
    let hasChanges: Bool
    let save: () -> Void
    @State private var askDiscard = false

    func body(content: Content) -> some View {
        content
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") {
                        if hasChanges {
                            askDiscard = true
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        save()
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .discardGuard(hasChanges: hasChanges, isAsking: $askDiscard)
    }
}

private struct DiscardGuard: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    let hasChanges: Bool
    @Binding var isAsking: Bool

    func body(content: Content) -> some View {
        content
            .interactiveDismissDisabled(hasChanges)
            .alert("Änderungen verwerfen?", isPresented: $isAsking) {
                Button("Verwerfen", role: .destructive) { dismiss() }
                Button("Weiter bearbeiten", role: .cancel) {}
            } message: {
                Text("Deine Eingaben in diesem Formular gehen verloren.")
            }
    }
}

/// Vergleichswert für „Formular geändert?“ (Felder als Text).
enum FormSnapshot {
    static func make(_ parts: [String]) -> String { parts.joined(separator: "\u{1F}") }
    static func date(_ d: Date) -> String { String(Int(d.timeIntervalSince1970)) }
}

/// Sync-Status als Toolbar-Symbol; Tippen zeigt Details (inkl. abgelehnter Änderungen).
struct SyncStatusButton: View {
    // Barrierefreiheit: beschreibt den Status für VoiceOver
    @Environment(TenantStore.self) private var store
    @State private var showInfo = false
    @State private var showRejected = false

    private var spokenStatus: String {
        let rejected = store.rejectedOps.count
        if store.isSyncing { return "Synchronisiert gerade" }
        if rejected > 0 { return rejected == 1 ? "1 Änderung abgelehnt" : "\(rejected) Änderungen abgelehnt" }
        if store.syncError != nil { return "Synchronisation fehlgeschlagen" }
        if store.outbox.isEmpty { return "Synchronisiert" }
        return "\(store.outbox.count) Änderungen ausstehend"
    }

    var body: some View {
        let rejected = store.rejectedOps.count
        Button { showInfo = true } label: {
            if store.isSyncing {
                ProgressView()
            } else if rejected > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "exclamationmark.icloud.fill")
                    Text("\(rejected)").font(.caption.monospacedDigit().weight(.bold))
                }
                .foregroundStyle(Color.dangerText)
            } else if store.syncError != nil {
                Image(systemName: "exclamationmark.icloud").foregroundStyle(Color.warningText)
            } else if !store.outbox.isEmpty {
                HStack(spacing: 2) {
                    Image(systemName: "icloud.and.arrow.up")
                    Text("\(store.outbox.count)").font(.caption.monospacedDigit())
                }
            } else {
                Image(systemName: "checkmark.icloud")
            }
        }
        .accessibilityLabel(spokenStatus)
        .popover(isPresented: $showInfo) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Synchronisation").font(.headline)
                Text("Ausstehend: \(store.outbox.count) Änderung(en)")
                if !store.pendingBlobs.isEmpty {
                    Text("Beleg-Fotos ausstehend: \(store.pendingBlobs.count)")
                }
                if let last = store.lastSync {
                    Text("Zuletzt: \(last.formatted(date: .abbreviated, time: .shortened))")
                }
                if let err = store.syncError {
                    Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(Color.warningText)
                }
                if rejected > 0 {
                    Button {
                        showInfo = false
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 450_000_000)   // Popover zuerst schliessen
                            showRejected = true
                        }
                    } label: {
                        Label(rejected == 1 ? "1 abgelehnte Änderung ansehen" : "\(rejected) abgelehnte Änderungen ansehen",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.dangerText)
                    }
                }
                Button("Jetzt synchronisieren") { Task { await store.sync() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isSyncing)
            }
            .font(.subheadline)
            .padding()
            .presentationCompactAdaptation(.popover)
        }
        .sheet(isPresented: $showRejected) {
            ModalNavigation { RejectedOpsView() }
        }
    }
}

/// Zeigt Hinweise aus dem Sync (Konflikte, Ablehnungen) als Alert.
struct SyncNoticeModifier: ViewModifier {
    @Environment(TenantStore.self) private var store

    func body(content: Content) -> some View {
        content.alert(
            "Synchronisation",
            isPresented: Binding(get: { !store.notices.isEmpty }, set: { if !$0 { store.notices.removeAll() } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.notices.joined(separator: "\n\n"))
        }
    }
}

/// Eingabefeld mit Einheit rechts (km, l, CHF).
struct UnitField: View {
    let title: String
    @Binding var text: String
    let unit: String
    var keyboard: UIKeyboardType = .decimalPad
    var placeholder = ""

    init(_ title: String, text: Binding<String>, unit: String, keyboard: UIKeyboardType = .decimalPad,
         placeholder: String = "") {
        self.title = title
        self._text = text
        self.unit = unit
        self.keyboard = keyboard
        self.placeholder = placeholder
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(placeholder.isEmpty ? title : placeholder, text: $text)
                    .keyboardType(keyboard)
                    .multilineTextAlignment(.trailing)
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }
}

/// Kleines Etikett (Teilbetankung, Überfällig, Ausstehend …): Text + optional Symbol, nie nur Farbe.
/// Systemfarben werden auf kontrastreiche Varianten abgebildet (≥ 4.5:1).
struct StatusTag: View {
    let text: String
    var color: Color = .warningText
    var systemImage: String?

    private var textColor: Color { Color.accessible(color) }

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).accessibilityHidden(true) }
            Text(text)
        }
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .foregroundStyle(textColor)
        .background(textColor.opacity(0.12), in: Capsule())
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Farben (Kontrast)

extension Color {
    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light })
    }

    /// Warnungen/Vorschläge als Text (statt `.orange`, ≈ 6:1 auf Weiss)
    static let warningText = adaptive(light: UIColor(red: 0.62, green: 0.30, blue: 0.0, alpha: 1),
                                      dark: UIColor(red: 1.0, green: 0.70, blue: 0.30, alpha: 1))
    /// Fehler/Überfällig als Text (statt `.red`)
    static let dangerText = adaptive(light: UIColor(red: 0.70, green: 0.11, blue: 0.10, alpha: 1),
                                     dark: UIColor(red: 1.0, green: 0.45, blue: 0.42, alpha: 1))
    /// Erfüllt/OK als Text (statt `.green`)
    static let successText = adaptive(light: UIColor(red: 0.10, green: 0.45, blue: 0.20, alpha: 1),
                                      dark: UIColor(red: 0.30, green: 0.85, blue: 0.45, alpha: 1))
    /// Information als Text (statt `.blue`)
    static let infoText = adaptive(light: UIColor(red: 0.0, green: 0.35, blue: 0.80, alpha: 1),
                                   dark: UIColor(red: 0.40, green: 0.70, blue: 1.0, alpha: 1))
    static let purpleText = adaptive(light: UIColor(red: 0.50, green: 0.20, blue: 0.70, alpha: 1),
                                     dark: UIColor(red: 0.80, green: 0.60, blue: 1.0, alpha: 1))
    /// Neutrale Kleinschrift (dunkler als `.secondary`)
    static let neutralText = adaptive(light: UIColor(red: 0.30, green: 0.30, blue: 0.32, alpha: 1),
                                      dark: UIColor(red: 0.78, green: 0.78, blue: 0.80, alpha: 1))

    /// Bildet Systemfarben auf kontrastreiche Textfarben ab.
    static func accessible(_ c: Color) -> Color {
        if c == .orange || c == .yellow { return .warningText }
        if c == .red { return .dangerText }
        if c == .green { return .successText }
        if c == .blue { return .infoText }
        if c == .purple { return .purpleText }
        if c == .gray || c == .secondary { return .neutralText }
        return c
    }
}

extension TripCategory {
    /// Begriffe laut Glossar (Kategorie „Privatfahrt“ ≠ Privatmodus ≠ Privatfahrzeug ≠ vertraulicher Ort)
    var uiLabel: String { self == .personal ? "Privatfahrt" : label }

    /// Kontrastreiche Textfarbe der Kategorie (Füllflächen nutzen weiterhin `color`)
    var textColor: Color {
        switch self {
        case .business: .warningText
        case .personal: .neutralText
        case .commute: .infoText
        case .field: .purpleText
        case .unknown: .warningText
        }
    }
}

extension Trip {
    /// Für die Leserolle maskierte Privatfahrt (ohne Orte/Zweck) oder Privatmodus.
    var isMaskedPrivate: Bool {
        privateMode || (category == TripCategory.personal.rawValue && startLabel == nil && endLabel == nil
                        && startPlaceId == nil && endPlaceId == nil)
    }
}

extension TenantStore {
    /// Strecke für die Anzeige; maskierte Privatfahrten erscheinen als „Privatfahrt“.
    func routeLabel(_ t: Trip) -> String {
        t.isMaskedPrivate ? "Privatfahrt" : routeText(t)
    }

    /// Kundenname: Stammdaten, sonst vom Server mitgelieferter Name.
    func customerLabel(_ t: Trip) -> String? {
        if let id = t.customerId, let c = customer(id: id) { return c.name }
        return t.customerName?.nilIfEmpty
    }
}

/// Kilometer-Texte mit Kennzeichnung geschätzter Werte („ca.“).
enum KmText {
    static func value(_ km: Int, estimated: Bool) -> String {
        estimated ? "ca. " + Fmt.km(km) : Fmt.km(km)
    }

    static func distance(_ t: Trip) -> String {
        guard let d = t.distanceKm else { return "– km" }
        return t.kmEstimated ? "ca. " + Fmt.kmD(d) : Fmt.kmD(d)
    }

    /// "+3 km" / "-2 km"
    static func signed(_ km: Int) -> String {
        let sign: String = km > 0 ? "+" : ""
        return sign + Fmt.km(km)
    }

    static func range(_ t: Trip) -> String? {
        guard let a = t.kmStart, let b = t.kmEnd else { return nil }
        let prefix: String = t.kmEstimated ? "ca. " : ""
        return prefix + Fmt.km(a) + " → " + Fmt.km(b)
    }
}
