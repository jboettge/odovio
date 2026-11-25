import Foundation

/// Jahresbericht ohne Server – gleiche Rechnung wie server/app/tax.py (`year_report`):
/// km je Kategorie, Anteile, Kosten, Privatanteil pauschal/effektiv, Kilometerentschädigung, Arbeitsweg-Abzug.
/// Parameter: `tax_params` (tenant > canton:XX > federal) vor Defaults [A]. Ergebnis im Modell `YearReport`
/// (Schlüssel snake_case; Zugriff über `item(_:)`/`km(_:)` ist unabhängig von der Schreibweise).
enum YearReportCalculator {
    static let noteA = "[A] Default gemäss Konzept Fahrtenbuch, mit Treuhand bestätigen"
    static let disclaimer = "Annahmen gemäss Konzept, mit Treuhand bestätigen. Die Berechnungen sind Hilfsgrössen und "
        + "ersetzen keine Steuerberatung; massgebend sind Spesenreglement, Lohnausweis und kantonale Praxis."

    static let keys = ["km_rate", "commute_rate", "cap_federal", "cap_canton", "private_share_pct",
                       "min_private_month", "vat_rate"]

    static let labels: [String: String] = [
        "km_rate": "Kilometeransatz Geschäftsfahrten (CHF/km)",
        "commute_rate": "Arbeitsweg Privatauto (CHF/km)",
        "cap_federal": "Fahrkostenabzug Obergrenze Bund (CHF)",
        "cap_canton": "Fahrkostenabzug Obergrenze Kanton (CHF)",
        "private_share_pct": "Privatanteil pauschal (% Kaufpreis pro Monat)",
        "min_private_month": "Privatanteil Minimum (CHF pro Monat)",
        "vat_rate": "MWST-Normalsatz (%)",
    ]

    static let sources: [String: String] = [
        "km_rate": "https://www.bexio.com/de-CH/blog/view/kilometergeld-schweiz",
        "commute_rate": "https://www.estv.admin.ch/de/newnsb/VzaAUrhkPx2EPde4a6e3O",
        "cap_federal": "https://www.estv.admin.ch/dam/estv/de/dokumente/estv/steuersystem/steuermaeppchen/"
            + "fahrkosten-de-fr.pdf.download.pdf/fahrkosten-de-fr.pdf",
        "private_share_pct": "https://www.sv.fin.be.ch/content/dam/sv_fin/dokumente/de/"
            + "Frage-Antwort_GESCHÄFTSFAHRZEUG_de_rz_WEBSITE.pdf",
        "min_private_month": "https://www.sv.fin.be.ch/content/dam/sv_fin/dokumente/de/"
            + "Frage-Antwort_GESCHÄFTSFAHRZEUG_de_rz_WEBSITE.pdf",
        "vat_rate": "https://www.weka.ch/themen/finanzen-controlling/steuern/juristische-personen/article/"
            + "berechnung-privatanteil-fahrzeug-mwst-risiken-vermeiden/",
    ]

    /// Defaults (Bund) je Jahr; Jahre ohne Eintrag nehmen das nächstältere (bzw. das älteste) Jahr.
    static let defaults: [Int: [String: Double]] = [
        2025: ["km_rate": 0.75, "commute_rate": 0.70, "cap_federal": 3300, "private_share_pct": 0.9,
               "min_private_month": 150, "vat_rate": 8.1],
        2026: ["km_rate": 0.75, "commute_rate": 0.75, "cap_federal": 3300, "private_share_pct": 0.9,
               "min_private_month": 150, "vat_rate": 8.1],
    ]

    // MARK: Parameter

    static func defaultParam(year: Int, key: String) -> YearReportParam? {
        let years = defaults.keys.sorted()
        guard let first = years.first else { return nil }
        let use = years.filter { $0 <= year }.max() ?? first
        guard let value = defaults[use]?[key] else { return nil }
        let note = use == year ? noteA : "\(noteA); Wert von \(use) übernommen"
        return YearReportParam(key: key, label: labels[key] ?? key, value: value, year: use, scope: "default",
                               sourceUrl: sources[key], note: note)
    }

    /// Kanton aus den Parametern ableiten: genau ein Kanton im Jahr erfasst → dieser.
    static func inferredCanton(_ params: [TaxParam], year: Int) -> String? {
        let cantons = Set(params.filter { !$0.deleted && $0.year == year && $0.scope.hasPrefix("canton:") }
            .map { String($0.scope.dropFirst("canton:".count)).uppercased() })
        return cantons.count == 1 ? cantons.first : nil
    }

