import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Selling vault files on the Mac: the words, the release promise and the
/// wiring. The client itself is `VaultProductsTests` (KhaytCore).
@MainActor
struct VaultProductsUITests {

    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/KhaytApp")
    static func read(_ name: String) throws -> String {
        try String(contentsOf: sources.appending(path: name), encoding: .utf8)
    }

    @Test("the release sheet says what the privacy policy says, word for word (website #74)")
    func releasePromise() {
        #expect(Words.own["mac.vp_release_promise"]?["en"] ==
            "A version you have released stays readable by Khayt Cloud while it is stored and is either still on sale or reachable through a buyer’s link. Deleting the file ends both. Stopping a sale protects only later versions, and buyers who have already paid keep their access unless you revoke it.")
        #expect(Words.own["mac.vp_release_promise"]?["ar"]?.hasPrefix("النسخة التي طرحتها تبقى مقروءة لسحابة خيط") == true)
    }

    @Test("every reason the cloud gives for selling has words, in both languages")
    func everyReasonIsSaid() {
        let reasons = ["no-publishing", "products-full", "removed", "provider-product-taken", "checkout-host",
                       "bad-checkout-url", "unknown-items", "not-in-product", "bad-release", "release-drops-file",
                       "publish-off", "not-released", "mail-off", "links-disabled", "role", "unknown-product",
                       "unknown-buyer", "previews-full", "unknown-previews", "bad-secret"]
        for r in reasons {
            let key = "mac.vp_err_" + r.replacingOccurrences(of: "-", with: "_")
            for lang in ["en", "ar"] {
                #expect(Words.own[key]?[lang]?.isEmpty == false, Comment(rawValue: "\(r) has no \(lang) words"))
            }
        }
        let shop = Shop()
        for p in VaultProducts.providers + ["manual"] {
            #expect(!shop.providerName(p).hasPrefix("mac."), Comment(rawValue: p))
            #expect(shop.providerName(p) != p, Comment(rawValue: "\(p) is shown as its id"))
        }
        for s in ["paid", "refunded", "revoked"] { #expect(Words.own["mac.vp_status_" + s] != nil) }
    }

    @Test("a refusal is said by its reason, and one the app has no words for still says something")
    func problemsAreSaid() async {
        let shop = Shop()
        await shop.load(.sample)
        let drop = VaultProducts.Refusal(status: 409, reason: "release-drops-file", error: "", fileIds: ["a", "b"], limit: nil)
        #expect(shop.productProblem(drop).contains("2"))
        let odd = VaultProducts.Refusal(status: 422, reason: "", error: "title: required", fileIds: [], limit: nil)
        #expect(shop.productProblem(odd).contains("title: required"))
        let unknown = VaultProducts.Refusal(status: 409, reason: "something-new", error: "", fileIds: [], limit: nil)
        #expect(!shop.productProblem(unknown).hasPrefix("mac."))
        #expect(shop.productProblem(VaultClient.Failure.vaultOff) == shop.words.callIt("mac.vl_err_vault_off"))
    }

    @Test("a release takes each file at its head, and leaves out what the vault no longer has")
    func releaseSources() throws {
        let json = #"""
        {"v":1,"shopId":"s","deviceId":"d","rev":3,"files":{
          "f1":{"seq":2,"head":2,"metaRev":1,"trashed":false,"row":{"fileId":"f1","purged":false,"head":2,"metaRev":1,
                "versions":[{"version":2,"uploadId":"u2","bytes":26,"chunks":1,"chunkBytes":4194304,
                             "manifestHash":"00","wrappedKey":"","versionMeta":"","createdAt":"x"}]}},
          "f2":{"seq":1,"head":1,"metaRev":0,"trashed":true}
        },"keys":{},"records":{}}
        """#
        let state = try JSONDecoder().decode(VaultSyncState.self, from: Data(json.utf8))
        let (out, missing) = Shop.releaseSources(["f1", "f2", "f3"], state: state)
        #expect(out.map(\.row.fileId) == ["f1"])
        #expect(out.first?.row.headVersion?.uploadId == "u2")
        #expect(missing == ["f2", "f3"])
    }

    @Test("Products is on the library strip and Sell as a Product on a model, only while the library is in the vault")
    func wiredIn() throws {
        #expect(try Self.read("ShopWindow.swift").contains("VaultProductsSheet(shop: shop)"))
        let strip = try Self.read("ScreenActions.swift")
        #expect(strip.contains("shop.showingVaultProducts = true"))
        let menu = try Self.read("FileActions.swift")
        #expect(menu.contains("shop.sellAsProduct(file)"))
        // Inside the vault-only block, beside Share by Private Link.
        let block = menu.components(separatedBy: "if shop.libraryOnVault {").dropFirst().first ?? ""
        #expect(block.contains("sellAsProduct"))
        let glue = try Self.read("Shop+VaultProducts.swift")
        #expect(glue.contains("guard libraryOnVault"))
    }

    @Test("the sample book, with no vault, offers no products")
    func sampleHasNone() async {
        let shop = Shop()
        await shop.load(.sample)
        #expect(!shop.libraryOnVault)
        #expect(await shop.vaultProductsEngine() == nil)
    }
}
