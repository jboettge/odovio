import SwiftUI

// MARK: Orte

/// Bekannte Orte (Wohnort, Arbeitsorte, Kunden …) inkl. erkannter Kandidaten zum Benennen.
@MainActor
struct PlacesView: View {
    @Environment(TenantStore.self) private var store
    @Environment(TripCoordinator.self) private var coordinator
    @State private var form: EditTarget<Place>?
    @State private var toDelete: Place?
    @State private var candidates: [PlaceCandidate] = []

    init() {}

    private var rowHint: String { store.canWrite ? "Bearbeiten" : "Ansehen" }

    private var emptyText: String {
        store.canWrite
            ? "Mit + Orte erfassen (z. B. Wohnort, Büro, Kunde). Häufige Ziele werden automatisch vorgeschlagen."
            : "Es sind noch keine Orte erfasst."
    }

    var body: some View {
        let list = store.placeList
        List {
            if store.canWrite && !candidates.isEmpty {
                Section {
                    ForEach(candidates) { c in
                        Button {
                            form = EditTarget(value: Place(name: c.suggestedLabel ?? "", kind: PlaceKind.other.rawValue,
                                                           lat: c.lat, lon: c.lon))
                        } label: {
                            candidateRow(c)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Ort benennen")
                    }
                } header: {
                    Text("Neue Orte erkannt")
                }
            }
            ForEach(PlaceKind.allCases) { kind in
                let items = list.filter { $0.kind == kind.rawValue }
                if !items.isEmpty {
                    Section {
                        ForEach(items) { p in
                            Button { form = EditTarget(value: p) } label: {
                                PlaceRow(place: p, customerName: p.customerId.flatMap { store.customer(id: $0)?.name },
                                         pending: store.isPending(p.id))
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(rowHint)
                            .swipeActions {
                                if store.canWrite {
                                    Button("Stornieren", role: .destructive) { toDelete = p }
                                }
                            }
                        }
                    } header: {
                        Text(kind.groupTitle)
                    }
                }
            }
            Section {
            } footer: {
                Text("Datenschutz: Die Koordinaten des Wohnorts bleiben nur auf diesem Gerät. Andere Orte werden "
                     + "auf rund 100 m gerundet synchronisiert. Private Orte erscheinen in Berichten ohne Adresse.")
            }
        }
        .overlay {
            if list.isEmpty && candidates.isEmpty {
                ContentUnavailableView("Keine Orte", systemImage: "mappin.and.ellipse", description: Text(emptyText))
            }
        }
        .navigationTitle("Orte")
        .toolbar {
            if store.canWrite {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { form = EditTarget(value: nil) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Ort hinzufügen")
                }
            }
        }
        .task { candidates = coordinator.placeCandidates() }
        .sheet(item: $form, onDismiss: { candidates = coordinator.placeCandidates() }) { target in
            PlaceFormView(place: target.value)
        }
        .stornoDialog($toDelete, title: "Ort stornieren?") { store.delete($0) }
        .refreshable { await store.sync() }
    }

    private func candidateRow(_ c: PlaceCandidate) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles").foregroundStyle(.purple).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("Hier warst du \(c.visits)×: benennen?")
                Text(c.suggestedLabel ?? String(format: "%.3f, %.3f", c.lat, c.lon))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct PlaceRow: View {
    let place: Place
    var customerName: String?
    var pending = false

    private var detail: String {
        var parts: [String] = [place.kindValue.label, "Radius \(place.radiusM) m"]
        if let customerName { parts.append(customerName) }
        if let c = place.defaultCategory { parts.append(TripCategory.of(c).label) }
        if place.isPrivate { parts.append("privat") }
        if !place.hasCoordinate { parts.append("ohne Koordinaten") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: place.kindValue.systemImage).foregroundStyle(.blue).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(place.name)
                    if pending { PendingBadge() }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

@MainActor
struct PlaceFormView: View {
    @Environment(TenantStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let place: Place?

    @State private var name = ""
    @State private var kind = PlaceKind.other
    @State private var lat = ""
    @State private var lon = ""
    @State private var radius = 150
    @State private var customerId: String?
    @State private var defaultCategory: String?
    @State private var isPrivate = false
    @State private var didPrefill = false

    init(place: Place?) {
        self.place = place
    }

    private var stored: Place? { place.flatMap { store.place(id: $0.id) } }
    private var titleText: String {
        if stored == nil { return "Neuer Ort" }
        return store.canWrite ? "Ort bearbeiten" : "Ort"
    }
    private var cancelTitle: String { store.canWrite ? "Abbrechen" : "Fertig" }

    private var latValue: Double? { lat.asDouble }
    private var lonValue: Double? { lon.asDouble }

    private var errors: [String] {
        var e: [String] = []
        if name.trimmed.count > Place.maxName { e.append("Name höchstens \(Place.maxName) Zeichen.") }
        if !lat.trimmed.isEmpty && (latValue.map { abs($0) > 90 } ?? true) { e.append("Breitengrad ungültig.") }
        if !lon.trimmed.isEmpty && (lonValue.map { abs($0) > 180 } ?? true) { e.append("Längengrad ungültig.") }
        if lat.trimmed.isEmpty != lon.trimmed.isEmpty { e.append("Breiten- und Längengrad zusammen angeben.") }
        return e
    }

    private var canSave: Bool { store.canWrite && !name.trimmed.isEmpty && errors.isEmpty }

    private var coordinateFooter: String {
        kind == .home
            ? "Die Koordinaten des Wohnorts bleiben nur auf diesem Gerät und werden nicht synchronisiert."
            : "Koordinaten werden auf rund 100 m gerundet synchronisiert (Erkennung von Start/Ziel)."
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Ort") {
                    TextField("Name (z. B. Büro b-re.ch)", text: $name)
                    Picker("Art", selection: $kind) {
                        ForEach(PlaceKind.allCases) { k in
                            Label(k.label, systemImage: k.systemImage).tag(k)
                        }
                    }
                    if kind == .customer {
                        CustomerPicker(selection: $customerId)
                    }
                }
                .disabled(!store.canWrite)

                Section {
                    Stepper(value: $radius, in: Place.radiusRange, step: 50) {
                        LabeledContent("Radius", value: "\(radius) m")
                    }
                    Picker("Standard-Kategorie", selection: $defaultCategory) {
                        Text("Keine").tag(String?.none)
                        ForEach(TripCategory.selectable) { c in
                            Text(c.label).tag(String?.some(c.rawValue))
                        }
                    }
                    Toggle("Privater Ort", isOn: $isPrivate)
                } header: {
                    Text("Erkennung")
                } footer: {
                    Text("Privat: Fahrten zu diesem Ort werden ohne Adresse gespeichert und berichtet.")
                }
                .disabled(!store.canWrite)

                Section {
                    LabeledContent("Breite") {
                        TextField("z. B. 47.377", text: $lat)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Länge") {
                        TextField("z. B. 8.540", text: $lon)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                    }
                    if !lat.isEmpty || !lon.isEmpty {
                        Button("Koordinaten entfernen", role: .destructive) {
                            lat = ""
                            lon = ""
                        }
                    }
                } header: {
                    Text("Koordinaten")
                } footer: {
                    Text(coordinateFooter)
                }
                .disabled(!store.canWrite)

                if !errors.isEmpty {
                    Section {
                        ForEach(errors, id: \.self) { Text($0).foregroundStyle(.red) }
                    }
                }

                if let p = stored {
                    HistorySection(entity: Place.entityName, id: p.id)
                }
            }
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(cancelTitle) { dismiss() }
                }
                if store.canWrite {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Sichern") {
                            save()
                            dismiss()
                        }
                        .disabled(!canSave)
                    }
                }
            }
            .onAppear(perform: prefill)
        }
    }

    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        guard let p = place.map({ store.place(id: $0.id) ?? $0 }) else { return }
        name = p.name
        kind = p.kindValue
        lat = p.lat.map { String(format: "%.5f", $0) } ?? ""
        lon = p.lon.map { String(format: "%.5f", $0) } ?? ""
        radius = min(max(p.radiusM, Place.radiusRange.lowerBound), Place.radiusRange.upperBound)
        customerId = p.customerId
        defaultCategory = p.defaultCategory
        isPrivate = p.isPrivate
    }

    private func save() {
        var p = stored ?? place ?? Place(name: "")
        p.name = name.trimmed
        p.kind = kind.rawValue
        p.lat = latValue
        p.lon = lonValue
        p.radiusM = radius
        p.customerId = kind == .customer ? customerId : nil
        p.defaultCategory = defaultCategory
        p.isPrivate = isPrivate
        if let old = stored {
            var compare = p
            compare.version = old.version
            compare.deleted = old.deleted
            if compare == old { return }
        }
        store.save(p)
    }
}