    /// Alle Schlüssel für ein Jahr auflösen (tenant > canton:XX > federal > Default). Bei Doppeln gilt die
    /// höhere Version.
    static func resolveParams(_ params: [TaxParam], year: Int, canton: String?) -> [String: YearReportParam] {
        var rank: [String: Int] = ["tenant": 0, "federal": 2]
        if let canton { rank["canton:\(canton.uppercased())"] = 1 }
        var best: [String: (prio: (Int, Int), param: TaxParam)] = [:]
        for p in params where !p.deleted && p.year == year {
            guard let r = rank[p.scope.hasPrefix("canton:") ? "canton:" + p.scope.dropFirst(7).uppercased() : p.scope]
            else { continue }
            let prio = (r, -p.version)
            if let current = best[p.key], !(prio < current.prio) { continue }
            best[p.key] = (prio, p)
        }
        var out: [String: YearReportParam] = [:]
        for key in keys {
            if let b = best[key]?.param {
                out[key] = YearReportParam(key: key, label: labels[key] ?? key, value: b.value, year: b.year,
                                           scope: b.scope, sourceUrl: b.sourceUrl, note: b.note)
            } else if let d = defaultParam(year: year, key: key) {
                out[key] = d
            }
        }
        return out
    }

    // MARK: Bericht

