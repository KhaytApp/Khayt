import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// "for cloud sign in saving credentials should be an option, a remember this
/// login check box… also i dont see a logout" — Turki, Sep 24 2026.
@MainActor
struct CloudSignOutTests {

    static func source(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/\(name)"), encoding: .utf8)
    }

    @Test("signing out turns the cloud off in the book and keeps how to sign back in")
    func signedOutBook() {
        var root: [String: JSONValue] = ["settings": .object(["cloud": .object([
            "enabled": .bool(true), "url": .string("https://cloud.khaytapp.com"),
            "email": .string("shop@example.com"), "shopId": .string("s1"),
            "verified": .bool(true),
        ])])]
        Shop.markSignedOut(&root)
        guard case .object(let settings)? = root["settings"],
              case .object(let cloud)? = settings["cloud"] else {
            Issue.record("settings.cloud is gone"); return
        }
        #expect(cloud["enabled"] == .bool(false))
        #expect(cloud["email"] == .string("shop@example.com"), "signing back in should be two fields")
        #expect(!Shop.cloudConnected(settings), "a signed-out book still reads as connected, so sync would go on")
    }

    @Test("a book never connected is left alone by signing out")
    func nothingToSignOutOf() {
        var root: [String: JSONValue] = ["settings": .object([:])]
        Shop.markSignedOut(&root)
        #expect(root["settings"] == .object([:]))
    }

    @Test("the sign-in sheet asks whether to remember, and both unlocks obey it")
    func rememberIsAChoice() throws {
        let sheet = try Self.source("CloudSignInSheet.swift")
        #expect(sheet.contains("@AppStorage(Shop.rememberCloudKeyDefault)"))
        #expect(sheet.contains("mac.cloud_remember"))
        let shop = try Self.source("Shop.swift")
        #expect(shop.components(separatedBy: "await keepCloudKey(").count - 1 == 2,
                "an unlock keeps the key without asking the shop's choice")
        #expect(!shop.contains("await CloudKeyMemory.remember(dek, fingerprint: CloudKeyMemory.fingerprint(of: .object(keyset)) ?? \"\",\n                                          shopId: session"),
                "sign-in keeps the key directly again")
        #expect(shop.contains("guard Self.rememberCloudKey,"), "a launch restores a key the shop chose not to keep")
    }

    @Test("Sign out is offered in the Book menu and on the sidebar's cloud line")
    func signOutIsFindable() throws {
        #expect(try Self.source("Menus.swift").contains("shop.confirmingSignOut = true"))
        #expect(try Self.source("Shell.swift").contains("shop.confirmingSignOut = true"))
        #expect(try Self.source("ShopWindow.swift").contains("await shop.signOutOfCloud()"))
    }
}
