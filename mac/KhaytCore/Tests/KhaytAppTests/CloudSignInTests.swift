import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Signing this Mac in to the shop's cloud.
///
/// The failure this closes is specific and was hit for real: a book restored
/// onto a new Mac carries `settings.cloud.token` sealed against the OLD Mac's
/// Keychain, so every cloud feature goes quiet and there was no way to obtain a
/// new token here. What is tested is the part this app owns — that the address
/// is checked before credentials travel to it, that a wrong passphrase writes
/// NOTHING, and that the object written is the shape the other app reads.
@MainActor
struct CloudSignInTests {

    /// The `POST /v1/login` body, as `lib/cloud-client.js` sends it.
    @Test("the address is validated before an email and password are sent")
    func addressFirst() async throws {
        let engine = try KhaytEngine()
        // A metadata address, a private one, and a string that is not a URL.
        for bad in ["http://169.254.169.254", "http://10.0.0.1", "not a url"] {
            await #expect(throws: (any Error).self) {
                _ = try await CloudSignIn.logIn(url: bad, email: "a@b.c",
                                                password: "pw", engine: engine)
            }
        }
    }

    /// `Secrets.seal` produces what `Secrets.open` reads, and what the other
    /// app's `__enc__` prefix means — a token written any other way would sit
    /// in plaintext in a file that syncs, backs up and exports.
    @Test("a token is sealed before it reaches the book")
    func tokenIsSealed() async throws {
        let build = StoreReader.Build.development
        // Skipped rather than failed where the Keychain is not available: a CI
        // runner has no login keychain, and a test that cannot seal is not
        // evidence that sealing is broken.
        guard (try? await Secrets.seal("probe", for: build)) != nil else { return }
        let sealed = try await Secrets.seal("tok_abc123", for: build)
        #expect(sealed.hasPrefix("__enc__"), "an unsealed token must never be written")
        let opened = try await Secrets.open(sealed, for: build)
        #expect(opened == "tok_abc123")
    }

    /// The one ordering that matters. A token saved beside a key that cannot be
    /// opened leaves a shop CONNECTED and unable to read a word of its own
    /// cloud, which reads as the server having lost it.
    @Test("the passphrase is proved before anything is written")
    func passphraseBeforeWrite() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Sources/KhaytApp/Shop.swift"),
            encoding: .utf8)
        guard let fn = source.range(of: "func signInToCloud(") else {
            Issue.record("signInToCloud is gone"); return
        }
        let body = source[fn.lowerBound...].prefix(4000)
        guard let unwrap = body.range(of: "SyncCrypto.unwrapDek("),
              let seal = body.range(of: "Secrets.seal("),
              let write = body.range(of: "StoreWriter.update(") else {
            Issue.record("sign-in no longer unwraps, seals and writes"); return
        }
        #expect(unwrap.lowerBound < write.lowerBound,
                "a wrong passphrase must change nothing")
        #expect(seal.lowerBound < write.lowerBound,
                "the token must be sealed before the book is touched")
    }

    /// The other app has to read this Mac's sign-in as its own, so the object
    /// written is `renderer/settings.js`'s, key for key.
    @Test("settings.cloud is written in the shape the other app writes")
    func theShapeMatches() throws {
        let mac = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Sources/KhaytApp/Shop.swift"),
            encoding: .utf8)
        guard let fn = mac.range(of: "func signInToCloud(") else {
            Issue.record("signInToCloud is gone"); return
        }
        let body = String(mac[fn.lowerBound...].prefix(4000))
        for key in ["enabled", "url", "email", "shopId", "token", "keyset",
                    "lastServerRev", "verified", "role"] {
            #expect(body.contains("\"\(key)\""),
                    "settings.cloud is missing \(key) — the other app expects it")
        }
        // `lastServerRev: 0` is not a placeholder. This machine has seen nothing
        // from the server yet, and a carried-over rev would let its first push
        // claim a base it never read.
        #expect(body.contains("\"lastServerRev\": .number(0)"),
                "a fresh sign-in must not claim to have seen a server revision")
    }

    /// The menu item is the whole point: a shop whose token cannot be opened is
    /// still `cloudConnected`, so gating this on that would hide it exactly
    /// when it is needed.
    @Test("signing in is offered even when the shop is already connected")
    func notGatedOnConnected() throws {
        let menus = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Sources/KhaytApp/Menus.swift"),
            encoding: .utf8)
        guard let item = menus.range(of: "mac.cloud_sign_in") else {
            Issue.record("the sign-in menu item is gone"); return
        }
        // Whatever follows on that line and the next must not disable it on
        // `cloudConnected` — the check item below it does, and that is correct
        // for a check and wrong for this.
        let after = String(menus[item.upperBound...].prefix(160))
        #expect(!after.contains("disabled(!shop.cloudConnected)"),
                "a shop with an unreadable token is still connected — do not hide sign-in from it")
    }
}
