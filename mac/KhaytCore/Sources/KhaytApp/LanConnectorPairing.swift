import Foundation
import Observation
import CryptoKit

/// The window the owner opens for a slicer plugin to pair over the shop's
/// network (Settings ▸ Online ▸ Connected apps, "Pair a slicer").
///
/// ── WHY NOT THE PHONE'S WAY ───────────────────────────────────────────────
///
/// A phone pairs by showing the LAN PIN, because the phone is the owner's and
/// its key opens what the PIN opens. A connector (Khayt for OrcaSlicer) runs
/// inside somebody's slicer and must never learn the PIN: the PIN opens the
/// whole book. So the plugin shows nothing secret. It asks, the owner sees
/// who asked, and approves on the Mac.
///
/// ── WHAT STOPS A DEVICE IN THE MIDDLE ────────────────────────────────────
///
/// The plugin sends a fresh X25519 key; the Mac answers with one of its own,
/// signed by its `LanIdentity`, and that identity key itself (which the plugin
/// pins). Both work out a 6-digit check number from the three keys and the
/// device id (`check`). A device on the Wi-Fi that swapped
/// either key makes the two screens disagree, and the owner denies. Until the
/// owner approves, nothing is enrolled: the plugin's key opens nothing.
///
/// ── ONE REQUEST AT A TIME ─────────────────────────────────────────────────
///
/// While one request waits for the owner, another is told `pairing-busy`.
/// A stranger who asks first only shows up on the Mac under a name the owner
/// does not expect and a number the plugin does not show: Deny keeps the
/// window open for the real one.
///
/// After approval the device is enrolled with kind `connector`, so its key
/// opens `/api/connectors/*` and nothing else (`LanServer.connectorRefusal`).
@MainActor @Observable
final class LanConnectorPairing {

    /// As long as a phone's: time to switch to the slicer and click Pair.
    nonisolated static let length: TimeInterval = 120
    /// What a plugin may call itself, and its app and version.
    nonisolated static let maxField = 60

    enum Closed: Equatable {
        case paired(name: String)
        case timedOut
        case byOwner
        case serverStopped
        /// The LAN PIN could not be read, so nothing was enrolled: a connector
        /// enrolled under a PIN nothing uses could never connect, and making
        /// room for it under that PIN took every phone off (beta.38 review).
        case pinUnreadable
    }

    /// What a poll is told about a request.
    enum Outcome: String, Equatable { case waiting, approved, denied, expired }

    /// A plugin that asked and waits for the owner. The Mac's private key is
    /// held here, in memory only, until the owner answers.
    struct Request {
        let pairId: String
        let pollHash: Data
        let deviceId: String
        let serverKey: Curve25519.KeyAgreement.PrivateKey
        let serverPublic: String
        let pluginPublic: String
        let name: String
        let app: String
        let version: String
        let address: String
        let check: String
    }

    /// What the route answers a plugin that asked.
    struct Offer: Equatable {
        let pairId: String
        let pollSecret: String
        let deviceId: String
        let publicKey: String
        let sig: String
        /// The Mac's identity key, which the plugin pins. It cannot ask
        /// `/api/identity` (that takes the PIN), so it is sent here and the
        /// check number covers it.
        let identity: String
    }

    enum Refusal: Error, Equatable { case closed, busy, badKey }

    private(set) var deadline: TimeInterval?
    var isOpenNow: Bool { deadline != nil }
    private(set) var lastClosed: Closed?
    /// The request the owner is looking at; nil while none has come.
    private(set) var pending: Request?
    /// Answers given in this window, by pair id, for the plugin's poll.
    private(set) var outcomes: [String: Outcome] = [:]

    @ObservationIgnored let clock: () -> TimeInterval
    /// This window's own answer to `enabled`, for a test that builds one: so a
    /// suite running beside others never has to write the shared static.
    @ObservationIgnored let enabledHere: Bool?

    init(clock: @escaping () -> TimeInterval = LanPairingWindow.monotonic, enabled: Bool? = nil) {
        self.clock = clock
        self.enabledHere = enabled
    }

    /// Pairing a slicer is OFF in beta.38 (Dev Hub, Nov 16): the protocol gets
    /// a commit-then-reveal before any plugin is public, and until then no
    /// window opens, so the pair route answers `pairing-closed`. On for a
    /// developer with `defaults write <bundle id> connectorPairing -bool YES`.
    nonisolated static var enabled: Bool {
        UserDefaults.standard.bool(forKey: "connectorPairing") || enabledForTests
    }
    nonisolated(unsafe) static var enabledForTests = false

    func open() {
        guard enabledHere ?? Self.enabled else { return }
        deadline = clock() + Self.length
        pending = nil
        outcomes = [:]
    }

    /// Whether a plugin may ask now. Past the deadline, this closes it.
    func isOpen() -> Bool {
        guard let deadline else { return false }
        if clock() >= deadline {
            shut(.timedOut)
            return false
        }
        return true
    }

    func remaining() -> TimeInterval? {
        guard let deadline else { return nil }
        let left = deadline - clock()
        return left > 0 ? left : nil
    }

    func close() {
        guard deadline != nil else { return }
        shut(.byOwner)
    }

    func serverStopped() {
        guard deadline != nil else { return }
        shut(.serverStopped)
    }

