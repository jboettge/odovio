import QuickLook
import SwiftUI

/// PDF-Export (serverseitig erzeugt, inkl. Änderungsprotokoll und Integritätsvermerk).
struct ReportView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TenantStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let vehicle: Vehicle

    @State private var from = Calendar.current.date(from: Calendar.current.dateComponents([.year], from: Date())) ?? Date()
    @State private var to = Date()
    @State private var loading = false
    @State private var fileURL: URL?
    @State private var previewURL: URL?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Von", selection: $from, in: ...to, displayedComponents: .date)
                    DatePicker("Bis", selection: $to, in: from..., displayedComponents: .date)
                } header: {
                    Text("Zeitraum")
                } footer: {
                    if !store.outbox.isEmpty {
                        Text("\(store.outbox.count) Änderung(en) noch nicht synchronisiert – sie fehlen im PDF.")
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    Button {
                        Task { await generate() }
                    } label: {
                        HStack {
                            Label("PDF erstellen", systemImage: "doc.badge.arrow.up")
                            if loading { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(loading)
                    if let fileURL {
                        Button { previewURL = fileURL } label: { Label("Vorschau", systemImage: "eye") }
                        ShareLink(item: fileURL) { Label("Teilen / Sichern", systemImage: "square.and.arrow.up") }
                    }
                }
            }
            .navigationTitle("PDF-Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Schliessen") { dismiss() } }
            }
            .quickLookPreview($previewURL)
            .errorAlert($error)
        }
    }

    private func generate() async {
        loading = true
        defer { loading = false }
        await store.sync()   // ausstehende Änderungen zuerst übertragen
        let f = APIClient.dayFormatter
        do {
            let data = try await settings.api.download(
                "api/t/\(store.tenant.slug)/vehicles/\(vehicle.id)/report.pdf",
                query: [URLQueryItem(name: "from", value: f.string(from: from)),
                        URLQueryItem(name: "to", value: f.string(from: to))])
            let name = "Fahrzeugbuch_\(vehicle.name)_\(f.string(from: from))_\(f.string(from: to)).pdf"
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: " ", with: "_")
            let url = FileManager.default.temporaryDirectory.appending(path: name)
            try data.write(to: url, options: .atomic)
            fileURL = url
            previewURL = url
        } catch {
            self.error = "PDF nur online verfügbar: \(error.localizedDescription)"
        }
    }
}
