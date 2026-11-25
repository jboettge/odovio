import Foundation

/// Inhalt eines Berichts unabhängig vom Ausgabeformat (PDF-Darstellung: `LocalReportsPDF.swift`, nur iOS).
struct ReportDocument {
    enum Block {
        case heading(String)
        case paragraph(String)
        case small(String)
        case table(ReportTable)
    }

    var title: String
    /// Kopfzeilen unter dem Titel
    var subtitle: [String]
    /// Querformat (Fahrtenbuch)
    var landscape: Bool
    var blocks: [Block]
    /// Fusszeile, ergänzt um „ · Seite n“
    var footer: String
    /// Dateiname ohne Endung (Präfix `Fahrzeugbuch_`)
    var fileName: String

    /// Reiner Text (Vorschau, Tests).
    var plainText: String {
        var out = [title] + subtitle
        for b in blocks {
            switch b {
            case .heading(let s), .paragraph(let s), .small(let s): out.append(s)
            case .table(let t):
                out.append(t.headers.joined(separator: " | "))
                out += t.rows.map { $0.joined(separator: " | ") }
            }
        }
        return out.joined(separator: "\n")
    }
}

/// Tabelle mit relativen Spaltenbreiten; `boldRows` = Summenzeilen.
struct ReportTable {
    var headers: [String]
    var rows: [[String]]
    var widths: [Double]
    var boldRows: Set<Int> = []
}

/// Berichte auf dem Gerät (Lokalmodus bzw. offline): Fahrzeugbericht, Fahrtenbuch, Jahresbericht (PDF) und
/// Fahrten als CSV. Gleicher Aufbau und gleiche Rechnung wie die Server-Berichte; Integritätsvermerk aus dem
/// lokalen Journal (Kettenkopf-Hash). Dateien im temporären Verzeichnis, Präfix `Fahrzeugbuch_`,
/// Dateischutz „complete“.
@MainActor
enum LocalReports {
    static let categoryNames = ["business": "geschäftlich", "private": "privat", "commute": "Arbeitsweg",
                                "field": "Aussendienst", "unknown": "unbekannt"]
    static let statusNames = ["draft": "Entwurf", "suggested": "vorgeschlagen", "confirmed": "bestätigt",
                              "locked": "abgeschlossen"]
    static let sourceNames = ["auto": "automatisch", "manual": "manuell", "gap": "Lücke", "import": "Import"]
    static let actionNames = ["create": "Erfasst", "update": "Geändert", "delete": "Storniert"]
    static let privateText = "privat"

    // MARK: Jahresbericht

    /// Jahresbericht lokal berechnet (wie Server `year_report`).
    static func yearReport(store: TenantStore, vehicle: Vehicle, year: Int) -> YearReport {
        YearReportCalculator.compute(
            vehicle: vehicle, trips: Array(store.trips.values), fuel: Array(store.fuel.values),
            odometer: Array(store.odometer.values), maintenance: Array(store.maintenance.values),
            materials: Array(store.materials.values), taxParams: Array(store.taxParams.values), year: year)
    }

