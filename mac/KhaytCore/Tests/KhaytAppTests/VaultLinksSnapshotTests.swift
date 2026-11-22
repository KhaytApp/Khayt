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

    /// Phase 2b: a link locked to four addresses, and one Khayt turned off.
    static func lockedAndDisabled() throws -> [VaultClient.Grant] {
        let json = """
        [{"grantId":"CCCCCCCCCCCCCCCCCCCCCC","state":"ok","createdAt":"2026-10-21T09:00:00Z","expiresAt":"2026-11-01T12:00:00Z",
          "limits":{"maxDownloads":5},"password":false,"used":1,"devices":1,
          "emailLock":["sara@example.com","omar@shop.sa","layla@studio.sa","fahad@example.com"],
          "items":[{"fileId":"f1","version":1,"used":1,"remaining":4}]},
         {"grantId":"DDDDDDDDDDDDDDDDDDDDDD","state":"disabled","createdAt":"2026-10-18T09:00:00Z",
          "disabledAt":"2026-10-22T08:15:00Z","disabledReason":"Reported for copyright",
          "limits":{},"password":true,"used":4,"devices":3,"emailLock":null,
          "items":[{"fileId":"f2","version":2,"used":4,"remaining":null}]}]
        """
        return try JSONDecoder().decode([VaultClient.Grant].self, from: Data(json.utf8))
    }

    static func events() throws -> [String: [VaultClient.GrantEvent]] {
        let json = """
        [{"at":"2026-10-22T10:05:00Z","kind":"ticket","fileId":"f1","country":"SA","deviceClass":"phone",
          "recipient":"sara@example.com"},
         {"at":"2026-10-22T10:01:00Z","kind":"open","country":"AE","deviceClass":"computer","recipient":"omar@shop.sa"}]
        """
        return ["CCCCCCCCCCCCCCCCCCCCCC": try JSONDecoder().decode([VaultClient.GrantEvent].self, from: Data(json.utf8))]
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
            // Phase 2b.
            try shot(VaultShareSheet(shop: shop, request: request,
                                     emails: "Sara@Example.com, omar@shop.sa, omar@shop.sa"), "share-lock",
                     CGSize(width: width, height: 640))
            try shot(VaultShareSheet(shop: shop, request: request, emails: "sara@example.com, omar@"),
                     "share-lock-bad", CGSize(width: width, height: 640))
            try shot(VaultShareSheet(shop: shop, request: request, shown: link, emails: "sara@example.com"),
                     "share-made-locked", CGSize(width: width, height: 420))
            try shot(VaultShareSheet(shop: shop, request: request, linksOff: true), "share-links-off",
                     CGSize(width: width, height: 260))
            try shot(VaultLinksSheet(shop: shop, preloaded: try Self.lockedAndDisabled(), names: names,
                                     events: try Self.events()), "links-2b",
                     CGSize(width: wide, height: 420))
        }
    }
}
