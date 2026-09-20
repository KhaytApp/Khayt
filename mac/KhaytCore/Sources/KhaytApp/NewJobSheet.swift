import SwiftUI
import KhaytCore

/// Taking a job.
///
/// The cart, then the money. A job is one or more parts — a part is a thing
/// that goes on a plate, and a job is what a customer is charged for — so the
/// parts are a list you add to rather than a single form, the way the shop
/// floor actually works: "two brackets and a lid, for Acme, by Thursday".
///
/// WHAT A PART COSTS IS NOT WORKED OUT HERE. `computePartBaseCost` in
/// `lib/calculator-cost.js` is the same function the Electron calculator and
/// the phone's quote endpoint call; this screen fills its inputs and shows what
/// it says. A second cost model would mean two prices for one part.
///
/// Choosing a spool fills the material and the cost of it, because the shelf
/// already knows what that spool cost and how much of it there was — asking
/// again is asking a shop to retype something it has told the app once.
///
/// The four figures under the total are there because most of what a print
/// costs is not filament. This screen asks for grams and hours and nothing
/// else, so a shop is entitled to see what else went into the number before it
/// quotes somebody — and, more to the point, to notice when one of them is
/// zero.
struct NewJobSheet: View {
    /// Everything between the title and the buttons.
    ///
    /// Its own property because `ImageRenderer` draws nothing inside a
    /// `ScrollView` — the snapshot of this sheet was a title, two rules and
    /// three buttons over an empty page, and passed, because a picture has
    /// nothing to assert. The test photographs this directly.
    var paper: some View {
        VStack(alignment: .leading, spacing: 16) {
            who
            if let agreementNote {
                Text(agreementNote).font(.caption).foregroundStyle(.secondary)
            }
            cart
            money
            total
            breakdown
        }
        .padding(18)
    }

    /// How wide this sheet is. A CONSTANT rather than a number in the body,
    /// because `SnapshotTests` photographs the sheet at a size of its own and
    /// the two silently disagreed: the sheet grew and the picture kept the old
    /// width, so the render came back cropped down the middle with no failure.
    static let width: CGFloat = 620

    let shop: Shop

    @State private var project = ""
    @State private var clientId: String?
    @State private var parts: [Draft] = []
    @State private var draft = Draft()
    /// What the shop typed for the assistant to read, and what came back.
    @State private var described = ""
    @State private var drafting = false
    /// Every inference the model made, for the shop to read BEFORE it quotes.
    @State private var assumptions: [String] = []
    @State private var aiProblem: String?
    @State private var margin = 40.0
    /// The shop's own realized margins on jobs like this one. Nil until asked.
    @State private var comparables: KhaytEngine.PriceComparables?
    @State private var advising = false
    /// What the model said, and why. Shown under the comparables it weighed.
    @State private var advice: String?
    @State private var discountPct = 0.0
    @State private var shippingCost = 0.0
    @State private var deposit = 0.0
    @State private var rush = false
    @State private var quoted: QuoteTotal?
    @State private var problem: String?
    /// The last word on the total: round it to 1, 5 or 10, or type it.
    @State private var rule = Shop.PriceRule()
    /// The typed total as typed. Text, because a `Double?` behind a field
    /// reformats under the cursor and cannot be cleared back to "auto".
    @State private var overrideText = ""
    /// Charges that are not printing: a design fee, painting, a marketplace's
    /// cut. Empty for most jobs, which is why the row only appears once there
    /// is one.
    @State private var extraLines: [Shop.ExtraLine] = []
    /// The marketplaces a shop can sell through, and which one this job is for.
    ///
    /// Held rather than asked while drawing: the engine is an actor, and a view
    /// cannot ask it a question in the middle of a body.
    @State private var platforms: [KhaytEngine.Platform] = []
    @State private var platformId = ""
    /// "Price agreement applied" — said once, under the customer, when
    /// choosing them changed a figure in the cart.
    @State private var agreementNote: String?
    @FocusState private var focused: Bool

