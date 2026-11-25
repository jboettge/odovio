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
