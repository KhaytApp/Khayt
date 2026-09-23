import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The cloud key kept on this Mac between launches.
///
/// The Keychain itself is not touched here: a test run must not write into the
/// login Keychain of whoever runs it. What is pinned is the part that decides
/// whether a kept key is USED (the fingerprint) and that it is wired in:
/// kept at both unlocks, dropped on Lock, restored when a book loads.
@MainActor
struct CloudKeyMemoryTests {

    static func keyset(_ ct: String, iv: String = "iv1") -> JSONValue {
        .object(["version": .number(1),
                 "kdf": .object(["n": .number(32768)]),
                 "wrappedByPassphrase": .object(["ct": .string(ct), "iv": .string(iv), "salt": .string("s")]),
                 "wrappedByRecovery": .object(["ct": .string("r")])])
    }

    @Test("a keyset is recognised again, and a changed one is not")
    func fingerprint() throws {
        let a = try #require(CloudKeyMemory.fingerprint(of: Self.keyset("abc")))
        #expect(CloudKeyMemory.fingerprint(of: Self.keyset("abc")) == a)
        // A new passphrase re-wraps the key: the kept one must not be trusted.
        #expect(CloudKeyMemory.fingerprint(of: Self.keyset("abd")) != a)
        #expect(CloudKeyMemory.fingerprint(of: Self.keyset("abc", iv: "iv2")) != a)
        // Nothing to recognise: no restore, never a crash.
        #expect(CloudKeyMemory.fingerprint(of: nil) == nil)
        #expect(CloudKeyMemory.fingerprint(of: .object([:])) == nil)
    }

    @Test("the key is kept at both unlocks, dropped on Lock, and restored when a book loads")
    func wired() throws {
        let shop = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Shop.swift"), encoding: .utf8)
        let kept = shop.components(separatedBy: "CloudKeyMemory.remember(").count - 1
        #expect(kept == 2, "sign-in and unlock must both keep the key (found \(kept))")
        #expect(shop.contains("await CloudKeyMemory.forget(shopId: shopId)"), "Lock no longer forgets it")
        #expect(shop.contains("if next.build != nil { await restoreCloudKey() }"),
                "a loaded book no longer restores the kept key, so every launch asks again")
        #expect(shop.contains("!cloudLockedByShop"), "a Lock this session could be undone by a reload")
    }
}