    /// One part, as this screen collects it.
    ///
    /// The cost fields it does not ask for — wear, power, labour, the failure
    /// allowance — come from `lib/print-rates.js`, which holds the figures the
    /// Electron calculator's own form opens on. They used to come from five
    /// settings keys Khayt never writes, which meant they came to nothing.
    struct Draft: Identifiable, Equatable {
        let id = UUID()
        var name = ""
        var spoolId: String?
        var grams = ""
        var hours = ""
        var qty = 1
        var cost: Double = 0
        /// What the customer has agreed to pay for each of these, when they
        /// have. The cost stays the cost; the price of this part is this.
        var agreedPrice: Double?
        /// Where that cost went. Held per part so the sheet can add up the cart
        /// without asking the engine again for each one.
        var parts: KhaytEngine.CostParts?
        /// What it was costed AT. Written onto the saved part, because Khayt's
        /// own editor reads these back and a part without them re-costs to
        /// nothing the next time somebody presses save there.
        var rates: KhaytEngine.Rates?
        /// The product part this came from, whole — so it is costed at the
        /// rates the catalogue priced it with, not the machine's defaults.
        var raw: [String: JSONValue] = [:]

        var isComplete: Bool { (Double(grams) ?? 0) > 0 || (Double(hours) ?? 0) > 0 }

        /// One of a product's parts, as this sheet holds it.
        ///
        /// The same fields `ProductSheet.PartRow` writes, read back — a job
        /// taken from a product starts as the product's own parts, and then
        /// belongs to the job: changing the grams here prices THIS job and
        /// leaves the catalogue alone.
        @MainActor static func from(_ value: JSONValue) -> Draft? {
            guard case .object(let o) = value else { return nil }
            var row = Draft()
            row.raw = o
            row.name = Shop.plainString(o["name"]) ?? ""
            row.spoolId = Shop.plainString(o["filamentId"])
            // `fieldValue`, NOT `quantity` — see the note there. The
            // display formatter groups thousands, and `Double("1,234.6")` is
            // nil, so every part over a kilo arrived as nothing.
            row.grams = Money.fieldValue(Shop.plainNumber(o["printWeight"]))
            row.hours = Money.fieldValue(Shop.plainNumber(o["printTime"]))
            row.qty = max(1, Int(Shop.plainNumber(o["qty"]) ?? 1))
            return row
        }
    }

