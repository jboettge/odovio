import AVFoundation
import SwiftUI
import UIKit
import Vision
import VisionKit

/// VIN scannen: Live-Kamera (VisionKit `DataScannerViewController`) mit Barcodes (Code 39, Data Matrix, QR) und
/// Texterkennung auf dem Gerät. Erkannte Kandidaten werden normalisiert, OCR-korrigiert und auf eine gültige
/// 17-stellige VIN gefiltert (`VIN.candidates`); Barcode-Treffer sofort, Text nach mehrfach gleicher Erkennung.
/// Ohne Live-Scan (Gerät/Kamera) erscheint ein Hinweis – die VIN lässt sich weiterhin eintippen.
struct VINScannerSheet: View {
    let onFound: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    enum Phase: Equatable {
        case checking
        case scanning
        case unsupported
        case unavailable
        case denied
    }

    @State private var phase: Phase = .checking

    var body: some View {
        Group {
            switch phase {
            case .scanning:
                VINLiveScanView(onFound: { vin in
                    onFound(vin)
                    dismiss()
                }, onCancel: { dismiss() })
            case .checking:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unsupported, .unavailable, .denied:
                fallback
            }
        }
        .task { await prepare() }
    }

    private var fallback: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: phase == .denied ? "camera.badge.ellipsis" : "barcode.viewfinder")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(fallbackTitle).font(.headline)
                Text(fallbackText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if phase == .denied {
                    Button("Einstellungen öffnen") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("VIN scannen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schliessen") { dismiss() }
                }
            }
        }
    }

    private var fallbackTitle: String {
        switch phase {
        case .denied: "Kein Zugriff auf die Kamera"
        default: "Scannen nicht verfügbar"
        }
    }

    private var fallbackText: String {
        switch phase {
        case .denied:
            return "Erlaube den Kamerazugriff in den Einstellungen oder tippe die VIN ein (Fahrzeugausweis, "
                + "Fahrgestell-Nr.)."
        case .unsupported:
            return "Dieses Gerät unterstützt den Live-Scan nicht. Tippe die VIN ein – sie steht im Fahrzeugausweis "
                + "(Fahrgestell-Nr.) oder unten an der Windschutzscheibe."
        default:
            return "Der Live-Scan ist gerade nicht verfügbar (z. B. Kamera eingeschränkt). Tippe die VIN ein."
        }
    }

    private func prepare() async {
        guard phase == .checking else { return }
        guard DataScannerViewController.isSupported else {
            phase = .unsupported
            return
        }
        guard await Self.cameraAccess() else {
            phase = .denied
            return
        }
        phase = DataScannerViewController.isAvailable ? .scanning : .unavailable
    }

    private static func cameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }
}

/// Kamerabild mit laufender Erkennung; übernimmt die erste sichere VIN und schliesst.
struct VINLiveScanView: View {
    let onFound: (String) -> Void
    let onCancel: () -> Void

    @State private var candidate: String?
    @State private var streak = 0
    @State private var accepted = false

    /// Gleiche VIN so oft in Folge per Texterkennung, bevor sie gilt (Barcode: sofort)
    static let requiredTextStreak = 3

    var body: some View {
        ZStack(alignment: .bottom) {
            VINDataScannerRepresentable { barcodes, texts in evaluate(barcodes: barcodes, texts: texts) }
                .ignoresSafeArea()
            panel
                .padding()
        }
        .overlay(alignment: .topLeading) {
            Button { onCancel() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Color.black.opacity(0.5))
            }
            .padding()
            .accessibilityLabel("VIN-Scan schliessen")
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let candidate {
                Text(candidate)
                    .font(.headline.monospaced())
                    .accessibilityLabel("Erkannt: \(VIN.spoken(candidate))")
                ProgressView(value: Double(min(streak, Self.requiredTextStreak)),
                             total: Double(Self.requiredTextStreak))
                    .accessibilityLabel("Erkennung wird bestätigt")
            } else {
                Text("Suche VIN (17 Zeichen) oder Strichcode …").font(.subheadline)
            }
            Text("Fahrzeugausweis, Windschutzscheibe unten links oder Türrahmen. Auswertung auf dem Gerät.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }

    private func evaluate(barcodes: [String], texts: [String]) {
        guard !accepted else { return }
        if let vin = VIN.bestCandidate(in: barcodes) {
            accept(vin)
            return
        }
        guard let vin = VIN.bestCandidate(in: texts) else {
            candidate = nil
            streak = 0
            return
        }
        if vin == candidate {
            streak += 1
        } else {
            candidate = vin
            streak = 1
        }
        if streak >= Self.requiredTextStreak { accept(vin) }
    }

    private func accept(_ vin: String) {
        accepted = true
        candidate = vin
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onFound(vin)
    }
}

struct VINDataScannerRepresentable: UIViewControllerRepresentable {
    /// (Barcode-Inhalte, erkannte Texte) aller aktuell sichtbaren Erkennungen
    let onItems: ([String], [String]) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [
                .barcode(symbologies: [.code39, .code39Checksum, .dataMatrix, .qr]),
                .text(),
            ],
            qualityLevel: .accurate,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        context.coordinator.onItems = onItems
        if !controller.isScanning {
            try? controller.startScanning()
        }
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onItems: onItems)
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onItems: ([String], [String]) -> Void

        init(onItems: @escaping ([String], [String]) -> Void) {
            self.onItems = onItems
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            report(allItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            report(allItems)
        }

        private func report(_ items: [RecognizedItem]) {
            var barcodes: [String] = []
            var texts: [String] = []
            for item in items {
                if case .barcode(let code) = item {
                    if let payload = code.payloadStringValue { barcodes.append(payload) }
                } else if case .text(let text) = item {
                    texts.append(text.transcript)
                }
            }
            onItems(barcodes, texts)
        }
    }
}
