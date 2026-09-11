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
    /// Table or grid, remembered per window.
    ///
    /// ── WHY THE CATALOGUE OF ALL SCREENS GETS A GRID ──────────────────────
    ///
    /// The library's grid was argued for on one line: *a print shop recognises
    /// a model by looking at it*. That argument is STRONGER here and the screen
    /// did not have it — these are the things a shop photographs and sells, and
    /// they were five columns of text. A shop scanning for "the one with the
    /// palm" was reading names.
    ///
    /// The table stays and stays the default: it is the only view that shows
    /// margin and weight side by side, which is what pricing work needs.
    @SceneStorage("catalogue.layout") private var layout: Layout = .table
    @State private var selection: KhaytEngine.CatalogueRow.ID?
    @State private var order: [KeyPathComparator<KhaytEngine.CatalogueRow>] =
        [.init(\.final, order: .reverse)]

    enum Layout: String { case table, grid }

    var body: some View {
        content
            .toolbar {
                ToolbarItem {
                    Picker("", selection: $layout) {
                        Image(systemName: "list.bullet").tag(Layout.table)
                            .help(shop.words.callIt("mac.view_list"))
                        Image(systemName: "square.grid.2x2").tag(Layout.grid)
                            .help(shop.words.callIt("mac.view_grid"))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                ToolbarItem {
                    Button {
                        shop.editingProduct = shop.newProduct()
                    } label: {
                        Label(shop.words.callIt("mac.new_product"), systemImage: "plus")
                    }
                    // A sample book is not the shop's to add to.
                    .disabled(!shop.canMoveJobs)
                    .help(shop.words.callIt("mac.new_product"))
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch layout {
        case .table: table
        case .grid:  grid
        }
    }

    /// Open one for editing. Shared by the table and the grid so the two cannot
    /// come to disagree about what a double-click does.
    private func edit(_ id: KhaytEngine.CatalogueRow.ID) {
        guard shop.canMoveJobs else { return }
        Task {
            guard let product = await shop.productForEditing(id) else { return }
            shop.editingProduct = product
        }
    }

    // MARK: - The grid

    private static let cellWidth: CGFloat = 176
    private static let spacing: CGFloat = 16

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cellWidth), spacing: Self.spacing)],
                      spacing: Self.spacing) {
                ForEach(shop.shownProducts.sorted(using: order)) { row in
                    ProductCell(row: row, shop: shop, selected: selection == row.id)
                        .onTapGesture(count: 2) { edit(row.id) }
                        .onTapGesture { selection = row.id }
                        .contextMenu { menu(for: row) }
                }
            }
            .padding(Metric.screen)
        }
        .background(Khayt.ground)
        .overlay { emptyState }
    }

    @ViewBuilder private func menu(for row: KhaytEngine.CatalogueRow) -> some View {
        Button(shop.words.callIt("mac.edit_product") + "\u{2026}") { edit(row.id) }
            .disabled(!shop.canMoveJobs)
    }

    /// Nothing here, or nothing matching — two different things to say.
    ///
    /// A shop that has typed a search and sees "No catalogue yet" has been told
    /// its products are gone.
    @ViewBuilder private var emptyState: some View {
        if shop.catalogueRows.isEmpty {
            EmptyHere(title: shop.words.callIt("mac.no_products"),
                      message: shop.words.callIt("mac.no_products_hint"), mark: .catalogue)
        } else if shop.shownProducts.isEmpty {
            NothingMatched(shop: shop, mark: .catalogue)
        }
    }

    // MARK: - The table

    private var table: some View {
        Table(shop.shownProducts.sorted(using: order), selection: $selection,
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
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        // As every other table in the app: the ground shows through.
        .scrollContentBackground(.hidden)
        .background(Khayt.ground)
        .contextMenu(forSelectionType: KhaytEngine.CatalogueRow.ID.self) { ids in
            if let id = ids.first {
                Button(shop.words.callIt("mac.edit_product") + "\u{2026}") { edit(id) }
                    .disabled(!shop.canMoveJobs)
            }
        } primaryAction: { ids in
            if let id = ids.first { edit(id) }
        }
        .overlay { emptyState }
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

/// One product, as a card.
///
/// The photo carries the cell and the price sits under it, because those are
/// the two things a shop looks for. Margin and weight are the table's job —
/// putting all five figures on a card makes it a table row with a picture.
private struct ProductCell: View {
    let row: KhaytEngine.CatalogueRow
    let shop: Shop
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary.opacity(0.4))
                if let image = Self.picture(row.thumbnail) {
                    Image(nsImage: image)
                        .resizable().scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    // Not a broken-image glyph: a product with no photo is the
                    // ordinary case in a shop that has not got round to it, and
                    // drawing it as a fault makes the whole grid look wrong.
                    Image(systemName: "shippingbox")
                        .font(.system(size: 28)).foregroundStyle(.tertiary)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3)
            }

            Text(row.name.isEmpty ? shop.words.callIt("mac.unnamed") : row.name)
                .lineLimit(2).font(.callout)
                .foregroundStyle(row.name.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            Text(Money.text(row.final, shop.currency))
                .moneyStyle().font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The shop's photo, decoded from the data URI on the record.
    ///
    /// Nil for anything that is not one. `CatalogueRow.thumbnail` has already
    /// refused everything but `data:image/`, so this is the second of the two
    /// gates rather than the only one.
    static func picture(_ uri: String) -> NSImage? {
        guard let comma = uri.firstIndex(of: ","), uri.hasPrefix("data:image/") else { return nil }
        let encoded = String(uri[uri.index(after: comma)...])
        guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else { return nil }
        return NSImage(data: data)
    }
}
