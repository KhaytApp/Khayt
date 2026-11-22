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

    @Test("Vault links UI: a failed cleanup is never reported as nothing shared, and the cloud's refusals read")
    func problems() {
        let shop = Shop()
        let live = shop.linkProblem(VaultLinks.Failure.incomplete(grantId: "g", sent: 500, total: 501, revoked: false, why: ""))
        let dead = shop.linkProblem(VaultLinks.Failure.incomplete(grantId: "g", sent: 500, total: 501, revoked: true, why: ""))
        #expect(live == shop.words.callIt("mac.vl_err_incomplete_live") && dead == shop.words.callIt("mac.vl_err_incomplete"))
        #expect(shop.linkProblem(VaultClient.Failure.fileTooLarge(limit: 0)) == shop.words.callIt("mac.vl_err_too_big"))
        #expect(shop.linkProblem(VaultClient.Failure.notFound("unknown-grant")) == shop.words.callIt("mac.vl_err_unknown_grant"))
        #expect(shop.linkProblem(VaultClient.Failure.notYet) == shop.words.callIt("mac.vl_err_not_yet"))
    }

    @Test("Vault links UI: the email lock's and Khayt's refusals each read as their own message, in both languages")
    func phase2bProblems() {
        let shop = Shop()
        let w = shop.words
        #expect(shop.linkProblem(VaultClient.Failure.mailOff) == w.callIt("mac.vl_err_mail_off"))
        #expect(shop.linkProblem(VaultClient.Failure.badEmailLock) == w.callIt("mac.vl_err_bad_lock"))
        #expect(shop.linkProblem(VaultClient.Failure.disabled) == w.callIt("mac.vl_err_disabled"))
        #expect(shop.linkProblem(VaultClient.Failure.linksDisabled) == w.callIt("mac.vl_err_links_off"))
        #expect(shop.linkProblem(VaultLinks.Failure.noEmails) == w.callIt("mac.vl_lock_err_none"))
        let tooMany = shop.linkProblem(VaultLinks.Failure.tooManyEmails(60))
        #expect(tooMany.contains("50") && !tooMany.contains("60"))
        // The address typed is named, isolated so it keeps its shape in Arabic.
        #expect(shop.linkProblem(VaultLinks.Failure.notAnEmail("omar@")).contains(Shop.address("omar@")))
        // None of them falls through to the generic line.
        let all: [any Error] = [VaultClient.Failure.mailOff, VaultClient.Failure.badEmailLock,
                                VaultClient.Failure.disabled, VaultClient.Failure.linksDisabled,
                                VaultLinks.Failure.noEmails, VaultLinks.Failure.tooManyEmails(51),
                                VaultLinks.Failure.notAnEmail("x")]
        for e in all {
            #expect(shop.linkProblem(e) != w.callIt("mac.vl_err_generic"))
        }
    }

    /// Copy Link only on a live link (`state == .ok`, so never a disabled
    /// one), and a disabled link's menu holds Revoke alone.
    @Test("Vault links UI: a link Khayt turned off shows no Copy Link, and Revoke is its only action")
    func disabledOnlyRevokes() throws {
        let s = try Self.source("VaultLinksSheet.swift")
        #expect(s.contains("private var live: Bool { grant.state == .ok }"))
        #expect(s.contains("if live && local == .copyable {"))
        // Everything but Revoke sits inside the live-and-whole block.
        let menu = try #require(s.range(of: "if live || disabled {"))
        let whole = try #require(s.range(of: "if live && !incomplete {", range: menu.upperBound..<s.endIndex))
        let revoke = try #require(s.range(of: "\"mac.vl_revoke\") + \"\\u{2026}\"", range: whole.upperBound..<s.endIndex))
        for key in ["mac.vl_add_downloads", "mac.vl_extend_days", "mac.vl_remove_end", "mac.vl_lock_set",
                    "mac.vl_lock_change", "mac.vl_lock_remove"] {
            let at = try #require(s.range(of: "\"\(key)\"", range: whole.upperBound..<revoke.lowerBound), "\(key)")
            #expect(at.lowerBound > whole.upperBound)
        }
        // And the core forgets nothing of a disabled link: Khayt can turn it back on.
        let grant = try JSONDecoder().decode(VaultClient.Grant.self, from: Data(
            #"{"grantId":"AAAAAAAAAAAAAAAAAAAAAA","state":"disabled","disabledReason":"x"}"#.utf8))
        #expect(grant.isDisabled && grant.state != .ok)
    }

    @Test("Vault links UI: the share sheet says who can read the addresses, and that each person gets a code")
    func lockExplained() {
        for lang in ["en", "ar"] {
            let en = Words.own["mac.vl_lock_explain"]?[lang] ?? ""
            #expect(!en.isEmpty)
        }
        let en = Words.own["mac.vl_lock_explain"]?["en"] ?? ""
        #expect(en.contains("code") && en.contains("Khayt Cloud") && en.contains("everyone in your shop"))
    }

    @Test("Vault links UI: a copied link is marked concealed and transient, for clipboard managers")
    func pasteboardMarkers() throws {
        #expect(Set(Shop.secretPasteboardMarkers.map(\.rawValue))
                == ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"])
        // Both copies go through copyLink: the button and the WhatsApp fallback.
        let s = try Self.source("Shop+VaultLinks.swift")
        #expect(!s.contains("FileActions.copy(link"))
        #expect(s.components(separatedBy: "copyLink(link)").count - 1 >= 1)
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
