import SwiftUI
import UniformTypeIdentifiers

/// A customer sent a model — over WhatsApp, by email, in Files. Open it in
/// Khayt, get the shop's price for it from the Mac, and turn it into a quote.
struct QuoteFileSheet: View {
    @EnvironmentObject private var api: KhaytAPIClient
    @Environment(\.dismiss) private var dismiss

    let file: URL
    @State private var qty = 1
    @State private var answer: KhaytAPIClient.ModelEstimate?
    @State private var problem: String?
    @State private var asking = false
    @State private var makingQuote = false
    @State private var machines: [MachineInfo] = []

    private var name: String { file.deletingPathExtension().lastPathComponent }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    V2FieldCard {
                        V2Field(label: L10n.tr("quote.file.file")) {
                            Text(file.lastPathComponent).font(.khayt(15, .medium, relativeTo: .body)).lineLimit(2)
                        }
                        V2Field(label: L10n.tr("order.field.quantity"), last: true) {
                            Stepper(value: $qty, in: 1...1000) {
                                Text(qty.formatted(.number.locale(L10n.locale))).monospacedDigit()
                            }
                        }
                    }
                    if asking {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20)
                    } else if let answer, answer.ok, let price = answer.price {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(Money.text(price, answer.currency))
                                .font(.khayt(30, .semibold, relativeTo: .largeTitle).monospacedDigit())
                                .foregroundStyle(KhaytDesign.ink)
                            HStack(spacing: 14) {
                                if let g = answer.grams { Text(L10n.grams(Int(g.rounded()))) }
                                if let h = answer.hours {
                                    Text(L10n.format("quote.file.hours", h.formatted(.number.precision(.fractionLength(0...1)).locale(L10n.locale))))
                                }
                            }
                            .font(.khayt(14, relativeTo: .subheadline)).foregroundStyle(KhaytDesign.note)
                            Text(L10n.tr(answer.exact == true ? "quote.file.exact" : "quote.file.estimated"))
                                .font(.khayt(12, relativeTo: .caption)).foregroundStyle(KhaytDesign.note)
                        }
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading).card()
                        V2PrimaryButton(title: L10n.tr("quote.file.make_quote")) { makingQuote = true }
                    }
                    if let problem { V2Note(text: problem, tone: KhaytDesign.late) }
                }
                .padding(16)
            }
            .background(KhaytDesign.ground.ignoresSafeArea())
            .navigationTitle(L10n.tr("quote.file.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.tr("common.close")) { dismiss() } }
            }
            .task(id: qty) { await ask() }
            .task { machines = (try? await api.fetchMachines()) ?? [] }
            .sheet(isPresented: $makingQuote) {
                NewOrderSheet(machines: machines, onCreated: { dismiss() }, initial: draft)
            }
        }
    }

    /// The quote the price becomes: the file's name as the project, the
    /// Mac's figure as the price. The shop adds the customer and checks it.
    private var draft: NewOrderDraft {
        var d = NewOrderDraft()
        d.project = name
        d.isQuote = true
        if let p = answer?.price { d.price = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), p) }
        return d
    }

    private func ask() async {
        asking = true
        problem = nil
        defer { asking = false }
        do {
            let a = try await api.estimate(file: file, qty: qty)
            answer = a
            if !a.ok { problem = Self.reason(a.reason) }
        } catch {
            answer = nil
            problem = error.localizedDescription
        }
    }

    static func reason(_ r: String?) -> String {
        let known = ["off", "unsupported", "too-large", "no-numbers", "no-price", "busy"]
        guard let r, known.contains(r) else { return L10n.tr("quote.file.reason.no-price") }
        return L10n.tr("quote.file.reason.\(r)")
    }

    /// The types a customer's model arrives as. STL and OBJ are the system's;
    /// 3MF is the identifier the Mac app declares, and G-code ours —
    /// both imported in Info.plist.
    static let types: [UTType] = [
        UTType("public.standard-tesselated-geometry-format"), UTType("public.geometry-definition-format"),
        UTType("app.khayt.mac.three-mf"), UTType("app.khayt.gcode"),
    ].compactMap { $0 }
}
