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
            Form {
                Section(L10n.tr("quote.part")) {
                    field(L10n.tr("quote.weight"), text: $printWeight, unit: "g")
                    field(L10n.tr("quote.time"), text: $printTime, unit: "h")
                    field(L10n.tr("quote.qty"), text: $qty, unit: nil)
                }
                Section(L10n.tr("quote.rates")) {
                    field(L10n.tr("quote.spool_cost"), text: $spoolCost, unit: nil)
                    field(L10n.tr("quote.labor_rate"), text: $laborRate, unit: nil)
                    field(L10n.tr("quote.margin"), text: $margin, unit: "%")
                    Toggle(L10n.tr("quote.rush"), isOn: $rush)
                }

                if let result {
                    resultSection(result)
                }
                if let error {
                    Section {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(KhaytDesign.danger)
                    }
                }
            }
            .khaytForm()
            .navigationTitle(L10n.tr("quote.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common.close")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("quote.calculate")) { Task { await calculate() } }
                        .disabled(isLoading)
                }
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, unit: String?) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 110)
            if let unit {
                Text(unit)
                    .font(.system(size: 13))
                    .foregroundStyle(KhaytDesign.textMuted)
            }
        }
    }

    @ViewBuilder
    private func resultSection(_ r: QuoteResult) -> some View {
        Section(L10n.tr("quote.result")) {
            row(L10n.tr("quote.total"), money(r.price.total), emphasis: true)
            if r.price.discount > 0 { row(L10n.tr("quote.discount"), "−" + money(r.price.discount)) }
            if r.price.rushFee > 0 { row(L10n.tr("quote.rush_fee"), money(r.price.rushFee)) }
            if let tier = r.priceTier {
                // A tier REPLACES cost-plus-margin, so say so rather than leaving
                // the shop wondering why their margin appears to be ignored.
                row(L10n.tr("quote.tier").replacingOccurrences(of: "{n}", with: "\(tier.minQty)"),
                    money(tier.pricePerUnit))
            }
        }
        Section(L10n.tr("quote.cost")) {
            // What the job costs the shop, so the margin is visible rather than
            // implied. Not a customer-facing number.
            row(L10n.tr("quote.unit_cost"), money(r.unitCost))
            row(L10n.tr("quote.bd.material"), money(r.breakdown.material))
            row(L10n.tr("quote.bd.machine"), money(r.breakdown.machine))
            row(L10n.tr("quote.bd.labor"), money(r.breakdown.labor))
            row(L10n.tr("quote.bd.buffer"), money(r.breakdown.buffer))
        }
    }

    private func row(_ label: String, _ value: String, emphasis: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: emphasis ? 16 : 14, weight: emphasis ? .bold : .regular))
            Spacer()
            Text(value)
                .font(.system(size: emphasis ? 18 : 14, weight: emphasis ? .bold : .regular))
                .foregroundStyle(emphasis ? KhaytDesign.brand : KhaytDesign.text)
                .monospacedDigit()
        }
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
