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
}
