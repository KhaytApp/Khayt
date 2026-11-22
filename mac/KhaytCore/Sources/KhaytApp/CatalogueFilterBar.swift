import SwiftUI
import KhaytCore

/// Narrowing the catalogue.
///
/// Reported together with the library's: *"there are some placeholder texts,
/// also where are the filters for products and models?"* — the answer for both
/// was a search box and nothing else, which makes a shop type what it could
/// have pressed and gives it no way to ask a question it cannot spell.
///
/// The three axes are `Shop.catalogueGroups`, `catalogueMaterials` and the
/// unpriced count, and that file says why each is here. The row itself is
/// `FilterBar`, shared with the library.
struct CatalogueFilterBar: View {
    @Bindable var shop: Shop

    private var chips: [FilterChipModel] {
        var out: [FilterChipModel] = []
        // FIRST, and not in the order the others are in. The other two chips
        // find things a shop is looking for; this one finds things it does not
        // know are wrong, which is the only reason to put a chip somewhere
        // other than where the sort would.
        let facets = shop.catalogueFacets
        if facets.unpriced > 0 || shop.catalogueUnpricedOnly {
            out.append(FilterChipModel(id: "unpriced",
                                       label: shop.words.callIt("mac.no_price_yet"),
                                       count: facets.unpriced,
                                       on: shop.catalogueUnpricedOnly) {
                shop.catalogueUnpricedOnly.toggle()
            })
        }
        for row in LibraryFilterBar.withActive(facets.categories, shop.catalogueCategory) {
            out.append(FilterChipModel(id: "category:" + row.name, label: row.name,
                                       count: row.count,
                                       on: shop.catalogueCategory == .named(row.name)) {
                shop.catalogueCategory =
                    shop.catalogueCategory == .named(row.name) ? nil : .named(row.name)
            })
        }
        for row in LibraryFilterBar.withActive(facets.materials, shop.catalogueMaterial) {
            out.append(FilterChipModel(id: "material:" + row.name, label: row.name,
                                       count: row.count,
                                       on: shop.catalogueMaterial == .named(row.name)) {
                shop.catalogueMaterial =
                    shop.catalogueMaterial == .named(row.name) ? nil : .named(row.name)
            })
        }
        return out
    }

    var body: some View {
        FilterBar(chips: chips,
                  showingClear: shop.catalogueFilterOn,
                  clearLabel: shop.words.callIt("log.clear_filters")) {
            shop.clearCatalogueFilter()
        }
    }
}
