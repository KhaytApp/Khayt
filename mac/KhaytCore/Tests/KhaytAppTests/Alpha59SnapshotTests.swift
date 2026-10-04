import Foundation
import SwiftUI
import AppKit
import Testing
import KhaytCore
@testable import KhaytApp

/// Pictures of what alpha.59 added and its review changed, so a review can SEE
/// them: the calculator filled from a two-plate model with two colours, purge
/// and a consumable; the library's As sliced and Consumables per print; a job
/// taken from a product with components; and the catalogue's search results.
///
/// Light and dark here; run once more with `KHAYT_LANG=ar` for right-to-left.
/// Writes only when `KHAYT_SNAPSHOT_DIR` is set.
@MainActor
struct Alpha59SnapshotTests {

    func both(_ view: some View, _ name: String, size: CGSize) throws {
        let lang = Direction.shopLanguage()
        try SnapshotTests().render(view.background(Khayt.ground), "a59-\(name)-\(lang)-light", size: size)
        try SnapshotTests().renderDark(view, "a59-\(name)-\(lang)-dark", size: size)
    }

    @Test("alpha.59's calculator, library, job sheet and catalogue, light and dark")
    func screens() async throws {
        guard SnapshotTests.outputDir != nil else { return }
        let shop = Shop()
        await shop.load(.sample)

        // ── The calculator, from the two-plate lantern ────────────────────
        let lantern = try #require(shop.files.first { $0.id == "PF-sample-lantern" })
        let made = try #require(await shop.partFields(from: lantern, plate: nil))
        let calc = CalculatorModel()
        calc.fill(from: lantern, plate: nil,
                  grams: Shop.plainNumber(made.part["printWeight"]) ?? 0,
                  hours: Shop.plainNumber(made.part["printTime"]) ?? 0, shop: shop)
        calc.purge = "18"
        if let magnet = shop.consumables.first(where: { $0.id == "CONS-07" }) {
            calc.consumableLines = [.init(consumableId: magnet.id, qty: 4)]
        }
        await calc.recompute(shop)
        try both(Calculator(shop: shop, model: calc, picked: (lantern, nil)).content.frame(width: 760),
                 "calculator-two-plates", size: CGSize(width: 760, height: 1100))

        // Two colours typed by hand, the second just added: the split note.
        let typed = CalculatorModel(grams: "180", hours: "4")
        typed.lines[0].spoolId = shop.spools.first?.id
        typed.addFilament(spools: shop.spools)
        await typed.recompute(shop)
        try both(Calculator(shop: shop, model: typed).content.frame(width: 760),
                 "calculator-split", size: CGSize(width: 760, height: 900))

        // ── The library: As sliced, and Consumables per print ─────────────
        let inspector = LibraryInspector(shop: shop)
        let sliced = try #require(inspector.slicedSection(lantern))
        try both(sliced.padding(16).frame(width: 380), "library-as-sliced",
                 size: CGSize(width: 380, height: 360))
        let dallah = try #require(shop.files.first { $0.id == "PF-sample-dallah" })
        try both(ModelConsumablesSection(shop: shop, file: dallah).padding(16).frame(width: 380),
                 "library-consumables", size: CGSize(width: 380, height: 200))

        // ── A job from a product with components ──────────────────────────
        var product = Product(id: "PROD-snap", names: ["en": "Dallah stand", "ar": "حامل الدلة"],
                              descriptions: [:], margin: 35, group: "", category: "",
                              createdAt: "2026-09-01", rest: [:])
        product.rest["components"] = .array([.object(["consumableId": .string("CONS-07"),
                                                       "qtyPerUnit": .number(4)])])
        product.rest["assemblyQty"] = .number(2)
        product.rest["parts"] = .array([.object(["name": .string("Base"), "printWeight": .number(120),
                                                 "printTime": .number(3.5), "qty": .number(1)])])
        let parts = await shop.jobParts(from: product)
        let components = await shop.jobComponentsCost(of: product, assemblyQty: 2)
        let sheet = NewJobSheet(shop: shop, seed: .init(project: "Dallah stand", parts: parts, product: product,
                                                        componentsCost: components, assemblyQty: 2))
        try both(sheet.paper.frame(width: NewJobSheet.width), "new-job-components",
                 size: CGSize(width: NewJobSheet.width, height: 640))

        // ── The catalogue's results, as the menu lists them ───────────────
        let hits = await shop.filamentSearch("bambu pla", limit: 30)
        try both(CatalogueMenuPicture(hits: hits).frame(width: 380), "catalogue-results",
                 size: CGSize(width: 380, height: 520))
    }
}

/// The catalogue menu, drawn as a list: an `NSMenu` cannot be hosted by
/// `ImageRenderer`. Same grouping, names and swatches the menu uses.
private struct CatalogueMenuPicture: View {
    let hits: [KhaytEngine.FilamentHit]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SpoolSheet.catalogueGroups(hits), id: \.brand) { group in
                if group.hits.count > 1 {
                    Text(group.brand + "  ›").font(.callout.weight(.semibold))
                    ForEach(group.hits.prefix(4)) { hit in
                        row(SpoolSheet.catalogueName(hit, underBrand: true), hit).padding(.leading, 14)
                    }
                } else if let hit = group.hits.first {
                    row(SpoolSheet.catalogueName(hit, underBrand: false), hit)
                }
            }
        }
        .padding(12)
    }

    private func row(_ title: String, _ hit: KhaytEngine.FilamentHit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title + "  ›").font(.callout)
            HStack(spacing: 6) {
                ForEach(hit.colours.prefix(6)) { colour in
                    if let image = Swatch.menuImage(hex: colour.hex) {
                        Image(nsImage: image)
                    }
                }
                Text(hit.colours.prefix(3).map(\.name).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}
