#if DEBUG
import SwiftUI

/// Nur Debug-Builds: Start mit `-demo [-screen <name>]` zeigt Beispieldaten ohne Server/Login
/// (für Screenshots im Simulator, siehe .github/workflows/fahrzeugbuch-screenshots.yml).
enum Demo {
    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains("-demo") }

    static var screen: String {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-screen"), i + 1 < args.count else { return "list" }
        return args[i + 1]
    }

    static let vehicleId = "11111111-1111-4111-8111-111111111111"
    static let serviceId = "22222222-2222-4222-8222-222222222222"
    static let busId = "33333333-3333-4333-8333-333333333333"

    static func articleId(_ n: Int) -> String { String(format: "dddddddd-dddd-4ddd-8ddd-%012ld", n) }
    static func tripId(_ n: Int) -> String { String(format: "eeeeeeee-eeee-4eee-8eee-%012ld", n) }
    static func placeId(_ n: Int) -> String { String(format: "ffffffff-ffff-4fff-8fff-%012ld", n) }
    static func customerId(_ n: Int) -> String { String(format: "abababab-abab-4bab-8bab-%012ld", n) }
    static func ruleId(_ n: Int) -> String { String(format: "cdcdcdcd-cdcd-4dcd-8dcd-%012ld", n) }
    static func taxId(_ n: Int) -> String { String(format: "efefefef-efef-4fef-8fef-%012ld", n) }

    @MainActor
    static func setUp(_ settings: AppSettings) {
        settings.serverURL = "https://fahrzeugbuch.j-mb.net"
        settings.auth.demoLogin(name: "jakob")
        let templates = [
            ChecklistTemplate(title: "Service", items: ["Motoröl gewechselt", "Ölfilter gewechselt",
                                                        "Luftfilter geprüft/gewechselt", "Bremsflüssigkeit geprüft"]),
            ChecklistTemplate(title: "Reifenwechsel", items: ["Räder gewechselt", "Reifendruck eingestellt"]),
            ChecklistTemplate(title: "MFK-Vorbereitung", items: ["Beleuchtung & Blinker", "Bremsen"]),
        ]
        UserDefaults.standard.set(try? JSONEncoder().encode(templates), forKey: "checklistTemplates")
        settings.demoTenants([TenantInfo(slug: "privat", role: "write"), TenantInfo(slug: "b-re.ch", role: "read")])
    }

    static func day(_ s: String) -> Date { APIClient.dayFormatter.date(from: s)! }

    @MainActor
    static func seed(_ store: TenantStore) {
        var octavia = Vehicle(id: vehicleId, version: 3, name: "Skoda Octavia", make: "Skoda",
                              model: "Octavia Combi 2.0 TSI", plate: "ZH 123 456", initialKm: 48000)
        octavia.ownership = "business"
        octavia.privateUseMethod = "flat"
        octavia.purchasePrice = 38_500
        octavia.annualFixedCosts = 2_400
        let bus = Vehicle(id: busId, version: 1, name: "VW California",
                          make: "VW", model: "T6.1 Ocean", plate: "ZH 98 765", fuelType: "diesel", initialKm: 71200)
        let fuel: [(String, Int, Double, Double, Bool, String)] = [
            ("2026-01-05", 48520, 45.2, 79.50, true, "Migrol Zürich"),
            ("2026-01-28", 49150, 41.3, 72.10, true, "Coop Pronto Wallisellen"),
            ("2026-02-15", 49480, 20.0, 35.60, false, "Shell Dübendorf"),
            ("2026-03-02", 49890, 26.5, 47.00, true, "Avia Uster"),
            ("2026-04-10", 50600, 44.8, 80.20, true, "Migrol Zürich"),
            ("2026-06-01", 51320, 46.1, 83.40, true, "BP Chur"),
            ("2026-08-14", 52080, 47.9, 84.90, true, "Agrola Thusis"),
            ("2026-10-30", 52790, 44.0, 78.30, true, "Migrol Zürich"),
        ]
        var fuelEntries: [FuelEntry] = fuel.enumerated().map { n, f in
            FuelEntry(id: String(format: "44444444-4444-4444-8444-%012ld", n), version: 1, vehicleId: vehicleId,
                      date: day(f.0), km: f.1, liters: f.2, priceTotal: f.3, fullTank: f.4, station: f.5)
        }
        let pendingFuel = FuelEntry(id: "55555555-5555-4555-8555-555555555555", vehicleId: vehicleId,
                                    date: day("2026-11-24"), km: 53410, liters: 43.6, priceTotal: 77.80,
                                    station: "Tamoil Landquart")
        fuelEntries.append(pendingFuel)

        let maintenance = [
            Maintenance(id: serviceId, version: 2, vehicleId: vehicleId, date: day("2026-03-20"), km: 50100,
                        title: "Service 50'000", cost: 420.50, note: "Garage Muster AG, Uster",
                        nextDueKm: 65000, nextDueDate: day("2027-03-20")),
            Maintenance(id: "66666666-6666-4666-8666-666666666666", version: 1, vehicleId: vehicleId,
                        date: day("2026-10-25"), km: 52750, title: "Reifenwechsel", cost: 80,
                        nextDueDate: day("2027-04-15")),
            Maintenance(id: "77777777-7777-4777-8777-777777777777", version: 1, vehicleId: vehicleId,
                        date: day("2022-11-10"), km: 31000, title: "MFK", nextDueDate: day("2026-11-10")),
        ]
        let labels = [("Motoröl gewechselt", true), ("Ölfilter gewechselt", true),
                      ("Luftfilter geprüft/gewechselt", true), ("Innenraumfilter gewechselt", false),
                      ("Bremsflüssigkeit geprüft", true), ("Batterie geprüft", false)]
        var items = labels.enumerated().map { n, l in
            MaintenanceItem(id: String(format: "88888888-8888-4888-8888-%012ld", n), version: 1,
                            maintenanceId: serviceId, label: l.0, done: l.1, position: n)
        }
        items += [("Räder gewechselt", true), ("Reifendruck eingestellt", true)].enumerated().map { n, l in
            MaintenanceItem(id: String(format: "99999999-9999-4999-8999-%012ld", n), version: 1,
                            maintenanceId: "66666666-6666-4666-8666-666666666666", label: l.0, done: l.1, position: n)
        }
        let parts: [(String, String?, Double, String, Double)] = [
            ("Motoröl 5W-30", nil, 4.5, "l", 14.90),
            ("Ölfilter", "W 712/95", 1, "Stk", 18.50),
            ("Luftfilter", nil, 1, "Stk", 32.00),
        ]
        // Positionen 0–2 stammen aus den Stammartikeln 0–2 (Werte = Kopie zum Erfassungszeitpunkt)
        let materials = parts.enumerated().map { n, p in
            MaintenanceMaterial(id: String(format: "cccccccc-cccc-4ccc-8ccc-%012ld", n), version: 1,
                                maintenanceId: serviceId, name: p.0, partNumber: p.1, quantity: p.2,
                                unit: p.3, unitPrice: p.4, position: n, articleId: articleId(n))
        }
        // Materialstamm: Name, Art.-Nr., Einheit, Preis, Kategorie, Fahrzeug (nil = alle)
        let catalog: [(String, String?, String, Double?, String, String?)] = [
            ("Motoröl 5W-30", nil, "l", 14.90, "Öl", nil),
            ("Ölfilter", "W 712/95", "Stk", 18.50, "Filter", vehicleId),
            ("Luftfilter", nil, "Stk", 32.00, "Filter", vehicleId),
            ("Innenraumfilter", "CUK 2939", "Stk", 27.80, "Filter", nil),
            ("Bremsflüssigkeit DOT 4", nil, "l", 12.50, "Flüssigkeiten", nil),
            ("Kühlmittel G13", nil, "l", 9.90, "Flüssigkeiten", nil),
            ("Scheibenwischer vorne", "A 297S", "Set", 39.90, "Sonstiges", nil),
            ("Glühbirne H7", "H7 12V 55W", "Stk", 8.90, "Elektrik", nil),
            ("Bremsbeläge vorne", nil, "Set", 89.00, "Bremsen", busId),
            ("Winterreifen 205/55 R16", nil, "Stk", 145.00, "Reifen", nil),
        ]
        let articles = catalog.enumerated().map { n, a in
            MaterialArticle(id: articleId(n), version: 1, name: a.0, partNumber: a.1, unit: a.2,
                            unitPrice: a.3, category: a.4, vehicleId: a.5)
        }
        let odometer = [
            OdometerReading(id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", version: 1, vehicleId: vehicleId,
                            date: day("2026-07-01"), km: 51700, note: "Ferienbeginn"),
            OdometerReading(id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", version: 1, vehicleId: vehicleId,
                            date: day("2026-07-21"), km: 52010, note: "Ferienende"),
        ]
        store.demoSeed(vehicles: [octavia, bus], odometer: odometer, fuel: fuelEntries,
                       maintenance: maintenance, items: items, materials: materials, articles: articles,
                       pending: [pendingFuel])
        seedTrips(store)
    }

    /// Lokale Zeit eines Tages als ISO-8601 mit Offset (unabhängig von der Zeitzone des Simulators).
    static func at(_ dayString: String, _ hour: Int, _ minute: Int) -> String {
        let d = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day(dayString)) ?? day(dayString)
        return Trip.isoString(d)
    }

    /// Fahrtenbuch: Orte, Kunden, Regeln, ~12 Fahrten über 2 Wochen, Lücke 12 km, abgeschlossener Vormonat.
    @MainActor
    static func seedTrips(_ store: TenantStore) {
        let home = placeId(0), office = placeId(1), meier = placeId(2), garage = placeId(3)
        let meierAG = customerId(0), huber = customerId(1)
        let places = [
            Place(id: home, version: 1, name: "Wohnort", kind: "home", lat: 47.3601, lon: 8.5301, radiusM: 150),
            Place(id: office, version: 1, name: "Büro b-re.ch", kind: "work", lat: 47.377, lon: 8.540, radiusM: 200,
                  defaultCategory: "business"),
            Place(id: meier, version: 1, name: "Meier AG", kind: "customer", lat: 47.421, lon: 8.602, radiusM: 150,
                  customerId: meierAG, defaultCategory: "business"),
            Place(id: garage, version: 1, name: "Garage Muster AG", kind: "other", lat: 47.347, lon: 8.721,
                  radiusM: 100),
        ]
        let customers = [
            Customer(id: meierAG, version: 1, name: "Meier AG", ref: "K-1001", note: "Heizungssanierung Uster"),
            Customer(id: huber, version: 1, name: "Huber Treuhand GmbH", ref: "K-1002"),
        ]
        let rules = [
            PurposeRule(id: ruleId(0), version: 1, priority: 10, fromPlaceId: home, toPlaceId: office,
                        weekdays: "1,2,3,4,5", timeFrom: "06:00", timeTo: "09:30", resultCategory: "commute",
                        resultPurpose: "Arbeitsweg"),
            PurposeRule(id: ruleId(1), version: 1, priority: 200, toPlaceId: meier, resultCategory: "business",
                        resultPurpose: "Kundentermin Meier AG", resultCustomerId: meierAG, origin: "learned"),
        ]
        let taxParams = [
            TaxParam(id: taxId(0), version: 1, year: 2026, scope: "tenant", key: "km_rate", value: 0.75,
                     note: "Spesenreglement b-re.ch"),
            TaxParam(id: taxId(1), version: 1, year: 2026, scope: "federal", key: "commute_rate", value: 0.75),
            TaxParam(id: taxId(2), version: 1, year: 2026, scope: "federal", key: "cap_federal", value: 3300),
            TaxParam(id: taxId(3), version: 1, year: 2026, scope: "canton:ZH", key: "cap_canton", value: 5000,
                     note: "Annahme – prüfen"),
        ]

        func trip(_ n: Int, _ dayString: String, _ start: (Int, Int), _ end: (Int, Int), _ km0: Int, _ km1: Int,
                  from: String?, to: String?, category: String, status: String,
                  purpose: String? = nil, customer: String? = nil, source: String = "auto") -> Trip {
            var t = Trip(id: tripId(n), version: 1, vehicleId: vehicleId, startAt: at(dayString, start.0, start.1))
            t.endAt = at(dayString, end.0, end.1)
            t.kmStart = km0
            t.kmEnd = km1
            t.distanceGps = Double(km1 - km0) * 0.98
            t.startPlaceId = from
            t.endPlaceId = to
            t.category = category
            t.status = status
            t.purpose = purpose
            t.customerId = customer
            t.source = source
            t.driverName = "jakob"
            return t
        }

        var trips: [Trip] = [
            trip(0, "2026-11-11", (7, 40), (8, 2), 53100, 53118, from: home, to: office,
                 category: "commute", status: "confirmed", purpose: "Arbeitsweg"),
            trip(1, "2026-11-11", (17, 30), (17, 52), 53118, 53136, from: office, to: home,
                 category: "commute", status: "confirmed", purpose: "Arbeitsweg"),
            trip(2, "2026-11-12", (7, 42), (8, 5), 53136, 53154, from: home, to: office,
                 category: "commute", status: "confirmed", purpose: "Arbeitsweg"),
            trip(3, "2026-11-12", (12, 10), (12, 45), 53154, 53185, from: office, to: meier,
                 category: "business", status: "confirmed", purpose: "Offerte Heizungssanierung", customer: meierAG),
            trip(4, "2026-11-12", (14, 30), (15, 5), 53185, 53216, from: meier, to: office,
                 category: "business", status: "confirmed", purpose: "Offerte Heizungssanierung", customer: meierAG),
            trip(6, "2026-11-16", (7, 41), (8, 3), 53264, 53282, from: home, to: office,
                 category: "commute", status: "confirmed", purpose: "Arbeitsweg"),
            // Lücke 53'282 → 53'294 (12 km): Heimfahrt am 16.11. fehlt
            trip(7, "2026-11-17", (7, 40), (8, 1), 53294, 53312, from: home, to: office,
                 category: "commute", status: "confirmed", purpose: "Arbeitsweg"),
            trip(8, "2026-11-19", (9, 15), (9, 50), 53312, 53340, from: home, to: garage,
                 category: "unknown", status: "draft", source: "manual"),
        ]

        // Privatfahrt im Privatmodus: nur Zeit und km
        var privateTrip = trip(5, "2026-11-14", (10, 0), (11, 20), 53216, 53264, from: nil, to: nil,
                               category: "private", status: "confirmed")
        privateTrip.privateMode = true
        privateTrip.distanceGps = nil
        trips.append(privateTrip)

        // Drei Vorschläge (Regel, Kalender, Regel)
        var s1 = trip(9, "2026-11-23", (7, 42), (8, 5), 53340, 53358, from: home, to: office,
                      category: "unknown", status: "suggested")
        s1.suggestionCategory = "commute"
        s1.suggestionPurpose = "Arbeitsweg"
        s1.suggestionConfidence = 0.95
        s1.suggestionReason = "Regel «Mo–Fr Wohnort → Büro»"
        s1.suggestionSource = "rule"
        var s2 = trip(10, "2026-11-23", (12, 10), (12, 48), 53358, 53389, from: office, to: meier,
                      category: "unknown", status: "suggested")
        s2.suggestionCategory = "business"
        s2.suggestionPurpose = "Meier Offerte"
        s2.suggestionCustomerId = meierAG
        s2.suggestionConfidence = 0.8
        s2.suggestionReason = "Kalendertermin «Meier Offerte» 12:30 in Uster"
        s2.suggestionSource = "calendar"
        var s3 = trip(11, "2026-11-24", (7, 40), (8, 2), 53389, 53407, from: home, to: office,
                      category: "unknown", status: "suggested")
        s3.suggestionCategory = "commute"
        s3.suggestionPurpose = "Arbeitsweg"
        s3.suggestionConfidence = 0.95
        s3.suggestionReason = "Regel «Mo–Fr Wohnort → Büro»"
        s3.suggestionSource = "rule"
        trips += [s1, s2, s3]

        let october = TripPeriod(id: "12121212-1212-4212-8212-121212121212", version: 1, vehicleId: vehicleId,
                                 month: "2026-10", status: "closed", closedBy: "jakob",
                                 closedAt: at("2026-11-03", 9, 12), anchorSeq: 412, kmStart: 52700, kmEnd: 53100,
                                 tripsCount: 38, businessKm: 120, privateKm: 140, commuteKm: 140, fieldKm: 0)
        store.demoSeedTrips(trips: trips, places: places, customers: customers, rules: rules,
                            taxParams: taxParams, periods: [october])
    }
}

