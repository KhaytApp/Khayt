import SwiftUI
import KhaytCore

/// The first-run setup: four short steps a new shop can walk through or leave.
///
/// See `ShopSetup` for what it asks and where each answer is written. This is
/// only the asking.
///
/// ── THE RULES IT IS BUILT TO ──────────────────────────────────────────────
///
/// - **Nothing blocks.** Every field is optional, Continue works on an empty
///   step, and Skip clears that step's answers before moving on.
/// - **Nothing is written until Finish**, and then in one write. Closing it
///   ("Not now", Escape) or choosing the sample writes nothing at all.
/// - **A way out on every step**: the sample shop, for somebody who wants to
///   see the app working before typing anything of their own.
/// - **It fits a 13-inch laptop.** A sheet cannot be moved, so it sits in
///   `SheetFrame`, which scrolls the questions and pins the buttons.
struct ShopSetupSheet: View {
    static let width: CGFloat = 520

    enum Step: Int, CaseIterable { case shop, printer, filament, finish }

    let shop: Shop

    @State private var step: Step
    // Step 1.
    @State private var currency: String
    @State private var electricity: Double?
    @State private var chargesVat: Bool
    @State private var vatRate: Double
    @State private var skippedShop = false
    // Step 2.
    @State private var printer: ShopSetup.Printer
    @State private var search = ""
    /// The model last picked, so its own name in the field is not offered
    /// back as a suggestion.
    @State private var pickedName: String?
    @State private var skippedPrinter = false
    // Step 3.
    @State private var filament: ShopSetup.Filament
    @State private var skippedFilament = false

    @State private var saving = false

    /// `step` and `prefill` are for the snapshot run, which photographs every
    /// step filled in. The app opens it with neither.
    init(shop: Shop, step: Step = .shop, prefill: ShopSetup? = nil) {
        self.shop = shop
        let held = ShopSetup.settingsReading(shop.settingsDict)
        _step = State(initialValue: step)
        _currency = State(initialValue: prefill?.currency ?? held.currency)
        _electricity = State(initialValue: prefill?.electricity)
        _chargesVat = State(initialValue: prefill?.chargesVat ?? held.chargesVat)
        _vatRate = State(initialValue: prefill?.chargesVat == nil ? held.vatRate : (prefill?.vatRate ?? 15))
        _printer = State(initialValue: prefill?.printer ?? ShopSetup.Printer())
        _search = State(initialValue: prefill?.printer?.name ?? "")
        _pickedName = State(initialValue: prefill?.printer?.name)
        _filament = State(initialValue: prefill?.filament ?? ShopSetup.Filament())
    }

    private var words: Words { shop.words }

    /// What Finish would write, from what is on screen.
    private var setup: ShopSetup {
        var out = ShopSetup()
        if !skippedShop {
            out.currency = currency
            out.electricity = electricity
            out.chargesVat = chargesVat
            out.vatRate = vatRate
        }
        if !skippedPrinter { out.printer = printer }
        if !skippedFilament { out.filament = filament }
        return out
    }

    private var held: (currency: String, chargesVat: Bool, vatRate: Double) {
        ShopSetup.settingsReading(shop.settingsDict)
    }

    private var writesAnything: Bool {
        setup.writesAnything(currentCurrency: held.currency, currentlyChargesVat: held.chargesVat,
                             currentVatRate: held.vatRate)
    }

