import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Settings ▸ Assistant's "Share customer names with AI assistants" switch,
/// which `khayt-mcp` reads as `settings.mcp.shareCustomerNames`.
struct McpShareNamesSettingTests {

    @Test("the choice is written into settings.mcp, and nothing else in the settings moves")
    func writesTheKey() {
        let stored: [String: JSONValue] = [
            "lang": .string("ar"),
            "mcp": .object(["somethingLater": .string("kept")]),
        ]
        let on = Shop.sharingCustomerNames(true, over: stored)
        #expect(on["lang"] == .string("ar"))
        #expect(on["mcp"] == .object(["somethingLater": .string("kept"),
                                      "shareCustomerNames": .bool(true)]))
        let off = Shop.sharingCustomerNames(false, over: on)
        #expect(off["mcp"] == .object(["somethingLater": .string("kept"),
                                       "shareCustomerNames": .bool(false)]))
        // A book with no `mcp` block at all gets one.
        #expect(Shop.sharingCustomerNames(true, over: [:])["mcp"]
                == .object(["shareCustomerNames": .bool(true)]))
    }

    @Test("the switch and its hint say it in both languages")
    func wordsInBothLanguages() {
        for key in ["mac.mcp_share_names", "mac.mcp_share_names_hint"] {
            let words = Words.own[key]
            #expect(words?["en"]?.isEmpty == false, "\(key) en")
            #expect(words?["ar"]?.isEmpty == false, "\(key) ar")
            // Arabic keeps Western digits: the labels an assistant sees are
            // "Customer 1", whatever language the shop reads.
            #expect(words?["ar"]?.contains(where: { ("٠"..."٩").contains($0) }) == false)
        }
    }
}
