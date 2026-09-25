import SwiftUI

/**
 * Quote a walk-in customer without going back to the desk.
 *
 * The shop floor case this exists for: someone arrives holding a part, asks what
 * it would cost, and today that means "let me go and check". Of the desktop
 * features missing from the phone this was the one worth building first — it is
 * revenue, and it happens standing up.
 *
 * The phone computes NOTHING. Every figure comes from POST /api/quote, which
 * runs the desktop's own costing and pricing. A quote given here and one given
 * at the desk are the same number by construction rather than by two
 * implementations agreeing on the day they were written.
 */
struct QuoteSheet: View {
    @EnvironmentObject private var api: KhaytAPIClient
    @Environment(\.dismiss) private var dismiss

    // Defaults a shop can quote from immediately: a 1 kg spool, and the material
    // cost left to the shop to fill in. Zeroes everywhere would make the first
    // result meaningless and teach the user to distrust the screen.
    @State private var printWeight = "50"
    @State private var printTime = "2"
    @State private var qty = "1"
    @State private var margin = "40"
    @State private var spoolCost = ""
    @State private var laborRate = ""
    @State private var rush = false

    @State private var result: QuoteResult?
    @State private var error: String?
    @State private var isLoading = false

    private var currency: String { result?.currency ?? "" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let result { resultCard(result) }
                    eyebrow(L10n.tr("quote.part"))
                    V2FieldCard {
                        HStack(spacing: 0) {
                            numberField(L10n.tr("quote.weight"), $printWeight, unit: "g")
                            divider
                            numberField(L10n.tr("quote.time"), $printTime, unit: "h")
                            divider
                            numberField(L10n.tr("quote.qty"), $qty, unit: nil, decimal: false)
                        }
                    }
                    eyebrow(L10n.tr("quote.rates"))
                    V2FieldCard {
                        V2Field(label: L10n.tr("quote.spool_cost")) {
                            TextField("", text: $spoolCost, prompt: Text(verbatim: "0")).keyboardType(.decimalPad)
                        }
                        V2Field(label: L10n.tr("quote.labor_rate")) {
                            TextField("", text: $laborRate, prompt: Text(verbatim: "0")).keyboardType(.decimalPad)
                        }
                        V2Field(label: L10n.tr("quote.margin")) {
                            HStack(spacing: 6) {
                                TextField("", text: $margin, prompt: Text(verbatim: "0")).keyboardType(.decimalPad)
                                Text(verbatim: "%").foregroundStyle(KhaytDesign.note)
                            }
                        }
                        Toggle(isOn: $rush) {
                            Text(L10n.tr("quote.rush"))
                                .font(.khayt(14.5, relativeTo: .subheadline))
                                .foregroundStyle(KhaytDesign.ink)
                        }
                        .tint(KhaytDesign.hot)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 52)
                    }
                    if let error {
                        V2Note(text: error, tone: KhaytDesign.late)
                    }
                    V2PrimaryButton(title: L10n.tr("quote.calculate"), busy: isLoading) {
                        Task { await calculate() }
                    }
                    .padding(.top, 4)
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(KhaytDesign.ground.ignoresSafeArea())
            .navigationTitle(L10n.tr("quote.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common.close")) { dismiss() }
                }
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(KhaytDesign.hairline).frame(width: 1).padding(.vertical, 10)
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.khayt(10.5, .bold, relativeTo: .caption2))
            .tracking(1.05)
            .foregroundStyle(KhaytDesign.note)
            .padding(.horizontal, 2)
            .padding(.top, 8)
    }

    /// Three short numbers abreast: weight, time, quantity are read together.
    private func numberField(_ label: String, _ text: Binding<String>, unit: String?, decimal: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label.uppercased())
                .font(.khayt(10, .bold, relativeTo: .caption2))
                .tracking(1)
                .foregroundStyle(KhaytDesign.note)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(spacing: 4) {
                TextField("", text: text, prompt: Text(verbatim: "0"))
                    .keyboardType(decimal ? .decimalPad : .numberPad)
                    .font(.khayt(18, .semibold, relativeTo: .body).monospacedDigit())
                    .foregroundStyle(KhaytDesign.ink)
                if let unit {
                    Text(verbatim: unit)
                        .font(.khayt(13, relativeTo: .footnote))
                        .foregroundStyle(KhaytDesign.note)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The answer, first — it is what the customer at the counter is waiting
    /// for. What the job costs the shop sits beneath it, for the margin to be
    /// seen rather than implied; it is not a customer-facing number.
    private func resultCard(_ r: QuoteResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("quote.total").uppercased())
                    .font(.khayt(10.5, .bold, relativeTo: .caption2))
                    .tracking(1.05)
                    .foregroundStyle(KhaytDesign.note)
                Text(money(r.price.total))
                    .font(.khayt(34, .semibold, relativeTo: .largeTitle).monospacedDigit())
                    .foregroundStyle(KhaytDesign.brand)
            }
            .padding(16)
            VStack(spacing: 0) {
                if r.price.discount > 0 { row(L10n.tr("quote.discount"), "−" + money(r.price.discount)) }
                if r.price.rushFee > 0 { row(L10n.tr("quote.rush_fee"), money(r.price.rushFee)) }
                if let tier = r.priceTier {
                    // A tier REPLACES cost-plus-margin, so say so rather than
                    // leaving the shop wondering why the margin is ignored.
                    row(L10n.tr("quote.tier").replacingOccurrences(of: "{n}", with: "\(tier.minQty)"),
                        money(tier.pricePerUnit))
                }
                row(L10n.tr("quote.unit_cost"), money(r.unitCost))
                row(L10n.tr("quote.bd.material"), money(r.breakdown.material))
                row(L10n.tr("quote.bd.machine"), money(r.breakdown.machine))
                row(L10n.tr("quote.bd.labor"), money(r.breakdown.labor))
                row(L10n.tr("quote.bd.buffer"), money(r.breakdown.buffer))
            }
        }
        .card()
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

    private func money(_ n: Double) -> String {
        let amount = String(format: "%.2f", n)
        return currency.isEmpty ? amount : "\(amount) \(currency)"
    }

    private func num(_ s: String) -> Double { Double(s.trimmingCharacters(in: .whitespaces)) ?? 0 }

    private func calculate() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        // A 1 kg spool is the near-universal case and the one number a shop
        // should not have to type to get an answer.
        let input = QuoteRequest(
            printWeight: num(printWeight),
            printTime: num(printTime),
            qty: max(1, Int(qty.trimmingCharacters(in: .whitespaces)) ?? 1),
            margin: num(margin),
            spoolCost: num(spoolCost),
            spoolWeight: 1000,
            laborRate: num(laborRate),
            prepTime: 0,
            postTime: 0,
            rush: rush
        )
        do {
            result = try await api.requestQuote(input)
        } catch {
            // Offline is a real answer here: a quote is a live question about the
            // shop's current prices, and a cached one could be honoured in front
            // of a customer at the wrong number.
            result = nil
            self.error = error.localizedDescription
        }
    }
}
