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
        let octavia = Vehicle(id: vehicleId, version: 3, name: "Skoda Octavia", make: "Skoda",
                              model: "Octavia Combi 2.0 TSI", plate: "ZH 123 456", initialKm: 48000)
        let bus = Vehicle(id: "33333333-3333-4333-8333-333333333333", version: 1, name: "VW California",
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
        let odometer = [
            OdometerReading(id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", version: 1, vehicleId: vehicleId,
                            date: day("2026-07-01"), km: 51700, note: "Ferienbeginn"),
            OdometerReading(id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", version: 1, vehicleId: vehicleId,
                            date: day("2026-07-21"), km: 52010, note: "Ferienende"),
        ]
        store.demoSeed(vehicles: [octavia, bus], odometer: odometer, fuel: fuelEntries,
                       maintenance: maintenance, items: items, pending: [pendingFuel])
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
                case "report": ReportView(vehicle: v)
                case "settings": NavigationStack { SettingsView() }
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