    /// A plugin asks to pair. Nothing is enrolled: the owner decides.
    func request(publicKey: String, name: String, app: String, version: String, address: String,
                 identity: Curve25519.Signing.PrivateKey,
                 serverKey: Curve25519.KeyAgreement.PrivateKey = .init(),
                 deviceId: String = LanDevices.freshId(),
                 pairId: String = LanConnectorPairing.freshSecret(12),
                 pollSecret: String = LanConnectorPairing.freshSecret(32)) throws(Refusal) -> Offer {
        guard isOpen() else { throw .closed }
        guard pending == nil else { throw .busy }
        guard let raw = Data(base64Encoded: publicKey), raw.count == 32,
              let theirs = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw),
              LanDevices.derive(serverKey, theirs, deviceId: deviceId) != nil else { throw .badKey }
        let serverPublic = serverKey.publicKey.rawRepresentation.base64EncodedString()
        let identityPublic = identity.publicKey.rawRepresentation.base64EncodedString()
        guard let sig = try? identity.signature(for: LanDevices.enrolMessage(
            deviceId: deviceId, serverPublic: serverPublic, phonePublic: publicKey)) else { throw .badKey }
        pending = Request(pairId: pairId, pollHash: Self.hash(pollSecret), deviceId: deviceId,
                          serverKey: serverKey, serverPublic: serverPublic, pluginPublic: publicKey,
                          name: Self.field(name), app: Self.field(app), version: Self.field(version),
                          address: address,
                          check: Self.check(deviceId: deviceId, identityPublic: identityPublic,
                                            serverPublic: serverPublic, pluginPublic: publicKey))
        outcomes[pairId] = .waiting
        return Offer(pairId: pairId, pollSecret: pollSecret, deviceId: deviceId,
                     publicKey: serverPublic, sig: sig.base64EncodedString(), identity: identityPublic)
    }

    /// The plugin asks how its request went. Nil for an id this window never
    /// gave out, or a secret that is not that request's.
    func poll(pairId: String, secret: String) -> Outcome? {
        _ = isOpen()
        guard let outcome = outcomes[pairId] else { return nil }
        if let pending, pending.pairId == pairId {
            return LanDevices.constantTimeEqual(pending.pollHash, Self.hash(secret)) ? outcome : nil
        }
        guard let hash = answeredHashes[pairId], LanDevices.constantTimeEqual(hash, Self.hash(secret)) else {
            return nil
        }
        return outcome
    }
    /// Poll secrets of requests already answered, so only that plugin learns how.
    @ObservationIgnored private var answeredHashes: [String: Data] = [:]

    /// The owner approved. `enrol` writes the device; when it throws, nothing
    /// changes and the request still waits.
    func approve(_ enrol: (Request) throws -> Void) rethrows {
        guard let request = pending, isOpen() else { return }
        try enrol(request)
        answer(request, .approved)
        shut(.paired(name: request.name))
    }

    /// The owner denied: that request is told so; the window stays open.
    func deny() {
        guard let request = pending else { return }
        answer(request, .denied)
    }

    private func answer(_ request: Request, _ outcome: Outcome) {
        outcomes[request.pairId] = outcome
        answeredHashes[request.pairId] = request.pollHash
        pending = nil
    }

    /// End the window for a reason the owner is told (`pinUnreadable`).
    func refuse(_ why: Closed) {
        guard deadline != nil else { return }
        shut(why)
    }

    private func shut(_ why: Closed) {
        if let request = pending { answer(request, .expired) }
        deadline = nil
        lastClosed = why
    }

    // MARK: - Shared with the plugin

    /// The 6-digit number both screens show. SHA-256 over the device id, the
    /// Mac's identity key and both X25519 keys (base64, as sent), one per line
    /// after a fixed prefix;
    /// the first four bytes big-endian, modulo 10^6, zero-padded. The vectors
    /// are `docs/connector-pair.vectors.json`; the plugin computes the same.
    nonisolated static func check(deviceId: String, identityPublic: String, serverPublic: String,
                                  pluginPublic: String) -> String {
        let text = ["khayt-connector-check-v1", deviceId, identityPublic, serverPublic, pluginPublic]
            .joined(separator: "\n")
        let digest = Array(SHA256.hash(data: Data(text.utf8)))
        let n = (UInt32(digest[0]) << 24) | (UInt32(digest[1]) << 16) | (UInt32(digest[2]) << 8) | UInt32(digest[3])
        let six = String(n % 1_000_000)
        return String(repeating: "0", count: 6 - six.count) + six
    }

    /// "418 207": how a person reads it.
    nonisolated static func spaced(_ check: String) -> String {
        guard check.count == 6 else { return check }
        return String(check.prefix(3)) + "\u{2009}" + String(check.suffix(3))
    }

    nonisolated static func field(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            .map(Character.init)).trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxField).description
    }

    nonisolated static func hash(_ secret: String) -> Data {
        Data(SHA256.hash(data: Data(secret.utf8)))
    }

    nonisolated static func freshSecret(_ count: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var rng = SystemRandomNumberGenerator()
        return String((0..<count).map { _ in alphabet.randomElement(using: &rng)! })
    }

    /// A pair id as `freshSecret(12)` makes it: the poll route takes nothing else.
    nonisolated static func plausiblePairId(_ id: String) -> Bool {
        id.count == 12 && id.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }

    nonisolated static let closedBody =
        #"{"reason":"pairing-closed","error":"On the Mac, open Settings, Online, Connected apps, and click Pair a slicer"}"#
    nonisolated static let busyBody =
        #"{"reason":"pairing-busy","error":"Another slicer is waiting for the shop to answer. Try again in a minute"}"#
}