    static func yearReportDocument(store: TenantStore, vehicle v: Vehicle, year: Int) -> ReportDocument {
        let r = yearReport(store: store, vehicle: v, year: year)
        var blocks: [ReportDocument.Block] = []
        let ownership = v.isBusiness ? "Geschäftsfahrzeug" : "Privatfahrzeug"
        blocks.append(.heading("Kilometer je Kategorie"))
        var kmRows: [[String]] = []
        for c in LogbookRules.allCategories {
            kmRows.append([categoryNames[c] ?? c, num(r.km(TripCategory.of(c)), 1),
                           r.share(TripCategory.of(c)).map { num($0, 1) } ?? "–"])
        }
        kmRows.append(["Total", num(r.totalKm, 1), r.totalKm.map { $0 > 0 ? "100.0" : "–" } ?? "–"])
        blocks.append(.table(ReportTable(headers: ["Kategorie", "km", "Anteil %"], rows: kmRows, widths: [50, 30, 30],
                                         boldRows: [kmRows.count - 1])))
        blocks.append(.heading("Kosten"))
        blocks.append(.table(ReportTable(headers: ["Position", "CHF"], rows: [
            ["Treibstoff", num(YearReport.value(r.costs, "fuel"), 2)],
            ["Wartung", num(YearReport.value(r.costs, "maintenance"), 2)],
            ["Fixkosten", num(YearReport.value(r.costs, "fixed"), 2)],
            ["Total", num(YearReport.value(r.costs, "total"), 2)],
        ], widths: [60, 40], boldRows: [3])))
        blocks.append(.heading("Steuerposten"))
        var itemRows: [[String]] = []
        for key in YearReportCalculator.itemOrder {
            guard let it = r.item(key) else { continue }
            let value: String
            if it.applicable == false {
                value = "nicht anwendbar" + (it.reason.map { " – \($0)" } ?? "")
            } else if let v = it.value {
                value = "CHF \(num(v, 2))"
            } else {
                value = "–" + (it.reason.map { " (\($0))" } ?? "")
            }
            itemRows.append([it.label ?? key, value, it.formula ?? ""])
        }
        blocks.append(.table(ReportTable(headers: ["Position", "Wert", "Formel"], rows: itemRows, widths: [45, 55, 80])))
        blocks.append(.heading("Parameter"))
        let paramRows = YearReportCalculator.keys.compactMap { key -> [String]? in
            guard let p = r.params[key] else { return nil }
            return [p.label ?? key, p.value.map { LogbookRules.pythonNumber($0) } ?? "–", TaxParam.scopeLabel(p.scope ?? ""),
                    p.year.map(String.init) ?? "–", p.note ?? ""]
        }
        blocks.append(.table(ReportTable(headers: ["Parameter", "Wert", "Quelle", "Jahr", "Hinweis"], rows: paramRows,
                                         widths: [60, 20, 30, 15, 70])))
        if !r.warnings.isEmpty {
            blocks.append(.heading("Hinweise"))
            for w in r.warnings { blocks.append(.paragraph("• " + w)) }
        }
        blocks += integrityBlocks(store)
        blocks.append(.small(r.disclaimer ?? YearReportCalculator.disclaimer))
        return ReportDocument(
            title: "Jahresbericht \(year) – \(v.name)",
            subtitle: [vehicleHead(v) + "  ·  \(ownership)",
                       "Fahrten: \(r.tripsCount ?? 0)  ·  unbestätigt: \(r.unconfirmed ?? 0)  ·  "
                       + "Monate mit Nutzung: \(r.monthsUsed ?? 0)",
                       "erstellt \(created()) auf diesem Gerät"],
            landscape: false, blocks: blocks, footer: footerText(store),
            fileName: "Fahrzeugbuch_Jahresbericht_\(safe(v.name))_\(year)")
    }

    // MARK: Fahrzeugbericht

