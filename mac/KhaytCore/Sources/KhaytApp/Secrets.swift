import Foundation
import KhaytCore

/// Opening a credential, at the moment it is used and nowhere else.
///
/// The store's secret fields are `__enc__` + Chromium OSCrypt, and this app has
/// never opened one. That was right while nothing needed the plaintext, and it
/// became a bug the moment something did: `Telegram.send` was handed
/// `__enc__AAAA…` as a bot token, `isBotToken` refused it, and every shop with
/// Telegram configured was told its message did not go out — every time, since
/// the day it shipped. `SafeStorage.open` existed, was tested, and nothing in
/// the app called it.
///
/// **The rule that survives is narrower than "never decrypts", and it is the
/// one that mattered.** `StoreWriter` never decrypts: an edit to some other
/// field carries the `__enc__` string through untouched, so a bad round trip
/// can never overwrite a working credential with bytes Electron cannot read.
/// That is unchanged. What is allowed now is reading one, in order to USE it —
/// which is what a credential is for, and what the Electron app does on every
/// load.
///
/// So: opened at the point of use, never held on a model, never written back.
@MainActor
enum Secrets {

    /// The Keychain is asked once per book per session.
    ///
    /// Not per message: the item is Electron's, macOS puts a prompt in front of
    /// it the first time, and a shop finishing six jobs should not answer six
    /// of them.
    private static var keys: [StoreReader.Build: Data?] = [:]

    /// Where a book's key comes from.
    ///
    /// A seam, and not a decorative one: **a test that reads the login Keychain
    /// hangs.** macOS puts a SecurityAgent dialog on screen and the process
    /// waits on it for ever — which is exactly what the first version of
    /// `SecretsTests` did, with no output and no timeout until it was killed by
    /// hand. Nothing under test may reach the real Keychain.
    /// `@Sendable`, because the lookup runs OFF THE MAIN ACTOR. See `key(for:)`.
    static var keySource: @Sendable (StoreReader.Build) -> Data? = { build in
        StoreReader.keychainPassword(for: build).map(SafeStorage.key(fromPassword:))
    }

    /// Why a credential could not be opened, in a sentence a shop can act on.
    enum Failure: Error, CustomStringConvertible {
        case noKeychain
        case unreadable(String)

        var description: String {
            switch self {
            case .noKeychain:
                return "The saved credential is locked. Khayt keeps it in your login Keychain, "
                     + "and this app was not given access to it."
            case .unreadable(let why):
                return "The saved credential could not be read: \(why)"
            }
        }
    }

    /// A stored field as it is meant to be used.
    ///
    /// A value with no `__enc__` marker is returned untouched — that is not an
    /// error, it is a store written before encryption was available, and
    /// `decryptStoreField` in `lib/store-io.js` does exactly the same. Empty
    /// stays empty, so "the shop has not set this up" is not reported as a
    /// Keychain fault.
    static func open(_ value: String, for build: StoreReader.Build) async throws -> String {
        guard !value.isEmpty else { return value }
        guard value.hasPrefix(SafeStorage.marker) else { return value }
        guard let key = await key(for: build) else { throw Failure.noKeychain }
        do { return try SafeStorage.open(value, key: key) }
        catch { throw Failure.unreadable(String(describing: error)) }
    }

    /// The same, for a book this app is only reading (the sample has none).
    static func open(_ value: String, for source: Shop.Source) async throws -> String {
        guard let build = source.build else { return value }
        return try await open(value, for: build)
    }

    /// OFF THE MAIN ACTOR, and that is the whole point of this being async.
    ///
    /// `SecItemCopyMatching` blocks until it returns, and macOS puts a
    /// SecurityAgent dialog in front of the first read by an application it has
    /// not seen before. On the main actor that freezes the entire window: no
    /// spinner, no message, nothing drawn, at 0% CPU, until somebody finds the
    /// dialog and answers it. Watched it happen twice, for twenty minutes each
    /// time, and the app looked hung rather than waiting.
    ///
    /// This app is ad-hoc signed, so its identity is its own content hash and
    /// every update is a new application as far as the Keychain is concerned.
    /// The dialog is therefore not a one-off — it is once per update, for every
    /// shop.
    ///
    /// The cache above still means one ASK per book per session; this means the
    /// window stays alive while it is being answered.
    private static func key(for build: StoreReader.Build) async -> Data? {
        if let cached = keys[build] { return cached }
        let source = keySource
        let key = await Task.detached(priority: .userInitiated) { source(build) }.value
        keys[build] = key
        return key
    }

    /// Seal a credential the shop has just typed, for writing to the store.
    ///
    /// ── THE ONLY PLACE THIS APP ENCRYPTS ──────────────────────────────────
    ///
    /// The rule above — "opened at the point of use, never held on a model,
    /// never written back" — is about credentials this app READ. This is the
    /// other direction, and it exists so that a printer's API key typed into
    /// the machine sheet lands in the book the same way Electron would have
    /// written it: `__enc__` + OSCrypt, under the same Keychain key, readable
    /// by both apps.
    ///
    /// Writing the plaintext instead would work, and would quietly put a
    /// credential in a file that syncs, backs up and exports. So a key that
    /// cannot be sealed is REFUSED rather than downgraded: the sheet tells the
    /// shop the Keychain is not available and keeps what was already stored.
    static func seal(_ text: String, for build: StoreReader.Build) async throws -> String {
        guard !text.isEmpty else { return "" }
        // Already sealed — carried through a form that never opened it.
        guard !text.hasPrefix(SafeStorage.marker) else { return text }
        guard let key = await key(for: build) else { throw Failure.noKeychain }
        do { return try SafeStorage.seal(text, key: key) }
        catch { throw Failure.unreadable(String(describing: error)) }
    }

    /// Forget the session's key — for a test, and for a book being closed.
    static func forget() { keys = [:] }

    /// Which books the Keychain has already been asked about this session.
    static func cachedBuilds() -> [StoreReader.Build] { Array(keys.keys) }
}