// MARK: Kunden

@MainActor
struct CustomersView: View {
    @Environment(TenantStore.self) private var store
    @State private var search = ""
    @State private var form: EditTarget<Customer>?
    @State private var toDelete: Customer?

    init() {}

    private var rowHint: String { store.canWrite ? "Bearbeiten" : "Ansehen" }

    private var emptyText: String {
        store.canWrite ? "Mit + Kunden oder Projekte erfassen." : "Es sind noch keine Kunden erfasst."
    }

    var body: some View {
        let all = store.customerList
        let query = search.trimmed
        let list = query.isEmpty ? all : all.filter { c in
            c.name.localizedStandardContains(query) || (c.ref?.localizedStandardContains(query) ?? false)
        }
        List {
            ForEach(list) { c in
                Button { form = EditTarget(value: c) } label: {
                    customerRow(c)
                }
                .buttonStyle(.plain)
                .accessibilityHint(rowHint)
                .swipeActions {
                    if store.canWrite {
                        Button("Stornieren", role: .destructive) { toDelete = c }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Name oder Nummer")
        .overlay {
            if all.isEmpty {
                ContentUnavailableView("Keine Kunden", systemImage: "person.2", description: Text(emptyText))
            } else if list.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .navigationTitle("Kunden")
        .toolbar {
            if store.canWrite {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { form = EditTarget(value: nil) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Kunde hinzufügen")
                }
            }
        }
        .sheet(item: $form) { target in
            CustomerFormView(customer: target.value)
        }
        .stornoDialog($toDelete, title: "Kunde stornieren?") { store.delete($0) }
        .refreshable { await store.sync() }
    }

    private func customerRow(_ c: Customer) -> some View {
        let count = store.tripCount(customerId: c.id)
        let countText: String = count == 1 ? "1 Fahrt" : "\(count) Fahrten"
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(c.name)
                    if store.isPending(c.id) { PendingBadge() }
                }
                if let ref = c.ref?.nilIfEmpty {
                    Text("Nr. \(ref)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(countText).font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

@MainActor
struct CustomerFormView: View {
    @Environment(TenantStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let customer: Customer?

    @State private var name = ""
    @State private var ref = ""
    @State private var note = ""
    @State private var didPrefill = false

    init(customer: Customer?) {
        self.customer = customer
    }

    private var stored: Customer? { customer.flatMap { store.customer(id: $0.id) } }
    private var titleText: String {
        if stored == nil { return "Neuer Kunde" }
        return store.canWrite ? "Kunde bearbeiten" : "Kunde"
    }
    private var cancelTitle: String { store.canWrite ? "Abbrechen" : "Fertig" }

    private var errors: [String] {
        var e: [String] = []
        if name.trimmed.count > Customer.maxName { e.append("Name höchstens \(Customer.maxName) Zeichen.") }
        if ref.trimmed.count > Customer.maxRef { e.append("Nummer höchstens \(Customer.maxRef) Zeichen.") }
        if note.trimmed.count > Customer.maxNote { e.append("Notiz höchstens \(Customer.maxNote) Zeichen.") }
        return e
    }

    private var canSave: Bool { store.canWrite && !name.trimmed.isEmpty && errors.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section("Kunde") {
                    TextField("Name (z. B. Meier AG)", text: $name)
                    TextField("Kunden-/Projektnummer (optional)", text: $ref)
                        .autocorrectionDisabled()
                }
                .disabled(!store.canWrite)
                Section("Notiz") {
                    TextField("optional", text: $note, axis: .vertical)
                }
                .disabled(!store.canWrite)
                if !errors.isEmpty {
                    Section {
                        ForEach(errors, id: \.self) { Text($0).foregroundStyle(.red) }
                    }
                }
                if let c = stored {
                    Section {
                        LabeledContent("Fahrten", value: "\(store.tripCount(customerId: c.id))")
                    }
                    HistorySection(entity: Customer.entityName, id: c.id)
                }
            }
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(cancelTitle) { dismiss() }
                }
                if store.canWrite {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Sichern") {
                            save()
                            dismiss()
                        }
                        .disabled(!canSave)
                    }
                }
            }
            .onAppear {
                guard !didPrefill else { return }
                didPrefill = true
                guard let c = stored ?? customer else { return }
                name = c.name
                ref = c.ref ?? ""
                note = c.note ?? ""
            }
        }
    }

    private func save() {
        var c = stored ?? customer ?? Customer(name: "")
        c.name = name.trimmed
        c.ref = ref.nilIfEmpty
        c.note = note.nilIfEmpty
        if let old = stored {
            var compare = c
            compare.version = old.version
            compare.deleted = old.deleted
            if compare == old { return }
        }
        store.save(c)
    }
}

// MARK: Regeln

@MainActor
struct RulesView: View {
    @Environment(TenantStore.self) private var store
    @State private var form: EditTarget<PurposeRule>?
    @State private var toDelete: PurposeRule?

    init() {}

    private var rowHint: String { store.canWrite ? "Bearbeiten" : "Ansehen" }

    private var emptyText: String {
        store.canWrite
            ? "Regeln schlagen Kategorie und Zweck vor, z. B. «Mo–Fr Wohnort → Büro = Arbeitsweg». "
                + "Mit + erfassen oder im Review vorgeschlagene Regeln übernehmen."
            : "Es sind noch keine Regeln erfasst."
    }

    var body: some View {
        let list = store.allRules
        List {
            if !list.isEmpty {
                Section {
                    ForEach(list) { r in
                        Button { form = EditTarget(value: r) } label: {
                            RuleRow(condition: store.ruleConditionText(r), result: store.ruleResultText(r), rule: r,
                                    pending: store.isPending(r.id))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(rowHint)
                        .swipeActions {
                            if store.canWrite {
                                Button("Stornieren", role: .destructive) { toDelete = r }
                            }
                        }
                    }
                } footer: {
                    Text("Reihenfolge nach Priorität (kleinere Zahl zuerst). Vorschläge werden immer im Review "
                         + "bestätigt – ausser bei Regeln mit Auto-Bestätigung.")
                }
            }
        }
        .overlay {
            if list.isEmpty {
                ContentUnavailableView("Keine Regeln", systemImage: "wand.and.stars", description: Text(emptyText))
            }
        }
        .navigationTitle("Regeln")
        .toolbar {
            if store.canWrite {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { form = EditTarget(value: nil) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Regel hinzufügen")
                }
            }
        }
        .sheet(item: $form) { target in
            RuleFormView(rule: target.value)
        }
        .stornoDialog($toDelete, title: "Regel stornieren?") { store.delete($0) }
        .refreshable { await store.sync() }
    }
}

struct RuleRow: View {
    let condition: String
    let result: String
    let rule: PurposeRule
    var pending = false

    var body: some View {
        let cat = TripCategory.of(rule.resultCategory)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: cat.systemImage).foregroundStyle(cat.color).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text("Wenn: \(condition)").font(.subheadline)
                Text("Dann: \(result)").font(.subheadline.weight(.semibold))
                HStack(spacing: 6) {
                    StatusTag(text: "Priorität \(rule.priority)", color: .secondary)
                    if rule.autoConfirm {
                        StatusTag(text: "Auto-Bestätigung", color: .red, systemImage: "bolt.fill")
                    }
                    if rule.isLearned {
                        StatusTag(text: "Gelernt", color: .purple, systemImage: "sparkles")
                    }
                    if !rule.active {
                        StatusTag(text: "Inaktiv", color: .gray)
                    }
                    if pending { PendingBadge() }
                }
            }
        }
        .opacity(rule.active ? 1 : 0.6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

@MainActor
struct RuleFormView: View {
    @Environment(TenantStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let rule: PurposeRule?

    @State private var priority = 100
    @State private var fromPlaceId: String?
    @State private var toPlaceId: String?
    @State private var days: Set<Int> = []
    @State private var useTime = false
    @State private var timeFrom = TimeOfDay.date("06:00")
    @State private var timeTo = TimeOfDay.date("09:30")
    @State private var vehicleId: String?
    @State private var resultCategory = TripCategory.commute
    @State private var resultPurpose = ""
    @State private var resultCustomerId: String?
    @State private var autoConfirm = false
    @State private var active = true
    @State private var didPrefill = false

    init(rule: PurposeRule?) {
        self.rule = rule
    }

    private var stored: PurposeRule? { rule.flatMap { store.rules[$0.id] } }
    private var titleText: String {
        if stored == nil { return "Neue Regel" }
        return store.canWrite ? "Regel bearbeiten" : "Regel"
    }
    private var cancelTitle: String { store.canWrite ? "Abbrechen" : "Fertig" }

    private var errors: [String] {
        var e: [String] = []
        if useTime && TimeOfDay.string(timeFrom) >= TimeOfDay.string(timeTo) {
            e.append("Zeitfenster: «von» muss vor «bis» liegen.")
        }
        if resultPurpose.trimmed.count > Trip.maxPurpose { e.append("Zweck höchstens \(Trip.maxPurpose) Zeichen.") }
        return e
    }

    private var canSave: Bool { store.canWrite && errors.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    placePicker("Von", selection: $fromPlaceId)
                    placePicker("Nach", selection: $toPlaceId)
                    weekdayRow
                    Toggle("Zeitfenster", isOn: $useTime)
                    if useTime {
                        DatePicker("Von", selection: $timeFrom, displayedComponents: .hourAndMinute)
                        DatePicker("Bis", selection: $timeTo, displayedComponents: .hourAndMinute)
                    }
                    Picker("Fahrzeug", selection: $vehicleId) {
                        Text("Alle Fahrzeuge").tag(String?.none)
                        ForEach(store.vehicleList) { v in
                            Text(v.name).tag(String?.some(v.id))
                        }
                    }
                } header: {
                    Text("Wenn")
                } footer: {
                    Text("Leere Bedingungen gelten immer. Wochentage: keiner gewählt = jeden Tag.")
                }
                .disabled(!store.canWrite)

                Section("Dann") {
                    Picker("Kategorie", selection: $resultCategory) {
                        ForEach(TripCategory.selectable) { c in
                            Label(c.label, systemImage: c.systemImage).tag(c)
                        }
                    }
                    TextField("Zweck (optional)", text: $resultPurpose)
                    CustomerPicker(selection: $resultCustomerId)
                }
                .disabled(!store.canWrite)

                Section {
                    Stepper(value: $priority, in: 0...1000, step: 10) {
                        LabeledContent("Priorität", value: "\(priority)")
                    }
                    Toggle("Aktiv", isOn: $active)
                    Toggle(isOn: $autoConfirm) {
                        Label("Automatisch bestätigen", systemImage: "bolt.fill")
                    }
                    .tint(.red)
                } header: {
                    Text("Ausführung")
                } footer: {
                    if autoConfirm {
                        Text("Achtung: Passende Fahrten werden ohne Rückfrage bestätigt. Nur für eindeutige Fälle "
                             + "wie den Arbeitsweg verwenden – die Fahrten bleiben im Review markiert sichtbar.")
                            .foregroundStyle(.red)
                    } else {
                        Text("Standard: Die Regel macht nur einen Vorschlag; du bestätigst im Review.")
                    }
                }
                .disabled(!store.canWrite)

                if let r = stored, r.isLearned {
                    Section {
                        Label("Gelernte Regel – aus wiederkehrenden Fahrten vorgeschlagen.", systemImage: "sparkles")
                            .foregroundStyle(.purple)
                    }
                }

                if !errors.isEmpty {
                    Section {
                        ForEach(errors, id: \.self) { Text($0).foregroundStyle(.red) }
                    }
                }

                if let r = stored {
                    HistorySection(entity: PurposeRule.entityName, id: r.id)
                }
            }
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(cancelTitle) { dismiss() }
                }
                if store.canWrite {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Sichern") {
                            save()
                            dismiss()
                        }
                        .disabled(!canSave)
                    }
                }
            }
            .onAppear(perform: prefill)
        }
    }

    private func placePicker(_ title: String, selection: Binding<String?>) -> some View {
        Picker(title, selection: selection) {
            Text("Beliebig").tag(String?.none)
            ForEach(store.placeList) { p in
                Text(p.name).tag(String?.some(p.id))
            }
        }
    }

    private var weekdayRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Wochentage")
            HStack(spacing: 6) {
                ForEach(1...7, id: \.self) { d in
                    dayButton(d)
                }
            }
        }
    }

    private func dayButton(_ d: Int) -> some View {
        let selected = days.contains(d)
        let label = PurposeRule.weekdayLabels[d - 1]
        return Button {
            if selected { days.remove(d) } else { days.insert(d) }
        } label: {
            Text(label)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 32)
                .foregroundStyle(selected ? Color.white : Color.accentColor)
                .background(selected ? Color.accentColor : Color.accentColor.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? AccessibilityTraits.isSelected : [])
    }

    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        guard let r = stored ?? rule else { return }
        priority = r.priority
        fromPlaceId = r.fromPlaceId
        toPlaceId = r.toPlaceId
        days = Set(r.weekdaySet)
        useTime = r.timeFrom != nil || r.timeTo != nil
        timeFrom = TimeOfDay.date(r.timeFrom, fallback: "00:00")
        timeTo = TimeOfDay.date(r.timeTo, fallback: "23:59")
        vehicleId = r.vehicleId
        let cat = TripCategory.of(r.resultCategory)
        resultCategory = cat == .unknown ? .business : cat
        resultPurpose = r.resultPurpose ?? ""
        resultCustomerId = r.resultCustomerId
        autoConfirm = r.autoConfirm
        active = r.active
    }

    private func save() {
        var r = stored ?? rule ?? PurposeRule()
        r.priority = priority
        r.fromPlaceId = fromPlaceId
        r.toPlaceId = toPlaceId
        r.weekdays = PurposeRule.weekdayString(Array(days))
        r.timeFrom = useTime ? TimeOfDay.string(timeFrom) : nil
        r.timeTo = useTime ? TimeOfDay.string(timeTo) : nil
        r.vehicleId = vehicleId
        r.resultCategory = resultCategory.rawValue
        r.resultPurpose = resultPurpose.nilIfEmpty
        r.resultCustomerId = resultCustomerId
        r.autoConfirm = autoConfirm
        r.active = active
        if let old = stored {
            var compare = r
            compare.version = old.version
            compare.deleted = old.deleted
            if compare == old { return }
        }
        store.save(r)
    }
}