    static func compute(vehicle v: Vehicle, trips allTrips: [Trip], fuel allFuel: [FuelEntry],
                        odometer allOdometer: [OdometerReading], maintenance allMaintenance: [Maintenance],
                        materials: [MaintenanceMaterial], taxParams: [TaxParam], year: Int,
                        canton: String? = nil) -> YearReport {
        let ownership = v.ownership ?? "private"
        let method = v.privateUseMethod ?? "flat"
        let business = ownership == "business"
        let kt = canton ?? inferredCanton(taxParams, year: year)
        let params = resolveParams(taxParams, year: year, canton: kt)
        var warnings: [String] = []
        let r2 = LogbookRules.round2, r1 = LogbookRules.round1
        let dayF = APIClient.dayFormatter
        let yearPrefix = String(format: "%04d-", year)

        let trips = LogbookRules.trips(allTrips, vehicleId: v.id, from: "\(year)-01-01", to: "\(year)-12-31")
        var km: [String: Double] = [:]
        for c in LogbookRules.allCategories { km[c] = 0 }
        for t in trips { km[t.category, default: 0] += LogbookRules.tripKm(t) }
        let total = km.values.reduce(0, +)
        let unconfirmed = trips.filter(LogbookRules.needsReview).count

        let fuel = allFuel.filter { !$0.deleted && $0.vehicleId == v.id && dayF.string(from: $0.date).hasPrefix(yearPrefix) }
        let odometer = allOdometer.filter {
            !$0.deleted && $0.vehicleId == v.id && dayF.string(from: $0.date).hasPrefix(yearPrefix)
        }
        let maintenance = allMaintenance.filter {
            !$0.deleted && $0.vehicleId == v.id && dayF.string(from: $0.date).hasPrefix(yearPrefix)
        }
        var months = Set(trips.map(LogbookRules.localMonth))
        for f in fuel { months.insert(String(dayF.string(from: f.date).prefix(7))) }
        for o in odometer { months.insert(String(dayF.string(from: o.date).prefix(7))) }
        let monthsUsed = months.count

        let byMaintenance = Dictionary(grouping: materials.filter { !$0.deleted }, by: \.maintenanceId)
        let fuelCost = fuel.reduce(0) { $0 + $1.priceTotal }
        let maintCost = maintenance.reduce(0.0) { sum, m in
            sum + StatsCalculator.maintenanceCost(m, materialTotal: MaintenanceMaterial.total(byMaintenance[m.id] ?? []))
        }
        let fixed = v.annualFixedCosts ?? 0
        let costTotal = fuelCost + maintCost + fixed

        func p(_ list: String...) -> [YearReportParam] { list.compactMap { params[$0] } }
        func num(_ d: Double) -> String { LogbookRules.pythonNumber(d) }
        var items: [String: YearReportItem] = [:]

        // Privatanteil pauschal
        let pct = params["private_share_pct"]?.value ?? 0
        let minimum = params["min_private_month"]?.value ?? 0
        var flat: Double?
        var why: String?
        if !business {
            why = "nur für Geschäftsfahrzeuge (ownership business)"
        } else if let price = v.purchasePrice {
            flat = max(pct / 100 * price, minimum) * Double(monthsUsed)
        } else {
            why = "Kaufpreis (purchase_price) fehlt"
        }
        items["private_share_flat"] = YearReportItem(
            label: "Privatanteil pauschal", value: flat.map(r2), applicable: business,
            formula: "max(\(num(pct)) % × Kaufpreis, CHF \(num(minimum))) × \(monthsUsed) Monate mit Nutzung",
            reason: why, params: p("private_share_pct", "min_private_month"))

        // Privatanteil effektiv (zwei Varianten wegen ungeklärter Arbeitsweg-Behandlung)
        for (key, label, cats) in [("private_share_effective", "Privatanteil effektiv", ["private"]),
                                   ("private_share_effective_incl_commute", "Privatanteil effektiv inkl. Arbeitsweg",
                                    ["private", "commute"])] {
            let part = cats.reduce(0) { $0 + (km[$1] ?? 0) }
            let value: Double? = business && total != 0 ? costTotal * part / total : nil
            items[key] = YearReportItem(label: label, value: value.map(r2), applicable: business,
                                        formula: "Kosten Jahr × \(cats.joined(separator: "+"))-km ÷ total-km",
                                        reason: business ? nil : "nur für Geschäftsfahrzeuge (ownership business)")
        }

        // Kilometerentschädigung (Geschäftsfahrten mit Privatauto)
        let rate = params["km_rate"]?.value ?? 0
        items["km_compensation"] = YearReportItem(
            label: "Kilometerentschädigung", value: business ? nil : r2((km["business"] ?? 0) * rate),
            applicable: !business, formula: "geschäftliche km × CHF \(num(rate))/km",
            reason: business ? "nur für Privatfahrzeuge (ownership private)" : nil, params: p("km_rate"))

        // Arbeitsweg-Abzug Bund / Kanton
        let crate = params["commute_rate"]?.value ?? 0
        let raw = (km["commute"] ?? 0) * crate
        let capF = params["cap_federal"]?.value ?? 0
        items["commute_deduction_federal"] = YearReportItem(
            label: "Arbeitsweg-Abzug Bund", value: r2(min(raw, capF)), applicable: true,
            formula: "min(Arbeitsweg-km × CHF \(num(crate))/km, CHF \(num(capF)))", reason: nil,
            params: p("commute_rate", "cap_federal"))
        let capC = params["cap_canton"]
        items["commute_deduction_canton"] = YearReportItem(
            label: "Arbeitsweg-Abzug Kanton", value: capC.flatMap { $0.value }.map { r2(min(raw, $0)) },
            applicable: capC != nil,
            formula: "min(Arbeitsweg-km × CHF \(num(crate))/km, CHF \(capC?.value.map(num) ?? "–"))",
            reason: capC == nil ? "Parameter cap_canton fehlt (tax_param scope canton:XX oder tenant)" : nil,
            params: p("commute_rate", "cap_canton"))

        // Warnungen (Reihenfolge wie Server)
        if trips.isEmpty { warnings.append("Keine Fahrten im Jahr erfasst.") }
        if unconfirmed > 0 {
            warnings.append("\(unconfirmed) Fahrt(en) nicht bestätigt bzw. ohne Kategorie – Zahlen vorläufig.")
        }
        if business && v.purchasePrice == nil {
            warnings.append("Kaufpreis (purchase_price) fehlt – Privatanteil pauschal nicht berechenbar.")
        }
        if v.ownership == nil { warnings.append("Eigentum (ownership) nicht erfasst – als Privatfahrzeug gerechnet.") }
        if business && v.privateUseMethod == nil {
            warnings.append("Methode Privatanteil nicht erfasst – Pauschale angenommen.")
        }
        if v.annualFixedCosts == nil {
            warnings.append("Fixkosten (annual_fixed_costs) fehlen – effektive Kosten unvollständig.")
        }
        if business && total != 0 && method == "flat"
            && ((km["business"] ?? 0) + (km["field"] ?? 0)) / total < 0.5 {
            warnings.append("Geschäftlicher Anteil unter 50 % – Pauschale gemäss Fachquellen ev. nicht zulässig [P].")
        }
        if business && (km["commute"] ?? 0) != 0 {
            warnings.append("Arbeitsweg mit Geschäftsfahrzeug: bei der Pauschale abgegolten (Art. 5a BKV); "
                            + "Behandlung bei effektiver Methode ungeklärt [P].")
        }
        if !business && (km["field"] ?? 0) != 0 {
            warnings.append("Aussendienst-km sind nicht in der Kilometerentschädigung enthalten – mit Treuhand klären.")
        }
        if params.values.contains(where: { $0.scope == "default" }) {
            warnings.append("Teilweise Default-Parameter verwendet [A] – eigene tax_params erfassen/bestätigen.")
        }

        var r = YearReport()
        r.year = year
        r.canton = kt
        r.tripsCount = trips.count
        r.unconfirmed = unconfirmed
        r.monthsUsed = monthsUsed
        var kmOut = km.mapValues(r1)
        kmOut["total"] = r1(total)
        r.km = kmOut
        if total != 0 {
            for c in LogbookRules.allCategories { r.sharesPct[c] = LogbookRules.round((km[c] ?? 0) / total * 100, 1) }
        }
        r.costs = ["fuel": r2(fuelCost), "maintenance": r2(maintCost), "fixed": r2(fixed), "total": r2(costTotal)]
        r.items = items
        r.params = params
        r.warnings = warnings
        r.disclaimer = disclaimer
        r.isLocal = true
        return r
    }

    /// Reihenfolge der Positionen (Anzeige/PDF wie Server)
    static let itemOrder = ["private_share_flat", "private_share_effective", "private_share_effective_incl_commute",
                            "km_compensation", "commute_deduction_federal", "commute_deduction_canton"]
}

extension LogbookRules {
    /// Zahl wie Python `str(float)` für Formeln: 0.75 → "0.75", 150.0 → "150.0", 3300 → "3300.0".
    static func pythonNumber(_ d: Double) -> String {
        if d.rounded() == d && abs(d) < 1e16 { return String(format: "%.1f", d) }
        return "\(d)"
    }
}
