import CryptoKit
import Foundation

/// Signing each request to the Mac instead of sending the PIN with it.
///
/// ── WHY ──────────────────────────────────────────────────────────────────
///
/// The LAN is plain http, so a PIN in a header is readable by anything on the
/// same Wi-Fi, on every request. Once the phone has paired, it enrols with
/// the PIN one last time (`POST /api/devices`): each side makes an X25519 key,
/// and the Mac signs its half with the identity key the phone pinned
/// (`MacIdentity`), so the phone knows the other half is the Mac's. Both
/// derive the same 32-byte key, which never crosses the network. Every request
/// after that carries an HMAC of what it asks for, a time and a nonce, so a
/// request read off the Wi-Fi can be neither replayed nor turned into the PIN.
///
/// The full wire rules are in `docs/LAN_API.md` ("POST /api/devices and signed
/// requests"); `docs/lan-device-keys.vectors.json` holds values the Mac, the
/// desktop and these tests all reproduce.
///
/// A Mac without the route (404/405) or without an identity key (503) keeps
/// getting the PIN, as before.
enum DeviceKey {
    /// What the phone keeps after enrolling, in the Keychain.
    struct Credential: Codable, Equatable, Sendable {
        let deviceId: String
        /// The derived HMAC key, base64.
        let key: String
        /// The identity key the Mac signed the enrolment with. A credential is
        /// only used while that is still the key the phone has pinned.
        let identityKey: String
    }

    struct Headers: Equatable, Sendable {
        let device, time, nonce, mac: String
    }

    static let salt = Data("khayt-device-v1".utf8)

    /// `dev_` and 12–40 of `[A-Za-z0-9_-]`.
    static func isDeviceId(_ id: String) -> Bool {
        guard id.hasPrefix("dev_") else { return false }
        let rest = id.dropFirst(4)
        return (12...40).contains(rest.count) && rest.allSatisfy { c in
            c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "-")
        }
    }

    /// What the Mac signs at enrolment: both public keys as base64, exactly as
    /// they travel in the JSON.
    static func enrolmentMessage(deviceId: String, macPublic: String, phonePublic: String) -> Data {
        Data("khayt-enrol:\(deviceId):\(macPublic):\(phonePublic)".utf8)
    }

    /// The shared HMAC key, or nil when `macPublic` is not an X25519 key.
    static func deriveKey(phonePrivate: Curve25519.KeyAgreement.PrivateKey,
                          macPublic: String, deviceId: String) -> SymmetricKey? {
        guard let raw = Data(base64Encoded: macPublic),
              let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw),
              let shared = try? phonePrivate.sharedSecretFromKeyAgreement(with: pub) else { return nil }
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                              sharedInfo: Data(deviceId.utf8), outputByteCount: 32)
    }

    /// The enrolment answer checked and turned into a credential: the
    /// signature must be the pinned identity key's.
    static func credential(deviceId: String, macPublic: String, sig: String,
                           phonePrivate: Curve25519.KeyAgreement.PrivateKey,
                           identityKey: String) -> Credential? {
        let phonePublic = phonePrivate.publicKey.rawRepresentation.base64EncodedString()
        guard isDeviceId(deviceId),
              let signer = MacIdentity.publicKey(identityKey),
              let signature = Data(base64Encoded: sig),
              signer.isValidSignature(signature, for: enrolmentMessage(deviceId: deviceId, macPublic: macPublic,
                                                                       phonePublic: phonePublic)),
              let key = deriveKey(phonePrivate: phonePrivate, macPublic: macPublic, deviceId: deviceId)
        else { return nil }
        return Credential(deviceId: deviceId,
                          key: key.withUnsafeBytes { Data($0) }.base64EncodedString(),
                          identityKey: identityKey)
    }

    /// The path and query as they go on the request line, still percent-encoded.
    static func requestTarget(_ url: URL) -> String {
        let path = url.path(percentEncoded: true)
        let target = path.isEmpty ? "/" : path
        guard let query = url.query(percentEncoded: true) else { return target }
        return target + "?" + query
    }

    static func canonical(method: String, target: String, time: Int, nonce: String, body: Data?) -> String {
        let hash = SHA256.hash(data: body ?? Data()).map { String(format: "%02x", $0) }.joined()
        return ["khayt-req-v1", method.uppercased(), target, String(time), nonce, hash].joined(separator: "\n")
    }

    static func mac(key: String, canonical: String) -> String? {
        guard let raw = Data(base64Encoded: key), raw.count == 32 else { return nil }
        let code = HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: SymmetricKey(data: raw))
        return Data(code).base64EncodedString()
    }

    static func headers(_ credential: Credential, method: String, url: URL, body: Data?,
                        now: Date, nonce: String = MacIdentity.nonce()) -> Headers? {
        let time = Int(now.timeIntervalSince1970.rounded(.down))
        let text = canonical(method: method, target: requestTarget(url), time: time, nonce: nonce, body: body)
        guard let mac = mac(key: credential.key, canonical: text) else { return nil }
        return Headers(device: credential.deviceId, time: String(time), nonce: nonce, mac: mac)
    }

    /// Why a signed request was refused, from a 401's `reason`.
    enum Refusal: Equatable {
        /// No such device, or its key does not match: enrol again.
        case unknown
        case clock(now: Int)
        /// The nonce was seen already; a fresh one will do.
        case replay
    }

    static func refusal(_ body: Data) -> Refusal? {
        struct Answer: Decodable { let reason: String?; let now: Int? }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: body), let reason = answer.reason else { return nil }
        switch reason {
        // A MAC the Mac cannot check means the two keys differ, which no
        // retry with this one will mend.
        case "device-unknown", "device-auth": return .unknown
        case "device-clock": return answer.now.map { .clock(now: $0) }
        case "device-replay": return .replay
        default: return nil
        }
    }
}
