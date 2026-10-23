import Foundation
import Testing
import SwiftUI
import KhaytCore
@testable import KhaytApp

/// The share sheet (before and after Create) and the Links sheet, in light
/// and dark. Writes only when KHAYT_SNAPSHOT_DIR is set, like `SnapshotTests`;
/// run once per language with KHAYT_LANG.
@Suite(.serialized) @MainActor
struct VaultLinksSnapshotTests {

    static func grants() throws -> [VaultClient.Grant] {
        let json = """
        [{"grantId":"AAAAAAAAAAAAAAAAAAAAAA","state":"ok","createdAt":"2026-10-20T09:00:00Z","expiresAt":"2026-10-30T12:00:00Z",
          "limits":{"maxDownloads":10},"password":true,"used":3,"devices":2,
          "items":[{"fileId":"f1","version":1,"used":3,"remaining":7},{"fileId":"f2","version":2,"used":0,"remaining":7}]},
         {"grantId":"BBBBBBBBBBBBBBBBBBBBBB","state":"revoked","createdAt":"2026-10-01T09:00:00Z",
          "revokedAt":"2026-10-05T16:30:00Z","limits":{},"password":false,"used":12,"devices":5,
          "items":[{"fileId":"f3","version":1,"used":12,"remaining":null}]}]
        """
        return try JSONDecoder().decode([VaultClient.Grant].self, from: Data(json.utf8))
    }

    @Test("the share and links sheets render, light and dark")
    func sheets() async throws {
        guard SnapshotTests.outputDir != nil else { return }
        let shop = Shop()
        await shop.load(.sample)
        let lang = Direction.shopLanguage()
        let request = VaultShareRequest(recordIds: ["a", "b"], titles: ["Bracket", "Hinge"])
        let link = try VaultLink(origin: "https://cloud.khaytapp.com", grantId: VaultCrypto.newGrantId(),
                                 secret: VaultCrypto.newLinkSecret())
        let names = ["f1": "Saudi Kings - Abdulaziz.3mf", "f2": "Stand.stl", "f3": "Kit.3mf"]
        let s = SnapshotTests()
        let width = SheetMetrics.outerWidth(440), wide = SheetMetrics.outerWidth(560)
        for dark in [false, true] {
            let tag = "vl-\(lang)-\(dark ? "dark" : "light")"
            func shot(_ v: some View, _ name: String, _ size: CGSize) throws {
                if dark { try s.renderDark(v, tag + "-" + name, size: size) }
                else { try s.render(v.background(Khayt.ground), tag + "-" + name, size: size) }
            }
            try shot(VaultShareSheet(shop: shop, request: request, withPassword: true), "share-form",
                     CGSize(width: width, height: 640))
            try shot(VaultShareSheet(shop: shop, request: request, shown: link, withPassword: true), "share-made",
                     CGSize(width: width, height: 420))
            try shot(VaultLinksSheet(shop: shop, preloaded: try Self.grants(), names: names), "links",
                     CGSize(width: wide, height: 360))
        }
    }
}
