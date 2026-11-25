import SwiftUI
import UIKit

extension ReadingField {
    /// Farbe der Hervorhebung im Foto und der Feldmarkierung
    var color: Color {
        switch self {
        case .amount: .green
        case .liters: .blue
        case .pricePerLiter: .orange
        case .km: .purple
        }
    }
}

/// Foto mit hervorgehobenen Werten, Zuordnung der Felder (mit Konfidenz bzw. Auswahl-Chips) und Übernahme.
struct ScanResultView: View {
    @Environment(TenantStore.self) private var store
    let image: UIImage
    let kind: ScanKind
    let highlights: Bool
    let allowAttachment: Bool
    let onApply: (ScanOutcome) -> Void
    let onRetake: (() -> Void)?

    enum FieldSource { case device, computed, chip, server, manual }

    @State private var reading: ScanReading
    @State private var liters: String
    @State private var amount: String
    @State private var ppl: String
    @State private var km: String
    @State private var useDate: Bool
    @State private var date: Date
    @State private var station: String
    @State private var saveAttachment: Bool
    @State private var sources: [ReadingField: FieldSource]
    @State private var selected: [ReadingField: Int]
    @State private var showChips: Bool
    @State private var visionAvailable = false
    @State private var serverBusy = false
    @State private var serverNote: String?

    init(image: UIImage, kind: ScanKind, reading: ScanReading, highlights: Bool = true, allowAttachment: Bool = true,
         onApply: @escaping (ScanOutcome) -> Void, onRetake: (() -> Void)? = nil) {
        self.image = image
        self.kind = kind
        self.highlights = highlights
        self.allowAttachment = allowAttachment
        self.onApply = onApply
        self.onRetake = onRetake
        _reading = State(initialValue: reading)
        _liters = State(initialValue: reading.value(.liters).map { Self.text($0, .liters) } ?? "")
        _amount = State(initialValue: reading.value(.amount).map { Self.text($0, .amount) } ?? "")
        _ppl = State(initialValue: reading.value(.pricePerLiter).map { Self.text($0, .pricePerLiter) } ?? "")
        _km = State(initialValue: reading.km.map { String($0) } ?? "")
        _useDate = State(initialValue: reading.date != nil)
        _date = State(initialValue: reading.date ?? Date())
        _station = State(initialValue: reading.station ?? "")
        _saveAttachment = State(initialValue: allowAttachment && kind == .receipt)
        _showChips = State(initialValue: !reading.isUnambiguous)
        var initialSources: [ReadingField: FieldSource] = [:]
        var initialSelection: [ReadingField: Int] = [:]
        for field in Self.fields(kind) where reading.value(field) != nil {
            initialSources[field] = reading.fuel?.computed == field ? .computed : .device
            if let tokenId = reading.tokenId(for: field) { initialSelection[field] = tokenId }
        }
        _sources = State(initialValue: initialSources)
        _selected = State(initialValue: initialSelection)
    }

    static func fields(_ kind: ScanKind) -> [ReadingField] {
        kind.isFuel ? ReadingField.fuelFields : [.km]
    }

    static func text(_ value: Double, _ field: ReadingField) -> String {
        if field == .km { return String(Int(value.rounded())) }
        return value.formatted(.number.grouping(.never).precision(.fractionLength(field.fractionDigits)))
    }

    private var fields: [ReadingField] { Self.fields(kind) }