    /// The product this job is being taken from, if any. Held so the sheet can
    /// offer its tiers and the saved order can name it.
    @State private var product: Product?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView { paper }
            Divider()
            footer
        }
        // Sized to what is in it, not to a number. A fixed height left a third
        // of the sheet blank for a one-part job and would have clipped a
        // six-part one; the cap is there so a long cart scrolls rather than
        // growing the window past the screen.
        .frame(width: Self.width)
        .frame(maxHeight: 640)
        .task {
            platforms = await shop.platforms()
            // A draft reopened already carrying a marketplace's lines must
            // show that marketplace, or the control is lying about the quote
            // it is sitting on.
            platformId = Shop.platformOn(extraLines) ?? ""
        }
        .onAppear {
            margin = shop.defaultMargin
            // ── FROM A PRODUCT, IF THE SHOP ASKED FOR ONE ─────────────────
            //
            // Its parts, its margin and its name, filled in — and then it is
            // an ordinary job sheet: everything here can be changed before it
            // is taken, because a customer who wants two of them in a
            // different colour is still ordering the product.
            if let taken = shop.jobFromProduct {
                product = taken
                project = taken.anyName()
                if let own = taken.margin { margin = own }
                // The product's own price — typed, or rounded to a step —
                // is the job's, so the total that opens is the catalogue's.
                rule = Shop.priceRule(of: taken)
                if let typed = rule.override { overrideText = Money.fieldValue(typed) }
                shop.jobFromProduct = nil
                // COSTED, not just measured: see `Shop.jobParts`. The engine
                // is asked once per part, so the cart fills in a beat later
                // than the name — and the total with it.
                Task { parts = await shop.jobParts(from: taken) }
            }
            focused = true
        }
        .task(id: signature) { await reprice() }
        .onChange(of: clientId) { _, chosen in Task { await customerChosen(chosen) } }
    }

    // MARK: - The screen

    private var header: some View {
        HStack {
            Text(shop.words.callIt("mac.new_job")).font(.headline)
            Spacer()
        }
        .padding(18)
    }

    private var who: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                Text(shop.words.callIt("mac.job")).gridColumnAlignment(.trailing)
                    .foregroundStyle(.secondary)
                TextField(shop.words.callIt("mac.what_is_it"), text: $project)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
            }
            GridRow {
                Text(shop.words.callIt("doc.client")).gridColumnAlignment(.trailing)
                    .foregroundStyle(.secondary)
                Picker("", selection: $clientId) {
                    // A walk-in is a real answer, and the commonest one for a
                    // shop that has not written the customer down yet.
                    Text(shop.words.callIt("mac.walk_in")).tag(String?.none)
                    // ONLY the customers with a record of their own. `id` on a
                    // name-only customer is their name lowercased, and a job
                    // carrying that as its clientId points at nothing — which
                    // is worse than a job with no customer, because it looks
                    // linked and is not.
                    ForEach(shop.customers.filter { $0.clientId != nil }) { c in
                        Text(c.name).tag(c.clientId)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260, alignment: .leading)
            }
        }
    }

    /// A product was taken and none of its parts can be costed.
    ///
    /// Not "the total is zero" — the total is `—`, because §5 says a figure
    /// nobody has been told is not a figure of nothing. What the shop needs is
    /// the reason, on the screen where it met it: the product editor says this
    /// when you are editing one, and a shop taking a job from the catalogue
    /// never opens that sheet.
    private var nothingToCost: Bool {
        product != nil && !parts.isEmpty && parts.allSatisfy { !$0.isComplete }
    }

    private var cart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(shop.words.callIt("mac.parts")).font(.subheadline.weight(.semibold))

            if nothingToCost, let product {
                Text(shop.words.callIt("mac.product_not_costed",
                                       ["product": .string(product.anyName())]))
                    .font(.callout)
                    .foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(parts) { part in
                HStack(spacing: 8) {
                    Text(part.name.isEmpty ? shop.words.callIt("mac.a_part") : part.name)
                        .lineLimit(1)
                    Text("×\(part.qty)").foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    if let agreed = part.agreedPrice {
                        // The agreed figure IS the price of this line; the
                        // cost it replaced is said small beside it.
                        Text(Money.figure(agreed * Double(part.qty)))
                            .monospacedDigit()
                        Text(shop.words.callIt("ce.pl_autofill") + " · " + Money.figure(part.cost * Double(part.qty)))
                            .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                    } else {
                        Text(Money.figure(part.cost * Double(part.qty)))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Button {
                        parts.removeAll { $0.id == part.id }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
                        .help(shop.words.callIt("common.delete"))
                }
                .padding(.vertical, 2)
            }

            // ABOVE the form it fills, not below it. Below, a shop types a
            // description and has to look UP to watch grams and hours appear —
            // the order on screen has to be the order of the work: say what it
            // is, see what that filled in, correct it, add it.
            describeBox
            partForm
        }
    }

    /// Describe the job in words and let the assistant fill the part.
    ///
    /// ── IT FILLS THE FORM; THE CALCULATOR STILL PRICES IT ─────────────────
    ///
    /// `lib/ai-quote.js` calls that its governing contract, and the shape of
    /// this screen is what keeps it: the draft lands in the SAME fields a shop
    /// types into, and nothing is added to the cart until Add is pressed. So
    /// every figure is seen, and changeable, before it reaches a customer — and
    /// the price is the shop's own calculator's, from the shop's own rates,
    /// exactly as it is for a part typed by hand.
    ///
    /// Only shown when the shop has actually agreed to it. A box offering to
    /// draft a quote for a shop that has not switched the feature on is an
    /// advertisement on a screen somebody is trying to work in.
    @ViewBuilder private var describeBox: some View {
        if shop.aiCanDraftQuotes {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(Khayt.brand)
                    TextField(shop.words.callIt("mac.describe_the_job"), text: $described)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await draftFromDescription() } }
                    Button(shop.words.callIt("mac.draft_it")) {
                        Task { await draftFromDescription() }
                    }
                    .disabled(drafting || described.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if drafting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(shop.words.callIt("mac.drafting")).font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                // WHAT IT ASSUMED, always, and not folded away. A drafted part
                // is a guess with figures in it, and the assumptions are the
                // only way to tell a good one from a confident one.
                if !assumptions.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shop.words.callIt("mac.it_assumed"))
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(assumptions, id: \.self) { note in
                            Text("• " + note).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if let aiProblem {
                    Text(aiProblem).font(.caption).foregroundStyle(Khayt.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .card(padding: 10)
        }
    }

    /// Ask, then fill the form the shop was going to type into.
    private func draftFromDescription() async {
        let said = described.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty, !drafting else { return }
        drafting = true
        aiProblem = nil
        assumptions = []
        defer { drafting = false }

        let out = await shop.draftPartFromDescription(said)
        switch out {
        case .refused(let why):
            aiProblem = why
        case .filled(let filled):
            // Only the fields the model is entitled to answer for. The name is
            // what the shop typed, because a model naming the job is a model
            // writing on an invoice.
            if draft.name.isEmpty { draft.name = said }
            if filled.grams > 0 { draft.grams = Money.fieldValue(filled.grams) }
            if filled.hours > 0 { draft.hours = Money.fieldValue(filled.hours) }
            if filled.qty > 0 { draft.qty = filled.qty }
            if let spool = filled.spoolId { draft.spoolId = spool }
            assumptions = filled.assumptions
        }
    }

    /// The part being described.
    ///
    /// IN ITS OWN BOX, with its own labels. It shared a Grid with the money
    /// fields at first, and "Target profit margin" stretched the label column so
    /// far that "Machine time" wrapped one letter per line. The two groups ask
    /// about different things and have no reason to line up.
    private var partForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(shop.words.callIt("mac.a_part"), text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $draft.spoolId) {
                    Text(shop.words.callIt("mac.filament")).tag(String?.none)
                    ForEach(shop.spools) { spool in
                        Text(spool.label(shop.words, unit: shop.unit(of: spool))).tag(String?.some(spool.id))
                    }
                }
                .labelsHidden()
                .frame(width: 190)
            }
            HStack(spacing: 8) {
                // Short prompts inside the fields rather than labels beside
                // them: three numbers on one line is the shape of the question
                // ("180 grams, four hours, two of them"), and a label each
                // would take the width the numbers need.
                TextField(shop.words.callIt("mac.grams"), text: $draft.grams)
                    .textFieldStyle(.roundedBorder).frame(width: 90).monospacedDigit()
                TextField(shop.words.callIt("mac.hours"), text: $draft.hours)
                    .textFieldStyle(.roundedBorder).frame(width: 90).monospacedDigit()
                Stepper("× \(draft.qty)", value: $draft.qty, in: 1...999)
                    .monospacedDigit().fixedSize()
                Spacer(minLength: 8)
                Button(shop.words.callIt("mac.add_part")) { Task { await addPart() } }
                    .disabled(!draft.isComplete)
            }
        }
        .card(padding: 10)
    }

    private var money: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                Text(shop.words.callIt("calc.quote.margin")).gridColumnAlignment(.trailing)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    percent($margin)
                    Text(shop.words.callIt("calc.quote.discount")).foregroundStyle(.secondary)
                    percent($discountPct)
                    Toggle(shop.words.callIt("calc.rush_fee"), isOn: $rush).fixedSize()
                }
            }
            // ── THE PRODUCT'S OWN TIERS ───────────────────────────────────
            //
            // A shop that sells the same thing retail and wholesale keeps the
            // two margins on the product. They are offered HERE, beside the
            // margin field, because that is the only thing a tier changes: the
            // price follows from the parts, so a tier stays right when
            // filament gets dearer in a way a stored price would not.
            if !Shop.tiers(of: product).isEmpty {
                GridRow {
                    Color.clear.frame(height: 0)
                    HStack(spacing: 6) {
                        Text(shop.words.callIt("cat.pick_tier"))
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(Shop.tiers(of: product)) { tier in
                            Button {
                                margin = tier.margin
                            } label: {
                                Text("\(tier.label) \(Money.quantity(tier.margin))%")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            // The one in force is shown as chosen, so a shop
                            // can see which price it is quoting rather than
                            // reading the margin back off the field.
                            .tint(abs(margin - tier.margin) < 0.005 ? Khayt.brand : nil)
                        }
                        Spacer()
                    }
                }
            }
            // ── THE LAST WORD ON THE TOTAL ────────────────────────────────
            //
            // Cost plus margin is where a price starts, not where it ends. A
            // shop that quotes 1,847.36 says 1,850, and one that has just
            // agreed 1,800 on the phone types 1,800. Same steps and words as
            // a product's price; the rule is lib/pricing.js and the record
            // says which of the three reached the figure.
            GridRow {
                Text(shop.words.callIt("pe.round_to")).gridColumnAlignment(.trailing)
                    .foregroundStyle(.secondary).fixedSize()
                // FIXED WIDTHS AND ONE LINE EACH. Photographed with a product's
                // rounding in force, this row let its labels wrap — "Or set the
                // price" stood four words tall — and the Total below it left the
                // sheet. A control row is measured, not negotiated.
                HStack(spacing: 8) {
                    Picker("", selection: $rule.step) {
                        ForEach(Shop.PriceRule.steps, id: \.self) { step in
                            Text(step == 0 ? shop.words.callIt("pe.round_off") : Money.quantity(step)).tag(step)
                        }
                    }
                    .labelsHidden().frame(width: 120)
                    Picker("", selection: $rule.mode) {
                        ForEach(Shop.PriceRule.modes, id: \.self) { mode in
                            Text(shop.words.callIt("pe.round_\(mode)")).tag(mode)
                        }
                    }
                    .labelsHidden().frame(width: 96)
                    .disabled(rule.step <= 0)
                    Text(shop.words.callIt("pe.price_override"))
                        .foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    TextField(shop.words.callIt("pe.price_override_ph"), text: $overrideText)
                        .textFieldStyle(.roundedBorder).frame(width: 84).monospacedDigit()
                        .onChange(of: overrideText) { _, typed in
                            let cleaned = typed.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
                            rule.override = cleaned.isEmpty ? nil : max(0, Double(cleaned) ?? 0)
                        }
                }
            }
            // ── CHARGES THAT ARE NOT PRINTING ─────────────────────────────
            //
            // A design fee, painting, a marketplace's cut. Khayt has priced
            // these since 3.0 and this sheet could not carry one, so a shop
            // that charges for anything but the print had to take the job in
            // the other window.
            //
            // A PERCENTAGE IS NOT AN AMOUNT. `lib/pricing.js` works a
            // percentage out against the price before extras — after the
            // margin, the discount and the rounding — so the two cannot be
            // collapsed into one field here. The picker is the whole reason
            // this is not just a number.
            //
            // ── A MARKETPLACE'S CUT, WITHOUT TYPING IT EVERY TIME ─────────
            //
            // Asked for twice by the same shop: "Etsy for instance charges two
            // percentage based fees and a relisting fee of .20 for each item
            // sold." Half of it already worked — those are three ordinary
            // extra lines — and what was missing is that somebody had to
            // remember Etsy's three numbers and type them onto every quote.
            //
            // THE SCHEDULE IS SHOWN, not a resolved total. Each line's own
            // money is already drawn beside it in the rows below, and a second
            // figure here would be a separate computation free to go stale
            // against the quote it is describing.
            //
            // The rates are a STARTING POINT and not an authority —
            // marketplaces change them, they vary by country and category, and
            // a shop on a legacy plan pays different ones. Every line lands in
            // the table below as an ordinary charge the shop can edit or
            // delete, which is why picking one is safe.
            if !platforms.isEmpty {
                GridRow {
                    Text(shop.words.callIt("calc.platform_fees"))
                        .gridColumnAlignment(.trailing)
                        .foregroundStyle(.secondary).fixedSize()
                    HStack(spacing: 8) {
                        Picker("", selection: $platformId) {
                            Text(shop.words.callIt("calc.platform_none")).tag("")
                            ForEach(platforms) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden().frame(width: 190)
                        // "6.5% + 3% + 0.20" — what it is, before it is added.
                        if let picked = platforms.first(where: { $0.id == platformId }) {
                            Text(picked.lines.map { line in
                                line.pct.map { Money.fieldValue($0) + "%" }
                                    ?? Money.figure(line.amount ?? 0)
                            }.joined(separator: " + "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                // PICKING REPLACES, it does not stack. Clicking twice would
                // otherwise put a second copy of Etsy's three charges on the
                // quote, which a shop only notices on the finished invoice.
                // The shop's own typed lines are kept exactly as they are.
                .onChange(of: platformId) {
                    let want = platformId
                    Task { extraLines = await shop.applyingPlatform(want, to: extraLines) }
                }
            }

            // The row only appears once there is a line, because most jobs
            // have none and an empty table is a row of furniture.
            GridRow {
                Text(shop.words.callIt("calc.extra_lines")).gridColumnAlignment(.trailing)
                    .foregroundStyle(.secondary).fixedSize()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach($extraLines) { $line in
                        HStack(spacing: 6) {
                            TextField(shop.words.callIt("calc.extra_label_ph"), text: $line.label)
                                .textFieldStyle(.roundedBorder).frame(width: 190)
                            Picker("", selection: Binding(
                                get: { line.isPercent },
                                set: { wantsPercent in
                                    // Switching kind CLEARS the other figure.
                                    // "50" meaning fifty riyals and "50"
                                    // meaning half the job are different
                                    // charges, and carrying the number across
                                    // would quietly turn one into the other.
                                    if wantsPercent { line.pct = 0; line.amount = 0 }
                                    else { line.pct = nil }
                                })) {
                                    Text(Money.mark(shop.currency)).tag(false)
                                    Text("%").tag(true)
                                }
                                .labelsHidden().pickerStyle(.segmented).frame(width: 84)
                            if line.isPercent {
                                TextField("", value: Binding(
                                    get: { line.pct ?? 0 },
                                    set: { line.pct = max(0, $0) }),
                                          format: .number.precision(.fractionLength(0...2)))
                                    .textFieldStyle(.roundedBorder).frame(width: 72).monospacedDigit()
                            } else {
                                TextField("", value: $line.amount,
                                          format: .number.precision(.fractionLength(0...2)))
                                    .textFieldStyle(.roundedBorder).frame(width: 72).monospacedDigit()
                            }
                            Button {
                                extraLines.removeAll { $0.id == line.id }
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(shop.words.callIt("common.delete"))
                        }
                    }
                    Button(shop.words.callIt("calc.add_extra_line")) {
                        extraLines.append(Shop.ExtraLine())
                    }
                    .buttonStyle(.borderless)
                }
            }
            .onChange(of: extraLines) { Task { await reprice() } }

            // ── WHAT THIS SHOP HAS ACTUALLY MADE ON WORK LIKE THIS ────────
            //
            // No model is involved. `buildComparables` is arithmetic over the
            // shop's own finished jobs, so a shop with the assistant switched
            // off — or with no key, or no wish to send anything anywhere — gets
            // this, which is most of the value and none of the risk.
            //
            // NET OF TAX. For an inclusive-VAT shop part of every price was the
            // tax authority's and was never revenue; margin against the gross
            // overstates it, and a shop pricing to an overstated median prices
            // thin by exactly that much.
            if let c = comparables, c.hasHistory, let median = c.medianMarginPct {
                GridRow {
                    Color.clear.frame(height: 0)
                    HStack(spacing: 6) {
                        Text(shop.words.callIt(
                            c.sameMaterial ? "mac.you_usually_make_material"
                                           : "mac.you_usually_make",
                            ["n": .number(Double(c.count)),
                             "pct": .number(median),
                             "material": .string(c.material)]))
                            .font(.caption).foregroundStyle(.secondary)
                        if abs(margin - median) >= 0.05 {
                            Button(shop.words.callIt("mac.use_it")) { margin = median }
                                .buttonStyle(.link).font(.caption)
                        }
                        // The OPTIONAL second opinion. The median above was
                        // computed here with nothing sent anywhere; this asks a
                        // model to weigh outliers and a thin sample and say why
                        // in a sentence. Offered only where the shop agreed.
                        if shop.aiPriceAllowed {
                            Button(shop.words.callIt("mac.ask_what_to_charge")) {
                                Task { await advise() }
                            }
                            .buttonStyle(.link).font(.caption)
                            .disabled(advising)
                        }
                        if advising { ProgressView().controlSize(.small) }
                        Spacer()
                    }
                }
            }
            if let advice {
                GridRow {
                    Color.clear.frame(height: 0)
                    Text(advice).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            GridRow {
                Text(shop.words.callIt("oe.shipping")).gridColumnAlignment(.trailing)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    amount($shippingCost)
                    Text(shop.words.callIt("pay.deposit_label")).foregroundStyle(.secondary)
                    amount($deposit)
                }
            }
        }
    }

    /// Where the cost went, before margin.
    ///
    /// Four figures, and any of them may be zero for a good reason — a job with
    /// no hours has no labour. What matters is that a shop can SEE it is zero,
    /// which is the thing that was missing while this app quoted material and
    /// called it a price.
    @ViewBuilder private var breakdown: some View {
        let sum = parts.compactMap(\.parts).reduce(into: (m: 0.0, k: 0.0, l: 0.0, b: 0.0)) { out, p in
            out.m += p.material; out.k += p.machine; out.l += p.labor; out.b += p.buffer
        }
        if sum.m + sum.k + sum.l + sum.b > 0 {
            HStack(spacing: 14) {
                chip("calc.bd.material", sum.m)
                chip("calc.bd.machine", sum.k)
                chip("calc.bd.labor", sum.l)
                chip("calc.bd.buffer", sum.b)
            }
        }
    }

    private func chip(_ key: String, _ value: Double) -> some View {
        HStack(spacing: 4) {
            Text(shop.words.callIt(key)).foregroundStyle(.secondary)
            Text(Money.figure(value)).monospacedDigit()
        }
        .font(.caption)
        // One line, always. A label that wraps inside a row whose height the
        // window is measuring is the shape that crashed this app once — see
        // `SidebarLayoutTests`. Four of these across a 560pt sheet is a
        // comfortable fit until somebody quotes six figures, and then they
        // shrink rather than fold.
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    /// What it comes to, said once and plainly.
    private var total: some View {
        HStack(spacing: 8) {
            Text(shop.words.callIt("common.total")).foregroundStyle(.secondary)
            Text(quoted.map { Money.figure($0.total) } ?? "—")
                .font(.title2.weight(.semibold)).monospacedDigit()
            if let quoted, quoted.differsFromComputed, let computed = quoted.computedTotal {
                // A rounded or typed total never passes for a calculated one.
                Text(shop.words.callIt(quoted.priceSource == "override" ? "pe.price_is_override" : "pe.price_is_rounded")
                     + " · " + shop.words.callIt("pe.price_is_base") + " " + Money.figure(computed))
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            if let quoted, quoted.discountAmount > 0 {
                Text("−" + Money.figure(quoted.discountAmount))
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            if let quoted, quoted.rushFee > 0 {
                Text("+" + Money.figure(quoted.rushFee) + " " + shop.words.callIt("calc.rush_fee"))
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private var footer: some View {
        HStack {
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Khayt.attention).lineLimit(2)
            }
            Spacer()
            Button(shop.words.callIt("common.cancel")) { shop.takingAJob = false }
                .keyboardShortcut(.cancelAction)
            Button(shop.words.callIt("mac.save_quote")) { Task { await save(asQuote: true) } }
                .disabled(parts.isEmpty)
            Button(shop.words.callIt("mac.take_the_job")) { Task { await save(asQuote: false) } }
                .keyboardShortcut(.defaultAction)
                .disabled(parts.isEmpty)
        }
        .padding(18)
    }

    /// A number field and the unit it is in.
    ///
    /// The unit is NOT decoration. `discountPct` is a percentage and the field
    /// said only "0", so a shop knocking fifty riyals off a job would type 50
    /// and take half the price off instead. Machines and spools already state
    /// their units this way — "mm" beside the nozzle, the currency beside a
    /// roll's cost — and money that does not is the field that gets it wrong.
    private func unit(_ value: Binding<Double>, _ width: CGFloat, _ suffix: String) -> some View {
        HStack(spacing: 4) {
            TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder).frame(width: width).monospacedDigit()
            Text(suffix).foregroundStyle(.secondary)
        }
    }

    private func percent(_ value: Binding<Double>) -> some View { unit(value, 70, "%") }

    private func amount(_ value: Binding<Double>) -> some View {
        unit(value, 90, Money.mark(shop.currency))
    }

    // MARK: - What it costs, and what it comes to

    /// Everything the price depends on, so the preview re-runs when any of it
    /// moves and not on every keystroke in the job's name.
    private var signature: String {
        "\(parts.map { "\($0.cost)x\($0.qty)@\($0.agreedPrice ?? -1)" }.joined())|\(margin)|\(discountPct)|\(shippingCost)|\(rush)|\(rule.step)|\(rule.mode)|\(rule.override ?? -1)"
    }

    /// The cart in two halves, the way the rule takes it: what is priced at
    /// cost plus margin, and what the customer has already agreed.
    private var costedBase: Double {
        parts.filter { $0.agreedPrice == nil }.reduce(0) { $0 + $1.cost * Double($1.qty) }
    }
    private var agreedAmount: Double {
        parts.reduce(0) { $0 + ($1.agreedPrice ?? 0) * Double($1.qty) }
    }

    private func addPart() async {
        var next = draft
        // One crossing for all three: the figure, where it went, and what it was
        // worked out at. They have to agree, so they are asked for together
        // rather than computed twice from the same inputs.
        defer { Task { await readComparables() } }
        let costed = await shop.costedPart(spoolId: next.spoolId,
                                           grams: Double(next.grams) ?? 0,
                                           hours: Double(next.hours) ?? 0,
                                           qty: next.qty)
        next.cost = costed?.cost ?? 0
        next.parts = costed?.parts
        next.rates = costed?.rates
        // A part added AFTER the customer was chosen takes their agreed price
        // too. The other app applies agreements only at the moment the
        // customer is picked; here the customer is usually picked first.
        if let agreed = await shop.agreedPrices(for: [next.name], clientId: clientId).first ?? nil {
            next.agreedPrice = agreed
            agreementNote = shop.words.callIt("ce.pl_autofill")
        }
        parts.append(next)
        draft = Draft()
    }

    /// What choosing a customer brings with it: their discount, and the
    /// prices they have agreed for the parts already in the cart.
    ///
    /// The agreed figure is the PRICE of that part — the cost stays the cost,
    /// and the shared rule charges the agreed figure instead of cost plus
    /// margin (`lib/price-agreements.js`). A part with no agreement for this
    /// customer loses one a previous customer left on it.
    private func customerChosen(_ chosen: String?) async {
        agreementNote = nil
        guard let chosen, let client = shop.clients.first(where: { $0.id == chosen }) else {
            for i in parts.indices { parts[i].agreedPrice = nil }
            return
        }
        if client.defaultDiscount > 0 { discountPct = client.defaultDiscount }
        let prices = await shop.agreedPrices(for: parts.map(\.name), clientId: chosen)
        var applied = 0
        for (i, price) in prices.enumerated() where i < parts.count {
            parts[i].agreedPrice = price
            if price != nil { applied += 1 }
        }
        if applied > 0 { agreementNote = shop.words.callIt("ce.pl_autofill") }
    }

    /// Ask what this shop has made on jobs in this material.
    ///
    /// Keyed on the cart's first bound spool, because that is what the shop has
    /// said the job is made of. With nothing bound the rule falls back to every
    /// priced job and says so through `basis`, which is why the sentence names
    /// the material only when the comparables actually are that material.
    private func readComparables() async {
        let material = parts.compactMap { part in
            part.spoolId.flatMap { id in shop.spools.first { $0.id == id }?.material }
        }.first ?? ""
        comparables = await shop.priceComparables(material: material)
    }

    /// Ask for a second opinion on the margin.
    private func advise() async {
        guard let c = comparables, c.hasHistory, !advising else { return }
        advising = true
        advice = nil
        defer { advising = false }
        let material = parts.compactMap { part in
            part.spoolId.flatMap { id in shop.spools.first { $0.id == id }?.material }
        }.first ?? ""
        guard let raw = await shop.priceComparablesRaw(material: material) else { return }
        let cost = parts.reduce(0.0) { $0 + $1.cost * Double($1.qty) }
        let grams = parts.reduce(0.0) { $0 + (Double($1.grams) ?? 0) * Double($1.qty) }
        let hours = parts.reduce(0.0) { $0 + (Double($1.hours) ?? 0) * Double($1.qty) }
        switch await shop.recommendMargin(comparables: c, raw: raw, cost: cost,
                                          grams: grams, hours: hours, material: material) {
        case .advised(let said):
            margin = said.margin
            // The REASON, always. A margin that changed with no sentence beside
            // it is a number a shop cannot argue with when a customer does.
            advice = said.rationale.isEmpty
                ? shop.words.callIt("mac.advice_no_reason",
                                    ["pct": .number(said.margin)])
                : said.rationale
        case .refused(let why):
            advice = why
        }
    }

    private func reprice() async {
        guard !parts.isEmpty else { quoted = nil; return }
        quoted = await shop.previewQuote(
            baseCost: costedBase,
            margin: margin, discountPct: discountPct,
            shippingCost: shippingCost, rush: rush,
            agreedAmount: agreedAmount, rule: rule, extraLines: extraLines)
    }

    private func save(asQuote: Bool) async {
        await shop.createJob(shop.newJobInput(
            parts: parts, project: project, clientId: clientId,
            margin: margin, discountPct: discountPct, shippingCost: shippingCost,
            deposit: deposit, rush: rush, asQuote: asQuote, fromProduct: product,
            rule: rule, extraLines: extraLines))
        if shop.moveProblem == nil { shop.takingAJob = false } else { problem = shop.moveProblem }
    }
}
