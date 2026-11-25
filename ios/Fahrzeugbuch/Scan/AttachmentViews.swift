import SwiftUI
import UIKit

/// Bild für die Vollbildanzeige.
struct AttachmentPreview: Identifiable {
    let id: String
    let title: String
    let image: UIImage
}

/// Belege eines Eintrags als Miniaturen: gespeicherte (mit Storno) und noch nicht gesicherte.
struct AttachmentStrip: View {
    @Environment(TenantStore.self) private var store
    let attachments: [Attachment]
    let pending: [PendingAttachment]
    let onRemovePending: (PendingAttachment) -> Void

    @State private var preview: AttachmentPreview?
    @State private var toDelete: Attachment?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(attachments) { a in
                    AttachmentThumbnail(attachment: a, uploadPending: store.isBlobPending(a.id)) { image in
                        preview = AttachmentPreview(id: a.id, title: a.kindLabel, image: image)
                    }
                    .contextMenu {
                        if store.canWrite {
                            Button("Stornieren", systemImage: "trash", role: .destructive) { toDelete = a }
                        }
                    }
                }
                ForEach(pending) { p in
                    pendingThumbnail(p)
                }
            }
            .padding(.vertical, 4)
        }
        .fullScreenCover(item: $preview) { item in
            AttachmentFullScreen(preview: item)
        }
        .stornoDialog($toDelete, title: "Beleg stornieren?") { store.delete($0) }
    }

    @ViewBuilder
    private func pendingThumbnail(_ p: PendingAttachment) -> some View {
        let image = UIImage(data: p.data)
        Button {
            if let image { preview = AttachmentPreview(id: p.id.uuidString, title: p.kind.label, image: image) }
        } label: {
            ThumbnailFrame(image: image, caption: p.kind.label, badge: "Neu")
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Entfernen", systemImage: "xmark", role: .destructive) { onRemovePending(p) }
        }
        .accessibilityLabel("Neuer Beleg \(p.kind.label), wird beim Sichern gespeichert")
        .accessibilityHint("Doppeltippen zum Anzeigen")
    }
}

/// Miniatur eines gespeicherten Belegs (lädt lokal oder vom Server).
struct AttachmentThumbnail: View {
    @Environment(TenantStore.self) private var store
    let attachment: Attachment
    let uploadPending: Bool
    let onOpen: (UIImage) -> Void

    @State private var image: UIImage?
    @State private var loading = true

    var body: some View {
        Button {
            if let image { onOpen(image) }
        } label: {
            ThumbnailFrame(image: image, caption: attachment.kindLabel, badge: uploadPending ? "Ausstehend" : nil,
                           loading: loading)
        }
        .buttonStyle(.plain)
        .disabled(image == nil)
        .task(id: attachment.id) {
            loading = true
            if let data = await store.attachmentData(attachment) {
                image = UIImage(data: data)
            }
            loading = false
        }
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(hintText)
    }

    private var hintText: String {
        image == nil ? "" : "Doppeltippen zum Anzeigen"
    }

    private var accessibilityText: String {
        var text = "Beleg \(attachment.kindLabel)"
        if let d = attachment.takenDate { text += " vom \(Fmt.day(d))" }
        if uploadPending { text += ", noch nicht übertragen" }
        if image == nil && !loading { text += ", offline nicht verfügbar" }
        return text
    }
}

private struct ThumbnailFrame: View {
    let image: UIImage?
    let caption: String
    var badge: String?
    var loading = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else if loading {
                        ProgressView()
                    } else {
                        Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 72, height: 96)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.orange, in: Capsule())
                        .foregroundStyle(.white)
                        .padding(3)
                }
            }
            Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 76)
    }
}

/// Vollbild mit Zoom.
struct AttachmentFullScreen: View {
    @Environment(\.dismiss) private var dismiss
    let preview: AttachmentPreview

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    Image(uiImage: preview.image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width * scale, height: geo.size.height * scale)
                        .accessibilityLabel("Beleg \(preview.title)")
                }
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in scale = min(5, max(1, lastScale * value.magnification)) }
                        .onEnded { _ in lastScale = scale }
                )
                .onTapGesture(count: 2) {
                    withAnimation {
                        scale = scale > 1 ? 1 : 2.5
                        lastScale = scale
                    }
                }
            }
            .background(Color.black)
            .navigationTitle(preview.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}