/// Zeigt einen einzelnen Screen für Screenshots.
struct DemoScreen: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if let store = settings.store, let v = store.vehicle(id: Demo.vehicleId) {
            Group {
                switch Demo.screen {
                case "overview": NavigationStack { VehicleDetailView(vehicle: v, pane: .overview) }
                case "fuel": NavigationStack { VehicleDetailView(vehicle: v, pane: .fuel) }
                case "maintenance": NavigationStack { VehicleDetailView(vehicle: v, pane: .maintenance) }
                case "odometer": NavigationStack { VehicleDetailView(vehicle: v, pane: .odometer) }
                case "maintenance-detail":
                    NavigationStack { MaintenanceDetailView(maintenanceId: Demo.serviceId, vehicle: v) }
                case "fuel-form": FuelFormView(vehicle: v, entry: nil)
                case "maintenance-form": MaintenanceFormView(vehicle: v, maintenance: nil)
                case "maintenance-edit":
                    MaintenanceFormView(vehicle: v, maintenance: store.maintenance(id: Demo.serviceId))
                case "report": ReportView(vehicle: v)
                case "settings": NavigationStack { SettingsView() }
                case "catalog": NavigationStack { MaterialCatalogView() }
                case "trips": NavigationStack { VehicleDetailView(vehicle: v, pane: .trips) }
                case "trips-recording":
                    NavigationStack { VehicleDetailView(vehicle: v, pane: .trips) }
                        .onAppear { TripCoordinator.shared.demoSetRecording(vehicleId: v.id) }
                case "trip-review": ModalNavigation { TripReviewView(vehicle: v) }
                case "trip-form": TripFormView(vehicle: v, trip: store.trip(id: Demo.tripId(10)))
                case "trip-new": TripFormView(vehicle: v, trip: nil)
                case "gaps": ModalNavigation { GapListView(vehicle: v) }
                case "month-close": ModalNavigation { MonthCloseView(vehicle: v, month: "2026-11") }
                case "month-closed": ModalNavigation { MonthCloseView(vehicle: v, month: "2026-10") }
                case "trip-reports": ModalNavigation { TripReportsView(vehicle: v) }
                case "places": NavigationStack { PlacesView() }
                case "customers": NavigationStack { CustomersView() }
                case "rules": NavigationStack { RulesView() }
                case "tax-params": NavigationStack { TaxParamsView() }
                case "material-picker": MaterialPickerView(vehicleId: v.id) { _ in }
                case "login": LoginView()
                default: VehicleListView()
                }
            }
            .environment(store)
        } else {
            ProgressView()
        }
    }
}
#endif
