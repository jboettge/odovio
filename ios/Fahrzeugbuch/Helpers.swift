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
    static func edit(_ v: Double) -> String { num(v, 2) }
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

    /// Standard-Toolbar für Formulare in Sheets.
    func formToolbar(canSave: Bool, saving: Bool, save: @escaping () async -> Void) -> some View {
        modifier(FormToolbar(canSave: canSave, saving: saving, save: save))
    }
}

private struct FormToolbar: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    let canSave: Bool
    let saving: Bool
    let save: () async -> Void

    func body(content: Content) -> some View {
        content
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Sichern") { Task { await save() } }
                            .disabled(!canSave)
                    }
                }
            }
    }
}