    static func vehicleReportDocument(store: TenantStore, vehicle v: Vehicle, from: Date, to: Date) -> ReportDocument {
        let f = APIClient.dayFormatter
        let dFrom = f.string(from: from), dTo = f.string(from: to)
        func inPeriod(_ d: Date) -> Bool { let s = f.string(from: d); return dFrom <= s && s <= dTo }
        let allFuel = store.fuel(for: v.id)
        let allOdo = store.odometer(for: v.id)
        let allMaint = store.maintenance(for: v.id)
        let fuel = allFuel.filter { inPeriod($0.date) }.sorted { ($0.date, $0.km) < ($1.date, $1.km) }
        let odo = allOdo.filter { inPeriod($0.date) }.sorted { ($0.date, $0.km) < ($1.date, $1.km) }
        let maint = allMaint.filter { inPeriod($0.date) }.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        let points = StatsCalculator.consumptionPoints(allFuel).filter { inPeriod($0.date) }
        var perKm: [Int: ConsumptionPoint] = [:]
        for p in points { perKm[p.km] = p }

        func kms(until: String, strict: Bool) -> [Int] {
            func ok(_ d: Date) -> Bool { let s = f.string(from: d); return strict ? s < until : s <= until }
            return allOdo.filter { ok($0.date) }.map(\.km) + allFuel.filter { ok($0.date) }.map(\.km)
                + allMaint.filter { ok($0.date) }.compactMap(\.km)
        }
        let kmStart = ([v.initialKm] + kms(until: dFrom, strict: true)).max() ?? v.initialKm
        let kmEnd = ([kmStart] + kms(until: dTo, strict: false)).max() ?? kmStart
        let dist = Double(points.reduce(0) { $0 + $1.distance })
        let liters = points.reduce(0) { $0 + $1.liters }
        let cost = points.reduce(0) { $0 + $1.cost }
        let fuelCost = fuel.reduce(0) { $0 + $1.priceTotal }
        let maintCost = maint.reduce(0.0) { $0 + StatsCalculator.maintenanceCost($1, materialTotal: store.materialTotal(for: $1.id)) }

        var blocks: [ReportDocument.Block] = [.heading("Übersicht")]
        blocks.append(.table(ReportTable(headers: ["Kennzahl", "Wert"], rows: [
            ["km-Stand Beginn / Ende", "\(km(kmStart)) / \(km(kmEnd)) km"],
            ["Gefahren im Zeitraum", "\(km(kmEnd - kmStart)) km"],
            ["Ø Verbrauch", "\(num(dist > 0 ? liters / dist * 100 : nil, 2)) l/100 km  "
                + "(\(num(dist > 0 ? liters / dist : nil, 3)) l/km)"],
            ["Ø Treibstoffkosten", "CHF \(num(dist > 0 ? cost / dist : nil, 3)) / km"],
            ["Treibstoff", "CHF \(num(fuelCost, 2))  (\(num(fuel.reduce(0) { $0 + $1.liters }, 2)) l)"],
            ["Wartung", "CHF \(num(maintCost, 2))"],
            ["Total", "CHF \(num(fuelCost + maintCost, 2))"],
        ], widths: [60, 110], boldRows: [6])))

        blocks.append(.heading("Tankvorgänge (\(fuel.count))"))
        if fuel.isEmpty {
            blocks.append(.paragraph("Keine Tankvorgänge im Zeitraum."))
        } else {
            blocks.append(.table(ReportTable(
                headers: ["Datum", "km-Stand", "Liter", "Betrag CHF", "CHF/l", "Voll", "l/100 km", "Tankstelle", "Beleg"],
                rows: fuel.map { e in
                    [day(e.date), km(e.km), num(e.liters, 2), num(e.priceTotal, 2), num(e.pricePerLiter, 3),
                     e.fullTank ? "ja" : "nein",
                     e.fullTank ? perKm[e.km].map { num($0.consumption, 2) } ?? "" : "",
                     e.station ?? "", store.attachments(forFuel: e.id).isEmpty ? "" : "ja"]
                }, widths: [20, 20, 16, 20, 15, 11, 18, 38, 12])))
        }

        blocks.append(.heading("Wartungen (\(maint.count))"))
        if maint.isEmpty {
            blocks.append(.paragraph("Keine Wartungen im Zeitraum."))
        } else {
            blocks.append(.table(ReportTable(
                headers: ["Datum", "km-Stand", "Titel", "Kosten CHF", "Nächste", "Checkliste [x] erledigt"],
                rows: maint.map { m in
                    let checklist = store.items(for: m.id).map { "\($0.label) [\($0.done ? "x" : " ")]" }
                        .joined(separator: ", ")
                    let due = [m.nextDueKm.map { "\(km($0)) km" }, m.nextDueDate.map(day)].compactMap { $0 }
                        .joined(separator: " / ")
                    let mats = store.materials(for: m.id)
                    let costText: String
                    if let c = m.cost {
                        costText = num(c, 2)
                    } else if mats.contains(where: { $0.unitPrice != nil }) {
                        costText = "\(num(MaintenanceMaterial.total(mats), 2)) (Material)"
                    } else {
                        costText = "–"
                    }
                    return [day(m.date), m.km.map(km) ?? "–", m.title, costText, due.isEmpty ? "–" : due,
                            checklist + (m.note.map { "\nNotiz: \($0)" } ?? "")]
                }, widths: [20, 18, 28, 18, 22, 64])))
        }

        let withMaterial = maint.filter { !store.materials(for: $0.id).isEmpty }
        if !withMaterial.isEmpty {
            var rows: [[String]] = []
            var bold: Set<Int> = []
            var totalAll = 0.0
            var count = 0
            for m in withMaterial {
                let mats = store.materials(for: m.id)
                count += mats.count
                for (n, x) in mats.enumerated() {
                    rows.append([n == 0 ? "\(day(m.date))\n\(m.title)" : "", x.name, x.partNumber ?? "",
                                 "\(qty(x.quantity)) \(x.unit)", num(x.unitPrice, 2), num(x.lineTotal, 2)])
                }
                let sum = MaintenanceMaterial.total(mats)
                totalAll += sum
                bold.insert(rows.count)
                rows.append(["", "Materialsumme", "", "", "",
                             num(mats.contains { $0.unitPrice != nil } ? sum : nil, 2)])
            }
            if withMaterial.count > 1 {
                bold.insert(rows.count)
                rows.append(["Total Material", "", "", "", "", num(totalAll, 2)])
            }
            blocks.append(.heading("Material (\(count))"))
            blocks.append(.table(ReportTable(headers: ["Wartung", "Material", "Art.-Nr.", "Menge", "Einzelpreis CHF",
                                                       "Total CHF"],
                                             rows: rows, widths: [30, 54, 26, 20, 20, 20], boldRows: bold)))
        }

        blocks.append(.heading("Kilometerstände (\(odo.count))"))
        if odo.isEmpty {
            blocks.append(.paragraph("Keine separaten Kilometerstände im Zeitraum."))
        } else {
            blocks.append(.table(ReportTable(headers: ["Datum", "km-Stand", "Notiz"],
                                             rows: odo.map { [day($0.date), km($0.km), $0.note ?? ""] },
                                             widths: [25, 25, 120])))
        }

        // Änderungsprotokoll (Änderungen/Stornos, keine Erfassungen)
        var ids = Set([v.id])
        for e in store.fuel.values where e.vehicleId == v.id && inPeriod(e.date) { ids.insert(e.id) }
        for e in store.odometer.values where e.vehicleId == v.id && inPeriod(e.date) { ids.insert(e.id) }
        let parents = store.maintenance.values.filter { $0.vehicleId == v.id && inPeriod($0.date) }.map(\.id)
        ids.formUnion(parents)
        let parentSet = Set(parents)
        for i in store.items.values where parentSet.contains(i.maintenanceId) { ids.insert(i.id) }
        for m in store.materials.values where parentSet.contains(m.maintenanceId) { ids.insert(m.id) }
        let fuelIds = ids
        let linked = store.attachments.values.filter { a in
            if let f = a.fuelId, fuelIds.contains(f) { return true }
            if let m = a.maintenanceId, parentSet.contains(m) { return true }
            return false
        }
        ids.formUnion(linked.map(\.id))
        blocks += changeLog(store, ids: ids, entities: nil)
        blocks += integrityBlocks(store)
        return ReportDocument(
            title: "Fahrzeugbuch – \(v.name)",
            subtitle: [vehicleHead(v), "Zeitraum: \(day(from)) – \(day(to))  ·  erstellt \(created()) auf diesem Gerät"],
            landscape: false, blocks: blocks, footer: footerText(store),
            fileName: "Fahrzeugbuch_Bericht_\(safe(v.name))_\(dFrom)_\(dTo)")
    }

