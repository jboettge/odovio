import CoreLocation
import CoreMotion
import EventKit
import SwiftUI
import UserNotifications

enum TripSetupKeys {
    /// Einrichtung wurde mindestens einmal gezeigt
    static let seen = "tripSetupSeen"
}

/// „Fahrtenbuch einrichten“: Berechtigungen Schritt für Schritt mit Zweck und Status, danach Wohnort.
/// Erreichbar aus den Einstellungen, beim ersten Start einer Fahrt und beim Einschalten der Automatik.
@MainActor
struct TripSetupView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TripCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Als Sheet: Titel des Abschlussknopfs (z. B. „Fahrt starten“) und Aktion danach
    var continueTitle: String?
    var onContinue: (() -> Void)?
    /// Automatik: Schritte „Immer“ und „Bewegung“ als nötig markieren
    var forAutomation = false


    enum Step: Int, CaseIterable, Identifiable {
        case locationInUse, locationAlways, motion, calendar, notifications, home
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .locationInUse: "Standort beim Verwenden"
            case .locationAlways: "Standort «Immer»"
            case .motion: "Bewegung & Fitness"
            case .calendar: "Kalender (optional)"
            case .notifications: "Mitteilungen"
            case .home: "Wohnort festlegen"
            }
        }

        var purpose: String {
            switch self {
            case .locationInUse:
                "Zeichnet Start, Ziel und Strecke einer Fahrt auf, solange sie läuft. Ohne Fahrt wird kein "
                    + "Standort erfasst."
            case .locationAlways:
                "Nötig für die automatische Erkennung und damit eine Fahrt auch bei gesperrtem iPhone "
                    + "weiterläuft."
            case .motion:
                "Erkennt am Bewegungsmuster, dass du im Auto sitzt – spart Akku, weil GPS erst dann startet."
            case .calendar:
                "Termine (Ort, Titel) helfen beim Vorschlag des Zwecks. Kalenderdaten bleiben auf dem Gerät."
            case .notifications:
                "Erinnert an fällige Wartungen, zu bestätigende Fahrten und eine noch laufende Aufzeichnung."
            case .home:
                "Fahrten von und nach Hause werden als «Wohnort» gespeichert – ohne Adresse. Die Koordinaten "
                    + "bleiben nur auf diesem Gerät."
            }
        }

        var systemImage: String {
            switch self {
            case .locationInUse: "location"
            case .locationAlways: "location.fill"
            case .motion: "figure.walk.motion"
            case .calendar: "calendar"
            case .notifications: "bell.badge"
            case .home: "house"
            }
        }

        var isOptional: Bool { self == .calendar }
    }

    enum StepState: Equatable {
        case done, open, denied, unavailable
    }

    @State private var states: [Step: StepState] = [:]
    @State private var texts: [Step: String] = [:]
    @State private var busy: Step?
    @State private var showHome = false

    private var openSteps: [Step] {
        Step.allCases.filter { !$0.isOptional && state($0) != .done && state($0) != .unavailable }
    }

    private var nextStep: Step? { openSteps.first }

    private var doneCount: Int { Step.allCases.filter { state($0) == .done }.count }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("In wenigen Schritten bereit für das Fahrtenbuch. Jede Berechtigung kannst du später in "
                         + "den iOS-Einstellungen ändern.")
                        .font(.subheadline)
                    ProgressView(value: Double(doneCount), total: Double(Step.allCases.count))
                        .accessibilityLabel("\(doneCount) von \(Step.allCases.count) Schritten erledigt")
                    Text("\(doneCount) von \(Step.allCases.count) erledigt")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            ForEach(Step.allCases) { step in
                Section {
                    stepRow(step)
                } header: {
                    Text("Schritt \(step.rawValue + 1)")
                }
            }

            if let onContinue {
                Section {
                    Button {
                        onContinue()
                        dismiss()
                    } label: {
                        Label(continueTitle ?? "Weiter", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowBackground(Color.clear)
                } footer: {
                    if !openSteps.isEmpty {
                        Text("Noch offen: " + openSteps.map(\.title).joined(separator: ", ")
                             + ". Die Aufzeichnung funktioniert dann eingeschränkt.")
                    }
                }
            }
        }
        .navigationTitle("Fahrtenbuch einrichten")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .onAppear { UserDefaults.standard.set(true, forKey: TripSetupKeys.seen) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }   // zurück aus den iOS-Einstellungen
        }
        .sheet(isPresented: $showHome, onDismiss: { Task { await refresh() } }) {
            if let store = settings.store {
                HomePlaceSetupView(store: store)
            }
        }
    }

    // MARK: Zeile

    private func state(_ step: Step) -> StepState { states[step] ?? .open }

    private func stateText(_ step: Step) -> String {
        if step == .home, let t = texts[step]?.nilIfEmpty { return t }
        if let t = texts[step]?.nilIfEmpty {
            if t == PermissionStatus.notAsked { return "Aktuell: noch nicht gefragt" }
            return "Aktuell: " + t
        }
        switch state(step) {
        case .done: return "Erledigt"
        case .open: return "Offen"
        case .denied: return "Nicht erlaubt"
        case .unavailable: return "Nicht verfügbar"
        }
    }

    private func stateIcon(_ step: Step) -> String {
        switch state(step) {
        case .done: "checkmark.circle.fill"
        case .open: step == nextStep ? "arrow.right.circle.fill" : "circle"
        case .denied: "xmark.circle.fill"
        case .unavailable: "minus.circle"
        }
    }

    private func stateColor(_ step: Step) -> Color {
        switch state(step) {
        case .done: .successText
        case .open: step == nextStep ? .infoText : .neutralText
        case .denied: .dangerText
        case .unavailable: .neutralText
        }
    }

    private func needed(_ step: Step) -> Bool {
        forAutomation && (step == .locationAlways || step == .motion)
    }

    private func stepRow(_ step: Step) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: step.systemImage)
                    .foregroundStyle(Color.infoText)
                    .frame(minWidth: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    // Bei grossen Schriften (AX) Hinweis auf eigener Zeile statt abgeschnitten (U9)
                    let titleLayout = typeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 6))
                    titleLayout {
                        Text(step.title)
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        if needed(step) && state(step) != .done {
                            StatusTag(text: "für Automatik nötig", color: .orange)
                        }
                    }
                    Text(step.purpose)
                        .font(.subheadline)
                        .foregroundStyle(Color.neutralText)
                        .fixedSize(horizontal: false, vertical: true)
                    Label(stateText(step), systemImage: stateIcon(step))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(stateColor(step))
                }
            }
            action(step)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func action(_ step: Step) -> some View {
        switch state(step) {
        case .done:
            if step == .home {
                Button("Wohnort ändern") { showHome = true }
                    .disabled(settings.store == nil || !(settings.store?.canWrite ?? false))
            }
        case .denied:
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: {
                Label("In den iOS-Einstellungen erlauben", systemImage: "gear")
            }
        case .unavailable:
            EmptyView()
        case .open where step == .locationAlways && coordinator.alwaysPromptUsed && state(.locationInUse) == .done:
            // iOS zeigt den Dialog «Immer» nur einmal; danach hilft nur die Einstellung (U3)
            OpenSystemSettingsButton(title: "In den iOS-Einstellungen auf «Immer» stellen")
            Text("Einstellungen › odovio › Standort › «Immer».")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .open:
            Button {
                Task { await perform(step) }
            } label: {
                HStack {
                    Text(actionTitle(step))
                    if busy == step { Spacer(); ProgressView() }
                }
            }
            .buttonStyle(.bordered)
            .disabled(busy != nil || AppMode.isDemo || !prerequisiteMet(step)
                      || (step == .home && settings.store == nil))
            if !prerequisiteMet(step) {
                Text("Zuerst «Standort beim Verwenden» erlauben.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func actionTitle(_ step: Step) -> String {
        switch step {
        case .home: "Wohnort festlegen …"
        case .locationAlways: "Auf «Immer» erweitern"
        default: "Erlauben"
        }
    }

    private func prerequisiteMet(_ step: Step) -> Bool {
        step != .locationAlways || state(.locationInUse) == .done
    }

    // MARK: Aktionen

    private func perform(_ step: Step) async {
        busy = step
        defer { busy = nil }
        switch step {
        case .locationInUse: _ = await coordinator.requestLocationWhenInUse()
        case .locationAlways: _ = await coordinator.requestLocationAlways()
        case .motion: _ = await coordinator.requestMotion()
        case .calendar: _ = await coordinator.requestCalendar()
        case .notifications: _ = await coordinator.requestNotifications()
        case .home:
            showHome = true
            return
        }
        await refresh()
    }

    /// Status je Schritt: Texte vom Koordinator, erledigt/abgelehnt aus den Systemstatus.
    private func refresh() async {
        let status = await coordinator.permissionStatus()
        texts[.locationInUse] = status.location
        texts[.locationAlways] = status.location
        texts[.motion] = status.motion
        texts[.calendar] = status.calendar
        texts[.notifications] = status.notifications

        let location = CLLocationManager().authorizationStatus
        switch location {
        case .authorizedAlways:
            states[.locationInUse] = .done
            states[.locationAlways] = .done
        case .authorizedWhenInUse:
            states[.locationInUse] = .done
            states[.locationAlways] = .open
        case .denied, .restricted:
            states[.locationInUse] = .denied
            states[.locationAlways] = .denied
        default:
            states[.locationInUse] = .open
            states[.locationAlways] = .open
        }

        if !CMMotionActivityManager.isActivityAvailable() {
            states[.motion] = .unavailable
        } else {
            switch CMMotionActivityManager.authorizationStatus() {
            case .authorized: states[.motion] = .done
            case .denied, .restricted: states[.motion] = .denied
            default: states[.motion] = .open
            }
        }

        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: states[.calendar] = .done
        case .denied, .restricted, .writeOnly: states[.calendar] = .denied
        default: states[.calendar] = .open
        }

        let notificationSettings = await UNUserNotificationCenter.current().notificationSettings()
        switch notificationSettings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: states[.notifications] = .done
        case .denied: states[.notifications] = .denied
        default: states[.notifications] = .open
        }

        let home = settings.store?.placeList.first(where: \.isHome)
        let homeReady = !coordinator.needsHomePlace && (home?.hasCoordinate ?? false)
        states[.home] = homeReady ? .done : .open
        texts[.home] = homeReady ? "Wohnort ist auf diesem Gerät hinterlegt"
            : "Noch kein Wohnort mit Koordinaten auf diesem Gerät"
    }

    /// Fehlt etwas für die automatische Erkennung (Standort «Immer», Bewegung)?
    static func automationReady(_ coordinator: TripCoordinator) -> Bool {
        coordinator.hasAlwaysLocationAccess
            && (CMMotionActivityManager.authorizationStatus() == .authorized
                || !CMMotionActivityManager.isActivityAvailable())
    }
}

