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
/// Commit, then reveal (v2). The plugin first sends only a commitment: the
/// SHA-256 of its fresh X25519 key and a random nonce (`commitment`). Only then
/// does the Mac draw a fresh X25519 key for this request and answer with it,
/// signed by its `LanIdentity`, and the identity key itself (which the plugin
/// pins). The plugin checks the signature, then reveals its key and nonce; the
/// Mac checks them against the commitment (constant time), and only now does a
/// 6-digit check number exist on either screen (`check`).
///
/// Why the order matters (v1 had none): a 6-digit number is one in 10^6, which
/// a device in the middle could beat by grinding its own keys once it had seen
/// every other input. Now it cannot. Toward the plugin, it must send its keys
/// before the plugin's key and nonce are revealed; toward the Mac, it must
/// commit before the Mac draws its fresh key. Either way one screen's number is
/// a blind guess, and at most `maxOffers` offers per opened window bound it to
/// 3 in 10^6 per click of Pair a slicer. Until the owner approves, nothing is
/// enrolled: the plugin's key opens nothing.
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
    /// Offers one opened window gives out, whatever became of them (denied,
    /// abandoned, a bad or late reveal). Then the owner must click again.
    nonisolated static let maxOffers = 3
    /// The plugin reveals at once; a reveal later than this expires the offer.
    nonisolated static let revealWithin: TimeInterval = 30
    /// The plugin's nonce: at least this many random bytes.
    nonisolated static let minNonce = 16

    enum Closed: Equatable {
        case paired(name: String)
        case timedOut
        case byOwner
        case serverStopped
        /// `maxOffers` offers were given out and none was approved.
        case offersUsed
        /// The LAN PIN could not be read, so nothing was enrolled: a connector
        /// enrolled under a PIN nothing uses could never connect, and making
        /// room for it under that PIN took every phone off (beta.38 review).
        case pinUnreadable
    }

    /// What a poll is told about a request.
    enum Outcome: String, Equatable { case waiting, approved, denied, expired }

    /// A plugin that asked and waits for the owner. The Mac's private key is
    /// held here, in memory only, until the owner answers. `pluginPublic` and
    /// `check` stay nil until the plugin's reveal matches its commitment: there
    /// is no number to show, and nothing to approve, before that.
    struct Request {
        let pairId: String
        let pollHash: Data
        let deviceId: String
        let serverKey: Curve25519.KeyAgreement.PrivateKey
        let serverPublic: String
        let identityPublic: String
        let commitment: Data
        let offeredAt: TimeInterval
        let name: String
        let app: String
        let version: String
        let address: String
        fileprivate(set) var pluginPublic: String?
        fileprivate(set) var check: String?
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

    enum Refusal: Error, Equatable { case closed, busy, badCommit }

    /// How a reveal went. `refused` expired the offer: no number exists.
    enum Revealed: Equatable { case accepted, unknown, already, refused }

    private(set) var deadline: TimeInterval?
    var isOpenNow: Bool { deadline != nil }
    private(set) var lastClosed: Closed?
    /// How many times this window has shut. `lastClosed` can be the same value
    /// twice running (two phones of one name, two timeouts), so whoever needs
    /// to act on EVERY ending watches this.
    private(set) var closes = 0
    /// The request the owner is looking at; nil while none has come.
    private(set) var pending: Request?
    /// Answers given in this window, by pair id, for the plugin's poll.
    private(set) var outcomes: [String: Outcome] = [:]
    /// Offers this window may still give out.
    private(set) var offersLeft = 0

    @ObservationIgnored let clock: () -> TimeInterval
    /// This window's own answer to `enabled`, for a test that builds one: so a
    /// suite running beside others never has to write the shared static.
    @ObservationIgnored let enabledHere: Bool?

    /// Which kind of device this window pairs. The hashes are the same; the
    /// PREFIXES differ, so a commitment, a signed offer or a check number made
    /// for one kind can never stand for the other (phone pairing design, 1).
    struct Flavor: Equatable, Sendable {
        let commit: String
        let check: String
        let offer: String
        static let connector = Flavor(commit: "khayt-connector-commit-v2", check: "khayt-connector-check-v2",
                                      offer: "khayt-enrol-commit-v2")
        static let phone = Flavor(commit: "khayt-phone-commit-v1", check: "khayt-phone-check-v1",
                                  offer: "khayt-enrol-phone-v1")
    }
    @ObservationIgnored let flavor: Flavor

    init(clock: @escaping () -> TimeInterval = LanPairingWindow.monotonic, enabled: Bool? = nil,
         flavor: Flavor = .connector) {
        self.clock = clock
        self.enabledHere = enabled
        self.flavor = flavor
    }

    /// Pairing a phone by code is OFF until the phone ships it: no route
    /// answers, so nothing can be offered. On for a developer with
    /// `defaults write <bundle id> phonePairingByCode -bool YES`.
    nonisolated static var phoneCodeEnabled: Bool { UserDefaults.standard.bool(forKey: "phonePairingByCode") }

    /// Pairing a slicer is OFF in beta.38 (Dev Hub, Nov 16): the protocol gets
    /// a commit-then-reveal before any plugin is public, and until then no
    /// window opens, so the pair route answers `pairing-closed`. On for a
    /// developer with `defaults write <bundle id> connectorPairing -bool YES`.
    nonisolated static var enabled: Bool {
        UserDefaults.standard.bool(forKey: "connectorPairing") || enabledForTests
    }
    nonisolated(unsafe) static var enabledForTests = false

    /// "Show prices in OrcaSlicer" (Connected apps ▸ Slicers), this Mac's own
    /// switch beside "Pair a slicer", OFF unless the owner turns it on. Even
    /// on, a plugin sees nothing until the shop grants that device a price.
    nonisolated static let pricesKey = "connectorPrices"
    nonisolated static var pricesOn: Bool { UserDefaults.standard.bool(forKey: pricesKey) }

    func open() {
        guard enabledHere ?? (flavor == .phone ? Self.phoneCodeEnabled : Self.enabled) else { return }
        deadline = clock() + Self.length
        pending = nil
        outcomes = [:]
        offersLeft = Self.maxOffers
    }

    /// Whether a plugin may ask now. Past the deadline, this closes it; an
    /// offer never revealed in time expires here, so it cannot hold the slot.
    func isOpen() -> Bool {
        guard let deadline else { return false }
        if clock() >= deadline {
            shut(.timedOut)
            return false
        }
        if let request = pending, request.check == nil, clock() - request.offeredAt > Self.revealWithin {
            answer(request, .expired)
        }
        return self.deadline != nil
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

    /// A plugin asks to pair with its commitment. The Mac's X25519 key is
    /// drawn here, after the commitment arrived and only if it is well formed
    /// (`freshKey` is called once or not at all). Nothing is enrolled, and no
    /// check number exists yet.
    func request(commitment: String, name: String, app: String, version: String, address: String,
                 identity: Curve25519.Signing.PrivateKey,
                 freshKey: () -> Curve25519.KeyAgreement.PrivateKey = { .init() },
                 deviceId: String = LanDevices.freshId(),
                 pairId: String = LanConnectorPairing.freshSecret(12),
                 pollSecret: String = LanConnectorPairing.freshSecret(32)) throws(Refusal) -> Offer {
        guard isOpen() else { throw .closed }
        guard pending == nil else { throw .busy }
        guard let commit = Data(base64Encoded: commitment), commit.count == 32 else { throw .badCommit }
        let serverKey = freshKey()
        let serverPublic = serverKey.publicKey.rawRepresentation.base64EncodedString()
        let identityPublic = identity.publicKey.rawRepresentation.base64EncodedString()
        guard let sig = try? identity.signature(for: Self.offerMessage(
            deviceId: deviceId, serverPublic: serverPublic, commitment: commitment, flavor: flavor)) else { throw .badCommit }
        offersLeft -= 1
        pending = Request(pairId: pairId, pollHash: Self.hash(pollSecret), deviceId: deviceId,
                          serverKey: serverKey, serverPublic: serverPublic, identityPublic: identityPublic,
                          commitment: commit, offeredAt: clock(),
                          name: Self.field(name), app: Self.field(app), version: Self.field(version),
                          address: address, pluginPublic: nil, check: nil)
        outcomes[pairId] = .waiting
        return Offer(pairId: pairId, pollSecret: pollSecret, deviceId: deviceId,
                     publicKey: serverPublic, sig: sig.base64EncodedString(), identity: identityPublic)
    }

    /// The plugin reveals the key and nonce it committed to. Anything but an
    /// exact, timely match expires the offer (it was counted when given) and no
    /// check number is ever worked out for it.
    func reveal(pairId: String, secret: String, publicKey: String, nonce: String) -> Revealed {
        guard let request = pending, request.pairId == pairId else { return .unknown }
        guard LanDevices.constantTimeEqual(request.pollHash, Self.hash(secret)) else { return .unknown }
        guard request.check == nil else { return .already }
        guard isOpen(), pending?.pairId == pairId else { return .refused }
        guard let raw = Data(base64Encoded: publicKey), raw.count == 32,
              let theirs = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw),
              LanDevices.derive(request.serverKey, theirs, deviceId: request.deviceId) != nil,
              let n = Data(base64Encoded: nonce), n.count >= Self.minNonce,
              LanDevices.constantTimeEqual(request.commitment, Self.commitment(pluginPublic: publicKey, nonce: nonce, flavor: flavor))
        else {
            answer(request, .expired)
            return .refused
        }
        var revealed = request
        revealed.pluginPublic = publicKey
        revealed.check = Self.check(deviceId: request.deviceId, identityPublic: request.identityPublic,
                                    serverPublic: request.serverPublic, pluginPublic: publicKey, nonce: nonce, flavor: flavor)
        pending = revealed
        return .accepted
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
        guard isOpen(), let request = pending, request.check != nil, request.pluginPublic != nil else { return }
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
        if outcome != .approved, offersLeft <= 0, deadline != nil { shut(.offersUsed) }
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
        closes += 1
    }

    // MARK: - Shared with the plugin

    // Every input below is hashed as the exact UTF-8 bytes of the strings as
    // sent (base64 for keys and the nonce), joined by "\n" after a fixed
    // prefix. The vectors are `docs/connector-pair.vectors.json`; the plugin
    // computes the same.

    /// What the plugin commits to before it sees anything of the Mac's.
    nonisolated static func commitment(pluginPublic: String, nonce: String, flavor: Flavor = .connector) -> Data {
        let text = [flavor.commit, pluginPublic, nonce].joined(separator: "\n")
        return Data(SHA256.hash(data: Data(text.utf8)))
    }

    /// What the Mac's identity signs in its offer: its fresh key, bound to the
    /// device id and to the commitment it answers.
    nonisolated static func offerMessage(deviceId: String, serverPublic: String, commitment: String,
                                         flavor: Flavor = .connector) -> Data {
        Data("\(flavor.offer):\(deviceId):\(serverPublic):\(commitment)".utf8)
    }

    /// The first four bytes, big-endian, of the SHA-256 the check number is
    /// cut from. Tests use it with a small modulus to measure grinding.
    nonisolated static func checkValue(deviceId: String, identityPublic: String, serverPublic: String,
                                       pluginPublic: String, nonce: String, flavor: Flavor = .connector) -> UInt32 {
        let text = [flavor.check, deviceId, identityPublic, serverPublic, pluginPublic, nonce]
            .joined(separator: "\n")
        let digest = Array(SHA256.hash(data: Data(text.utf8)))
        return (UInt32(digest[0]) << 24) | (UInt32(digest[1]) << 16) | (UInt32(digest[2]) << 8) | UInt32(digest[3])
    }

    /// The 6-digit number both screens show: `checkValue` modulo 10^6, zero-padded.
    nonisolated static func check(deviceId: String, identityPublic: String, serverPublic: String,
                                  pluginPublic: String, nonce: String, flavor: Flavor = .connector) -> String {
        let six = String(checkValue(deviceId: deviceId, identityPublic: identityPublic, serverPublic: serverPublic,
                                    pluginPublic: pluginPublic, nonce: nonce, flavor: flavor) % 1_000_000)
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
    nonisolated static let upgradeBody =
        #"{"reason":"pairing-upgrade","error":"Update Khayt for OrcaSlicer: this Mac pairs with version 2 of the handshake"}"#
    nonisolated static let busyBody =
        #"{"reason":"pairing-busy","error":"Another slicer is waiting for the shop to answer. Try again in a minute"}"#
}