    // MARK: Fahrtenbuch

    /// Zeitraum aus `month` ("yyyy-MM") bzw. `from`/`to` (Tage).
    static func period(month: String?, from: Date?, to: Date?) -> (from: String, to: String) {
        if let month, let b = LogbookRules.monthBounds(month) { return (b.first, b.last) }
        let f = APIClient.dayFormatter
        let now = Date()
        let start = from.map { f.string(from: $0) } ?? LogbookRules.currentMonth(now: now) + "-01"
        let end = to.map { f.string(from: $0) } ?? LogbookRules.day(now)
        return (start, max(start, end))
    }

    static func logbookDocument(store: TenantStore, vehicle v: Vehicle, month: String?, from: Date?,
                                to: Date?) -> ReportDocument {
        let range = period(month: month, from: from, to: to)
        let all = Array(store.trips.values)
        let trips = LogbookRules.trips(all, vehicleId: v.id, from: range.from, to: range.to)
        var blocks: [ReportDocument.Block] = [.heading("Fahrten (\(trips.count))")]
        if trips.isEmpty {
            blocks.append(.paragraph("Keine Fahrten im Zeitraum."))
        } else {
            blocks.append(.table(ReportTable(
                headers: ["Datum", "Zeit", "km Beginn", "km Ende", "Distanz", "Start » Ziel", "Kategorie",
                          "Zweck / Kunde", "Fahrer", "Status", "Quelle"],
                rows: trips.map { t in
                    let (start, end) = route(store, t)
                    var purpose = purposeText(store, t)
                    if let note = t.note?.nilIfEmpty, !t.privateMode {
                        purpose = purpose.isEmpty ? "Notiz: \(note)" : "\(purpose)\nNotiz: \(note)"
                    }
                    return [localDayText(t.startAt), timeRange(t), t.kmStart.map(km) ?? "–", t.kmEnd.map(km) ?? "–",
                            num(LogbookRules.tripKm(t), 1), "\(start) » \(end)", categoryNames[t.category] ?? t.category,
                            purpose, t.driverName ?? String((t.driverSub ?? "–").prefix(20)),
                            statusNames[t.status] ?? t.status, sourceNames[t.source] ?? t.source]
                }, widths: [18, 22, 17, 17, 14, 55, 20, 52, 18, 18, 16])))
        }

        // Summen je Kategorie
        let kms = LogbookRules.kmByCategory(trips)
        let total = kms.values.reduce(0, +)
        var rows: [[String]] = []
        for c in LogbookRules.allCategories {
            let count = trips.filter { $0.category == c }.count
            guard count > 0 || c != "unknown" else { continue }
            rows.append([categoryNames[c] ?? c, String(count), num(kms[c] ?? 0, 1),
                         total > 0 ? num((kms[c] ?? 0) / total * 100, 1) : "–"])
        }
        rows.append(["Total", String(trips.count), num(total, 1), total > 0 ? "100.0" : "–"])
        blocks.append(.heading("Summen je Kategorie"))
        blocks.append(.table(ReportTable(headers: ["Kategorie", "Fahrten", "km", "Anteil %"], rows: rows,
                                         widths: [40, 25, 30, 25], boldRows: [rows.count - 1])))

        // Lücken
        let previous = LogbookRules.previousTrip(all, vehicleId: v.id, before: range.from)
        let gaps = LogbookRules.gaps(trips, previous: previous)
        var byId = Dictionary(trips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if let previous { byId[previous.id] = previous }
        blocks.append(.heading("Lücken in der km-Kette (\(gaps.count))"))
        if gaps.isEmpty {
            blocks.append(.paragraph("Keine Lücken (km-Ende jeder Fahrt = km-Beginn der nächsten)."))
        } else {
            blocks.append(.table(ReportTable(
                headers: ["nach Fahrt", "vor Fahrt", "km von", "km bis", "Differenz km"],
                rows: gaps.map { g in
                    [g.afterTripId.flatMap { byId[$0] }.map { localDayText($0.startAt) } ?? "–",
                     g.beforeTripId.flatMap { byId[$0] }.map { localDayText($0.startAt) } ?? "–",
                     km(g.kmFrom), km(g.kmTo), km(g.km)]
                }, widths: [35, 35, 30, 30, 30])))
        }

        // Odometer-Abgleich je Monat
        let readings = store.odometerReadings(vehicleId: v.id)
        var odoRows: [[String]] = []
        for m in LogbookRules.months(from: range.from, to: range.to) {
            guard let b = LogbookRules.monthBounds(m) else { continue }
            let mTrips = trips.filter { LogbookRules.localMonth($0) == m }
            let chk = LogbookRules.odometerCheck(readings: readings, trips: mTrips, first: max(b.first, range.from),
                                                 last: min(b.last, range.to))
            let result: String
            switch chk.ok {
            case .some(true): result = "ok"
            case .some(false): result = "ABWEICHUNG"
            case .none: result = chk.note ?? "–"
            }
            odoRows.append([m, num(chk.tripKm, 1), chk.odometerKm.map { km(Int($0)) } ?? "–",
                            chk.diffKm.map { num($0, 1) } ?? "–", result])
        }
        blocks.append(.heading("Abgleich mit km-Ständen (Odometer, Tank, Wartung)"))
        blocks.append(.table(ReportTable(headers: ["Monat", "Fahrten-km", "km-Stände", "Differenz",
                                                   "Ergebnis (Toleranz max. 5 km / 2 %)"],
                                         rows: odoRows, widths: [25, 30, 30, 25, 100])))

        // Monatsabschluss
        var periodRows: [[String]] = []
        for m in LogbookRules.months(from: range.from, to: range.to) {
            guard let p = store.period(vehicleId: v.id, month: m) else {
                periodRows.append([m, "offen", "–", "–", "Nicht abgeschlossen: Einträge können noch geändert werden."])
                continue
            }
            var remark = "lokal abgeschlossen (Journal)"
            if let note = p.note { remark += "\n\(note)" }
            if let c = p.corrections, c > 0 { remark += "\nKorrekturen nach Abschluss: \(c)" }
            periodRows.append([m, "abgeschlossen", p.closedBy ?? "–",
                               String((p.closedAt ?? "").prefix(19)).replacingOccurrences(of: "T", with: " "), remark])
        }
        blocks.append(.heading("Monatsabschluss"))
        blocks.append(.table(ReportTable(headers: ["Monat", "Status", "durch", "am (UTC)", "Bemerkung"],
                                         rows: periodRows, widths: [20, 25, 35, 32, 150])))

        // Änderungsprotokoll der Fahrten
        let tripIds = Set(store.trips.values.filter { t in
            guard t.vehicleId == v.id, let d = LogbookRules.localDay(t.startAt) else { return false }
            return range.from <= d && d <= range.to
        }.map(\.id))
        blocks += changeLog(store, ids: tripIds, entities: [Trip.entityName], title: "Änderungsprotokoll Fahrten")
        blocks += integrityBlocks(store)
        blocks.append(.heading("Hinweis"))
        blocks.append(.small(YearReportCalculator.disclaimer))
        blocks.append(.small("Massgebend sind die km-Stände (Tacho); GPS-/Routendistanzen dienen nur der Kontrolle. "
                             + "Private Fahrten im Privatmodus enthalten keine Orte."))
        let label = month ?? "\(range.from)_\(range.to)"
        return ReportDocument(
            title: "Fahrtenbuch – \(v.name)",
            subtitle: [vehicleHead(v),
                       "Zeitraum: \(dayText(range.from)) – \(dayText(range.to))  ·  erstellt \(created()) auf diesem Gerät"],
            landscape: true, blocks: blocks, footer: footerText(store),
            fileName: "Fahrzeugbuch_Fahrtenbuch_\(safe(v.name))_\(label)")
    }

    // MARK: CSV

    /// Fahrten als CSV (Semikolon, UTF-8 mit BOM, CRLF, Formelschutz) – Spalten wie Server.
    static func tripsCSVData(store: TenantStore, vehicle v: Vehicle, from: Date, to: Date) -> Data {
        let f = APIClient.dayFormatter
        let trips = LogbookRules.trips(Array(store.trips.values), vehicleId: v.id, from: f.string(from: from),
                                       to: f.string(from: to))
        var lines = [row(["Datum", "Start", "Ende", "km Beginn", "km Ende", "Distanz km", "Startort", "Zielort",
                          "Kategorie", "Zweck", "Kunde", "Fahrer", "Status", "Quelle", "Notiz", "Fahrzeug",
                          "Kennzeichen", "ID"])]
        for t in trips {
            let hide = t.privateMode
            let (start, end) = route(store, t)
            let s = t.startDate, e = t.endDate
            let endText: String
            if let e, let s {
                endText = zurich("dd.MM.yyyy", e) != zurich("dd.MM.yyyy", s) ? zurich("dd.MM.yyyy HH:mm", e)
                    : zurich("HH:mm", e)
            } else {
                endText = ""
            }
            lines.append(row([
                s.map { zurich("dd.MM.yyyy", $0) } ?? "", s.map { zurich("HH:mm", $0) } ?? "", endText,
                t.kmStart.map(String.init) ?? "", t.kmEnd.map(String.init) ?? "",
                String(format: "%.1f", LogbookRules.tripKm(t)),
                cell(start), cell(end), categoryNames[t.category] ?? t.category,
                hide ? privateText : cell(t.purpose), hide ? "" : cell(customerText(store, t)),
                cell(t.driverName ?? t.driverSub), statusNames[t.status] ?? t.status, sourceNames[t.source] ?? t.source,
                hide ? "" : cell(t.note), cell(v.name), cell(v.plate), t.id,
            ]))
        }
        return Data(("\u{FEFF}" + lines.joined()).utf8)
    }

    static func tripsCSV(store: TenantStore, vehicle v: Vehicle, from: Date, to: Date) throws -> URL {
        let f = APIClient.dayFormatter
        return try writeExport(tripsCSVData(store: store, vehicle: v, from: from, to: to),
                               name: "Fahrzeugbuch_Fahrten_\(safe(v.name))_\(f.string(from: from))_\(f.string(from: to))",
                               ext: "csv")
    }

    /// Keine Formel-Injektion in Tabellenprogrammen (=, +, -, @, Tab, CR am Anfang von Text).
    static func cell(_ value: String?) -> String {
        guard let s = value else { return "" }
        guard let first = s.unicodeScalars.first else { return s }
        return ["=", "+", "-", "@", "\t", "\r"].contains(String(first)) ? "'" + s : s
    }

    /// CSV-Zeile (Semikolon, Quoting bei ; " CR/LF wie Python `csv`, CRLF).
    static func row(_ fields: [String]) -> String {
        fields.map { field -> String in
            if field.contains(";") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
                return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return field
        }.joined(separator: ";") + "\r\n"
    }

    // MARK: Dateien

    /// Exportdatei im temporären Verzeichnis (Dateischutz „complete“).
    static func writeExport(_ data: Data, name: String, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(name).\(ext)")
        try data.write(to: url, options: StoreFiles.exportOptions)
        return url
    }

    static func safe(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let text = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return text.isEmpty ? "Fahrzeug" : String(text.prefix(40))
    }

    // MARK: Bausteine

    static func integrityBlocks(_ store: TenantStore) -> [ReportDocument.Block] {
        var out: [ReportDocument.Block] = [.heading("Integrität")]
        if store.isLocal {
            let i = store.verifyLocalJournal()
            out.append(.paragraph(i.summary))
            if !i.headHash.isEmpty { out.append(.small("Kettenkopf (SHA-256): \(i.headHash)")) }
            out.append(.small("Erstellt aus dem lokalen Datenstand dieses Geräts (Lokalmodus). Jede Änderung ist im "
                              + "lokalen Journal mit SHA-256-Kette protokolliert; es gibt keinen signierten Server-Anker."))
        } else {
            out.append(.paragraph("Auf dem Gerät aus dem zuletzt synchronisierten Stand erstellt (offline) – nicht "
                                  + "vom Server geprüft. Massgebend ist der Bericht des Servers."))
        }
        return out
    }

    static func changeLog(_ store: TenantStore, ids: Set<String>, entities: Set<String>?,
                          title: String = "Änderungsprotokoll") -> [ReportDocument.Block] {
        guard let journal = store.localJournal else { return [] }
        let list = journal.entries.filter { e in
            ids.contains(e.entityId) && e.action != "create" && (entities?.contains(e.entity) ?? true)
        }
        var out: [ReportDocument.Block] = [.heading("\(title) (\(list.count))")]
        if list.isEmpty {
            out.append(.paragraph("Keine nachträglichen Änderungen oder Stornierungen."))
        } else {
            out.append(.table(ReportTable(
                headers: ["Seq", "Zeitpunkt (UTC)", "Benutzer", "Aktion", "Objekt", "Begründung"],
                rows: list.map { e in
                    [String(e.seq), String(e.at.prefix(19)).replacingOccurrences(of: "T", with: " "),
                     e.actor ?? LocalIdentity.actorName, actionNames[e.action] ?? e.action,
                     "\(TenantStore.entityLabel(e.entity)) v\(e.version)", e.reason ?? ""]
                }, widths: [12, 30, 22, 22, 30, 70])))
        }
        return out
    }

    static func route(_ store: TenantStore, _ t: Trip) -> (String, String) {
        if t.privateMode { return (privateText, privateText) }
        func place(_ label: String?, _ id: String?) -> String {
            if let l = label?.nilIfEmpty { return l }
            return id.flatMap { store.place(id: $0)?.name } ?? "–"
        }
        return (place(t.startLabel, t.startPlaceId), place(t.endLabel, t.endPlaceId))
    }

    static func customerText(_ store: TenantStore, _ t: Trip) -> String {
        if let frozen = t.customerName?.nilIfEmpty { return frozen }
        return t.customerId.flatMap { store.customer(id: $0) }.map(LogbookRules.customerDisplay) ?? ""
    }

    static func purposeText(_ store: TenantStore, _ t: Trip) -> String {
        if t.privateMode { return privateText }
        return [t.purpose?.nilIfEmpty, customerText(store, t).nilIfEmpty].compactMap { $0 }.joined(separator: " · ")
    }

    static func timeRange(_ t: Trip) -> String {
        guard let s = t.startDate else { return "–" }
        guard let e = t.endDate else { return "\(zurich("HH:mm", s))–?" }
        if zurich("yyyy-MM-dd", s) == zurich("yyyy-MM-dd", e) { return "\(zurich("HH:mm", s))–\(zurich("HH:mm", e))" }
        return "\(zurich("HH:mm", s))–\(zurich("dd.MM. HH:mm", e))"
    }

    static func vehicleHead(_ v: Vehicle) -> String {
        let car = [v.make, v.model].compactMap { $0?.nilIfEmpty }.joined(separator: " ")
        let own = v.isBusiness ? "Geschäftsfahrzeug" : "Privatfahrzeug"
        let method = v.isBusiness ? (v.privateUseMethod == "effective" ? "Privatanteil effektiv (Fahrtenbuch)"
                                     : "Privatanteil pauschal (0.9 %/Monat)") : "–"
        return (car.isEmpty ? "" : car + "  ·  ") + "Kennzeichen: \(v.plate?.nilIfEmpty ?? "–")  ·  Lokales Fahrzeugbuch  ·  "
            + "\(own)  ·  Methode: \(method)"
    }

    static func footerText(_ store: TenantStore) -> String {
        store.isLocal ? "Fahrzeugbuch · lokal" : "Fahrzeugbuch · \(store.tenant.slug) · auf dem Gerät erstellt"
    }

    // MARK: Formatierung (wie Server: Tausender mit Apostroph)

    static func num(_ v: Double?, _ digits: Int) -> String {
        guard let v, v.isFinite else { return "–" }
        let text = String(format: "%.\(digits)f", LogbookRules.round(v, digits))
        let negative = text.hasPrefix("-")
        let body = negative ? String(text.dropFirst()) : text
        let parts = body.split(separator: ".", maxSplits: 1)
        let grouped = group(String(parts[0]))
        return (negative ? "-" : "") + grouped + (parts.count > 1 ? "." + parts[1] : "")
    }

    static func km(_ v: Int) -> String {
        (v < 0 ? "-" : "") + group(String(abs(v)))
    }

    static func qty(_ v: Double) -> String {
        var s = num(v, 3)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    private static func group(_ digits: String) -> String {
        var out = ""
        for (n, c) in digits.reversed().enumerated() {
            if n > 0 && n % 3 == 0 { out.append("'") }
            out.append(c)
        }
        return String(out.reversed())
    }

    static func day(_ d: Date) -> String { dayText(APIClient.dayFormatter.string(from: d)) }

    /// "yyyy-MM-dd" → "dd.MM.yyyy"
    static func dayText(_ iso: String) -> String {
        let p = iso.prefix(10).split(separator: "-")
        guard p.count == 3 else { return String(iso) }
        return "\(p[2]).\(p[1]).\(p[0])"
    }

    static func localDayText(_ iso: String) -> String { LogbookRules.localDay(iso).map(dayText) ?? "–" }

    static func created() -> String { zurich("dd.MM.yyyy HH:mm", Date()) }

    static func zurich(_ format: String, _ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_CH")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = LogbookRules.timeZone
        f.dateFormat = format
        return f.string(from: date)
    }
}
