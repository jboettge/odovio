#if canImport(UIKit)
import Foundation
import UIKit

/// PDF-Ausgabe der lokalen Berichte (A4; Fahrtenbuch quer). Mehrseitige Tabellen mit wiederholter Kopfzeile,
/// Fusszeile „Fahrzeugbuch · lokal · Seite n“.
extension LocalReports {
    /// Fahrzeugbericht (Übersicht, Tankvorgänge, Wartungen inkl. Material, km-Stände, Änderungen, Integrität).
    static func vehicleReportPDF(store: TenantStore, vehicle: Vehicle, from: Date, to: Date) throws -> URL {
        try pdf(vehicleReportDocument(store: store, vehicle: vehicle, from: from, to: to))
    }

    /// Fahrtenbuch eines Monats (`month` "yyyy-MM") bzw. Zeitraums (`from`/`to`), Querformat.
    static func logbookPDF(store: TenantStore, vehicle: Vehicle, month: String?, from: Date? = nil,
                           to: Date? = nil) throws -> URL {
        try pdf(logbookDocument(store: store, vehicle: vehicle, month: month, from: from, to: to))
    }

    /// Jahresbericht (lokal berechnet).
    static func yearReportPDF(store: TenantStore, vehicle: Vehicle, year: Int) throws -> URL {
        try pdf(yearReportDocument(store: store, vehicle: vehicle, year: year))
    }

    static func pdf(_ doc: ReportDocument) throws -> URL {
        try writeExport(render(doc), name: doc.fileName, ext: "pdf")
    }

    // MARK: Darstellung

    private static let mm: CGFloat = 72 / 25.4

    static func render(_ doc: ReportDocument) -> Data {
        let a4 = CGSize(width: 210 * mm, height: 297 * mm)
        let size = doc.landscape ? CGSize(width: a4.height, height: a4.width) : a4
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: doc.title,
                               kCGPDFContextCreator as String: "Fahrzeugbuch (lokal)"]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size), format: format)
        return renderer.pdfData { ctx in
            var layout = PageLayout(ctx: ctx, size: size, footer: doc.footer)
            layout.newPage()
            layout.text(doc.title, font: .boldSystemFont(ofSize: 16), spacing: 4)
            for line in doc.subtitle { layout.text(line, font: .systemFont(ofSize: 8.5), color: .darkGray, spacing: 1) }
            layout.y += 6
            for block in doc.blocks {
                switch block {
                case .heading(let s):
                    layout.ensure(40)
                    layout.y += 6
                    layout.text(s, font: .boldSystemFont(ofSize: 11), spacing: 3)
                case .paragraph(let s):
                    layout.text(s, font: .systemFont(ofSize: 9), spacing: 3)
                case .small(let s):
                    layout.text(s, font: .systemFont(ofSize: 7.5), color: .darkGray, spacing: 2)
                case .table(let t):
                    layout.table(t)
                }
            }
            layout.finishPage()
        }
    }

    private struct PageLayout {
        let ctx: UIGraphicsPDFRendererContext
        let size: CGSize
        let footer: String
        let margin: CGFloat = 15 * (72 / 25.4)
        let bottom: CGFloat = 18 * (72 / 25.4)
        var y: CGFloat = 0
        var page = 0

        init(ctx: UIGraphicsPDFRendererContext, size: CGSize, footer: String) {
            self.ctx = ctx
            self.size = size
            self.footer = footer
        }

        var width: CGFloat { size.width - 2 * margin }
        var maxY: CGFloat { size.height - bottom }

        mutating func newPage() {
            if page > 0 { finishPage() }
            ctx.beginPage()
            page += 1
            y = margin
        }

        func finishPage() {
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 7.5),
                                                        .foregroundColor: UIColor.gray]
            let text = NSAttributedString(string: "\(footer) · Seite \(page)", attributes: attrs)
            text.draw(at: CGPoint(x: margin, y: size.height - bottom + 8))
        }

        mutating func ensure(_ height: CGFloat) {
            if y + height > maxY { newPage() }
        }

        mutating func text(_ s: String, font: UIFont, color: UIColor = .black, spacing: CGFloat) {
            let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
            let h = ceil(str.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                          options: [.usesLineFragmentOrigin], context: nil).height)
            ensure(min(h, maxY - margin))
            str.draw(with: CGRect(x: margin, y: y, width: width, height: h), options: [.usesLineFragmentOrigin],
                     context: nil)
            y += h + spacing
        }

        mutating func table(_ t: ReportTable) {
            let count = max(t.headers.count, 1)
            let rel = t.widths.count == count ? t.widths : Array(repeating: 1.0, count: count)
            let sum = rel.reduce(0, +)
            let widths = rel.map { CGFloat($0 / (sum > 0 ? sum : 1)) * width }
            let pad: CGFloat = 2.5
            let font = UIFont.systemFont(ofSize: 7.5)
            let bold = UIFont.boldSystemFont(ofSize: 7.5)

            func cells(_ row: [String], _ f: UIFont) -> [NSAttributedString] {
                (0..<count).map { i in
                    NSAttributedString(string: i < row.count ? row[i] : "", attributes: [.font: f])
                }
            }
            func height(_ cs: [NSAttributedString]) -> CGFloat {
                var h: CGFloat = 0
                for (i, c) in cs.enumerated() {
                    let r = c.boundingRect(with: CGSize(width: max(widths[i] - 2 * pad, 4), height: .greatestFiniteMagnitude),
                                           options: [.usesLineFragmentOrigin], context: nil)
                    h = max(h, ceil(r.height))
                }
                return h + 2 * pad
            }
            func draw(_ cs: [NSAttributedString], h: CGFloat, fill: UIColor?) {
                var x = margin
                if let fill {
                    fill.setFill()
                    UIRectFill(CGRect(x: margin, y: y, width: width, height: h))
                }
                UIColor(white: 0.75, alpha: 1).setStroke()
                for (i, c) in cs.enumerated() {
                    let rect = CGRect(x: x, y: y, width: widths[i], height: h)
                    UIBezierPath(rect: rect).stroke()
                    c.draw(with: rect.insetBy(dx: pad, dy: pad), options: [.usesLineFragmentOrigin], context: nil)
                    x += widths[i]
                }
                y += h
            }

            let header = cells(t.headers, bold)
            let headerHeight = height(header)
            ensure(headerHeight * 2)
            draw(header, h: headerHeight, fill: UIColor(white: 0.9, alpha: 1))
            for (n, row) in t.rows.enumerated() {
                let cs = cells(row, t.boldRows.contains(n) ? bold : font)
                let h = min(height(cs), maxY - margin - headerHeight)
                if y + h > maxY {
                    newPage()
                    draw(header, h: headerHeight, fill: UIColor(white: 0.9, alpha: 1))   // Kopfzeile wiederholen
                }
                draw(cs, h: h, fill: t.boldRows.contains(n) ? UIColor(white: 0.96, alpha: 1) : nil)
            }
            y += 4
        }
    }
}
#endif