// MARK: Steuerparameter

@MainActor
struct TaxParamsView: View {
    @Environment(TenantStore.self) private var store
    @State private var form: EditTarget<TaxParam>?
    @State private var toDelete: TaxParam?

    init() {}

    private var rowHint: String { store.canWrite ? "Bearbeiten" : "Ansehen" }

    var body: some View {
        let list = store.taxParamList
        let years = Array(Set(list.map(\.year))).sorted(by: >)
        List {
            Section {
                Label("Annahmen – mit Treuhand prüfen. Sätze und Obergrenzen ändern jährlich und je Kanton; "
                      + "ohne eigene Werte rechnet der Server mit Standardwerten.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(years, id: \.self) { y in
                Section {
                    ForEach(list.filter { $0.year == y }) { p in
                        Button { form = EditTarget(value: p) } label: {
                            paramRow(p)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(rowHint)
                        .swipeActions {
                            if store.canWrite {
                                Button("Stornieren", role: .destructive) { toDelete = p }
                            }
                        }
                    }
                } header: {
                    Text(String(y))
                }
            }
        }
        .overlay {
            if list.isEmpty {
                ContentUnavailableView("Keine eigenen Parameter", systemImage: "percent",
                                       description: Text("Der Server verwendet Standardwerte (Annahmen)."))
            }
        }
        .navigationTitle("Steuerparameter")
        .toolbar {
            if store.canWrite {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { form = EditTarget(value: nil) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Parameter hinzufügen")
                }
            }
        }
        .sheet(item: $form) { target in
            TaxParamFormView(param: target.value)
        }
        .stornoDialog($toDelete, title: "Parameter stornieren?") { store.delete($0) }
        .refreshable { await store.sync() }
    }

    private func paramRow(_ p: TaxParam) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(TaxParam.label(p.key))
                    if store.isPending(p.id) { PendingBadge() }
                }
                Text(TaxParam.scopeLabel(p.scope) + (p.sourceUrl == nil ? "" : " · mit Quelle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(TaxParam.valueText(p.key, p.value)).monospacedDigit()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

@MainActor
struct TaxParamFormView: View {
    @Environment(TenantStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let param: TaxParam?

    enum ScopeKind: String, CaseIterable, Identifiable {
        case federal, canton, tenant
        var id: String { rawValue }
        var label: String {
            switch self {
            case .federal: "Bund"
            case .canton: "Kanton"
            case .tenant: "Mandant (eigenes Reglement)"
            }
        }
    }

    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var scopeKind = ScopeKind.tenant
    @State private var canton = ""
    @State private var key = "km_rate"
    @State private var value = ""
    @State private var sourceUrl = ""
    @State private var note = ""
    @State private var didPrefill = false

    init(param: TaxParam?) {
        self.param = param
    }

    private var stored: TaxParam? { param.flatMap { store.taxParams[$0.id] } }
    private var titleText: String {
        if stored == nil { return "Neuer Parameter" }
        return store.canWrite ? "Parameter bearbeiten" : "Parameter"
    }
    private var cancelTitle: String { store.canWrite ? "Abbrechen" : "Fertig" }

    private var scope: String {
        switch scopeKind {
        case .federal: return "federal"
        case .tenant: return "tenant"
        case .canton: return "canton:\(canton.trimmed.uppercased())"
        }
    }

    private var errors: [String] {
        var e: [String] = []
        if scopeKind == .canton {
            let c = canton.trimmed.uppercased()
            if c.count != 2 || !c.allSatisfy({ $0.isLetter && $0.isASCII }) {
                e.append("Kanton als Kürzel mit zwei Buchstaben (z. B. ZH).")
            }
        }
        if let v = value.asDouble {
            if v < 0 || v > TaxParam.maxValue { e.append("Wert ausserhalb 0 bis 1'000'000.") }
        } else {
            e.append("Wert angeben.")
        }
        if sourceUrl.trimmed.count > TaxParam.maxText { e.append("Quelle höchstens \(TaxParam.maxText) Zeichen.") }
        if note.trimmed.count > TaxParam.maxText { e.append("Notiz höchstens \(TaxParam.maxText) Zeichen.") }
        return e
    }

    private var duplicateHint: String? {
        let s = scope
        let exists = store.taxParamList.contains { p in
            p.id != param?.id && p.year == year && p.scope == s && p.key == key
        }
        return exists ? "Für dieses Jahr, diesen Geltungsbereich und Schlüssel existiert bereits ein Wert." : nil
    }

    private var canSave: Bool { store.canWrite && errors.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $year, in: 2000...2100) {
                        LabeledContent("Jahr", value: String(year))
                    }
                    Picker("Geltungsbereich", selection: $scopeKind) {
                        ForEach(ScopeKind.allCases) { s in
                            Text(s.label).tag(s)
                        }
                    }
                    if scopeKind == .canton {
                        TextField("Kanton (z. B. ZH)", text: $canton)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    }
                    Picker("Parameter", selection: $key) {
                        ForEach(TaxParam.keys, id: \.self) { k in
                            Text(TaxParam.label(k)).tag(k)
                        }
                    }
                    UnitField("Wert", text: $value, unit: TaxParam.unit(key))
                } header: {
                    Text("Parameter")
                } footer: {
                    if let duplicateHint {
                        Text(duplicateHint).foregroundStyle(.orange)
                    }
                }
                .disabled(!store.canWrite)

                Section {
                    TextField("Quelle (URL, optional)", text: $sourceUrl)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Notiz (optional)", text: $note, axis: .vertical)
                } header: {
                    Text("Nachweis")
                } footer: {
                    Text("Annahmen – mit Treuhand prüfen. Keine Steuer- oder Rechtsberatung.")
                }
                .disabled(!store.canWrite)

                if !errors.isEmpty {
                    Section {
                        ForEach(errors, id: \.self) { Text($0).foregroundStyle(.red) }
                    }
                }

                if let p = stored {
                    HistorySection(entity: TaxParam.entityName, id: p.id)
                }
            }
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(cancelTitle) { dismiss() }
                }
                if store.canWrite {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Sichern") {
                            save()
                            dismiss()
                        }
                        .disabled(!canSave)
                    }
                }
            }
            .onAppear(perform: prefill)
        }
    }

    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        guard let p = stored ?? param else { return }
        year = p.year
        if p.scope == "federal" {
            scopeKind = .federal
        } else if p.scope.hasPrefix("canton:") {
            scopeKind = .canton
            canton = String(p.scope.dropFirst("canton:".count))
        } else {
            scopeKind = .tenant
        }
        key = TaxParam.keys.contains(p.key) ? p.key : "km_rate"
        value = Fmt.editQty(p.value)
        sourceUrl = p.sourceUrl ?? ""
        note = p.note ?? ""
    }

    private func save() {
        guard let v = value.asDouble else { return }
        var p = stored ?? param ?? TaxParam(year: year, key: key, value: v)
        p.year = year
        p.scope = scope
        p.key = key
        p.value = v
        p.sourceUrl = sourceUrl.nilIfEmpty
        p.note = note.nilIfEmpty
        if let old = stored {
            var compare = p
            compare.version = old.version
            compare.deleted = old.deleted
            if compare == old { return }
        }
        store.save(p)
    }
}
