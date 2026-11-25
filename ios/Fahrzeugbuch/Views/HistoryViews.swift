import SwiftUI

/// Revisionsverlauf eines Eintrags (online, aus der unveränderlichen Revisionskette).
struct HistorySection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TenantStore.self) private var store
    let entity: String
    let id: String

    @State private var revisions: [RevisionEntry]?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        Section {
            if let revisions {
                ForEach(revisions) { r in
                    DisclosureGroup {
                        ForEach(r.data.keys.sorted().filter { $0 != "deleted" && !$0.hasSuffix("_id") }, id: \.self) { k in
                            LabeledContent(k, value: r.data[k]?.description ?? "–").font(.caption)
                        }
                        LabeledContent("Hash", value: String(r.hash.prefix(16)) + "…").font(.caption2.monospaced())
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("v\(r.version) · \(r.actionLabel)").font(.subheadline.bold())
                                if r.conflict {
                                    Text("Konflikt").font(.caption2).foregroundStyle(.orange)
                                }
                            }
                            Text("\(Self.time(r.recordedAt)) · \(r.actorName ?? "–")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if revisions.isEmpty {
                    Text(store.isPending(id) ? "Noch nicht synchronisiert." : "Kein Verlauf.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    Task { await load() }
                } label: {
                    HStack {
                        Label("Verlauf laden", systemImage: "clock.arrow.circlepath")
                        if loading { Spacer(); ProgressView() }
                    }
                }
                .disabled(loading)
                if let error {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Änderungsverlauf")
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            revisions = try await settings.api.get("api/t/\(store.tenant.slug)/history/\(entity)/\(id)")
            error = nil
        } catch {
            self.error = "Nur online verfügbar: \(error.localizedDescription)"
        }
    }

    static func time(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: iso) else { return iso }
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}
