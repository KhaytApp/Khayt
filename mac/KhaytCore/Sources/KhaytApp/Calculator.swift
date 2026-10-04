import SwiftUI
import KhaytCore

/// What should I charge for this?
///
/// ── WHY A SCREEN, WHEN THE JOB SHEET ALREADY QUOTES ───────────────────────
///
/// Because the job sheet answers a different question. It quotes a job it is
/// about to take, and every figure in it is on its way into the book. A shop
/// asked "what would a hundred of these cost?" over the counter does not want
/// to create a job, price it, read the number and delete it — and that was the
/// only way to get an answer on this Mac. The Electron app has had a
/// calculator tab since the beginning; this is the one screen in it that a
/// shop reaches for daily and the Mac had no answer to at all.
///
/// ── AND WHY IT IS SHORT ───────────────────────────────────────────────────
///
/// Every figure here comes from `lib/calculator-cost.js` and `lib/pricing.js`,
/// through the same two calls the job sheet uses — `Shop.costedPart` and
/// `Shop.previewQuote`. Not one line of arithmetic is written in Swift. A
/// quote worked out here and the same job taken through the sheet come to the
/// same halalah, because they are the same code answering twice.
///
/// The rates a part is costed at — wear, power, electricity, prep, post,
/// labour, failure — come from the machine and the shop's settings, exactly as
/// they do for a real job. That is the point of picking a machine here rather
/// than typing seven numbers: the answer is what this shop on this printer
/// would actually charge, not a general one.
struct Calculator: View {
    @Bindable var shop: Shop

    /// ── THE ONE SCREEN THAT ONLY EXISTS FILLED IN ────────────────────────
    ///
    /// `KHAYT_SNAPSHOT_PART` / `_HOURS` fill it for the snapshot runner only —
    /// an environment variable this app is never launched with otherwise.
    ///
    /// Everything typed lives in `CalculatorModel`, so a test can move each
    /// input and watch the total move through the same calls this screen
    /// makes. The spool starts on a real one (see `onAppear`): without one
    /// there is no cost per gram and the material bucket comes out at zero.
    @State private var model = CalculatorModel.fromEnvironment()
    @State private var showRates = false
    @State private var newPresetName = ""
    /// The model the From a model row starts on — the snapshot harness's.
    private var pickedModel: (file: LibraryFile, plate: Int?)?

    init(shop: Shop) { self.shop = shop }

    /// Filled in from outside, for the snapshot harness: `ImageRenderer`
    /// cannot type into the fields or wait for the From a model sheet.
    init(shop: Shop, model: CalculatorModel, picked: (file: LibraryFile, plate: Int?)? = nil) {
        self.shop = shop
        _model = State(initialValue: model)
        pickedModel = picked
    }

