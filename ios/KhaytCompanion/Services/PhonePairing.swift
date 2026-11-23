import CryptoKit
import Foundation
import Security
import KhaytCore

/// Pairing this phone with a number approved on the Mac, instead of the
/// owner PIN (C1 + C9, ~/Khayt-proposals/phone-pairing-code-design.md, decided
/// by Turki Nov 22: all as recommended).
///
/// It is the slicer plugin's reviewed flow (`POST /api/connectors/pair`, v2,
/// docs/LAN_API.md) with the phone's own prefixes, so a connector offer can
/// never be replayed as a phone or the other way round:
///
///  1. The phone draws an X25519 key and a 16-byte nonce and COMMITS to them:
///     `commit = SHA-256(prefix \n publicKey \n nonce)`. It sends only that.
///  2. The Mac draws a fresh key for this offer and signs
///     `<offerPrefix>:<deviceId>:<Mac publicKey>:<commit>` with its identity
///     key, which the phone pins (it cannot ask `/api/identity`: that takes the PIN).
///  3. The phone checks the signature, then REVEALS its key and nonce.
///  4. Both show the 6-digit check number, worked out from everything above.
///     A device in the middle would have to grind a key whose number matches
///     before seeing the other side's, a blind 1-in-10^6 guess per offer.
///  5. Someone at the Mac approves, picking the phone's role. Both derive the
///     same key (`DeviceKey.deriveKey`, HKDF info = deviceId) and requests are
///     signed exactly as a PIN-enrolled phone's are.
///
/// This file is the arithmetic and the checks, with no network: the same
/// functions run `docs/connector-pair.vectors.json` with the connector's
/// prefixes, which proves the phone's variant is the reviewed math.
enum PairCode {
    /// The three prefixes that keep one kind of offer from passing as another.
    struct Variant: Equatable, Sendable {
        let commit: String
        let offer: String
        let check: String

        /// The slicer plugin (docs/LAN_API.md, `connector-pair.vectors.json`).
        static let connector = Variant(commit: "khayt-connector-commit-v2", offer: "khayt-enrol-commit-v2",
                                       check: "khayt-connector-check-v2")
        /// A phone (the design note's prefixes).
        static let phone = Variant(commit: "khayt-phone-commit-v1", offer: "khayt-enrol-phone-v1",
                                   check: "khayt-phone-check-v1")
    }

    static let minNonceBytes = 16

    /// base64 `SHA-256(commit \n publicKey \n nonce)`; keys and nonce as base64 of the raw bytes.
    static func commit(_ v: Variant, publicKey: String, nonce: String) -> String {
        Data(SHA256.hash(data: Data("\(v.commit)\n\(publicKey)\n\(nonce)".utf8))).base64EncodedString()
    }

    /// What the Mac's identity key signs in its offer.
    static func offerMessage(_ v: Variant, deviceId: String, serverPublic: String, commit: String) -> Data {
        Data("\(v.offer):\(deviceId):\(serverPublic):\(commit)".utf8)
    }

    /// The 6-digit number both screens show: the first 4 bytes of the hash,
    /// big-endian, modulo 1,000,000, zero-padded.
    static func check(_ v: Variant, deviceId: String, identity: String, serverPublic: String,
                      clientPublic: String, nonce: String) -> String {
        let text = [v.check, deviceId, identity, serverPublic, clientPublic, nonce].joined(separator: "\n")
        let d = Array(SHA256.hash(data: Data(text.utf8)))
        let n = (UInt32(d[0]) << 24) | (UInt32(d[1]) << 16) | (UInt32(d[2]) << 8) | UInt32(d[3])
        return String(format: "%06u", n % 1_000_000)
    }

    /// The check number as the person reads it: "481 207".
    static func spaced(_ check: String) -> String {
        guard check.count == 6 else { return check }
        return String(check.prefix(3)) + " " + String(check.suffix(3))
    }
}

/// What `POST /api/devices/pair` answers with.
struct PairOffer: Decodable, Equatable, Sendable {
    let pairId: String
    let pollSecret: String
    let deviceId: String
    /// The Mac's fresh X25519 key for this offer, base64 raw.
    let publicKey: String
    /// Ed25519 signature of the offer message by `identity`.
    let sig: String
    /// The Mac's identity key (Ed25519, base64 raw). Pinned once approved.
    let identity: String

    /// An id or secret the phone puts in a path or a header: short, and only
    /// characters that need no escaping, so a hostile answer cannot steer the
    /// next request somewhere else.
    static func isToken(_ s: String) -> Bool {
        (8...128).contains(s.count) && s.allSatisfy { c in
            c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "-")
        }
    }
}

/// One attempt at pairing by number: this phone's key and nonce, never reused.
struct CodePairing: Sendable {
    let variant: PairCode.Variant
    private let keyRaw: Data
    let nonceRaw: Data

    init(variant: PairCode.Variant = .phone) {
        self.variant = variant
        keyRaw = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        var bytes = [UInt8](repeating: 0, count: 16)
        // A nonce from the system's generator; on the impossible failure the
        // key itself is still fresh, and the Mac refuses a short nonce anyway.
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        nonceRaw = Data(bytes)
    }

    /// For the vectors: a known key and nonce.
    init(variant: PairCode.Variant, privateKey: Data, nonce: Data) {
        self.variant = variant
        keyRaw = privateKey
        nonceRaw = nonce
    }