    var body: some View {
        SheetFrame(width: Self.width) {
            header
            switch step {
            case .shop:     shopStep
            case .printer:  printerStep
            case .filament: filamentStep
            case .finish:   finishStep
            }
            if let problem = shop.setupProblem {
                Text(problem)
                    .font(.callout).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            footer
        }
        .task { await shop.readCatalog() }
    }

    // MARK: - The frame of every step

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                CapsLabel(words.callIt("mac.setup_step", [
                    "n": .number(Double(step.rawValue + 1)),
                    "total": .number(Double(Step.allCases.count)),
                ]), tint: Role.acc, size: 9.5)
                Spacer(minLength: 8)
                // Closing writes nothing, and is remembered — see
                // `Shop.setupKey`. The Book menu brings it back.
                Button(words.callIt("mac.setup_not_now")) { shop.setupSkipped() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            }
            Text(words.callIt(titleKey)).font(.title3.weight(.semibold))
            Text(words.callIt(whyKey))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var titleKey: String {
        switch step {
        case .shop: "mac.setup_shop_title"
        case .printer: "mac.setup_printer_title"
        case .filament: "mac.setup_filament_title"
        case .finish: "mac.setup_finish_title"
        }
    }

    private var whyKey: String {
        switch step {
        // On a Mac with no book, the first thing said is that nothing is
        // written until Finish — and that Finish starts one.
        case .shop: shop.source.isReal ? "mac.setup_shop_why" : "mac.setup_shop_why_new"
        case .printer: "mac.setup_printer_why"
        case .filament: "mac.setup_filament_why"
        case .finish: writesAnything ? "mac.setup_finish_why" : "mac.setup_finish_nothing"
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            // The escape hatch, on every step.
            Button(words.callIt("mac.setup_try_sample")) {
                Task { await shop.setupChoseSample() }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Role.accInk)
            .fixedSize()
            Spacer(minLength: 8)
            if step != .shop {
                Button(words.callIt("mac.setup_back")) { move(-1) }
            }
            if step != .finish {
                Button(words.callIt("mac.setup_skip")) { skipThisStep() }
                Button(words.callIt("mac.setup_continue")) { move(1) }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(words.callIt(finishKey)) {
                    saving = true
                    Task {
                        await shop.finishSetup(setup)
                        saving = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving)
            }
        }
    }

    private var finishKey: String {
        guard writesAnything else { return "mac.setup_close" }
        return shop.source.isReal ? "mac.setup_save" : "mac.setup_start_book"
    }

    private func move(_ by: Int) {
        step = Step(rawValue: min(max(0, step.rawValue + by), Step.allCases.count - 1)) ?? step
    }

    /// Skip clears what the step holds, so what was typed and then skipped is
    /// not written behind the shop's back.
    private func skipThisStep() {
        switch step {
        case .shop: skippedShop = true
        case .printer: skippedPrinter = true
        case .filament: skippedFilament = true
        case .finish: break
        }
        move(1)
    }

    // MARK: - Step 1: the shop

    private var currencies: [(code: String, label: String)] {
        let known = shop.currencies.map { ($0.key, $0.value.label) }.sorted { $0.1 < $1.1 }
        // The book's own, even if the table has never heard of it, so the
        // picker is never blank.
        return known.contains { $0.0 == currency } ? known : [(currency, currency)] + known
    }

    @ViewBuilder private var shopStep: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                label("set.currency")
                Picker("", selection: Binding(get: { currency },
                                              set: { currency = $0; skippedShop = false })) {
                    ForEach(currencies, id: \.code) { Text($0.label).tag($0.code) }
                }
                .labelsHidden().fixedSize()
            }
            GridRow {
                label("mac.setup_electricity")
                HStack(spacing: 6) {
                    TextField("0.18", value: Binding(get: { electricity },
                                                     set: { electricity = $0; skippedShop = false }),
                              format: .number.precision(.fractionLength(0...3)))
                        .textFieldStyle(.roundedBorder).monospacedDigit().frame(width: 90)
                    Text(words.callIt("mac.setup_per_kwh", ["mark": .string(Money.mark(currency))]))
                        .foregroundStyle(.secondary)
                }
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                hint("mac.setup_electricity_hint", ["name": .string(words.callIt("mac.setup_preset_name"))])
            }
            GridRow {
                label("mac.setup_vat")
                HStack(spacing: 8) {
                    Toggle(words.callIt("mac.setup_vat_on"),
                           isOn: Binding(get: { chargesVat }, set: { chargesVat = $0; skippedShop = false }))
                    if chargesVat {
                        TextField("", value: $vatRate, format: .number.precision(.fractionLength(0...2)))
                            .textFieldStyle(.roundedBorder).monospacedDigit().frame(width: 60)
                        Text(verbatim: "%").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Step 2: the printer

    /// The catalogue's filament printers, narrowed by what is typed. Five at
    /// most: this is a first question, not a browser, and typing narrows it.
    private var matches: [CatalogPrinter] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty, q != pickedName?.lowercased() else { return [] }
        return Array(shop.catalog
            .filter { ($0.tech ?? "fdm") == "fdm" && $0.name.lowercased().contains(q) }
            .prefix(5))
    }

    @ViewBuilder private var printerStep: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow(alignment: .top) {
                label("mach.printer_model")
                VStack(alignment: .leading, spacing: 4) {
                    TextField(words.callIt("mach.printer_model_ph"), text: $search)
                        .textFieldStyle(.roundedBorder)
                    ForEach(matches) { model in
                        Button { pick(model) } label: {
                            Text(model.name).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Role.accInk)
                    }
                    if let id = printer.catalogId,
                       let specs = shop.catalog.first(where: { $0.id == id })?.specs, !specs.isEmpty {
                        Text(verbatim: specs)
                            .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                }
            }
            GridRow {
                label("mach.name")
                TextField(words.callIt("mach.name_ph"), text: edit(\.name))
                    .textFieldStyle(.roundedBorder)
            }
            GridRow {
                label("mac.power")
                HStack(spacing: 4) {
                    TextField("", value: edit(\.powerDraw), format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder).monospacedDigit().frame(width: 80)
                    Text(words.callIt("mac.unit_watts")).foregroundStyle(.secondary)
                }
            }
            GridRow {
                label("mac.dep_price")
                HStack(spacing: 4) {
                    TextField("", value: edit(\.price), format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder).monospacedDigit().frame(width: 100)
                    Text(Money.mark(currency)).foregroundStyle(.secondary)
                }
            }
            GridRow {
                label("mac.dep_bought")
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { printer.bought != nil },
                        set: { printer.bought = $0 ? (printer.bought ?? Date()) : nil; skippedPrinter = false }))
                        .labelsHidden()
                    if let bought = printer.bought {
                        DatePicker("", selection: Binding(get: { bought }, set: { printer.bought = $0 }),
                                   in: ...Date(), displayedComponents: .date)
                            .labelsHidden()
                    }
                }
            }
            GridRow {
                label("mac.dep_life")
                HStack(spacing: 6) {
                    TextField("", value: edit(\.lifeHours), format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder).monospacedDigit().frame(width: 80)
                    Text(words.callIt("mac.dep_unit_hours")).foregroundStyle(.secondary)
                }
            }
        }
        hint("mac.setup_printer_hint")
    }

    /// A binding into the printer that also un-skips the step: typing into a
    /// step after skipping it means the shop changed its mind.
    private func edit<T>(_ path: WritableKeyPath<ShopSetup.Printer, T>) -> Binding<T> {
        Binding(get: { printer[keyPath: path] },
                set: { printer[keyPath: path] = $0; skippedPrinter = false })
    }

    private func pick(_ model: CatalogPrinter) {
        skippedPrinter = false
        printer.catalogId = model.id
        pickedName = model.name
        search = model.name
        if printer.name.trimmingCharacters(in: .whitespaces).isEmpty { printer.name = model.name }
        // The Machine sheet's own rule for what a picked model fills in.
        var form = MachineSheet.Form()
        form.powerDraw = printer.powerDraw
        form.nozzleDiameter = printer.nozzleDiameter
        form.nozzleMaterial = printer.nozzleMaterial
        let filled = MachineSheet.picked(model, into: form)
        printer.powerDraw = filled.powerDraw
        printer.nozzleDiameter = filled.nozzleDiameter
        printer.nozzleMaterial = filled.nozzleMaterial
    }

    // MARK: - Step 3: the filament

    private func spoolEdit<T>(_ path: WritableKeyPath<ShopSetup.Filament, T>) -> Binding<T> {
        Binding(get: { filament[keyPath: path] },
                set: { filament[keyPath: path] = $0; skippedFilament = false })
    }

    @ViewBuilder private var filamentStep: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                label("mac.setup_material")
                TextField("PLA", text: spoolEdit(\.material))
                    .textFieldStyle(.roundedBorder).frame(width: 160)
            }
            GridRow {
                label("inv.cost")
                HStack(spacing: 4) {
                    TextField("", value: spoolEdit(\.cost), format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder).monospacedDigit().frame(width: 100)
                    Text(Money.mark(currency)).foregroundStyle(.secondary)
                }
            }
            GridRow {
                label("inv.weight")
                HStack(spacing: 4) {
                    TextField("", value: spoolEdit(\.weight), format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder).monospacedDigit().frame(width: 80)
                    Text(words.callIt("unit.g")).foregroundStyle(.secondary)
                }
            }
            if filament.cost > 0, filament.weight > 0 {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text(words.callIt("mac.setup_per_kg", [
                        "price": .string(Self.isolated(Money.text(filament.cost / filament.weight * 1000, currency))),
                    ]))
                    .font(.callout.weight(.semibold))
                }
            }
        }
        hint("mac.setup_filament_hint")
    }

    // MARK: - Step 4: finish

    /// One line per thing Finish will write, in the shop's words.
    private var summary: [String] {
        let s = setup
        var lines: [String] = []
        if let form = s.settingsForm(currentCurrency: held.currency, currentlyChargesVat: held.chargesVat,
                                     currentVatRate: held.vatRate) {
            if case .string(let code)? = form["currency"] {
                lines.append(words.callIt("mac.setup_sum_currency", ["code": .string(Self.isolated(code))]))
            }
            if case .bool(let on)? = form["enableVat"] {
                lines.append(on
                    ? words.callIt("mac.setup_sum_vat_on", ["rate": .string(Self.isolated(Words.plain(.number(s.vatRate))))])
                    : words.callIt("mac.setup_sum_vat_off"))
            }
        }
        if s.writesElectricity, let tariff = s.electricity {
            lines.append(words.callIt("mac.setup_sum_electricity", [
                "rate": .string(Self.isolated(Words.plain(.number(tariff)) + " " + Money.mark(currency))),
                "name": .string(words.callIt("mac.setup_preset_name")),
            ]))
        }
        if s.writesPrinter, let p = s.printer {
            lines.append(p.price > 0
                ? words.callIt("mac.setup_sum_printer_value", [
                    "name": .string(Self.named(s.printerName)),
                    "price": .string(Self.isolated(Money.text(p.price, currency))),
                    "hours": .string(Self.isolated(Words.plain(.number(p.lifeHours)))),
                ])
                : words.callIt("mac.setup_sum_printer", ["name": .string(Self.named(s.printerName))]))
        }
        if s.writesFilament, let f = s.filament {
            lines.append(words.callIt("mac.setup_sum_filament", [
                "material": .string(Self.named(f.material.trimmingCharacters(in: .whitespaces))),
                "price": .string(Self.isolated(Money.text(f.cost, currency))),
            ]))
        }
        return lines
    }

    @ViewBuilder private var finishStep: some View {
        let lines = summary
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                // A fixed handful — five at most, one per kind of answer.
                ForEach(lines, id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "checkmark").foregroundStyle(Role.acc).font(.caption)
                        Text(line).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        hint("mac.setup_finish_hint")
    }

    // MARK: - Pieces

    private func label(_ key: String) -> some View {
        Text(words.callIt(key)).foregroundStyle(.secondary)
    }

    private func hint(_ key: String, _ params: [String: JSONValue] = [:]) -> some View {
        Text(params.isEmpty ? words.callIt(key) : words.callIt(key, params))
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A figure set into a sentence, held left to right — the reason
    /// `Money.held` exists, applied to every figure: in an Arabic sentence a
    /// bare "5,000" or "15" takes the paragraph's direction at its edges.
    static func isolated(_ figure: String) -> String { "\u{2066}" + figure + "\u{2069}" }

    /// A name the shop typed, set into a sentence in its OWN direction (a
    /// first-strong isolate). Without it an Arabic line that opens with
    /// "Bambu Lab X1 Carbon" is read as a left-to-right paragraph — its first
    /// strong letter is Latin — and the name lands at the wrong end.
    static func named(_ text: String) -> String { "\u{2068}" + text + "\u{2069}" }
}
