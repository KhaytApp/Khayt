import SwiftUI
import KhaytCore

/// The calculator: what a part costs this shop to make, and what to charge.
///
/// Priced on the phone from the shop's own book — spools, printers, presets,
/// consumables and settings — through the same rules as the Mac's calculator
/// (`PhoneCalculator`). A phone that does not keep the book (paired before the
/// offline work, or never synced) gets the older sheet that asks the Mac.
/// Figures to start the calculator from — a library model's weight and time.
struct CalculatorSeed: Equatable {
    var grams: Double?
    var hours: Double?
    var qty = 1
    /// The model's material: the first spool of it is picked, when there is one.
    var material: String?
}

struct CalculatorScreen: View {
    /// A sheet has a Close button; the sidebar tab does not.
    var asSheet = false
    var seed: CalculatorSeed?
    @EnvironmentObject private var api: KhaytAPIClient

    var body: some View {
        if api.holdsBook, let reader = api.reader {
            CalculatorView(reader: reader, asSheet: asSheet, seed: seed)
        } else {
            QuoteSheet()
        }
    }
}

struct CalculatorView: View {
    let reader: BookReader
    var asSheet = false
    var seed: CalculatorSeed?

    @EnvironmentObject private var api: KhaytAPIClient
    @Environment(\.dismiss) private var dismiss
    @State private var model = PhoneCalculator()
    @State private var showRates = false
    @State private var makingOrder: NewOrderDraft?
    @State private var machines: [MachineInfo] = []

