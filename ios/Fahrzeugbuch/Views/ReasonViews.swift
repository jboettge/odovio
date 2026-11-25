import SwiftUI

/// Begründung für Korrekturen in abgeschlossenen Monaten (Storno, Änderung, erzwungener Abschluss).
enum CorrectionReason {
    static let minLength = 10

    static func isValid(_ text: String) -> Bool { text.trimmed.count >= minLength }

    static func hint(_ text: String) -> String {
        let n = text.trimmed.count
        return n >= minLength ? "\(n) Zeichen" : "Noch \(minLength - n) Zeichen (mindestens \(minLength))"
    }
}

/// Sheet: Begründung erfassen (mind. 10 Zeichen) und bestätigen.
struct ReasonSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let message: String
    let confirmTitle: String
    var destructive = true
    let onConfirm: (String) -> Void

    @State private var reason = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(message)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    TextField("Grund der Korrektur", text: $reason, axis: .vertical)
                        .lineLimit(2...6)
                        .focused($focused)
                } header: {
                    Text("Begründung")
                } footer: {
                    Text(CorrectionReason.hint(reason))
                        .foregroundStyle(CorrectionReason.isValid(reason) ? Color.secondary : Color.warningText)
                }
                Section {
                    Button(role: destructive ? ButtonRole.destructive : nil) {
                        onConfirm(reason.trimmed)
                        dismiss()
                    } label: {
                        Text(confirmTitle).frame(maxWidth: .infinity)
                    }
                    .disabled(!CorrectionReason.isValid(reason))
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
            .interactiveDismissDisabled(!reason.trimmed.isEmpty)
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}

extension View {
    /// Storno mit Rückfrage; verlangt `requiresReason` eine Begründung (abgeschlossener Monat),
    /// folgt ein Begründungsdialog (≥ 10 Zeichen). `action` erhält die Begründung oder `nil`.
    func reasonedStorno<T>(_ item: Binding<T?>, title: String,
                           message: @escaping (T) -> String,
                           requiresReason: @escaping (T) -> Bool,
                           action: @escaping (T, String?) -> Void) -> some View {
        modifier(ReasonedStorno(item: item, title: title, message: message,
                                requiresReason: requiresReason, action: action))
    }
}

private struct ReasonedStorno<T>: ViewModifier {
    @Binding var item: T?
    let title: String
    let message: (T) -> String
    let requiresReason: (T) -> Bool
    let action: (T, String?) -> Void

    @State private var reasonTarget: EditTarget<T>?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                title,
                isPresented: Binding(get: { item != nil }, set: { if !$0 { item = nil } }),
                titleVisibility: .visible,
                presenting: item
            ) { value in
                if requiresReason(value) {
                    Button("Mit Begründung stornieren …", role: .destructive) {
                        reasonTarget = EditTarget(value: value)
                    }
                } else {
                    Button("Stornieren", role: .destructive) { action(value, nil) }
                }
            } message: { value in
                Text(message(value))
            }
            .sheet(item: $reasonTarget) { target in
                ReasonSheet(title: "Storno begründen",
                            message: "Der Eintrag gehört zu einem abgeschlossenen Monat. Die Stornierung wird mit "
                                + "dieser Begründung im Änderungsprotokoll und im Fahrtenbuch vermerkt.",
                            confirmTitle: "Stornieren") { reason in
                    if let value = target.value { action(value, reason) }
                }
            }
    }
}

/// Textfeld „Begründung“ als Formular-Abschnitt (Änderung in abgeschlossenem Monat).
struct ReasonSection: View {
    @Binding var reason: String
    var monthLabel: String?

    var body: some View {
        Section {
            TextField("Pflicht: Grund der Korrektur", text: $reason, axis: .vertical)
        } header: {
            Text("Korrekturbegründung")
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                if let monthLabel {
                    Text("\(monthLabel) ist abgeschlossen – Änderungen werden mit Begründung protokolliert.")
                } else {
                    Text("Der Monat ist abgeschlossen – Änderungen werden mit Begründung protokolliert.")
                }
                Text(CorrectionReason.hint(reason))
                    .foregroundStyle(CorrectionReason.isValid(reason) ? Color.secondary : Color.warningText)
            }
        }
    }
}
