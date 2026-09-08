import SwiftUI
import KhaytCore

/// What the shop sells.
///
/// Not the print library — that is the files. This is the catalogue: the things
/// a shop has decided are products, with a price it stands behind. On this book
/// it is the Saudi kings series, and it feeds the storefront, which is why the
/// price shown here is the one the shared rule computes rather than whatever
/// number is nearest to hand.
///
/// A PRICE HAS A REASON AND THE REASON IS SHOWN. `lib/product-price.js`
/// answers with a source as well as a figure — a typed override, a rounded
/// figure, or the calculated one — and a price whose provenance is not stated
/// is a price nobody can check.
struct Catalogue: View {
    @Bindable var shop: Shop
    @SceneStorage("catalogue.columns") private var columns: TableColumnCustomization<KhaytEngine.CatalogueRow>
    @State private var selection: KhaytEngine.CatalogueRow.ID?
    @State private var order: [KeyPathComparator<KhaytEngine.CatalogueRow>] =
        [.init(\.final, order: .reverse)]

    var body: some View {
        Table(shop.catalogueRows.sorted(using: order), selection: $selection,
              sortOrder: $order, columnCustomization: $columns) {
            TableColumn(shop.words.callIt("cat.title"), value: \.name) { row in
                VStack(alignment: .leading, spacing: 1) {
                    // A product with no name in any language reads as blank in
                    // Khayt too; saying so beats a row that looks lost.
                    Text(row.name.isEmpty ? shop.words.callIt("mac.unnamed") : row.name)
                        .lineLimit(1)
                        .foregroundStyle(row.name.isEmpty ? AnyShapeStyle(.secondary)
                                                          : AnyShapeStyle(.primary))
                    if !row.description.isEmpty {
                        Text(row.description).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .width(min: 180, ideal: 280)

            TableColumn(shop.words.callIt("mac.price"), value: \.final) { row in
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Money.text(row.final, shop.currency)).moneyStyle()
                    // WHY that number. A rounded price that matches the
                    // calculated one says "calculated", because saying
                    // "rounded" of a figure that did not move is noise.
                    Text(Self.reasonLine(row, shop.words, currency: shop.currency))
                        .font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 110, ideal: 140)
            .alignment(.trailing)

            TableColumn(shop.words.callIt("mac.margin"), value: \.marginSort) { row in
                Text(row.margin.map { "\(Int($0))%" } ?? "—")
                    .moneyStyle().foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 88)
            .alignment(.trailing)

            TableColumn(shop.words.callIt("mac.weight"), value: \.weightSort) { row in
                Text(row.weightGrams.map { "\(Int($0)) \(shop.words.callIt("common.grams"))" } ?? "—")
                    .moneyStyle()
            }
            .width(min: 72, ideal: 90)
            .alignment(.trailing)

            TableColumn(shop.words.callIt("plib.material"), value: \.material) { row in
                Text(row.material.isEmpty ? "—" : row.material).lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 130)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        // As every other table in the app: the ground shows through.
        .scrollContentBackground(.hidden)
        .background(Khayt.ground)
        .overlay {
            if shop.catalogueRows.isEmpty {
                EmptyHere(title: shop.words.callIt("mac.no_products"), message: shop.words.callIt("mac.no_products_hint"))
            }
        }
    }

    /// Khayt's own words for where a price came from.
    ///
    /// The choice is `lib/product-price.js`'s `describe`, made once and carried
    /// on the row. It used to be made again here in Swift, correctly — and that
    /// is the problem with it: a rule written down twice is a rule that can
    /// disagree with itself later, and the copy that drifts is the one nobody
    /// is looking at.
    static func reason(_ row: KhaytEngine.CatalogueRow) -> String { row.reason }

    /// That reason as a FINISHED line.
    ///
    /// ── A PREFIX IS NOT A SENTENCE ─────────────────────────────────────────
    ///
    /// `pe.price_is_rounded` is "Rounded from" — and it is "Gerundet von",
    /// "Arrondi depuis", "مُقرَّب من" in the other eight. Every one of them is a
    /// PREFIX that names a figure, and the Electron app supplies the figure:
    /// `(${why} · ${fmtPrice(r.basePrice)})` in `renderer/inventory.js`.
    ///
    /// This app printed the prefix alone. The first time the catalogue was ever
    /// photographed, nineteen of its twenty rows read "Rounded from" and
    /// stopped — pointing at a number the screen never showed, and the one
    /// figure a shop needs to tell a rounded price from a calculated one.
    ///
    /// `base` was already on the row. Only the sentence was missing.
    static func reasonLine(_ row: KhaytEngine.CatalogueRow,
                           _ words: Words, currency: String) -> String {
        let said = words.callIt(row.reason)
        // Only the rounding reason names another number. "Calculated" and
        // "Your own price" are whole sentences, and appending a figure to
        // either would state the price twice.
        guard row.reason == "pe.price_is_rounded" else { return said }
        return "\(said) \(Money.text(row.base, currency))"
    }
}

extension KhaytEngine.CatalogueRow {
    /// A table sorts on a value, and a missing margin must sort as absent
    /// rather than as zero — a product with no margin set is not the cheapest.
    var marginSort: Double { margin ?? -1 }
    var weightSort: Double { weightGrams ?? -1 }
}
