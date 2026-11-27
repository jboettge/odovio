import AVFoundation
import CoreImage
import PhotosUI
import SwiftUI
import UIKit
import VisionKit

/// Server-Einrichtung per Link bzw. QR-Code.
/// Formate: `https://fahrzeugbuch.example.net` oder `fahrzeugbuch://setup?server=https://…`.
/// Hinweis: Das URL-Schema `fahrzeugbuch` muss in `project.yml` (CFBundleURLTypes) registriert sein.
enum ServerLink {
    static let scheme = "fahrzeugbuch"

    /// Server-URL aus einem Link/QR-Inhalt; `nil`, wenn ungültig oder nicht HTTPS.
    static func serverURL(from text: String) -> String? {
        let raw = text.trimmed
        guard let comps = URLComponents(string: raw), let scheme = comps.scheme?.lowercased() else { return nil }
        if scheme == Self.scheme {
            guard comps.host?.lowercased() == "setup",
                  let value = comps.queryItems?.first(where: { $0.name == "server" })?.value else { return nil }
            return validated(value)
        }
        return validated(raw)
    }

    /// Ist `url` ein Einrichtungslink der App?
    static func isSetupLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == Self.scheme
    }

    private static func validated(_ value: String) -> String? {
        var text = value.trimmed
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), AuthManager.isSecure(url) else { return nil }
        return text
    }

    /// Hostname für Texte („Anmeldung mit deinem Konto für …“).
    static func host(_ server: String) -> String {
        URLComponents(string: server)?.host ?? server
    }

    /// Entscheid für einen Einrichtungslink (I1): Ein Server wird nie ohne Bestätigung übernommen – auch nicht,
    /// wenn noch keine Betriebsart gewählt bzw. kein Server eingerichtet ist (Phishing-Link).
    enum SetupDecision: Equatable {
        /// keine gültige HTTPS-Adresse
        case invalid
        /// Lokalmodus: nichts umstellen, Server nur im Übertragungs-Assistenten vorbelegen
        case suggestForTransfer(server: String)
        /// derselbe Server ist schon eingerichtet (ggf. nur Betriebsart «Mit Server» wieder wählen)
        case alreadyConfigured
        /// Rückfrage mit deutlich angezeigtem Host; `replacing` = Host des bisherigen Servers
        case confirm(server: String, host: String, replacing: String?)
    }

    static func setupDecision(link: URL, mode: AppMode?, currentServer: String) -> SetupDecision {
        guard isSetupLink(link), let server = serverURL(from: link.absoluteString) else { return .invalid }
        if mode == .local { return .suggestForTransfer(server: server) }
        let current = currentServer.trimmed
        if !current.isEmpty && TokenBinding.normalize(current) == TokenBinding.normalize(server) {
            return .alreadyConfigured
        }
        return .confirm(server: server, host: host(server), replacing: current.isEmpty ? nil : host(current))
    }
}

/// QR-Code mit der Server-Adresse scannen (Live per VisionKit, sonst aus einem Foto).
struct ServerQRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    let onServer: (String) -> Void

    @State private var liveReady = false
    @State private var checkedCamera = false
    @State private var photoItem: PhotosPickerItem?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if liveReady {
                    QRDataScanner { payload in handle(payload) }
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableView {
                        Label("Kamera-Scan nicht verfügbar", systemImage: "qrcode.viewfinder")
                    } description: {
                        Text(checkedCamera
                             ? "Wähle ein Foto oder einen Bildschirmfoto des QR-Codes aus der Mediathek."
                             : "Kamera wird vorbereitet …")
                    }
                }
                VStack(spacing: 10) {
                    if let message {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(Color.warningText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("QR-Code aus Foto lesen", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Text("Den QR-Code erhältst du vom Betreiber deines Fahrzeugbuch-Servers.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle("QR-Code scannen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
            .task {
                if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                    _ = await AVCaptureDevice.requestAccess(for: .video)
                }
                liveReady = DataScannerViewController.isSupported && DataScannerViewController.isAvailable
                checkedCamera = true
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    let data = try? await item.loadTransferable(type: Data.self)
                    photoItem = nil
                    guard let data, let image = UIImage(data: data) else {
                        message = "Das Foto konnte nicht geladen werden."
                        return
                    }
                    let codes = QRImageDecoder.decode(image)
                    if codes.isEmpty {
                        message = "Kein QR-Code im Foto gefunden."
                    } else if let code = codes.first(where: { ServerLink.serverURL(from: $0) != nil }) {
                        handle(code)
                    } else {
                        handle(codes[0])
                    }
                }
            }
        }
    }

    private func handle(_ payload: String) {
        if let server = ServerLink.serverURL(from: payload) {
            onServer(server)
            dismiss()
        } else {
            message = "Der QR-Code enthält keine gültige HTTPS-Serveradresse."
        }
    }
}

/// QR-Codes in einem Bild finden (Core Image).
enum QRImageDecoder {
    static func decode(_ image: UIImage) -> [String] {
        guard let ci = CIImage(image: image),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else { return [] }
        return detector.features(in: ci).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }
}

/// Live-Scan von QR-Codes (VisionKit).
struct QRDataScanner: UIViewControllerRepresentable {
    let onPayload: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        context.coordinator.onPayload = onPayload
        if !controller.isScanning {
            try? controller.startScanning()
        }
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPayload: onPayload)
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onPayload: (String) -> Void
        private var delivered = false

        init(onPayload: @escaping (String) -> Void) {
            self.onPayload = onPayload
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in addedItems {
                guard case .barcode(let code) = item, let text = code.payloadStringValue else { continue }
                if ServerLink.serverURL(from: text) != nil {
                    guard !delivered else { return }
                    delivered = true
                }
                onPayload(text)
                return
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            guard case .barcode(let code) = item, let text = code.payloadStringValue else { return }
            onPayload(text)
        }
    }
}
