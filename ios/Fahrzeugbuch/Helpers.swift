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
        try data.write(to: url, options: .atomic)
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
    func formToolbar(canSave: Bool, save: @escaping () -> Void) -> some View {
        modifier(FormToolbar(canSave: canSave, save: save))
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
    let save: () -> Void

    func body(content: Content) -> some View {
        content
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        save()
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
    }
}

/// Sync-Status als Toolbar-Symbol; Tippen synchronisiert.
struct SyncStatusButton: View {
    // Barrierefreiheit: beschreibt den Status für VoiceOver
    @Environment(TenantStore.self) private var store
    @State private var showInfo = false

    var body: some View {
        Button { showInfo = true } label: {
            if store.isSyncing {
                ProgressView()
            } else if store.syncError != nil {
                Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange)
            } else if !store.outbox.isEmpty {
                HStack(spacing: 2) {
                    Image(systemName: "icloud.and.arrow.up")
                    Text("\(store.outbox.count)").font(.caption2.monospacedDigit())
                }
            } else {
                Image(systemName: "checkmark.icloud")
            }
        }
        .accessibilityLabel(store.isSyncing ? "Synchronisiert gerade"
                            : store.syncError != nil ? "Synchronisation fehlgeschlagen"
                            : store.outbox.isEmpty ? "Synchronisiert" : "\(store.outbox.count) Änderungen ausstehend")
        .popover(isPresented: $showInfo) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Synchronisation").font(.headline)
                Text("Ausstehend: \(store.outbox.count) Änderung(en)")
                if let last = store.lastSync {
                    Text("Zuletzt: \(last.formatted(date: .abbreviated, time: .shortened))")
                }
                if let err = store.syncError {
                    Text(err).foregroundStyle(.orange)
                }
                Button("Jetzt synchronisieren") { Task { await store.sync() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isSyncing)
            }
            .font(.subheadline)
            .padding()
            .presentationCompactAdaptation(.popover)
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

/// Kleines farbiges Etikett (Teilbetankung, Überfällig, Ausstehend …).
struct StatusTag: View {
    let text: String
    var color: Color = .orange
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.15), in: Capsule())
    }
}
