import SwiftUI

// MARK: Materialstamm – Pflege

/// Materialstamm des Mandanten: Liste mit Suche, nach Kategorie gruppiert.
/// Schreibrolle: hinzufügen, bearbeiten, stornieren. Leserolle: nur ansehen.
struct MaterialCatalogView: View {
    @Environment(TenantStore.self) private var store
    @State private var search = ""
    @State private var form: EditTarget<MaterialArticle>?
    @State private var toDelete: MaterialArticle?

    init() {}

    private var emptyText: String {
        store.canWrite
            ? "Mit + Artikel erfassen. Sie stehen danach beim Material einer Wartung zur Auswahl."
            : "Es sind noch keine Artikel erfasst."
    }

    private var rowHint: String { store.canWrite ? "Bearbeiten" : "Ansehen" }

    var body: some View {
        let all = store.articles(for: nil)
        let query = search.trimmed
        let list = query.isEmpty ? all : all.filter { $0.matches(query) }
        let groups = MaterialArticle.grouped(list)
        let usage = store.articleUsage()
        List {
            ForEach(groups) { group in
                Section {
                    ForEach(group.articles) { article in
                        Button { form = EditTarget(value: article) } label: {
                            MaterialArticleRow(article: article, vehicleName: vehicleName(article),
                                               usageCount: usage[article.id]?.count ?? 0,
                                               pending: store.isPending(article.id))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(rowHint)
                        .swipeActions {
                            if store.canWrite {
                                Button("Stornieren", role: .destructive) { toDelete = article }
                            }
                        }
                    }
                } header: {
                    Text(group.title)
                }
            }
        }
        .searchable(text: $search, prompt: "Name, Art.-Nr. oder Kategorie")
        .overlay {
            if all.isEmpty {
                ContentUnavailableView("Materialstamm leer", systemImage: "shippingbox",
                                       description: Text(emptyText))
            } else if list.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .navigationTitle("Materialstamm")
        .toolbar {
            if store.canWrite {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { form = EditTarget(value: nil) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Artikel hinzufügen")
                }
            }
        }
        .sheet(item: $form) { target in
            MaterialArticleFormView(article: target.value)
        }
        .stornoDialog($toDelete, title: "Artikel stornieren?") { store.delete($0) }
        .refreshable { await store.sync() }
    }

    private func vehicleName(_ article: MaterialArticle) -> String? {
        guard let id = article.vehicleId else { return nil }
        return store.vehicle(id: id)?.name ?? "Unbekanntes Fahrzeug"
    }
}

/// Erfassen/Bearbeiten eines Stammartikels (Leserolle: nur ansehen).
struct MaterialArticleFormView: View {
    @Environment(TenantStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let article: MaterialArticle?

    @State private var name = ""
    @State private var partNumber = ""
    @State private var unit = "Stk"
    @State private var unitPrice = ""
    @State private var category = ""
    @State private var vehicleId: String?
    @State private var note = ""
    @State private var didPrefill = false

    init(article: MaterialArticle?) {
        self.article = article
    }

    private var titleText: String {
        if article == nil { return "Neuer Artikel" }
        return store.canWrite ? "Artikel bearbeiten" : "Artikel"
    }

    private var cancelTitle: String { store.canWrite ? "Abbrechen" : "Fertig" }

    // MARK: Validierung (Grenzen wie Server)

    private var nameValid: Bool {
        let n = name.trimmed
        return !n.isEmpty && n.count <= MaterialArticle.maxName
    }

    private var priceValid: Bool {
        if unitPrice.trimmed.isEmpty { return true }
        guard let p = unitPrice.asDouble else { return false }
        return p >= 0 && p <= MaterialArticle.maxUnitPrice
    }

    private var partNumberValid: Bool { partNumber.trimmed.count <= MaterialArticle.maxPartNumber }
    private var unitValid: Bool { unit.trimmed.count <= MaterialArticle.maxUnit }
    private var categoryValid: Bool { category.trimmed.count <= MaterialArticle.maxCategory }
    private var noteValid: Bool { note.trimmed.count <= MaterialArticle.maxNote }

    private var canSave: Bool {
        store.canWrite && nameValid && priceValid && partNumberValid && unitValid && categoryValid && noteValid
    }

    private var validationMessage: String? {
        if name.trimmed.count > MaterialArticle.maxName {
            return "Bezeichnung höchstens \(MaterialArticle.maxName) Zeichen."
        }
        if !partNumberValid { return "Art.-Nr. höchstens \(MaterialArticle.maxPartNumber) Zeichen." }
        if !unitValid { return "Einheit höchstens \(MaterialArticle.maxUnit) Zeichen." }
        if !priceValid { return "Einzelpreis ungültig (0 bis \(Fmt.chf(MaterialArticle.maxUnitPrice)))." }
        if !categoryValid { return "Kategorie höchstens \(MaterialArticle.maxCategory) Zeichen." }
        if !noteValid { return "Notiz höchstens \(MaterialArticle.maxNote) Zeichen." }
        return nil
    }

    /// Hinweis auf einen gleichnamigen Artikel (Doppelte vermeiden, nicht blockierend)
    private var duplicateHint: String? {
        let n = name.trimmed
        guard !n.isEmpty else { return nil }
        let part = partNumber.trimmed
        let found = store.articles(for: nil).first { a in
            a.id != article?.id
                && a.name.compare(n, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                && (a.partNumber ?? "").compare(part, options: [.caseInsensitive]) == .orderedSame
        }
        guard found != nil else { return nil }
        return "Ein Artikel mit dieser Bezeichnung und Art.-Nr. existiert bereits."
    }

    private var usageText: String {
        guard let a = article else { return "–" }
        let count = store.articleUsage()[a.id]?.count ?? 0
        return count == 1 ? "1 Materialposition" : "\(count) Materialpositionen"
    }

    // MARK: Ansicht

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Bezeichnung (z. B. Motoröl 5W-30)", text: $name)
                    TextField("Art.-Nr. (optional)", text: $partNumber)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                    ArticleCategoryField(text: $category)
                } header: {
                    Text("Artikel")
                } footer: {
                    if let hint = duplicateHint {
                        Text(hint).foregroundStyle(.orange)
                    }
                }
                .disabled(!store.canWrite)

                Section {
                    unitRow
                    UnitField("Einzelpreis", text: $unitPrice, unit: "CHF", placeholder: "optional")
                } header: {
                    Text("Einheit & Preis")
                } footer: {
                    Text("Wird beim Erfassen einer Wartung übernommen und kann dort angepasst werden.")
                }
                .disabled(!store.canWrite)

                Section {
                    vehiclePicker
                } header: {
                    Text("Gültig für")
                } footer: {
                    Text("«Alle Fahrzeuge»: bei jeder Wartung wählbar, sonst nur beim gewählten Fahrzeug.")
                }
                .disabled(!store.canWrite)

                Section("Notiz") {
                    TextField("optional", text: $note, axis: .vertical)
                }
                .disabled(!store.canWrite)

                if let message = validationMessage {
                    Section {
                        Text(message).foregroundStyle(.red)
                    }
                }

                if let a = article {
                    Section {
                        LabeledContent("Verwendet in", value: usageText)
                        if store.isPending(a.id) {
                            Label("Noch nicht synchronisiert", systemImage: "icloud.and.arrow.up")
                                .foregroundStyle(.orange)
                        }
                    }
                    HistorySection(entity: MaterialArticle.entityName, id: a.id)
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

    private var unitRow: some View {
        LabeledContent("Einheit") {
            HStack(spacing: 8) {
                TextField("Stk", text: $unit)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Menu {
                    ForEach(MaterialArticle.commonUnits, id: \.self) { u in
                        Button(u) { unit = u }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .accessibilityLabel("Einheit auswählen")
            }
        }
    }

    private var vehiclePicker: some View {
        Picker("Fahrzeug", selection: $vehicleId) {
            Text("Alle Fahrzeuge").tag(String?.none)
            ForEach(store.vehicleList) { v in
                Text(v.name).tag(String?.some(v.id))
            }
            // Fahrzeug nicht (mehr) in der Liste, z. B. storniert → Auswahl trotzdem anzeigen
            if let current = vehicleId, !store.vehicleList.contains(where: { $0.id == current }) {
                Text(store.vehicle(id: current)?.name ?? "Unbekanntes Fahrzeug").tag(String?.some(current))
            }
        }
    }

    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        guard let a = article else { return }
        name = a.name
        partNumber = a.partNumber ?? ""
        unit = a.unit
        unitPrice = a.unitPrice.map { MaintenanceFormView.DraftMaterial.priceText($0) } ?? ""
        category = a.category ?? ""
        vehicleId = a.vehicleId
        note = a.note ?? ""
    }

    private func save() {
        var a = article ?? MaterialArticle(name: "")
        a.name = name.trimmed
        a.partNumber = partNumber.nilIfEmpty
        a.unit = unit.nilIfEmpty ?? "Stk"
        a.unitPrice = unitPrice.asDouble
        a.category = category.nilIfEmpty
        a.vehicleId = vehicleId
        a.note = note.nilIfEmpty
        if let old = article, old == a { return } // unverändert → keine Revision
        store.save(a)
    }
}

/// Kategorie-Eingabe mit Vorschlägen (Standard + bereits verwendete Kategorien).
struct ArticleCategoryField: View {
    @Environment(TenantStore.self) private var store
    @Binding var text: String

    var body: some View {
        LabeledContent("Kategorie") {
            HStack(spacing: 8) {
                TextField("optional", text: $text)
                    .multilineTextAlignment(.trailing)
                Menu {
                    ForEach(store.articleCategories, id: \.self) { c in
                        Button(c) { text = c }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .accessibilityLabel("Kategorie auswählen")
            }
        }
    }
}

// MARK: Materialauswahl

/// Auswahl eines Stammartikels für eine Materialposition: Suche, «Häufig verwendet», nach Kategorie.
struct MaterialPickerView: View {
    @Environment(TenantStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let vehicleId: String?
    let onSelect: (MaterialArticle) -> Void
    @State private var search = ""

    init(vehicleId: String?, onSelect: @escaping (MaterialArticle) -> Void) {
        self.vehicleId = vehicleId
        self.onSelect = onSelect
    }

    private var editTitle: String { store.canWrite ? "Stamm bearbeiten" : "Stamm ansehen" }

    private var emptyText: String {
        store.canWrite
            ? "Über «Stamm bearbeiten» Artikel erfassen oder beim Material «In Materialstamm speichern» wählen."
            : "Für dieses Fahrzeug sind keine Artikel erfasst."
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Materialstamm")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Name, Art.-Nr. oder Kategorie")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Abbrechen") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            MaterialCatalogView()
                        } label: {
                            Text(editTitle)
                        }
                    }
                }
        }
    }

    private var content: some View {
        let all = store.articles(for: vehicleId)
        let query = search.trimmed
        let list = query.isEmpty ? all : all.filter { $0.matches(query) }
        let frequent = query.isEmpty ? store.frequentArticles(for: vehicleId) : []
        let groups = MaterialArticle.grouped(list)
        let usage = store.articleUsage()
        return List {
            if !frequent.isEmpty {
                Section {
                    ForEach(frequent) { article in
                        row(article, usageCount: usage[article.id]?.count ?? 0)
                    }
                } header: {
                    Text("Häufig verwendet")
                }
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.articles) { article in
                        row(article, usageCount: usage[article.id]?.count ?? 0)
                    }
                } header: {
                    Text(group.title)
                }
            }
        }
        .overlay {
            if all.isEmpty {
                ContentUnavailableView("Materialstamm leer", systemImage: "shippingbox",
                                       description: Text(emptyText))
            } else if list.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    private func row(_ article: MaterialArticle, usageCount: Int) -> some View {
        Button {
            onSelect(article)
            dismiss()
        } label: {
            MaterialArticleRow(article: article, vehicleName: vehicleName(article), usageCount: usageCount,
                               pending: store.isPending(article.id))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Übernehmen")
    }

    private func vehicleName(_ article: MaterialArticle) -> String? {
        guard let id = article.vehicleId else { return nil }
        return store.vehicle(id: id)?.name ?? "Unbekanntes Fahrzeug"
    }
}

// MARK: Zeile

/// Zeile eines Stammartikels: Name, Art.-Nr., Preis/Einheit, ggf. Fahrzeug und Verwendung.
struct MaterialArticleRow: View {
    let article: MaterialArticle
    var vehicleName: String? = nil
    var usageCount = 0
    var pending = false

    private var priceText: String {
        guard let p = article.unitPrice else { return article.unit }
        return "\(Fmt.chf(p)) / \(article.unit)"
    }

    private var detailText: String {
        var parts: [String] = []
        if let p = article.partNumber, !p.isEmpty { parts.append("Art.-Nr. \(p)") }
        if usageCount > 0 { parts.append("\(usageCount)× verwendet") }
        return parts.joined(separator: " · ")
    }

    private var spokenText: String {
        var parts: [String] = [article.name]
        if let p = article.unitPrice {
            parts.append("\(Fmt.chf(p)) pro \(article.unit)")
        } else {
            parts.append("Einheit \(article.unit), ohne Preis")
        }
        if let p = article.partNumber, !p.isEmpty { parts.append("Artikelnummer \(p)") }
        if let vehicleName { parts.append("nur für \(vehicleName)") }
        if usageCount > 0 { parts.append("\(usageCount) mal verwendet") }
        if pending { parts.append("noch nicht synchronisiert") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(article.name)
                    if pending { PendingBadge() }
                }
                if !detailText.isEmpty {
                    Text(detailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let vehicleName {
                    StatusTag(text: vehicleName, color: .blue, systemImage: "car")
                }
            }
            Spacer(minLength: 8)
            Text(priceText)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenText)
    }
}
