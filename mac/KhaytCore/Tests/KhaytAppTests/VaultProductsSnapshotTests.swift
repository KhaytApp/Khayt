import Foundation
import Testing
import SwiftUI
import KhaytCore
@testable import KhaytApp

/// The products list, the editor, the release sheet and the buyers sheet,
/// light and dark. Writes only when KHAYT_SNAPSHOT_DIR is set; once per
/// language with KHAYT_LANG.
@Suite(.serialized) @MainActor
struct VaultProductsSnapshotTests {

    static func product() throws -> VaultProducts.Product {
        let json = """
        {"productId":"P000000000000000000001","status":"active","kind":"paid","provider":"stripe",
         "checkoutUrl":"https://buy.stripe.com/test_123","priceText":"SAR 25",
         "title":{"en":"Saudi Kings relief set","ar":"طقم ملوك السعودية البارز"},
         "description":{"en":"Seven matched reliefs.","ar":"سبع لوحات متطابقة."},"defaultLang":"en",
         "licence":{"code":"personal","name":"Personal use"},"files":["f1","f2"],"previews":[],
         "makerrunListable":true,"delivery":{"maxDownloads":20,"perFile":true,"validDays":null}}
        """
        return try JSONDecoder().decode(VaultProducts.Product.self, from: Data(json.utf8))
    }

    static func buyers() throws -> [VaultProducts.Buyer] {
        let json = """
        [{"provider":"stripe","orderId":"cs_test_a1","buyerEmail":"sara@example.com","status":"paid","grantId":"G1",
          "used":3,"remaining":37},
         {"provider":"manual","orderId":"BANK-7","buyerEmail":"omar@shop.sa","status":"revoked","grantId":"G2",
          "used":1,"remaining":null}]
        """
        return try JSONDecoder().decode([VaultProducts.Buyer].self, from: Data(json.utf8))
    }

    @Test("the selling sheets render, light and dark")
    func sheets() async throws {
        guard SnapshotTests.outputDir != nil else { return }
        let shop = Shop()
        await shop.load(.sample)
        let lang = Direction.shopLanguage()
        let p = try Self.product()
        let names = ["f1": "Abdulaziz.3mf", "f2": "Stand.stl", "f3": "Kit.3mf"]
        let s = SnapshotTests()
        let wide = SheetMetrics.outerWidth(600), mid = SheetMetrics.outerWidth(560), narrow = SheetMetrics.outerWidth(500)
        for dark in [false, true] {
            let tag = "vp-\(lang)-\(dark ? "dark" : "light")"
            func shot(_ v: some View, _ name: String, _ size: CGSize) throws {
                if dark { try s.renderDark(v, tag + "-" + name, size: size) }
                else { try s.render(v.background(Khayt.ground), tag + "-" + name, size: size) }
            }
            try shot(VaultProductsSheet(shop: shop, shown: [p], released: [
                p.productId: .init(releasedAt: "2026-10-24T10:00:00Z", items: [.init(fileId: "f1", version: 2)])]),
                     "list", CGSize(width: wide, height: 520))
            try shot(VaultProductEditor(shop: shop, target: .edit(p), names: names) { _ in }, "editor",
                     CGSize(width: mid, height: 1100))
            try shot(VaultReleaseSheet(shop: shop, product: p, names: names,
                                       shown: [("f1", "Abdulaziz.3mf", 2), ("f2", "Stand.stl", 1)]) { _ in },
                     "release", CGSize(width: narrow, height: 460))
            try shot(VaultBuyersSheet(shop: shop, product: p, shown: try Self.buyers()) {}, "buyers",
                     CGSize(width: mid, height: 520))
        }
    }
}
