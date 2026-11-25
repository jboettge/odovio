import ImageIO
import UIKit
import Vision

/// Texterkennung auf dem Gerät (Vision). Liefert Zeilen inkl. Kandidaten für den `ReadingParser`.
enum TextRecognizer {
    static let languages = ["de-CH", "de-DE", "en-US"]

    /// Erkennt Text in einem Bild. Läuft im Hintergrund (nicht auf dem Main-Thread).
    static func recognize(cgImage: CGImage, orientation: CGImagePropertyOrientation = .up) async throws
        -> [RecognizedLine] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let lines = try perform(cgImage: cgImage, orientation: orientation)
                    continuation.resume(returning: lines)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Bequemlichkeit für `UIImage` (Orientierung wird an Vision übergeben).
    @MainActor
    static func recognize(image: UIImage) async throws -> [RecognizedLine] {
        guard let cgImage = image.cgImage else { return [] }
        return try await recognize(cgImage: cgImage, orientation: CGImagePropertyOrientation(image.imageOrientation))
    }

    /// Synchron (für Hintergrund-Queues).
    static func perform(cgImage: CGImage, orientation: CGImagePropertyOrientation) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false   // Zahlen nicht "korrigieren"
        request.minimumTextHeight = 0.012        // auch kleine Beschriftungen (CHF/l)
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let wanted = languages.filter { supported.contains($0) }
        request.recognitionLanguages = wanted.isEmpty ? ["en-US"] : wanted

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        try handler.perform([request])

        var lines: [RecognizedLine] = []
        for observation in request.results ?? [] {
            let candidates = observation.topCandidates(3)
            guard let best = candidates.first else { continue }
            // Vision: normalisiert, Ursprung unten links → oben links
            let b = observation.boundingBox
            let box = TextBox(x: Double(b.minX), y: Double(1 - b.maxY), width: Double(b.width), height: Double(b.height))
            lines.append(RecognizedLine(text: best.string, candidates: candidates.map { $0.string },
                                        confidence: Double(best.confidence), box: box))
        }
        return lines
    }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

/// Bilder verkleinern und als JPEG kodieren.
@MainActor
enum ImageTools {
    /// Aufrecht (Orientierung .up) und höchstens `maxDimension` Pixel an der längeren Kante.
    static func normalized(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longest = max(pixelWidth, pixelHeight)
        guard longest > 0 else { return image }
        let factor = min(1, maxDimension / longest)
        if factor >= 1 && image.imageOrientation == .up && image.scale == 1 { return image }
        let target = CGSize(width: max(1, (pixelWidth * factor).rounded()), height: max(1, (pixelHeight * factor).rounded()))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// JPEG mit Grössenlimit: senkt zuerst die Qualität, dann die Auflösung.
    static func jpeg(_ image: UIImage, maxDimension: CGFloat, quality: CGFloat, maxBytes: Int) -> Data? {
        var dimension = maxDimension
        var q = quality
        for _ in 0..<8 {
            let scaled = normalized(image, maxDimension: dimension)
            if let data = scaled.jpegData(compressionQuality: q), data.count <= maxBytes {
                return data
            }
            if q > 0.45 {
                q -= 0.15
            } else {
                dimension *= 0.75
            }
        }
        return nil
    }

    /// Beleg für die Ablage (max. 2000 px, ≤ 8 MiB).
    static func attachmentJPEG(_ image: UIImage) -> Data? {
        jpeg(image, maxDimension: 2000, quality: 0.75, maxBytes: Attachment.maxSize)
    }

    /// Bild für die KI-Auswertung auf dem Server (max. 1600 px, Qualität 0.7, ≤ 2 MiB).
    static func scanJPEG(_ image: UIImage) -> Data? {
        jpeg(image, maxDimension: 1600, quality: 0.7, maxBytes: 2 * 1024 * 1024)
    }
}
