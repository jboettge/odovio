import AVFoundation
import PhotosUI
import SwiftUI
import UIKit
import VisionKit

/// Ergebnis eines Scans, das ein Formular übernimmt.
struct ScanOutcome {
    var kind: ScanKind
    var liters: Double?
    var amount: Double?
    var pricePerLiter: Double?
    var km: Int?
    var date: Date?
    var station: String?
    /// JPEG für die Belegablage; `nil` = nicht als Beleg speichern
    var attachmentJPEG: Data?
}

/// Auslöser für `.sheet(item:)`.
struct ScanRequest: Identifiable {
    let id = UUID()
    let kind: ScanKind
}

/// Noch nicht gespeicherter Beleg eines Formulars (wird beim Sichern angelegt).
struct PendingAttachment: Identifiable {
    let id = UUID()
    let kind: ScanKind
    let data: Data
}

/// Aufnahme mit Auswertung.
struct ScanCapture: Identifiable {
    let id = UUID()
    var image: UIImage
    var reading: ScanReading
    /// Hervorhebungen passen nur, wenn die Erkennung auf genau diesem Bild lief
    var highlights: Bool
}

/// Scannen von Zapfsäule, Quittung oder Tacho: Live-Scan (VisionKit) oder Foto, Auswertung auf dem Gerät.
struct ScannerView: View {
    @Environment(\.dismiss) private var dismiss
    let kinds: [ScanKind]
    let lastKnownKm: Int?
    let allowAttachment: Bool
    let onApply: (ScanOutcome) -> Void

    @State private var kind: ScanKind
    @State private var capture: ScanCapture?
    @State private var isRecognizing = false
    @State private var showLive = false
    @State private var showCamera = false
    @State private var photoItem: PhotosPickerItem?
    @State private var cameraDenied = false
    @State private var message: String?

    init(kinds: [ScanKind], initialKind: ScanKind, lastKnownKm: Int?, allowAttachment: Bool = true,
         onApply: @escaping (ScanOutcome) -> Void) {
        self.kinds = kinds.isEmpty ? [initialKind] : kinds
        self.lastKnownKm = lastKnownKm
        self.allowAttachment = allowAttachment
        self.onApply = onApply
        _kind = State(initialValue: initialKind)
    }

