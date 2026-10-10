import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Opening a credential at the moment it is used.
///
/// THE DEFECT THIS EXISTS FOR: the store keeps `settings.telegram.botToken` as
/// `__enc__` + OSCrypt, this app read the store raw, and `tell` handed that
/// string to `Telegram.send` as a bot token. `isBotToken` refused it, so every
/// shop with Telegram configured was told its message did not go out — every
/// time, since the day it shipped. `SafeStorage.open` existed and was tested;
/// nothing called it.
///
/// This shop's own book has an empty `botToken`, which is why the path never
/// failed here and the bug survived a release.
///
/// **NOTHING HERE MAY TOUCH THE LOGIN KEYCHAIN.** The first version of this
/// file did, and macOS put a SecurityAgent dialog on screen and the test
/// process waited on it for ever — no output, no timeout, killed by hand.
/// `Secrets.keySource` is the seam that keeps the suite off it.
/// SERIALIZED: `Secrets` keeps the session's key in static storage, and Swift
/// Testing runs a suite's tests in parallel — so the "locked Keychain" case
/// substituted a nil key source out from under the round-trip case, which then
/// failed for a reason that had nothing to do with it.
@MainActor
@Suite(.serialized)
struct SecretsTests {

    /// A key of our own, so a sealed value can be opened without the Keychain.
    /// `nonisolated`, because `keySource` is `@Sendable` now — the lookup runs
    /// off the main actor so a Keychain dialog cannot freeze the window.
    nonisolated static let key = SafeStorage.key(fromPassword: "a test password, not a shop's")

    init() {
        Secrets.forget()
        Secrets.keySource = { _ in Self.key }
    }

    @Test("a token stored in the clear is a token, not a Keychain question")
    func plaintextPassesThrough() async throws {
        // Older stores, and any machine where safeStorage was unavailable when
        // the value was written. `decryptStoreField` in lib/store-io.js does
        // the same: no marker, no decryption.
        let plain = "123456789:AAH-abcdefghijklmnopqrstuvwxyz012345678"
        #expect(try await Secrets.open(plain, for: .development) == plain)
    }

    @Test("an empty field is not a locked one")
    func emptyIsNotAFault() async throws {
        // "The shop has not set Telegram up" must not be reported as a Keychain
        // refusal — and a Keychain prompt for a field nobody filled in would be
        // inexcusable.
        Secrets.keySource = { _ in Issue.record("the Keychain was asked for an empty field"); return nil }
        #expect(try await Secrets.open("", for: .development) == "")
    }

    @Test("a sealed token comes back as the token Telegram accepts")
    func sealedRoundTrip() async throws {
        // Both halves of the bug, on the real functions.
        let real = "123456789:AAH-abcdefghijklmnopqrstuvwxyz012345678"
        let sealed = try SafeStorage.seal(real, key: Self.key)
        #expect(sealed.hasPrefix(SafeStorage.marker))
        #expect(!KhaytTelegram.isBotToken(sealed), "an encrypted token was never going to be accepted")

        let opened = try await Secrets.open(sealed, for: .development)
        #expect(opened == real)
        #expect(KhaytTelegram.isBotToken(opened))
    }

    @Test("a locked Keychain is said out loud, never returned as the value")
    func lockedIsRefused() async throws {
        // The one outcome that must never occur is the `__enc__` string coming
        // back as though it were the credential.
        Secrets.forget()
        Secrets.keySource = { _ in nil }
        let sealed = try SafeStorage.seal("secret", key: Self.key)
        await #expect(throws: Secrets.Failure.self) {
            try await Secrets.open(sealed, for: .development)
        }
    }

    @Test("the wrong key is a refusal, not a garbled credential")
    func wrongKeyIsRefused() async throws {
        let sealed = try SafeStorage.seal("secret", key: Self.key)
        Secrets.forget()
        Secrets.keySource = { _ in SafeStorage.key(fromPassword: "another machine's password") }
        await #expect(throws: Secrets.Failure.self) {
            try await Secrets.open(sealed, for: .development)
        }
    }

    @Test("the Keychain is asked once, not once per message")
    func theKeyIsCached() async throws {
        // Electron owns the Keychain item and macOS puts a prompt in front of
        // it. A shop finishing six jobs should not answer six prompts.
        Secrets.forget()
        // A counter the lookup can reach: `keySource` is `@Sendable` and runs
        // off the main actor now, so it cannot close over a local `var`.
        let asked = Counter()
        Secrets.keySource = { _ in asked.bump(); return Self.key }
        let sealed = try SafeStorage.seal("secret", key: Self.key)
        for _ in 0..<5 { _ = try await Secrets.open(sealed, for: .development) }
        #expect(asked.count == 1)
    }

    /// THE PROPERTY, NOT THE INTENTION.
    ///
    /// `SecItemCopyMatching` blocks until it returns, and macOS puts a
    /// SecurityAgent dialog in front of the first read by an application it has
    /// not seen before. On the main actor that freezes the whole window — no
    /// spinner, no message, nothing drawn, 0% CPU — until somebody finds the
    /// dialog. This app is ad-hoc signed, so every update is a new application
    /// as far as the Keychain is concerned and the dialog is once per update
    /// rather than once ever.
    @Test("the Keychain is not asked on the main thread")
    func theLookupIsOffTheMainActor() async throws {
        Secrets.forget()
        let wasMain = Flag()
        Secrets.keySource = { _ in wasMain.set(Thread.isMainThread); return Self.key }
        let sealed = try SafeStorage.seal("secret", key: Self.key)
        _ = try await Secrets.open(sealed, for: .development)
        #expect(wasMain.value == false,
                "the Keychain was read on the main thread — a dialog would freeze the window")
    }

    @Test("the sample shop is never asked for a credential")
    func sampleHasNoBook() async throws {
        // It has no build, so there is no Keychain item and nothing to open.
        Secrets.keySource = { _ in Issue.record("the sample shop reached for a Keychain"); return nil }
        #expect(try await Secrets.open("__enc__whatever", for: Shop.Source.sample) == "__enc__whatever")
    }

    @Test("the send path opens the token before it sends it")
    func theSendPathIsWired() async throws {
        // A source guard, and named as one — `tell` is private, takes no
        // injectable session and awaits a real request. What it is worth is
        // catching the exact regression: somebody passing `message.botToken`
        // straight to `send` again, which is what the code did until now.
        let shop = try ShopSources.read(URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Shop.swift"))
        guard let at = shop.range(of: "private func tell(_ message: TelegramMessage)") else {
            Issue.record("tell has been renamed"); return
        }
        let body = String(shop[at.lowerBound...].prefix(1400))
        #expect(body.contains("Secrets.open(message.botToken"),
                "the bot token must be opened before it is sent")
        #expect(!body.contains("botToken: message.botToken"),
                "the encrypted string is being sent as the token again")
    }
}

/// A count that survives crossing an isolation boundary.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// A one-shot answer from across an isolation boundary.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    func set(_ value: Bool) { lock.lock(); stored = value; lock.unlock() }
    var value: Bool? { lock.lock(); defer { lock.unlock() }; return stored }
}