    var body: some View {
        Form {
            Section {
                ScanImageView(image: image, tokens: highlights ? reading.tokens.filter(\.isChip) : [],
                              selected: selected)
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            } footer: {
                Text(reading.reason.isEmpty ? "Auswertung auf dem Gerät." : reading.reason)
            }

            Section {
                ForEach(fields) { field in
                    fieldRow(field)
                }
                if let warning = consistencyWarning {
                    Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(Color.warningText)
                }
            } header: {
                HStack {
                    Text("Erkannte Werte")
                    Spacer()
                    confidenceTag
                }
                .textCase(nil)
            } footer: {
                if showChips {
                    Text("Tippe auf eine erkannte Zahl, um sie dem Feld zuzuordnen. Werte lassen sich auch direkt ändern.")
                }
            }

            if kind == .receipt {
                Section("Quittung") {
                    Toggle("Datum übernehmen", isOn: $useDate)
                    if useDate {
                        DatePicker("Datum", selection: $date, in: ...Date(), displayedComponents: .date)
                    }
                    TextField("Tankstelle", text: $station)
                }
            }

            if showServerButton || serverNote != nil {
                Section {
                    if showServerButton {
                        Button(action: askServer) {
                            HStack {
                                Label("Mit KI auswerten", systemImage: "sparkles")
                                Spacer()
                                if serverBusy { ProgressView() }
                            }
                        }
                        .disabled(serverBusy)
                    }
                    if let serverNote {
                        Text(serverNote).font(.footnote).foregroundStyle(.secondary)
                    }
                } footer: {
                    if showServerButton {
                        Text("Bild wird an deinen Server gesendet (verkleinert) und dort ausgewertet.")
                    }
                }
            }

            if allowAttachment {
                Section {
                    Toggle("Foto als Beleg speichern", isOn: $saveAttachment)
                } footer: {
                    Text(attachmentFooter)
                }
            }

            Section {
                Button(action: apply) {
                    Text("Übernehmen").bold().frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canApply)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                if let onRetake {
                    Button("Neu aufnehmen", systemImage: "camera.rotate") { onRetake() }
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Übernehmen", action: apply).disabled(!canApply)
            }
        }
        .task {
            if !reading.isUnambiguous && !store.isLocal {
                visionAvailable = await VisionAvailability.check(api: store.api)
            }
        }
    }

    // MARK: Felder

    @ViewBuilder
    private func fieldRow(_ field: ReadingField) -> some View {
        let chips = reading.chips(for: field)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(field.color).frame(width: 10, height: 10).accessibilityHidden(true)
                UnitField(field.label, text: binding(field), unit: field.unit,
                          keyboard: field == .km ? .numberPad : .decimalPad,
                          placeholder: field == .km ? "" : Self.text(0, field))
            }
            HStack(spacing: 8) {
                sourceTag(field)
                Spacer()
                if !showChips && !chips.isEmpty {
                    Button("Andere Zahl wählen") { showChips = true }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
            }
            if showChips && !chips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(chips) { token in
                            chip(token, field: field)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func chip(_ token: NumberToken, field: ReadingField) -> some View {
        let isSelected = selected[field] == token.id
        let label = Self.text(token.value, field)
        return Button { choose(token, for: field) } label: {
            Text(label)
                .font(.callout.monospacedDigit())
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? field.color.opacity(0.25) : Color.secondary.opacity(0.12), in: Capsule())
                .overlay(Capsule().stroke(isSelected ? field.color : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) als \(field.label) übernehmen")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func binding(_ field: ReadingField) -> Binding<String> {
        Binding(
            get: { value(of: field) },
            set: { newValue in
                guard newValue != value(of: field) else { return }
                setValue(newValue, for: field)
                sources[field] = .manual
                selected[field] = nil
            })
    }

    private func value(of field: ReadingField) -> String {
        switch field {
        case .liters: liters
        case .amount: amount
        case .pricePerLiter: ppl
        case .km: km
        }
    }

    private func setValue(_ text: String, for field: ReadingField) {
        switch field {
        case .liters: liters = text
        case .amount: amount = text
        case .pricePerLiter: ppl = text
        case .km: km = text
        }
    }

    @ViewBuilder
    private func sourceTag(_ field: ReadingField) -> some View {
        switch sources[field] {
        case .device:
            if reading.confidence >= ScanReading.unambiguousThreshold {
                StatusTag(text: "Erkannt", color: .green, systemImage: "checkmark")
            } else {
                StatusTag(text: "Bitte prüfen", color: .orange, systemImage: "questionmark")
            }
        case .computed:
            StatusTag(text: "Berechnet", color: .blue, systemImage: "function")
        case .chip:
            StatusTag(text: "Ausgewählt", color: .blue, systemImage: "hand.tap")
        case .server:
            StatusTag(text: "KI", color: .purple, systemImage: "sparkles")
        case .manual:
            StatusTag(text: "Manuell", color: .secondary, systemImage: "pencil")
        case nil:
            if value(of: field).trimmed.isEmpty {
                StatusTag(text: "Nicht erkannt", color: .secondary)
            }
        }
    }

    @ViewBuilder
    private var confidenceTag: some View {
        let pct = Fmt.pct(reading.confidence * 100)
        if !reading.hasValues {
            StatusTag(text: "Nichts Eindeutiges", color: .red)
                .accessibilityLabel("Keine eindeutigen Werte erkannt")
        } else if reading.confidence >= ScanReading.unambiguousThreshold {
            StatusTag(text: "Sicher · \(pct)", color: .green)
                .accessibilityLabel("Erkennung sicher, \(pct)")
        } else if reading.confidence >= 0.45 {
            StatusTag(text: "Prüfen · \(pct)", color: .orange)
                .accessibilityLabel("Erkennung unsicher, bitte prüfen, \(pct)")
        } else {
            StatusTag(text: "Unsicher · \(pct)", color: .red)
                .accessibilityLabel("Erkennung sehr unsicher, \(pct)")
        }
    }

    // MARK: Logik

    private func choose(_ token: NumberToken, for field: ReadingField) {
        setValue(Self.text(token.value, field), for: field)
        sources[field] = .chip
        selected[field] = token.id
        derive(after: field)
    }

    /// Dritten Wert aus den beiden anderen ableiten (Betrag = Liter × Preis pro Liter).
    private func derive(after field: ReadingField) {
        guard kind.isFuel else { return }
        let l = liters.asDouble
        let a = amount.asDouble
        let p = ppl.asDouble
        switch field {
        case .liters, .amount:
            if let lv = l, let av = a, lv > 0 {
                let computed = av / lv
                if Self.fuelRangeOK(ppl: computed) && sources[.pricePerLiter] != .chip && sources[.pricePerLiter] != .manual {
                    ppl = Self.text(computed, .pricePerLiter)
                    sources[.pricePerLiter] = .computed
                    selected[.pricePerLiter] = reading.chips(for: .pricePerLiter)
                        .first { abs($0.value - computed) < 0.0015 }?.id
                }
            }
        case .pricePerLiter:
            if let lv = l, let pv = p, a == nil || sources[.amount] == .computed {
                amount = Self.text(lv * pv, .amount)
                sources[.amount] = .computed
                selected[.amount] = nil
            } else if let av = a, let pv = p, pv > 0, l == nil || sources[.liters] == .computed {
                liters = Self.text(av / pv, .liters)
                sources[.liters] = .computed
                selected[.liters] = nil
            }
        case .km:
            break
        }
    }

    private static func fuelRangeOK(ppl: Double) -> Bool { ReadingParser.pplRange.contains(ppl) }

    private var consistencyWarning: String? {
        guard kind.isFuel, let l = liters.asDouble, let a = amount.asDouble, let p = ppl.asDouble, l > 0 else {
            return nil
        }
        if abs(a - l * p) > max(0.02, l * 0.001) {
            return "Betrag entspricht nicht Liter × Preis pro Liter – bitte Werte prüfen."
        }
        return nil
    }

    private var canApply: Bool {
        if kind.isFuel { return liters.asDouble != nil || amount.asDouble != nil }
        return km.asInt != nil
    }

    /// „Mit KI auswerten“ nur mit Server (im Lokalmodus nie)
    private var showServerButton: Bool {
        !store.isLocal && !reading.isUnambiguous && visionAvailable
    }

    private var attachmentFooter: String {
        store.isLocal
            ? "Der Beleg wird beim Sichern gespeichert und bleibt auf diesem iPhone."
            : "Der Beleg wird beim Sichern gespeichert und bei Verbindung auf deinen Server übertragen."
    }

    private func apply() {
        var outcome = ScanOutcome(kind: kind)
        if kind.isFuel {
            let p = ppl.asDouble
            var a = amount.asDouble
            var l = liters.asDouble
            if a == nil, let lv = l, let pv = p { a = (lv * pv * 100).rounded() / 100 }
            if l == nil, let av = a, let pv = p, pv > 0 { l = (av / pv * 100).rounded() / 100 }
            outcome.liters = l
            outcome.amount = a
            outcome.pricePerLiter = p
            if kind == .receipt {
                outcome.date = useDate ? date : nil
                outcome.station = station.nilIfEmpty
            }
        } else {
            outcome.km = km.asInt
        }
        if allowAttachment && saveAttachment {
            outcome.attachmentJPEG = ImageTools.attachmentJPEG(image)
        }
        onApply(outcome)
    }

    // MARK: Server (KI)

    private func askServer() {
        guard let jpeg = ImageTools.scanJPEG(image) else {
            serverNote = "Das Bild konnte nicht vorbereitet werden."
            return
        }
        serverBusy = true
        serverNote = nil
        let client = ScanClient(api: store.api, tenant: store.tenant.slug)
        let scanKind = kind
        Task {
            let outcome = await client.scan(jpeg: jpeg, kind: scanKind)
            serverBusy = false
            switch outcome {
            case .reading(let result):
                applyServer(result)
            case .noResult:
                serverNote = "Der Server hat keine Werte erkannt."
            case .notConfigured:
                visionAvailable = false
                serverNote = "Die KI-Auswertung ist auf deinem Server nicht eingerichtet."
            case .failed(let text):
                serverNote = text
            }
        }
    }

    private func applyServer(_ r: ScanClient.ServerReading) {
        if let v = r.liters, ReadingParser.litersRange.contains(v) { setServer(v, .liters) }
        if let v = r.amount, ReadingParser.amountRange.contains(v) { setServer(v, .amount) }
        if let v = r.pricePerLiter, ReadingParser.pplRange.contains(v) {
            setServer(v, .pricePerLiter)
        } else if kind.isFuel {
            derive(after: .liters)
        }
        if let v = r.km, v >= 0, v < 10_000_000 { setServer(v, .km) }
        if kind == .receipt {
            if let d = r.parsedDate {
                date = d
                useDate = true
            }
            if let s = r.station?.nilIfEmpty { station = s }
        }
        showChips = true
        var note = "Ausgewertet von der KI deines Servers"
        if let c = r.confidence { note += " (Konfidenz \(Fmt.pct(min(1, max(0, c)) * 100)))" }
        if let reason = r.reason?.nilIfEmpty { note += ": \(reason)" }
        serverNote = note + ". Bitte Werte prüfen."
    }

    private func setServer(_ value: Double, _ field: ReadingField) {
        guard Self.fields(kind).contains(field) else { return }
        setValue(Self.text(value, field), for: field)
        sources[field] = .server
        selected[field] = nil
    }
}

/// Foto mit Rahmen um erkannte Zahlen; zugeordnete Werte farbig.
struct ScanImageView: View {
    let image: UIImage
    let tokens: [NumberToken]
    let selected: [ReadingField: Int]

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    ForEach(tokens) { token in
                        marker(token, size: geo.size)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(maxHeight: 320)
            .accessibilityElement()
            .accessibilityLabel(accessibilityText)
    }

    private func marker(_ token: NumberToken, size: CGSize) -> some View {
        let field = selected.first { $0.value == token.id }?.key
        let color = field?.color ?? Color.white
        let width = max(token.box.width * size.width + 6, 10)
        let height = max(token.box.height * size.height + 4, 10)
        return RoundedRectangle(cornerRadius: 3)
            .stroke(color, lineWidth: field == nil ? 1 : 3)
            .background(color.opacity(field == nil ? 0 : 0.2), in: RoundedRectangle(cornerRadius: 3))
            .shadow(color: .black.opacity(0.5), radius: 1)
            .frame(width: width, height: height)
            .position(x: token.box.midX * size.width, y: token.box.midY * size.height)
            .opacity(field == nil ? 0.7 : 1)
    }

    private var accessibilityText: String {
        let assigned = ReadingField.allCases.compactMap { field -> String? in
            guard let id = selected[field], let t = tokens.first(where: { $0.id == id }) else { return nil }
            return "\(field.label) \(ScanResultView.text(t.value, field))"
        }
        if assigned.isEmpty { return "Aufnahme" }
        return "Aufnahme, hervorgehoben: " + assigned.joined(separator: ", ")
    }
}
