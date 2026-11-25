import SwiftUI

/// Revisionsverlauf eines Eintrags: Servermodus online aus der unveränderlichen Revisionskette,
/// Lokalmodus aus dem lokalen Änderungsprotokoll (sofort, ohne Netz).
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
                                    StatusTag(text: "Konflikt", color: .orange)
                                }
                            }
                            Text("\(Self.time(r.recordedAt)) · \(r.actorName ?? "–")")
                                .font(.footnote).foregroundStyle(Color.neutralText)
                        }
                    }
                }
                if revisions.isEmpty {
                    Text(emptyText).foregroundStyle(.secondary)
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
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(Color.warningText)
                }
            }
        } header: {
            Text("Änderungsverlauf")
        } footer: {
            if store.isLocal {
                Text("Aus dem lokalen Änderungsprotokoll auf diesem iPhone.")
            }
        }
        .task(id: id) {
            if store.isLocal { loadLocal() }
        }
    }

    private var emptyText: String {
        if store.isLocal { return "Kein Verlauf." }
        return store.isPending(id) ? "Noch nicht synchronisiert." : "Kein Verlauf."
    }

    private func loadLocal() {
        revisions = store.localHistory(entity: entity, id: id)
        error = nil
    }

    private func load() async {
        if store.isLocal {
            loadLocal()
            return
        }
        loading = true
        defer { loading = false }
        do {
            revisions = try await settings.api.get("api/t/\(store.tenant.slug)/history/\(entity)/\(id)")
            error = nil
        } catch {
            self.error = "Verlauf nicht geladen: \(error.userMessage)"
        }
    }

    static func time(_ iso: String) -> String {
        guard let d = Present.parseISO(iso) else { return iso }
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}
