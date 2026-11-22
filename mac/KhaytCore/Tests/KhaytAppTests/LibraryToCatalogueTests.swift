import Foundation
import Testing
@testable import KhaytApp
import KhaytCore

/// "I should be able to add to the catalogue using the library" (Sep 2026).
@MainActor
struct LibraryToCatalogueTests {
    static func shop() async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        return shop
    }

    @Test("several models make ONE product, each a part, priced by the same rule as one model")
    func severalAsOne() async throws {
        let shop = await Self.shop()
        let files = Array(shop.files.prefix(3))
        try #require(files.count == 3, "the sample book has fewer than three models")
        let product = try #require(await shop.productFromFiles(files, name: "Desk set"))
        guard case .array(let parts)? = product.rest["parts"] else { Issue.record("no parts"); return }
        #expect(parts.count == 3)
        #expect(product.names.values.allSatisfy { $0 == "Desk set" })
        // Each part is what a single model would have made.
        let single = try #require(await shop.partFields(from: files[1]))
        #expect(parts[1] == .object(single.part))
    }

    @Test("with no name given, the product is called after the first model")
    func defaultName() async throws {
        let shop = await Self.shop()
        let files = Array(shop.files.prefix(2))
        try #require(files.count == 2)
        let product = try #require(await shop.productFromFiles(files, name: "  "))
        #expect(product.names.values.allSatisfy { $0 == files[0].title })
    }

    @Test("a project folder is every model under it, at any depth")
    func folder() async throws {
        let shop = await Self.shop()
        guard let path = shop.files.compactMap(\.groupName).first else { return }
        let top = path.components(separatedBy: ImportGrouping.separator)[0]
        let inIt = shop.files(inFolder: top)
        #expect(!inIt.isEmpty)
        #expect(inIt.allSatisfy { Shop.isUnder($0.groupName, top) })
        #expect(shop.files(inFolder: top + "-not-a-folder").isEmpty)
    }

    @Test("a part from the library is COSTED — rates and a spool — so the product has a price")
    func priced() async throws {
        let shop = await Self.shop()
        let file = try #require(shop.files.first { $0.mesh != nil } ?? shop.files.first)
        let filled = try #require(await shop.partFields(from: file))
        for key in ["laborRate", "elecRate", "failureRate", "wearRate", "powerDraw"] {
            #expect(filled.part[key] != nil, "\(key) is blank, so it costs nothing")
        }
        #expect(filled.part["filamentId"] != nil && filled.part["spoolCost"] != nil)
        let product = try #require(await shop.productFromFile(file))
        guard case .array(let parts)? = product.rest["parts"] else { Issue.record("no parts"); return }
        let pricing = try #require(await shop.priceProduct(parts: parts, margin: nil, components: nil))
        #expect(pricing.price > 0, "it is not calculating the price")
    }

    @Test("the spool is the material the slicer used, else the first costed one")
    func spoolChoice() throws {
        let json = """
        [{"id":"a","material":"PETG","cost":90,"weight":1000},{"id":"b","material":"PLA+ 2.0","cost":75,"weight":859},
         {"id":"c","material":"TPU","cost":0}]
        """
        let spools = try JSONDecoder().decode([Spool].self, from: Data(json.utf8))
        let pla: JSONValue = .object(["parsed": .object(["filamentType": .string("PLA")])])
        #expect(Shop.spool(for: [:], file: pla, among: spools)?.id == "b")
        #expect(Shop.spool(for: [:], file: .object([:]), among: spools)?.id == "a", "no material said: the first costed")
        #expect(Shop.spool(for: [:], file: .object([:]), among: [spools[2]]) == nil, "a spool with no cost prices nothing")
    }
}