    private var currency: String? { model.shelf.currency }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    answerCard
                    eyebrow(L10n.tr("calc.part"))
                    partCard
                    eyebrow(L10n.tr("calc.printer"))
                    printerCard
                    ratesCard
                    if !model.shelf.consumables.isEmpty {
                        eyebrow(L10n.tr("calc.pieces"))
                        piecesCard
                    }
                    eyebrow(L10n.tr("calc.price"))
                    priceCard
                    if let problem = model.problem {
                        V2Note(text: problem, tone: KhaytDesign.late)
                    }
                    if model.answer != nil { actions }
                }
                .padding(16)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(KhaytDesign.ground.ignoresSafeArea())
            .navigationTitle(L10n.tr("calc.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if asSheet {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.tr("common.close")) { dismiss() }
                    }
                }
            }
            .task {
                await model.load(reader)
                machines = (try? await reader.machines()) ?? []
                if let seed { model.apply(seed) }
                #if DEBUG
                // `-KhaytCalc "120:4"` on the launch line: grams and hours, for screenshots.
                if let fill = UserDefaults.standard.string(forKey: "KhaytCalc") {
                    let bits = fill.split(separator: ":").map(String.init)
                    model.lines[0].grams = bits.first ?? ""
                    model.hours = bits.count > 1 ? bits[1] : ""
                    if bits.count > 2 { model.addColour(); model.lines[1].grams = bits[2] }
                }
                #endif
            }
            // Every input in one value: any change re-prices, and a change
            // made while the last answer is still coming cancels it.
            .task(id: model.question) { await model.recompute(reader) }
            .task(id: "\(model.machineId ?? "")|\(model.presetId ?? "")") { await model.resolveRates(reader) }
            .sheet(item: $makingOrder) { draft in
                NewOrderSheet(machines: machines, onCreated: { makingOrder = nil }, initial: draft)
            }
        }
    }

    // MARK: - The answer

    /// First, because it is what the customer at the counter is waiting for.
    /// The shop's cost and what it keeps sit beneath — not customer-facing.
    @ViewBuilder private var answerCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("calc.charge").uppercased())
                    .font(.khayt(10.5, .bold, relativeTo: .caption2))
                    .tracking(1.05)
                    .foregroundStyle(KhaytDesign.note)
                Text(model.answer.map { Money.text($0.quoted.total, currency) } ?? "—")
                    .font(.khayt(36, .semibold, relativeTo: .largeTitle).monospacedDigit())
                    .foregroundStyle(model.answer == nil ? KhaytDesign.note : KhaytDesign.brand)
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("calc.total")
                if let a = model.answer, a.qty > 1 {
                    Text(L10n.format("calc.each", Money.text(a.perPiece, currency)))
                        .font(.khayt(13.5, relativeTo: .subheadline).monospacedDigit())
                        .foregroundStyle(KhaytDesign.note)
                }
                if model.answer == nil {
                    Text(L10n.tr("calc.nothing"))
                        .font(.khayt(13.5, relativeTo: .subheadline))
                        .foregroundStyle(KhaytDesign.note)
                }
            }
            .padding(16)
            if let a = model.answer {
                VStack(spacing: 0) {
                    row(L10n.tr("calc.cost"), Money.text(a.cost, currency))
                    if a.overhead > 0 { row(L10n.tr("calc.overhead"), Money.text(a.overhead, currency)) }
                    row(L10n.tr("calc.keeps"), Money.text(a.keeps, currency))
                    if a.quoted.discountAmount > 0 {
                        row(L10n.tr("quote.discount"), "−" + Money.text(a.quoted.discountAmount, currency))
                    }
                    if a.quoted.rushFee > 0 { row(L10n.tr("quote.rush_fee"), Money.text(a.quoted.rushFee, currency)) }
                    breakdown(a)
                }
            }
        }
        .card()
        .animation(.snappy, value: model.answer)
    }

    /// Where one piece's cost goes, as a bar and four figures that add up.
    private func breakdown(_ a: CalculatorAnswer) -> some View {
        let p = a.costed.parts
        let buckets: [(String, Double, Color)] = [
            (L10n.tr("quote.bd.material"), p.material, KhaytDesign.brand),
            (L10n.tr("quote.bd.machine"), p.machine, KhaytDesign.attention),
            (L10n.tr("quote.bd.labor"), p.labor, KhaytDesign.hot),
            (L10n.tr("quote.bd.buffer"), p.buffer, KhaytDesign.note),
        ]
        let total = max(0.0001, p.total)
        return VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("calc.per_piece").uppercased())
                .font(.khayt(10, .bold, relativeTo: .caption2)).tracking(1)
                .foregroundStyle(KhaytDesign.note)
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(buckets.indices, id: \.self) { i in
                        if buckets[i].1 > 0 {
                            buckets[i].2.frame(width: max(2, (geo.size.width - 6) * buckets[i].1 / total))
                        }
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            .accessibilityHidden(true)
            ForEach(buckets.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    Circle().fill(buckets[i].2).frame(width: 8, height: 8)
                    Text(buckets[i].0).foregroundStyle(KhaytDesign.note)
                    Spacer()
                    Text(Money.text(buckets[i].1, currency)).monospacedDigit().foregroundStyle(KhaytDesign.ink)
                }
                .font(.khayt(13.5, relativeTo: .subheadline))
            }
        }
        .padding(16)
        .overlay(alignment: .top) { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
    }

    // MARK: - The part

    private var partCard: some View {
        V2FieldCard {
            ForEach(Array(model.lines.enumerated()), id: \.element.id) { index, line in
                filamentRow(line, index: index)
            }
            Button { model.addColour() } label: {
                Label(L10n.tr("calc.add_colour"), systemImage: "plus.circle")
                    .font(.khayt(14.5, .medium, relativeTo: .subheadline))
                    .foregroundStyle(KhaytDesign.brand)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)
            .disabled(model.shelf.spools.isEmpty)
            .overlay(alignment: .bottom) { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
            if model.lines.count > 1 {
                numberRow(L10n.tr("calc.purge"), text: $model.purge, unit: L10n.tr("unit.g"))
            }
            HStack(spacing: 0) {
                numberRow(L10n.tr("quote.time"), text: $model.hours, unit: L10n.tr("unit.h"))
                Rectangle().fill(KhaytDesign.hairline).frame(width: 1).padding(.vertical, 10)
                VStack(alignment: .leading, spacing: 7) {
                    fieldLabel(L10n.tr("quote.qty"))
                    Stepper(value: $model.qty, in: 1...9999) {
                        Text(verbatim: Money.figure(Double(model.qty), places: 0))
                            .font(.khayt(18, .semibold, relativeTo: .body).monospacedDigit())
                            .foregroundStyle(KhaytDesign.ink)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
            if model.unpricedSpool {
                V2Note(text: L10n.tr("calc.no_spool_price"), tone: KhaytDesign.attention)
                    .padding(.horizontal, 14).padding(.bottom, 12)
            }
        }
    }

    private func filamentRow(_ line: PhoneCalculator.FilamentLine, index: Int) -> some View {
        let spool = model.shelf.spools.first { $0.id == line.spoolId }
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                fieldLabel(model.lines.count > 1 ? L10n.format("calc.colour_n", index + 1) : L10n.tr("quote.weight"))
                HStack(spacing: 4) {
                    TextField("", text: gramsBinding(line.id), prompt: Text(verbatim: "0"))
                        .keyboardType(.decimalPad)
                        .font(.khayt(18, .semibold, relativeTo: .body).monospacedDigit())
                        .foregroundStyle(KhaytDesign.ink)
                        .frame(maxWidth: 110)
                    Text(verbatim: L10n.tr("unit.g"))
                        .font(.khayt(13, relativeTo: .footnote)).foregroundStyle(KhaytDesign.note)
                }
            }
            Spacer(minLength: 4)
            Menu {
                Picker(L10n.tr("calc.filament"), selection: spoolBinding(line.id)) {
                    Text(L10n.tr("calc.no_spool")).tag(String?.none)
                    ForEach(model.shelf.spools) { s in
                        Text(s.label).tag(Optional(s.id))
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    SpoolSwatch(hex: spool?.hex, size: 14)
                    Text(spool?.label ?? L10n.tr("calc.no_spool"))
                        .font(.khayt(14, .medium, relativeTo: .subheadline))
                        .foregroundStyle(KhaytDesign.ink)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(KhaytDesign.note)
                }
            }
            if model.lines.count > 1 {
                Button { model.removeColour(line.id) } label: {
                    Image(systemName: "minus.circle").foregroundStyle(KhaytDesign.late)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("calc.remove_colour"))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
    }

    // MARK: - Printer and rates

    private var printerCard: some View {
        V2FieldCard {
            pickerRow(L10n.tr("calc.machine"), selection: $model.machineId,
                      none: L10n.tr("calc.any_machine"), options: model.shelf.machines)
            pickerRow(L10n.tr("calc.preset"), selection: $model.presetId,
                      none: L10n.tr("calc.default_rates"), options: model.shelf.presets, last: true)
        }
    }

    /// The seven figures a part is costed at: shown, seeded from the preset
    /// and machine, and editable — a typed one wins for this calculation.
    private var ratesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy) { showRates.toggle() } } label: {
                HStack {
                    Text(L10n.tr("calc.rates"))
                        .font(.khayt(14.5, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(KhaytDesign.ink)
                    if model.ratesEdited {
                        Text(L10n.tr("calc.rates_edited"))
                            .font(.khayt(12, .medium, relativeTo: .caption))
                            .foregroundStyle(KhaytDesign.attention)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(showRates ? 0 : (L10n.usesArabicLayout ? 90 : -90)))
                        .foregroundStyle(KhaytDesign.note)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showRates {
                VStack(spacing: 0) {
                    ForEach(PhoneCalculator.rateKeys, id: \.self) { key in
                        rateRow(key)
                    }
                    Button(L10n.tr("calc.rates_reset")) { model.resetRates() }
                        .font(.khayt(14, .medium, relativeTo: .subheadline))
                        .disabled(model.rates.values.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .overlay(alignment: .top) { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
                }
            }
        }
        .card()
    }

    private func rateRow(_ key: String) -> some View {
        let unit: String = switch key {
        case "laborRate", "wearRate", "elecRate": currency.map(Money.mark) ?? ""
        case "prepTime", "postTime": L10n.tr("unit.h")
        case "powerDraw": "W"
        default: "%"
        }
        let seeded = model.resolved[key].map { PhoneCalculator.figure($0) } ?? "0"
        return HStack {
            Text(L10n.tr("calc.rate.\(key)"))
                .font(.khayt(14, relativeTo: .subheadline))
                .foregroundStyle(KhaytDesign.note)
            Spacer()
            TextField("", text: Binding(get: { model.rates[key] ?? "" },
                                        set: { model.rates[key] = $0 }),
                      prompt: Text(verbatim: seeded))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.khayt(15, .medium, relativeTo: .body).monospacedDigit())
                .frame(maxWidth: 110)
            Text(verbatim: unit)
                .font(.khayt(12.5, relativeTo: .footnote))
                .foregroundStyle(KhaytDesign.note)
                .frame(minWidth: 28, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 46)
        .overlay(alignment: .top) { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
    }

    // MARK: - Pieces

    private var piecesCard: some View {
        V2FieldCard {
            ForEach(model.pieces) { piece in
                HStack(spacing: 10) {
                    Picker("", selection: pieceBinding(piece.id)) {
                        ForEach(model.shelf.consumables, id: \.id) { c in
                            Text(c.name ?? c.id).tag(Optional(c.id))
                        }
                    }
                    .labelsHidden()
                    .tint(KhaytDesign.ink)
                    Spacer()
                    Stepper(value: pieceQtyBinding(piece.id), in: 1...9999) {
                        Text(verbatim: "× " + Money.figure(Double(piece.qty), places: 0))
                            .font(.khayt(15, .medium, relativeTo: .body).monospacedDigit())
                    }
                    .fixedSize()
                    Button { model.removePiece(piece.id) } label: {
                        Image(systemName: "minus.circle").foregroundStyle(KhaytDesign.late)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.tr("calc.remove_piece"))
                }
                .padding(.horizontal, 14).frame(minHeight: 52)
                .overlay(alignment: .bottom) { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
            }
            Button { model.addPiece() } label: {
                Label(L10n.tr("calc.add_piece"), systemImage: "plus.circle")
                    .font(.khayt(14.5, .medium, relativeTo: .subheadline))
                    .foregroundStyle(KhaytDesign.brand)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Price

    private var priceCard: some View {
        V2FieldCard {
            sliderRow(L10n.tr("quote.margin"), value: $model.margin, range: 0...300)
            sliderRow(L10n.tr("quote.discount"), value: $model.discount, range: 0...90)
            Toggle(isOn: $model.rush) {
                Text(L10n.tr("quote.rush"))
                    .font(.khayt(14.5, relativeTo: .subheadline))
                    .foregroundStyle(KhaytDesign.ink)
            }
            .tint(KhaytDesign.hot)
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
        }
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                fieldLabel(label)
                Spacer()
                Text(verbatim: Money.figure(value.wrappedValue, places: 0) + "%")
                    .font(.khayt(15, .semibold, relativeTo: .body).monospacedDigit())
                    .foregroundStyle(KhaytDesign.ink)
            }
            Slider(value: value, in: range, step: 1)
                .tint(KhaytDesign.brand)
                .accessibilityLabel(label)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
    }

    // MARK: - Actions

    /// Send the price to the customer, or take the job on.
    private var actions: some View {
        VStack(spacing: 10) {
            if let text = model.quoteText(currency: currency) {
                ShareLink(item: text) {
                    Label(L10n.tr("calc.share"), systemImage: "square.and.arrow.up")
                        .font(.khayt(15.5, .semibold, relativeTo: .body))
                        .foregroundStyle(KhaytDesign.brand)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(KhaytDesign.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(KhaytDesign.brand, lineWidth: 1))
                }
            }
            V2PrimaryButton(title: L10n.tr("calc.make_order")) {
                makingOrder = orderDraft()
            }
        }
        .padding(.top, 4)
    }

    /// The job this price is for: the total, the material, the printer.
    private func orderDraft() -> NewOrderDraft {
        var draft = NewOrderDraft()
        if let a = model.answer { draft.price = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), a.quoted.total) }
        let materials = model.lines.compactMap { line in
            line.spoolId.flatMap { id in model.shelf.spools.first { $0.id == id }?.costing.material }
        }.filter { !$0.isEmpty }
        draft.material = Array(NSOrderedSet(array: materials)).compactMap { $0 as? String }.joined(separator: " + ")
        draft.machineId = model.machineId
        draft.isQuote = true
        return draft
    }

    // MARK: - Pieces of form

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.khayt(10, .bold, relativeTo: .caption2))
            .tracking(1)
            .foregroundStyle(KhaytDesign.note)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.khayt(10.5, .bold, relativeTo: .caption2))
            .tracking(1.05)
            .foregroundStyle(KhaytDesign.note)
            .padding(.horizontal, 2)
            .padding(.top, 8)
    }

    private func numberRow(_ label: String, text: Binding<String>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            fieldLabel(label)
            HStack(spacing: 4) {
                TextField("", text: text, prompt: Text(verbatim: "0"))
                    .keyboardType(.decimalPad)
                    .font(.khayt(18, .semibold, relativeTo: .body).monospacedDigit())
                    .foregroundStyle(KhaytDesign.ink)
                Text(verbatim: unit)
                    .font(.khayt(13, relativeTo: .footnote))
                    .foregroundStyle(KhaytDesign.note)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pickerRow(_ label: String, selection: Binding<String?>, none: String,
                           options: [CalculatorShelf.Named], last: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.khayt(14.5, relativeTo: .subheadline))
                .foregroundStyle(KhaytDesign.note)
            Spacer()
            Picker(label, selection: selection) {
                Text(none).tag(String?.none)
                ForEach(options) { Text($0.name).tag(Optional($0.id)) }
            }
            .labelsHidden()
            .tint(KhaytDesign.ink)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.khayt(14, relativeTo: .subheadline))
                .foregroundStyle(KhaytDesign.note)
            Spacer()
            Text(value)
                .font(.khayt(14, .medium, relativeTo: .subheadline).monospacedDigit())
                .foregroundStyle(KhaytDesign.ink)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .overlay(alignment: .top) { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
    }

    // MARK: - Bindings by id (never by index: a removed line would trap)

    private func gramsBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { model.lines.first { $0.id == id }?.grams ?? "" },
                set: { v in if let i = model.lines.firstIndex(where: { $0.id == id }) { model.lines[i].grams = v } })
    }

    private func spoolBinding(_ id: UUID) -> Binding<String?> {
        Binding(get: { model.lines.first { $0.id == id }?.spoolId },
                set: { v in if let i = model.lines.firstIndex(where: { $0.id == id }) { model.lines[i].spoolId = v } })
    }

    private func pieceBinding(_ id: UUID) -> Binding<String?> {
        Binding(get: { model.pieces.first { $0.id == id }?.consumableId },
                set: { v in if let i = model.pieces.firstIndex(where: { $0.id == id }) { model.pieces[i].consumableId = v } })
    }

    private func pieceQtyBinding(_ id: UUID) -> Binding<Int> {
        Binding(get: { model.pieces.first { $0.id == id }?.qty ?? 1 },
                set: { v in if let i = model.pieces.firstIndex(where: { $0.id == id }) { model.pieces[i].qty = v } })
    }
}

extension NewOrderDraft: Identifiable {
    var id: String { "\(project)|\(price)|\(material)|\(machineId ?? "")" }
}
