import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The share-link screens: shown only on a vault library, and every word in
/// both languages.
@MainActor
struct VaultLinksUITests {

    static func source(_ file: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/\(file)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    static let files = ["VaultShareSheet.swift", "VaultLinksSheet.swift", "Shop+VaultLinks.swift",
                        "FileActions.swift", "ScreenActions.swift"]
    /// Keys built at run time from a known list (`VaultGrantRow.eventLine`).
    static let built = ["open", "ticket", "refused", "other"].map { "mac.vl_event_" + $0 }
        + ["phone", "tablet", "computer", "other"].map { "mac.vl_device_" + $0 }

    @Test("Vault links UI: offered only when the library's remote is the vault")
    func onlyOnTheVault() {
        let shop = Shop()
        for id in [nil, "s3:r2.example/bucket/", "gdrive:abc/Khayt print library"] as [String?] {
            shop.libraryRemoteId = id
            #expect(!shop.libraryOnVault)
        }
        shop.libraryRemoteId = CloudLibrary.vaultIdentityPrefix + "shop_1"
        #expect(shop.libraryOnVault)
    }

    /// Each way in sits INSIDE an `if shop.libraryOnVault {` block: the
    /// nearest such `if` before the key, with its braces still open there.
    @Test("Vault links UI: Share and Links are inside the vault gate, and the sheets go away at Lock")
    func gated() throws {
        for (file, key) in [("FileActions.swift", "\"mac.vl_share\""), ("ScreenActions.swift", "\"mac.vl_links\"")] {
            let s = try Self.source(file)
            let at = try #require(s.range(of: key), "\(key) is not in \(file)")
            let gate = try #require(s.range(of: "if shop.libraryOnVault {", options: .backwards,
                                            range: s.startIndex..<at.lowerBound), "\(key) has no vault gate")
            let between = s[gate.upperBound..<at.lowerBound]
            let open = between.filter { $0 == "{" }.count, close = between.filter { $0 == "}" }.count
            #expect(close <= open, "\(key) in \(file) is after its vault gate closed")
        }
        let lock = try Self.source("OperatorLock.swift")
        #expect(lock.contains("sharingByLink = nil; showingVaultLinks = false"))
    }

    @Test("Vault links UI: every word is in English and Arabic, with the same placeholders")
    func everyWordInBothLanguages() throws {
        var keys = Set(Self.built)
        for f in Self.files {
            let s = try Self.source(f)
            for m in s.matches(of: /"(mac\.vl_[a-z0-9_]+)"/) where !m.output.1.hasSuffix("_") { keys.insert(String(m.output.1)) }
        }
        #expect(keys.count > 40)
        func holes(_ s: String) -> Set<String> { Set(s.matches(of: /\{([a-z]+)\}/).map { String($0.output.1) }) }
        for k in keys.sorted() {
            let entry = try #require(Words.own[k], "\(k) is missing")
            let en = try #require(entry["en"], "\(k) has no English"), ar = try #require(entry["ar"], "\(k) has no Arabic")
            #expect(ar.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) }, "\(k) is not Arabic")
            #expect(holes(en) == holes(ar), "\(k) placeholders differ")
        }
    }

    @Test("Vault links UI: the WhatsApp message carries the link, never the password")
    func message() throws {
        let shop = Shop()
        let link = try VaultLink(origin: "https://cloud.khaytapp.com", grantId: VaultCrypto.newGrantId(),
                                 secret: VaultCrypto.newLinkSecret())
        let text = shop.linkMessage(link)
        #expect(text.contains(link.url))
        #expect(!text.lowercased().contains("password"))
    }
}