    var privateKey: Curve25519.KeyAgreement.PrivateKey? {
        try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyRaw)
    }
    var publicKey: String { privateKey?.publicKey.rawRepresentation.base64EncodedString() ?? "" }
    var nonce: String { nonceRaw.base64EncodedString() }
    var commit: String { PairCode.commit(variant, publicKey: publicKey, nonce: nonce) }

    /// Why an offer was not taken. The phone shows nothing for any of these
    /// (no number, no Approve); the person starts again.
    enum Refusal: Error, Equatable { case malformed, badSignature, badKey }

    /// The offer checked: well-formed ids, the Mac's key a real X25519 key,
    /// and the identity's signature over THIS phone's commit. Only then is
    /// there a number to show.
    func accept(_ offer: PairOffer) -> Result<String, Refusal> {
        guard DeviceKey.isDeviceId(offer.deviceId), PairOffer.isToken(offer.pairId),
              PairOffer.isToken(offer.pollSecret) else { return .failure(.malformed) }
        guard let raw = Data(base64Encoded: offer.publicKey), raw.count == 32,
              let mac = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw),
              let mine = privateKey,
              let shared = try? mine.sharedSecretFromKeyAgreement(with: mac),
              // The all-zero secret: a low-order point, no key at all.
              shared.withUnsafeBytes({ $0.contains { $0 != 0 } }) else { return .failure(.badKey) }
        guard let signer = MacIdentity.publicKey(offer.identity),
              let sig = Data(base64Encoded: offer.sig),
              signer.isValidSignature(sig, for: PairCode.offerMessage(variant, deviceId: offer.deviceId,
                                                                       serverPublic: offer.publicKey,
                                                                       commit: commit))
        else { return .failure(.badSignature) }
        return .success(PairCode.check(variant, deviceId: offer.deviceId, identity: offer.identity,
                                       serverPublic: offer.publicKey, clientPublic: publicKey, nonce: nonce))
    }

    /// The credential, once the Mac approved: the key both sides derive, tied
    /// to the identity that signed the offer. Nil for an offer `accept` refuses.
    func credential(_ offer: PairOffer) -> DeviceKey.Credential? {
        guard case .success = accept(offer), let mine = privateKey,
              let key = DeviceKey.deriveKey(phonePrivate: mine, macPublic: offer.publicKey, deviceId: offer.deviceId)
        else { return nil }
        return DeviceKey.Credential(deviceId: offer.deviceId,
                                    key: key.withUnsafeBytes { Data($0) }.base64EncodedString(),
                                    identityKey: offer.identity)
    }

    /// `POST /api/devices/pair`'s body. No PIN, no signature.
    func startBody(name: String, version: String) -> [String: JSONValue] {
        ["v": .number(2), "commit": .string(commit), "name": .string(String(name.prefix(60))),
         "app": .string("Khayt iPhone"), "version": .string(version)]
    }

    /// The reveal's body.
    var revealBody: [String: JSONValue] { ["publicKey": .string(publicKey), "nonce": .string(nonce)] }
}

/// A phone's role (C9), as the Mac reports it and as `lib/device-roles.js`
/// `roleOf` reads it. Kept as text, never an enum that drops a role it does
/// not know (the security review of #2625): an unknown role reads as viewer.
///
/// The Mac's 403 on every request is the actual check; the phone uses this
/// only to choose what to ask for and what to show.
enum DeviceRole {
    static let ladder = ["owner", "manager", "operator", "viewer"]

    /// `roleOf` for this phone: its role when it is on the ladder; a phone
    /// paired with the owner PIN before roles (no role, not paired by code) is
    /// the owner, as it always was; anything else is a viewer.
    static func effective(role: String?, pairedByCode: Bool) -> String {
        if let role, ladder.contains(role) { return role }
        return role == nil && !pairedByCode ? "owner" : "viewer"
    }

    /// `book:read` (GET /api/store): manager and owner only. Below that the
    /// phone keeps NO book and runs on the question routes (D-P6 a, floor mode).
    static func mayHoldBook(_ effective: String) -> Bool { effective == "owner" || effective == "manager" }

    /// `scopesFor` (lib/device-roles.js): what each role may do. The owner
    /// holds every scope. Tested against `device-roles-vectors.json` so the
    /// phone never offers a button the Mac would refuse, nor hides one it allows.
    static let viewerScopes: Set<String> = ["queue:read", "machines:read", "orders:read", "inventory:read"]
    static let operatorScopes = viewerScopes.union(["orders:write", "inventory:write", "waste:write", "machines:control"])
    static let managerScopes = operatorScopes.union(["clients:read", "clients:write", "expense:write", "quote:write", "book:read"])

    /// Whether `effective` holds `scope`. Only the owner holds a scope this
    /// table does not name, as the shared rule fails closed.
    static func allows(_ effective: String, _ scope: String) -> Bool {
        switch effective {
        case "owner": return true
        case "manager": return managerScopes.contains(scope)
        case "operator": return operatorScopes.contains(scope)
        default: return viewerScopes.contains(scope)
        }
    }

    /// A floor phone (D-P6 a): below manager. No book, no money, no clients.
    static func isFloor(_ effective: String) -> Bool { !mayHoldBook(effective) }

    /// A 403 that says the role does not reach the route:
    /// `{"reason":"role-scope","required":"book:read"}`. The required scope, or nil.
    static func refusedScope(status: Int, body: Data) -> String? {
        guard status == 403, case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: body),
              o["reason"] == .string("role-scope") else { return nil }
        if case .string(let s)? = o["required"] { return s }
        return ""
    }
}
