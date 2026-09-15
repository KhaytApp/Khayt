import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Filling a product's part from a model in the library.
///
/// Reported from the running app: *"in Catalogue I should be able to load the
/// print file to calculate the price"*.
@MainActor
struct ProductPartFromModelTests {

    @Test("a part keeps the model it was filled from through a save")
    func partRoundTripsItsModel() throws {
        var row = ProductSheet.PartRow()
        row.name = "hand"; row.grams = "140.91"; row.hours = "5.25"; row.printFileId = "PF-x"
        let record = row.record(spools: [])
        let back = try #require(ProductSheet.PartRow.from(record))
        #expect(back.printFileId == "PF-x", "the join to the library model was dropped on the way through")
        #expect(back.grams == "140.91" && back.hours == "5.25")
        // And a part typed by hand carries no join at all — not an empty one.
        var typed = ProductSheet.PartRow(); typed.name = "x"; typed.grams = "1"
        guard case .object(let o) = typed.record(spools: []) else { return }
        #expect(o["printFileId"] == nil)
    }

    @Test("a library model fills a part, named, joined, and with a note when figures are estimates")
    func modelFillsAPart() async throws {
        let shop = Shop()
        await shop.load(.sample)
        guard let file = shop.files.first else { return }
        let filled = try #require(await shop.partFields(from: file))
        #expect(Shop.plainString(filled.part["name"]) == file.title)
        #expect(Shop.plainString(filled.part["printFileId"]) == file.id,
                "the part does not say which model it came from")
        #expect(Shop.plainNumber(filled.part["qty"]) == 1)
        // The same rule the other direction uses: a product made from this
        // model has exactly this part.
        let product = try #require(await shop.productFromFile(file))
        guard case .array(let parts)? = product.rest["parts"], case .object(let p)? = parts.first else {
            Issue.record("productFromFile made no part"); return
        }
        #expect(p["printWeight"] == filled.part["printWeight"] && p["printTime"] == filled.part["printTime"],
                "product-from-model and part-from-model disagree, and they are one rule")
        #expect(shop.productNote == filled.note, "the two say different things about the same figures")
    }

    /// ── THE SENTENCES THAT WENT NOWHERE ────────────────────────────────────
    ///
    /// `productNote` and `productProblem` were set by `productFromFile` — "the
    /// weight is an estimate", "material is still missing" — and no view read
    /// them. A product made from an unsliced model showed estimated figures as
    /// if typed. The sheet shows both now, with the picker's own note.
    @Test("the product sheet offers the library and shows what a model could not answer")
    func sheetIsWired() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        let sheet = (try? String(contentsOf: root.appending(path: "ProductSheet.swift"), encoding: .utf8)) ?? ""
        #expect(!sheet.isEmpty, "ProductSheet.swift moved; this test is reading nothing")
        #expect(sheet.contains("PickModelSheet(shop: shop)"), "the product sheet no longer offers the library")
        #expect(sheet.contains("link.from_library"), "the button is not the shared word both apps use")
        #expect(sheet.contains("shop.productNote") && sheet.contains("shop.productProblem"), """
            the product notes are set and shown nowhere again — an estimate that \
            looks typed is the same bug as a zero that looks typed
            """)
        let picker = (try? String(contentsOf: root.appending(path: "PickModelSheet.swift"), encoding: .utf8)) ?? ""
        #expect(picker.contains("LibrarySort.khayt.order"), "the picker orders models by a rule of its own")
        #expect(picker.contains(".cancelAction"), "Escape does not close the picker — §6")
    }
}
