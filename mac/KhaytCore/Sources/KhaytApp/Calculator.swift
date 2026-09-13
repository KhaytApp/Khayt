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
    /// Empty, this screen is two fields and a sentence. Everything it is FOR —
    /// the cost breakdown, what to charge, the margin the shop would actually
    /// make — appears only once there is a weight or a time in it, and the
    /// snapshot runner had never put one there. So the highest-stakes screen in
    /// the app had been photographed exactly once, in the state where it does
    /// nothing.
    ///
    /// `KHAYT_SNAPSHOT_PART` fills it, and only in the runner: an environment
    /// variable this app is never launched with otherwise.
    @State private var grams = ProcessInfo.processInfo.environment["KHAYT_SNAPSHOT_PART"] ?? ""
    @State private var hours = ProcessInfo.processInfo.environment["KHAYT_SNAPSHOT_HOURS"] ?? ""
    @State private var qty = 1
    /// Which spool, and it starts on a real one.
    ///
    /// NOT nil. Without a spool there is no cost per gram, so the material
    /// bucket comes out at zero — and material is the largest part of most
    /// prints. A calculator that opens quoting a job with no plastic in it
    /// gives a confidently wrong answer to the one question it exists for.
    @State private var spoolId: String?
    @State private var machineId: String?
    @State private var margin = 30.0
    @State private var discount = 0.0
    @State private var rush = false

    @State private var costed: KhaytEngine.CostedPart?
    @State private var quoted: QuoteTotal?

    private var gramsValue: Double { Double(grams.replacingOccurrences(of: ",", with: ".")) ?? 0 }
    private var hoursValue: Double { Double(hours.replacingOccurrences(of: ",", with: ".")) ?? 0 }
    /// Nothing to price until there is something to print.
    private var hasInput: Bool { gramsValue > 0 || hoursValue > 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                DetailSection(shop.words.callIt("mac.calc_part"),
                              accent: Khayt.brand, symbol: "wrench.and.screwdriver.fill") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            field(shop.words.callIt("mac.calc_weight"), $grams,
                                  unit: shop.words.callIt("common.grams"))
                            field(shop.words.callIt("mac.calc_time"), $hours,
                                  unit: shop.words.callIt("common.hours"))
                            Stepper(value: $qty, in: 1...9999) {
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
                        LayerRule()
                        HStack(spacing: 10) {
                            // The spool decides the material cost per gram, and
                            // the machine decides the wear and the electricity.
                            // Both are the book's own rows, so the answer is
                            // this shop's, not a worked example.
                            Picker(shop.words.callIt("calc.part.filament"),
                                   selection: $spoolId) {
                                Text(shop.words.callIt("mac.any_filament")).tag(String?.none)
                                ForEach(shop.spools) { spool in
                                    Text(spool.material).tag(String?.some(spool.id))
                                }
                            }
                            Picker(shop.words.callIt("mac.calc_printer"), selection: $machineId) {
                                Text(shop.words.callIt("mac.any_machine")).tag(String?.none)
                                ForEach(shop.machines) { machine in
                                    Text(machine.name).tag(String?.some(machine.id))
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .card()
                }

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
                                slider(shop.words.callIt("calc.quote.margin"), $margin, 0...300)
                                slider(shop.words.callIt("calc.quote.discount"), $discount, 0...90)
                                Toggle(shop.words.callIt("calc.rush_fee"), isOn: $rush).fixedSize()
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
        .background(Khayt.ground)
        .task(id: recomputeKey) { await recompute() }
        // The book may not have loaded when this screen first appears, so the
        // default is chosen when the spools arrive rather than at init.
        .onChange(of: shop.spools.map(\.id)) { _, ids in
            if spoolId == nil, let first = ids.first { spoolId = first }
        }
        .onAppear { if spoolId == nil { spoolId = shop.spools.first?.id } }
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
                if spoolId == nil && gramsValue > 0 {
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

    /// Everything the answer depends on, in one value, so the recompute runs
    /// when any of it moves and not once per keystroke per field.
    private var recomputeKey: String {
        "\(grams)|\(hours)|\(qty)|\(spoolId ?? "")|\(machineId ?? "")|\(margin)|\(discount)|\(rush)"
    }

    private func recompute() async {
        guard hasInput else { costed = nil; quoted = nil; return }
        let part = await shop.costedPart(spoolId: spoolId, grams: gramsValue,
                                         hours: hoursValue, qty: qty, machineId: machineId)
        costed = part
        quoted = await shop.previewQuote(baseCost: (part?.cost ?? 0) * Double(qty),
                                         margin: margin, discountPct: discount,
                                         shippingCost: 0, rush: rush)
    }
}
