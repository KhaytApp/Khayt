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
    @State private var margin = 40.0
    @State private var discountPct = 0.0
    @State private var shippingCost = 0.0
    @State private var deposit = 0.0
    @State private var rush = false
    @State private var quoted: QuoteTotal?
    @State private var problem: String?
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
        /// Where that cost went. Held per part so the sheet can add up the cart
        /// without asking the engine again for each one.
        var parts: KhaytEngine.CostParts?
        /// What it was costed AT. Written onto the saved part, because Khayt's
        /// own editor reads these back and a part without them re-costs to
        /// nothing the next time somebody presses save there.
        var rates: KhaytEngine.Rates?

        var isComplete: Bool { (Double(grams) ?? 0) > 0 || (Double(hours) ?? 0) > 0 }
    }

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
        .onAppear {
            margin = shop.defaultMargin
            focused = true
        }
        .task(id: signature) { await reprice() }
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

    private var cart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(shop.words.callIt("mac.parts")).font(.subheadline.weight(.semibold))

            ForEach(parts) { part in
                HStack(spacing: 8) {
                    Text(part.name.isEmpty ? shop.words.callIt("mac.a_part") : part.name)
                        .lineLimit(1)
                    Text("×\(part.qty)").foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Text(Money.figure(part.cost * Double(part.qty)))
                        .monospacedDigit().foregroundStyle(.secondary)
                    Button {
                        parts.removeAll { $0.id == part.id }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
                        .help(shop.words.callIt("common.delete"))
                }
                .padding(.vertical, 2)
            }

            partForm
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
                        Text(spool.label(shop.words)).tag(String?.some(spool.id))
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
        .padding(10)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
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
        "\(parts.map { "\($0.cost)x\($0.qty)" }.joined())|\(margin)|\(discountPct)|\(shippingCost)|\(rush)"
    }

    private func addPart() async {
        var next = draft
        // One crossing for all three: the figure, where it went, and what it was
        // worked out at. They have to agree, so they are asked for together
        // rather than computed twice from the same inputs.
        let costed = await shop.costedPart(spoolId: next.spoolId,
                                           grams: Double(next.grams) ?? 0,
                                           hours: Double(next.hours) ?? 0,
                                           qty: next.qty)
        next.cost = costed?.cost ?? 0
        next.parts = costed?.parts
        next.rates = costed?.rates
        parts.append(next)
        draft = Draft()
    }

    private func reprice() async {
        guard !parts.isEmpty else { quoted = nil; return }
        quoted = await shop.previewQuote(
            baseCost: parts.reduce(0) { $0 + $1.cost * Double($1.qty) },
            margin: margin, discountPct: discountPct,
            shippingCost: shippingCost, rush: rush)
    }

    private func save(asQuote: Bool) async {
        await shop.createJob(shop.newJobInput(
            parts: parts, project: project, clientId: clientId,
            margin: margin, discountPct: discountPct, shippingCost: shippingCost,
            deposit: deposit, rush: rush, asQuote: asQuote))
        if shop.moveProblem == nil { shop.takingAJob = false } else { problem = shop.moveProblem }
    }
}