    private var liveSupported: Bool {
        DataScannerViewController.isSupported
    }

    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let capture {
                    ScanResultView(image: capture.image, kind: kind, reading: capture.reading,
                                   highlights: capture.highlights, allowAttachment: allowAttachment,
                                   onApply: { outcome in
                                       onApply(outcome)
                                       dismiss()
                                   },
                                   onRetake: { self.capture = nil })
                } else if isRecognizing {
                    ProgressView("Text wird erkannt …")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    chooser
                }
            }
            .navigationTitle("\(kind.label) scannen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
        .fullScreenCover(isPresented: $showLive) {
            LiveScanView(kind: kind, lastKnownKm: lastKnownKm,
                         onCapture: { image, reading in
                             showLive = false
                             handleLive(image: image, reading: reading)
                         },
                         onCancel: { showLive = false })
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(onImage: { image in
                showCamera = false
                process(image)
            }, onCancel: { showCamera = false })
            .ignoresSafeArea()
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                photoItem = nil
                if let data, let image = UIImage(data: data) {
                    process(image)
                } else {
                    message = "Das Foto konnte nicht geladen werden."
                }
            }
        }
        .errorAlert($message)
    }

    // MARK: Auswahl

    private var chooser: some View {
        Form {
            if kinds.count > 1 {
                Section {
                    Picker("Was scannen?", selection: $kind) {
                        ForEach(kinds) { k in
                            Label(k.label, systemImage: k.systemImage).tag(k)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            Section {
                if liveSupported {
                    Button { start(live: true) } label: {
                        Label("Live-Scan", systemImage: "text.viewfinder")
                    }
                    .accessibilityHint("Erkennt die Werte laufend im Kamerabild")
                }
                if cameraAvailable {
                    Button { start(live: false) } label: {
                        Label("Foto aufnehmen", systemImage: "camera")
                    }
                }
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Foto aus Mediathek wählen", systemImage: "photo.on.rectangle")
                }
            } header: {
                Text(kind.label)
            } footer: {
                Text(hint)
            }
            if cameraDenied {
                Section {
                    Label("Kein Zugriff auf die Kamera", systemImage: "camera.badge.ellipsis")
                        .foregroundStyle(.orange)
                    Button("Einstellungen öffnen") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                } footer: {
                    Text("Erlaube den Kamerazugriff in den Einstellungen oder wähle ein vorhandenes Foto.")
                }
            }
        }
    }

    private var hint: String {
        let privacy = "Die Texterkennung läuft auf diesem iPhone – es wird kein Bild übertragen."
        switch kind {
        case .pump:
            return "Anzeige der Zapfsäule mit Betrag, Liter und Preis pro Liter formatfüllend aufnehmen. " + privacy
        case .receipt:
            return "Quittung flach hinlegen und vollständig aufnehmen. Datum und Tankstelle werden mit übernommen. "
                + privacy
        case .odometer:
            return "Kilometerstand (Gesamt-km) im Tacho aufnehmen, nicht den Tageskilometerzähler. " + privacy
        }
    }

    // MARK: Ablauf

    private func start(live: Bool) {
        Task {
            guard await cameraAccess() else {
                cameraDenied = true
                return
            }
            cameraDenied = false
            if live {
                if DataScannerViewController.isAvailable {
                    showLive = true
                } else {
                    message = "Der Live-Scan ist auf diesem Gerät gerade nicht verfügbar."
                }
            } else {
                showCamera = true
            }
        }
    }

    private func cameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    /// Foto auswerten (Vision auf dem Gerät).
    private func process(_ image: UIImage) {
        isRecognizing = true
        let currentKind = kind
        let lastKm = lastKnownKm
        Task {
            let prepared = ImageTools.normalized(image, maxDimension: 2400)
            let lines = (try? await TextRecognizer.recognize(image: prepared)) ?? []
            let reading = ReadingParser.parse(lines, kind: currentKind, lastKnownKm: lastKm)
            capture = ScanCapture(image: prepared, reading: reading, highlights: true)
            isRecognizing = false
        }
    }

    /// Live-Ergebnis: Foto erneut auswerten (für Hervorhebungen); bei Abweichung gilt das Live-Ergebnis.
    private func handleLive(image photo: UIImage?, reading: ScanReading) {
        guard let image = photo else {
            message = "Das Foto konnte nicht aufgenommen werden."
            return
        }
        isRecognizing = true
        let currentKind = kind
        let lastKm = lastKnownKm
        Task {
            let prepared = ImageTools.normalized(image, maxDimension: 2400)
            let lines = (try? await TextRecognizer.recognize(image: prepared)) ?? []
            let photoReading = ReadingParser.parse(lines, kind: currentKind, lastKnownKm: lastKm)
            // Stabiles Live-Ergebnis hat Vorrang, wenn das Foto etwas anderes ergibt (Hervorhebung passt dann nicht)
            if reading.confidence >= LiveScanView.requiredConfidence, let key = reading.stabilityKey,
               photoReading.stabilityKey != key {
                capture = ScanCapture(image: prepared, reading: reading, highlights: false)
            } else {
                capture = ScanCapture(image: prepared, reading: photoReading, highlights: true)
            }
            isRecognizing = false
        }
    }
}

// MARK: - Live-Scan (VisionKit)

/// Kamerabild mit laufender Texterkennung; ein Ergebnis wird angeboten, sobald es 3× stabil erkannt wurde.
struct LiveScanView: View {
    let kind: ScanKind
    let lastKnownKm: Int?
    let onCapture: (UIImage?, ScanReading) -> Void
    let onCancel: () -> Void

    @State private var scannerHandle = DataScannerHandle()
    @State private var current: ScanReading?
    @State private var stable: ScanReading?
    @State private var lastKey: String?
    @State private var streak = 0
    @State private var isCapturing = false

    static let requiredStreak = 3
    static let requiredConfidence = 0.75

    var body: some View {
        ZStack(alignment: .bottom) {
            DataScannerRepresentable(handle: scannerHandle) { lines in evaluate(lines) }
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
            .accessibilityLabel("Live-Scan schliessen")
        }
    }

    @ViewBuilder
    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let stable {
                Label("Erkannt", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(.green)
                Text(summary(stable)).font(.title3.monospacedDigit())
                HStack {
                    Button("Weiter scannen") { reset() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button { capture(stable) } label: {
                        if isCapturing { ProgressView() } else { Text("Übernehmen").bold() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isCapturing)
                }
            } else {
                if let current, current.hasValues {
                    Text(summary(current)).font(.headline.monospacedDigit())
                    ProgressView(value: Double(min(streak, Self.requiredStreak)), total: Double(Self.requiredStreak))
                        .accessibilityLabel("Erkennung wird bestätigt")
                } else {
                    Text(searchText).font(.subheadline)
                }
                HStack {
                    Text("Auswertung auf dem Gerät").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { capture(current ?? ScanReading(kind: kind)) } label: {
                        Label("Foto", systemImage: "camera.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isCapturing)
                    .accessibilityLabel("Foto aufnehmen und auswerten")
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }

    private var searchText: String {
        switch kind {
        case .pump, .receipt: "Suche Betrag, Liter und Preis pro Liter …"
        case .odometer: "Suche Kilometerstand …"
        }
    }

    private func summary(_ r: ScanReading) -> String {
        if let km = r.km { return Fmt.km(km) }
        guard let f = r.fuel else { return "" }
        return "CHF \(Fmt.num(f.amount)) · \(Fmt.num(f.liters)) l · \(Fmt.num(f.pricePerLiter, 3)) CHF/l"
    }

    private func evaluate(_ lines: [RecognizedLine]) {
        guard stable == nil, !isCapturing else { return }
        let reading = ReadingParser.parse(lines, kind: kind, lastKnownKm: lastKnownKm)
        current = reading
        guard let key = reading.stabilityKey, reading.confidence >= Self.requiredConfidence else {
            streak = 0
            lastKey = nil
            return
        }
        if key == lastKey {
            streak += 1
        } else {
            lastKey = key
            streak = 1
        }
        if streak >= Self.requiredStreak {
            stable = reading
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private func reset() {
        stable = nil
        current = nil
        lastKey = nil
        streak = 0
    }

    private func capture(_ reading: ScanReading) {
        isCapturing = true
        Task {
            let image = try? await scannerHandle.controller?.capturePhoto()
            isCapturing = false
            onCapture(image, reading)
        }
    }
}

/// Verweis auf den laufenden DataScanner (für `capturePhoto()`).
@MainActor
final class DataScannerHandle {
    weak var controller: DataScannerViewController?
}

struct DataScannerRepresentable: UIViewControllerRepresentable {
    let handle: DataScannerHandle
    let onLines: ([RecognizedLine]) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.text()],
            qualityLevel: .accurate,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        handle.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        context.coordinator.onLines = onLines
        if !controller.isScanning {
            try? controller.startScanning()
        }
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onLines: onLines)
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onLines: ([RecognizedLine]) -> Void

        init(onLines: @escaping ([RecognizedLine]) -> Void) {
            self.onLines = onLines
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            report(dataScanner, allItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            report(dataScanner, allItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didRemove removedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            report(dataScanner, allItems)
        }

        /// Erkennungen in Zeilen mit normalisierten Rechtecken (Bezug: Ansicht) umwandeln.
        private func report(_ scanner: DataScannerViewController, _ items: [RecognizedItem]) {
            let size = scanner.view.bounds.size
            guard size.width > 0, size.height > 0 else { return }
            var lines: [RecognizedLine] = []
            for item in items {
                guard case .text(let text) = item else { continue }
                let b = text.bounds
                let xs = [b.topLeft.x, b.topRight.x, b.bottomLeft.x, b.bottomRight.x]
                let ys = [b.topLeft.y, b.topRight.y, b.bottomLeft.y, b.bottomRight.y]
                let minX = xs.min() ?? 0
                let maxX = xs.max() ?? 0
                let minY = ys.min() ?? 0
                let maxY = ys.max() ?? 0
                let box = TextBox(x: Double(minX / size.width), y: Double(minY / size.height),
                                  width: Double((maxX - minX) / size.width), height: Double((maxY - minY) / size.height))
                lines.append(RecognizedLine(text: text.transcript, confidence: 0.8, box: box))
            }
            onLines(lines)
        }
    }
}

// MARK: - Kamera (Foto)

struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage, onCancel: onCancel)
    }

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (UIImage) -> Void
        let onCancel: () -> Void

        init(onImage: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onImage = onImage
            self.onCancel = onCancel
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                onImage(image)
            } else {
                onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}