    private var costed: KhaytEngine.CostedPart? { model.costed }
    private var quoted: QuoteTotal? { model.quoted }
    private var qty: Int { model.qty }
    private var machineId: String? { model.machineId }
    private var gramsValue: Double { model.gramsValue }
    /// Nothing to price until there is something to print.
    /// ── WHAT IT IS BEING COSTED AT, AND HOW TO CHANGE IT ────────────────
    ///
    /// The screen used to pick a machine and stop there, on the argument that
    /// picking one beats typing seven numbers — which is right, and was not
    /// the whole story: a machine carries only its power draw and its wear
    /// rate. Labour, prep, post, electricity and the failure allowance came
    /// from `lib/print-rates.js`'s openers whatever the shop had written down,
    /// and there was nowhere on this Mac to say otherwise. A shop paying a
    /// different wage was quoted at 90 an hour for ever.
    ///
    /// So: the figures are SHOWN, seeded from the preset and the machine, and
    /// editable. Typing one sends it as part of the part, where the shared
    /// rule already lets a part's own value win — no new precedence is
    /// invented here.
    @ViewBuilder private var ratesSection: some View {
        DisclosureGroup(isExpanded: $showRates) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                rateRow("calc.labor.rate", "laborRate", unit: shop.currency)
                rateRow("calc.labor.prep", "prepTime", unit: shop.words.callIt("common.hours"))
                rateRow("calc.labor.post", "postTime", unit: shop.words.callIt("common.hours"))
                rateRow("calc.machine.wear", "wearRate", unit: shop.currency)
                rateRow("calc.machine.power", "powerDraw", unit: "W")
                rateRow("calc.machine.elec", "elecRate", unit: shop.currency)
                rateRow("calc.labor.failure", "failureRate", unit: "%")
                // What this machine and material have actually failed at —
                // offered, never applied on its own.
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    VStack(alignment: .leading, spacing: 2) {
                        FailureHint(shop: shop, machineId: machineId,
                                    material: shop.spools.first { $0.id == model.lines.first?.spoolId }?.material,
                                    current: Double(model.rates["failureRate"] ?? "")) { pct in
                            model.rates["failureRate"] = Words.plain(.number(pct))
                        }
                    }
                }
            }
            .padding(.top, 6)
            HStack(spacing: 8) {
                Button(shop.words.callIt("mac.calc_rates_reset")) { model.seedRates() }
                    .disabled(!ratesEdited)
                Spacer(minLength: 0)
                // Keeping them is the difference between answering today's
                // question and not being asked it again.
                TextField(shop.words.callIt("calc.machine.preset_name_ph"), text: $newPresetName)
                    .textFieldStyle(.roundedBorder).frame(width: 140)
                Button(shop.words.callIt("calc.machine.save_preset")) {
                    Task {
                        var out: [String: Double] = [:]
                        for key in Shop.Preset.rateKeys { out[key] = model.typed(key) }
                        if let id = await shop.savePreset(name: newPresetName, rates: out) {
                            model.presetId = id
                            newPresetName = ""
                        }
                    }
                }
                .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Text(shop.words.callIt("mac.calc_cost_rates")).font(.caption.weight(.semibold))
                if ratesEdited {
                    Text(shop.words.callIt("mac.calc_rates_edited"))
                        .font(.caption2).foregroundStyle(Khayt.attention)
                }
            }
        }
    }

    private func rateRow(_ key: String, _ field: String, unit: String) -> some View {
        GridRow {
            Text(shop.words.callIt(key)).gridColumnAlignment(.trailing)
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                TextField("", text: Binding(get: { model.rates[field] ?? "" },
                                            set: { model.rates[field] = $0 }))
                    .textFieldStyle(.roundedBorder).frame(width: 70).monospacedDigit()
                Text(unit).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
            }
        }
    }

    private var ratesEdited: Bool { model.ratesEdited }
    private var hasInput: Bool { model.hasInput }

    var body: some View {
        ScrollView { content }
        .background(Khayt.ground)
        .task(id: model.key) { await model.recompute(shop) }
        // The rule's own answer for this preset and machine. Re-asked when
        // either moves, and the fields follow UNLESS the shop has typed over
        // them — overwriting a typed labour rate because a machine was picked
        // would throw away the thing they came here to change.
        .task(id: "\(model.presetId ?? "")|\(model.machineId ?? "")") {
            let edited = model.ratesEdited
            model.resolved = await shop.resolvedRates(presetId: model.presetId, machineId: model.machineId)
            if !edited { model.seedRates() }
        }
        // The book may not have loaded when this screen first appears, so the
        // default is chosen when the spools arrive rather than at init.
        .onChange(of: shop.spools.map(\.id)) { _, ids in
            if !model.lines.isEmpty, model.lines[0].spoolId == nil, let first = ids.first { model.lines[0].spoolId = first }
        }
        .onAppear {
            if !model.lines.isEmpty, model.lines[0].spoolId == nil { model.lines[0].spoolId = shop.spools.first?.id }
            // The runner's picture of the whole screen: a second colour, a
            // purge and a consumable. Never set outside the runner.
            if ProcessInfo.processInfo.environment["KHAYT_SNAPSHOT_MULTI"] == "1", model.lines.count == 1 {
                model.addFilament(spools: shop.spools)
                model.lines[0].grams = "116"
                model.lines[1].grams = "64"
                model.splitFrom = nil
                model.purge = "18"
                if !shop.consumables.isEmpty {
                    model.addConsumable(shop.consumables)
                    model.consumableLines[0].consumableId =
                        (shop.consumables.first { $0.id == "CONS-07" } ?? shop.consumables[0]).id
                    model.consumableLines[0].qty = 4
                }
            }
        }
    }

    /// The screen without its ScrollView, which `ImageRenderer` draws as an
    /// empty page — the snapshot tests photograph this.
    var content: some View {
            VStack(alignment: .leading, spacing: 22) {
                DetailSection(shop.words.callIt("mac.calc_part"),
                              accent: Khayt.brand, symbol: "wrench.and.screwdriver.fill") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            firstLineField
                            field(shop.words.callIt("mac.calc_time"), $model.hours,
                                  unit: shop.words.callIt("common.hours"))
                            Stepper(value: $model.qty, in: 1...9999) {
                                HStack(spacing: 6) {
                                    Text(shop.words.callIt("calc.part.qty"))
                                        .foregroundStyle(.secondary)
                                    Text("\(qty)").monospacedDigit()
                                }
                                .font(.callout)
                            }
                            .fixedSize()
                            Spacer(minLength: 0)
                        }
                        // Weight and time from a library model — the whole
                        // project, or one plate of it. See CalculatorFromModel.
                        CalculatorFromModel(shop: shop, calc: model,
                                            model: pickedModel?.file, plate: pickedModel?.plate)
                        LayerRule()
                        HStack(spacing: 10) {
                            // The spool decides the material cost per gram, and
                            // the machine decides the wear and the electricity.
                            // Both are the book's own rows, so the answer is
                            // this shop's, not a worked example.
                            spoolPicker(shop.words.callIt("calc.part.filament"),
                                        model.firstLineID.map(model.spoolBinding) ?? .constant(nil))
                            Picker(shop.words.callIt("mac.calc_printer"), selection: $model.machineId) {
                                Text(shop.words.callIt("mac.any_machine")).tag(String?.none)
                                ForEach(shop.machines) { machine in
                                    Text(machine.name).tag(String?.some(machine.id))
                                }
                            }
                            // The shop's own rates. A machine carries two of
                            // the seven; a preset carries all of them.
                            if !shop.presets.isEmpty {
                                Picker(shop.words.callIt("calc.machine.preset"), selection: $model.presetId) {
                                    Text(shop.words.callIt("mac.calc_rates_default")).tag(String?.none)
                                    ForEach(shop.presets) { preset in
                                        Text(preset.name).tag(String?.some(preset.id))
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        filamentLines
                        ratesSection
                    }
                    .card()
                }
                consumablesSection

                // ── NOT BEFORE THERE IS SOMETHING TO PRICE ────────────────
                //
                // A live margin slider, a discount slider and a rush-fee switch
                // sat above the words "Nothing to price yet" — three controls
                // for a calculation that has not started, on the screen a shop
                // prices a job on. Dragging any of them did nothing and said
                // nothing, which is the sort of control that teaches somebody
                // the app is not listening.
                //
                // The part comes first, then what to charge for it, then the
                // answer. That is also the order the question is asked in.
                if hasInput {
                    // The CONTROLS, which are not the answer — both sections
                    // were headed "What to charge", stacked, so the screen
                    // asked the same question twice and answered underneath the
                    // second one.
                    DetailSection(shop.words.callIt("mac.calc_rates")) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 14) {
                                slider(shop.words.callIt("calc.quote.margin"), $model.margin, 0...300)
                                slider(shop.words.callIt("calc.quote.discount"), $model.discount, 0...90)
                                Toggle(shop.words.callIt("calc.rush_fee"), isOn: $model.rush).fixedSize()
                                Spacer(minLength: 0)
                            }
                            // ── WHAT "MARGIN" MEANS HERE, IN THE ARITHMETIC ──
                            //
                            // `lib/pricing.js` documents its own parameter as
                            // "Percent markup on cost" and computes
                            // `baseCost * (1 + margin / 100)`. That is a MARKUP,
                            // and the slider beside it says "Target profit
                            // margin" — two different numbers. At 30% on a 95.36
                            // cost the price is 123.97 and the actual margin is
                            // 23.1%, which is seven points below what a shop
                            // reading the label would expect to keep.
                            //
                            // The other host has always said so: `tip.margin`
                            // reads "Your profit on top of cost. Price = cost ×
                            // (1 + margin%)" and is on the field in Electron.
                            // This app showed the slider and nothing else.
                            //
                            // So the SENTENCE is what was missing, not the
                            // arithmetic. Changing the formula would silently
                            // reprice every quote in every shop to fix a word;
                            // the existing string, already translated into nine
                            // languages, says exactly what the formula does.
                            //
                            // Under the row rather than on hover: a tooltip
                            // nobody opens is the same as no sentence at all,
                            // and this one is worth 7% of a price.
                            Text(shop.words.callIt("tip.margin"))
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .card()
                    }
                    answer
                } else {
                    nothingYet
                }
            }
            .padding(Metric.screen)
            // 720, not 900. This form is six short fields and two pickers;
            // stretched to 900 the last picker sat four hundred points from the
            // one before it and the row stopped reading as a row.
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// What the price is, and where it went.
    @ViewBuilder private var answer: some View {
        DetailSection(shop.words.callIt("mac.calc_price"),
                      accent: Khayt.brand, symbol: "banknote.fill") {
            VStack(alignment: .leading, spacing: 10) {
                BigFigure(value: Money.figure(quoted?.total ?? 0),
                          unit: Money.mark(shop.currency))
                // The cost underneath the price, because the difference between
                // them is the only reason to look at this screen twice.
                HStack(spacing: 5) {
                    Text(Money.short((costed?.cost ?? 0) * Double(qty), shop.currency))
                        .monospacedDigit()
                    Text(shop.words.callIt("mac.calc_cost").lowercased())
                        .foregroundStyle(.secondary)
                    if let q = quoted, q.discountAmount > 0 {
                        Text("·").foregroundStyle(.tertiary)
                        Text("−" + Money.short(q.discountAmount, shop.currency))
                            .monospacedDigit().foregroundStyle(Khayt.attention)
                    }
                    if let q = quoted, q.rushFee > 0 {
                        Text("·").foregroundStyle(.tertiary)
                        Text("+" + Money.short(q.rushFee, shop.currency))
                            .monospacedDigit().foregroundStyle(Khayt.hot)
                    }
                }
                .font(.callout).lineLimit(1)
                // The one thing this screen can be silently wrong about. With
                // no spool there is no cost per gram, the material bucket is
                // zero, and the price looks like a price. Said in words rather
                // than left for somebody to notice in the breakdown.
                if model.lines.contains(where: { $0.spoolId == nil && CalculatorModel.number($0.grams) > 0 }) {
                    Label(shop.words.callIt("mac.calc_no_filament"),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Khayt.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .card(rail: Khayt.brand, padding: 14)
        }

        // The four buckets, which is the thing a shop argues with. Same figures
        // the job sheet shows, from the same call.
        if let costedPart = costed, case let p = costedPart.parts,
           p.material + p.machine + p.labor + p.buffer > 0 {
            // ── THE FOUR SHOWN FIGURES ADD TO THE SHOWN COST ──────────────
            //
            // They did not. Each bucket is rounded to the halala on its own, so
            // 15.70 + 3.50 + 67.50 + 8.67 came to 95.37 while the cost — the
            // unrounded sum, rounded once — printed 95.36. A shop adding the
            // row by eye got a different answer from the one beside it, which
            // is the precise failure this whole line was added to prevent.
            //
            // The rounding lands in the BUFFER, which is what a buffer is: the
            // other three are measured quantities and this one is the allowance
            // that makes the total come out. The figure moves by at most a
            // halala and the row is checkable.
            let shownCost = costedPart.cost.rounded(toPlaces: 2)
            let m = p.material.rounded(toPlaces: 2)
            let mc = p.machine.rounded(toPlaces: 2)
            let lb = p.labor.rounded(toPlaces: 2)
            let bf = (shownCost - m - mc - lb).rounded(toPlaces: 2)
            DetailSection(shop.words.callIt("mac.calc_breakdown")) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 10) {
                        bucket("calc.bd.material", m)
                        bucket("calc.bd.machine", mc)
                        bucket("calc.bd.labor", lb)
                        bucket("calc.bd.buffer", bf)
                    }
                    // AND THAT THEY ADD UP. Four figures beside a fifth, with
                    // nothing saying the four make the fifth, is four figures a
                    // shop has to add in its head before it can argue with any
                    // of them — and arguing with them is what this section is
                    // for.
                    HStack(spacing: 5) {
                        Rectangle().fill(Khayt.hairline).frame(width: 1, height: 9)
                        Text("\(Money.figure(m)) + \(Money.figure(mc)) + "
                             + "\(Money.figure(lb)) + \(Money.figure(bf)) = "
                             + "\(Money.figure(shownCost)) "
                             + shop.words.callIt("mac.calc_breakdown_sum"))
                            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var nothingYet: some View {
        EmptyHere(title: shop.words.callIt("mac.calc_nothing"),
                  message: shop.words.callIt("mac.calc_nothing_hint"),
                  mark: .calculator)
            .frame(height: 260)
    }

    private func bucket(_ key: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(shop.words.callIt(key))
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .lineLimit(1)
            Text(Money.figure(value * Double(qty)))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        }
        .card()
    }

    private func field(_ label: String, _ text: Binding<String>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                TextField("", text: text)
                    .labelsHidden()
                    .monospacedDigit()
                    .frame(width: 74)
                Text(unit).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text("\(Int(value.wrappedValue))%").font(.caption).monospacedDigit()
            }
            Slider(value: value, in: range, step: 1).frame(width: 190)
        }
    }

    private func spoolPicker(_ label: String, _ selection: Binding<String?>) -> some View {
        Picker(label, selection: selection) {
            Text(shop.words.callIt("mac.any_filament")).tag(String?.none)
            // Material AND colour: a multicolour print is several spools of the
            // same material, and "PLA, PLA, PLA" is not a choice.
            ForEach(shop.spools) { spool in
                Text(shop.spoolName(spool)).tag(String?.some(spool.id))
            }
        }
    }

    // MARK: - Several filaments

    /// The first line's grams: the print's Weight while there is one
    /// filament, and plainly "Colour 1" — with its swatch, and the total
    /// beside it — once there are more. The same box meant the whole print
    /// and then, silently, one colour of it.
    @ViewBuilder private var firstLineField: some View {
        let id = model.firstLineID
        let grams = id.map(model.gramsBinding) ?? .constant("")
        if model.lines.count > 1, let first = model.lines.first {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    colourDot(first.hex ?? shop.spools.first { $0.id == first.spoolId }?.color)
                    Text(shop.words.callIt("mac.calc_colour_n", ["n": .number(1)]))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    TextField("", text: grams).labelsHidden().monospacedDigit().frame(width: 74)
                    Text(shop.words.callIt("common.grams")).font(.caption).foregroundStyle(.tertiary)
                    Text(shop.words.callIt("mac.calc_total_grams",
                                           ["g": .string(Money.grams(model.gramsValue))]))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        } else {
            field(shop.words.callIt("mac.calc_weight"), grams, unit: shop.words.callIt("common.grams"))
        }
    }

    @ViewBuilder private func colourDot(_ hex: String?) -> some View {
        if let rgb = CalculatorModel.rgb(hex) {
            Circle().fill(Color(red: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255))
                .overlay(Circle().stroke(Khayt.hairline))
                .frame(width: 10, height: 10)
        }
    }

    /// The second and later colours, the way to add one, and the purge.
    ///
    /// Bound BY ID (`CalculatorModel.gramsBinding`): an enumerated index
    /// binding trapped when a line was removed or From a model shrank the list.
    @ViewBuilder private var filamentLines: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.lines.dropFirst()) { line in
                let n = (model.lines.firstIndex { $0.id == line.id } ?? 0) + 1
                HStack(spacing: 8) {
                    colourDot(line.hex ?? shop.spools.first { $0.id == line.spoolId }?.color)
                    spoolPicker(shop.words.callIt("mac.calc_colour_n", ["n": .number(Double(n))]),
                                model.spoolBinding(line.id))
                    TextField("", text: model.gramsBinding(line.id))
                        .labelsHidden().monospacedDigit().frame(width: 74)
                    Text(shop.words.callIt("common.grams")).font(.caption).foregroundStyle(.tertiary)
                    Button(role: .destructive) { model.removeFilament(line.id) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(shop.words.callIt("common.delete"))
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 12) {
                Button { model.addFilament(spools: shop.spools) } label: {
                    Label(shop.words.callIt("mac.calc_add_filament"), systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                Spacer(minLength: 0)
                Text(shop.words.callIt("mac.calc_purge")).font(.caption).foregroundStyle(.secondary)
                TextField("", text: $model.purge)
                    .labelsHidden().monospacedDigit().frame(width: 60)
                Text(shop.words.callIt("common.grams")).font(.caption).foregroundStyle(.tertiary)
            }
            // Said once, when adding a colour divided the weight already typed
            // rather than adding to it.
            if let split = model.splitFrom {
                Text(shop.words.callIt("mac.calc_split_note", ["g": .string(Money.grams(split))]))
                    .font(.caption).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.isMulticolour || model.purgeValue > 0 {
                Text(shop.words.callIt(model.isMulticolour ? "mac.calc_multicolour_note" : "mac.calc_purge_note",
                                       ["g": .string(Money.grams(model.gramsValue + model.purgeValue)),
                                        "n": .number(Double(model.lines.filter { CalculatorModel.number($0.grams) > 0 }.count))]))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Consumables

    /// Magnets, inserts, screws — off the Consumables shelf, per printed piece.
    private var consumablesSection: some View {
        DetailSection(shop.words.callIt("mac.calc_consumables"), symbol: "shippingbox") {
            VStack(alignment: .leading, spacing: 8) {
                if shop.consumables.isEmpty {
                    Text(shop.words.callIt("mac.calc_no_consumables"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // By id, for the reason `filamentLines` gives.
                    ForEach(model.consumableLines) { line in
                        HStack(spacing: 8) {
                            Picker(shop.words.callIt("mac.calc_consumable"),
                                   selection: model.consumableBinding(line.id)) {
                                ForEach(shop.consumables) { item in
                                    Text(item.title(shop.words)).tag(String?.some(item.id))
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 240)
                            // From 1, as on the model page: a line of none is
                            // removed with its button, not stepped to zero.
                            Stepper(value: model.consumableQtyBinding(line.id), in: 1...9999, step: 1) {
                                Text("× " + Words.plain(.number(line.qty))).monospacedDigit()
                            }
                            .fixedSize()
                            if let id = line.consumableId,
                               let item = shop.consumables.first(where: { $0.id == id }) {
                                Text(Money.short((item.cost ?? 0) * line.qty, shop.currency))
                                    .monospacedDigit().foregroundStyle(.secondary)
                            }
                            Button(role: .destructive) {
                                model.removeConsumable(line.id)
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help(shop.words.callIt("common.delete"))
                            Spacer(minLength: 0)
                        }
                    }
                    Button { model.addConsumable(shop.consumables) } label: {
                        Label(shop.words.callIt("mac.calc_add_consumable"), systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    if !model.consumableLines.isEmpty {
                        Text(shop.words.callIt("mac.calc_consumables_note"))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .card()
        }
    }
}