// MARK: Wohnort

/// Wohnort festlegen: aktueller Standort oder Adresse. Die Koordinaten bleiben nur auf diesem Gerät.
@MainActor
struct HomePlaceSetupView: View {
    @Environment(TripCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    let store: TenantStore

    @State private var address = ""
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var source: String?
    @State private var busy = false
    @State private var message: String?
    @State private var locator = OneShotLocation()

    private var existingHome: Place? { store.placeList.first(where: \.isHome) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Die Koordinaten des Wohnorts bleiben nur auf diesem iPhone und werden nie an den "
                          + "Server gesendet. Fahrten von und nach Hause erscheinen als «Wohnort» – ohne Adresse.",
                          systemImage: "lock.shield")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    Button {
                        Task { await useCurrentLocation() }
                    } label: {
                        HStack {
                            Label("Aktuellen Standort verwenden", systemImage: "location.fill")
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy || AppMode.isDemo)
                } header: {
                    Text("Ich bin zu Hause")
                } footer: {
                    Text("Am besten vor der Haustür oder am Parkplatz.")
                }
                Section {
                    TextField("Strasse Nr., PLZ Ort", text: $address, axis: .vertical)
                        .textContentType(.fullStreetAddress)
                    Button("Adresse suchen") { Task { await geocode() } }
                        .disabled(busy || address.trimmed.isEmpty || AppMode.isDemo)
                } header: {
                    Text("Oder Adresse eingeben")
                } footer: {
                    Text("Die Adresse wird einmalig mit den Kartendiensten von Apple in Koordinaten umgewandelt "
                         + "und nicht gespeichert.")
                }
                if let coordinate {
                    Section {
                        LabeledContent("Quelle", value: source ?? "–")
                        LabeledContent("Koordinaten",
                                       value: String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude))
                    } header: {
                        Text("Gefunden")
                    }
                }
                if let message {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.warningText)
                    }
                }
            }
            .navigationTitle("Wohnort festlegen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        save()
                        dismiss()
                    }
                    .disabled(coordinate == nil || !store.canWrite)
                }
            }
            .interactiveDismissDisabled(coordinate != nil)
        }
    }

    private func useCurrentLocation() async {
        busy = true
        defer { busy = false }
        message = nil
        let status = CLLocationManager().authorizationStatus
        if status == .notDetermined {
            _ = await coordinator.requestLocationWhenInUse()
        }
        if let location = await locator.current() {
            coordinate = location.coordinate
            source = "Aktueller Standort (± \(Int(location.horizontalAccuracy.rounded())) m)"
        } else {
            message = "Standort nicht verfügbar – Standortzugriff erlauben oder Adresse eingeben."
        }
    }

    private func geocode() async {
        busy = true
        defer { busy = false }
        message = nil
        do {
            let marks = try await CLGeocoder().geocodeAddressString(address.trimmed)
            if let location = marks.first?.location {
                coordinate = location.coordinate
                source = "Adresse"
            } else {
                message = "Adresse nicht gefunden."
            }
        } catch {
            message = "Adresse nicht gefunden – Schreibweise prüfen oder Standort verwenden."
        }
    }

    private func save() {
        guard let c = coordinate else { return }
        var p = existingHome ?? Place(name: "Wohnort", kind: PlaceKind.home.rawValue)
        p.kind = PlaceKind.home.rawValue
        p.lat = c.latitude
        p.lon = c.longitude
        store.save(p)
    }
}

/// Einmalige Standortabfrage (nur mit vorhandener Berechtigung).
@MainActor
final class OneShotLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    func current() async -> CLLocation? {
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways, continuation == nil else { return nil }
        return await withCheckedContinuation { (c: CheckedContinuation<CLLocation?, Never>) in
            continuation = c
            manager.requestLocation()
        }
    }

    private func finish(_ location: CLLocation?) {
        continuation?.resume(returning: location)
        continuation = nil
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        Task { @MainActor in self.finish(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }
}
