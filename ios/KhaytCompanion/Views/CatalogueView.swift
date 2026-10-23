import KhaytCore
import SwiftUI
import UIKit

/// What the shop sells, on the phone: find a product, see its price as the
/// Mac shows it, and send it to the customer or start a quote from it.
struct CatalogueView: View {
    @EnvironmentObject private var api: KhaytAPIClient
    @Environment(\.dismiss) private var dismiss

    @State private var page: CataloguePage?
    @State private var query = ""
    @State private var problem: String?

    /// The groups in the order the shop's products first name them.
    private var groups: [(name: String, items: [CatalogueItem])] {
        let shown = BookReader.filter(page?.items ?? [], query: query)
        var order: [String] = []
        var by: [String: [CatalogueItem]] = [:]
        for item in shown {
            if by[item.row.group] == nil { order.append(item.row.group) }
            by[item.row.group, default: []].append(item)
        }
        return order.map { (name: $0, items: by[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    KhaytSearchField(text: $query, prompt: L10n.tr("catalogue.search"))
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
                if let problem {
                    Section { V2Note(text: problem, tone: KhaytDesign.note).listRowBackground(Color.clear) }
                }
                if let page, !page.whole {
                    // Never look complete when it is not: say how much is here.
                    Section {
                        V2Note(text: L10n.format("catalogue.partial", page.items.count, page.available ?? page.items.count))
                            .listRowBackground(Color.clear)
                    }
                }
                ForEach(groups, id: \.name) { group in
                    Section(group.name.isEmpty ? L10n.tr("catalogue.ungrouped") : group.name) {
                        ForEach(group.items) { item in
                            NavigationLink { CatalogueItemPage(item: item, currency: page?.currency) } label: {
                                CatalogueRow(item: item, currency: page?.currency)
                            }
                            .listRowBackground(KhaytDesign.surface)
                        }
                    }
                }
                if let page, groups.isEmpty, problem == nil {
                    Section {
                        Text(L10n.tr(page.items.isEmpty ? "catalogue.empty" : "catalogue.no_match"))
                            .font(.khayt(14, relativeTo: .body)).foregroundStyle(KhaytDesign.note)
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .khaytScreen(title: L10n.tr("catalogue.title"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.tr("common.close")) { dismiss() } }
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func load() async {
        do {
            page = try await api.fetchCatalogue()
            problem = nil
        } catch {
            page = CataloguePage()
            problem = KhaytAPIClient.say(error)
        }
    }
}

/// A product's picture from its record, or a box where it has none.
struct CataloguePicture: View {
    let dataURI: String
    let side: CGFloat

    private var image: UIImage? {
        guard let comma = dataURI.firstIndex(of: ","), dataURI.hasPrefix("data:image/"),
              let data = Data(base64Encoded: String(dataURI[dataURI.index(after: comma)...])) else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side > 100 ? 14 : 9).fill(KhaytDesign.sunk)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "shippingbox").font(.system(size: side * 0.36, weight: .light))
                    .foregroundStyle(KhaytDesign.note)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side > 100 ? 14 : 9))
        .accessibilityHidden(true)
    }
}

struct CatalogueRow: View {
    let item: CatalogueItem
    let currency: String?

    var body: some View {
        HStack(spacing: 12) {
            CataloguePicture(dataURI: item.row.thumbnail, side: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.row.name.isEmpty ? item.row.id : item.row.name)
                    .font(.khayt(15, .medium, relativeTo: .body)).foregroundStyle(KhaytDesign.ink).lineLimit(2)
                if let line = CatalogueItemPage.specs(item.row) {
                    Text(line).font(.khayt(12.5, relativeTo: .footnote)).foregroundStyle(KhaytDesign.note).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                Text(Money.text(item.row.final, currency))
                    .font(.khayt(15, .semibold, relativeTo: .body).monospacedDigit()).foregroundStyle(KhaytDesign.ink)
                if let stock = item.stock {
                    StockBadge(count: stock)
                }
            }
        }
    }
}

struct StockBadge: View {
    let count: Int
    var body: some View {
        Text(count > 0 ? L10n.format("catalogue.in_stock", count) : L10n.tr("catalogue.out_of_stock"))
            .font(.khayt(11.5, .medium, relativeTo: .caption))
            .foregroundStyle(count > 0 ? KhaytDesign.done : KhaytDesign.late)
    }
}

/// One product: its picture, price and why, what it takes to print, and
/// the two things a customer conversation needs.
struct CatalogueItemPage: View {
    let item: CatalogueItem
    let currency: String?
    @EnvironmentObject private var api: KhaytAPIClient

    @State private var qty = 1
    @State private var makingQuote = false
    @State private var machines: [MachineInfo] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    CataloguePicture(dataURI: item.row.thumbnail, side: 112)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.row.name.isEmpty ? item.row.id : item.row.name)
                            .font(.khayt(19, .semibold, relativeTo: .title3)).foregroundStyle(KhaytDesign.ink)
                        if !item.row.group.isEmpty {
                            Text(item.row.group).font(.khayt(13, relativeTo: .footnote)).foregroundStyle(KhaytDesign.note)
                        }
                        if let stock = item.stock { StockBadge(count: stock) }
                    }
                }
                .padding(.bottom, 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text(Money.text(item.row.final * Double(qty), currency))
                        .font(.khayt(30, .semibold, relativeTo: .largeTitle).monospacedDigit())
                        .foregroundStyle(KhaytDesign.ink)
                    if qty > 1 {
                        Text(L10n.format("calc.share.each", qty, Money.text(item.row.final, currency)))
                            .font(.khayt(13, relativeTo: .footnote)).foregroundStyle(KhaytDesign.note)
                    }
                    Text(L10n.tr(Self.reasonKey(item.row)))
                        .font(.khayt(12, relativeTo: .caption)).foregroundStyle(KhaytDesign.note)
                    if let line = Self.specs(item.row) {
                        Text(line).font(.khayt(13.5, relativeTo: .subheadline)).foregroundStyle(KhaytDesign.note)
                    }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading).card()

                V2FieldCard {
                    V2Field(label: L10n.tr("order.field.quantity"), last: true) {
                        Stepper(value: $qty, in: 1...1000) {
                            Text(qty.formatted(.number.locale(L10n.locale))).monospacedDigit()
                        }
                    }
                }

                if item.row.final > 0 {
                    ShareLink(item: shareText) {
                        Label(L10n.tr("calc.share"), systemImage: "square.and.arrow.up")
                            .font(.khayt(15.5, .semibold, relativeTo: .body))
                            .foregroundStyle(KhaytDesign.brand)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(KhaytDesign.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(KhaytDesign.brand, lineWidth: 1))
                    }
                    V2PrimaryButton(title: L10n.tr("quote.file.make_quote")) { makingQuote = true }
                }

                if !item.row.description.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.tr("catalogue.description")).font(.khayt(12, .semibold, relativeTo: .caption))
                            .foregroundStyle(KhaytDesign.note)
                        Text(item.row.description).font(.khayt(14, relativeTo: .body)).foregroundStyle(KhaytDesign.ink)
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading).card()
                }
            }
            .padding(16)
        }
        .background(KhaytDesign.ground.ignoresSafeArea())
        .navigationTitle(item.row.name.isEmpty ? item.row.id : item.row.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { machines = (try? await api.fetchMachines()) ?? [] }
        .sheet(isPresented: $makingQuote) { NewOrderSheet(machines: machines, onCreated: {}, initial: draft) }
    }

    /// The customer's message: the product, the total, and each when more than one.
    private var shareText: String { Self.shareText(item.row, qty: qty, currency: currency) }

    static func shareText(_ row: KhaytEngine.CatalogueRow, qty: Int, currency: String?) -> String {
        var lines = [row.name.isEmpty ? row.id : row.name,
                     L10n.format("calc.share.price", Money.text(row.final * Double(max(1, qty)), currency))]
        if qty > 1 { lines.append(L10n.format("calc.share.each", qty, Money.text(row.final, currency))) }
        return lines.joined(separator: "\n")
    }

    private var draft: NewOrderDraft {
        var d = NewOrderDraft()
        d.project = qty > 1 ? "\(item.row.name) × \(qty)" : item.row.name
        d.isQuote = true
        d.material = item.row.material
        d.price = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), item.row.final * Double(qty))
        return d
    }

    /// `lib/product-price.js`'s `describe`, as this app's words.
    static func reasonKey(_ row: KhaytEngine.CatalogueRow) -> String {
        switch row.source {
        case "override": return "catalogue.price.override"
        case "rounded" where abs(row.final - row.base) >= 0.005: return "catalogue.price.rounded"
        default: return "catalogue.price.calculated"
        }
    }

    /// Print time, weight and material, from what the parts record.
    static func specs(_ row: KhaytEngine.CatalogueRow) -> String? {
        var bits: [String] = []
        if let h = row.printHours, h > 0 {
            bits.append(L10n.format("quote.file.hours", h.formatted(.number.precision(.fractionLength(0...1)).locale(L10n.locale))))
        }
        if let g = row.weightGrams, g > 0 { bits.append(L10n.grams(Int(g.rounded()))) }
        if !row.material.isEmpty { bits.append(row.material) }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }
}
