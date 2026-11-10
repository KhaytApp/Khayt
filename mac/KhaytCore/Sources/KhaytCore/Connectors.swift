import CryptoKit
import Foundation

/// The two things about a connector the JavaScript cannot do, shared by the
/// Mac and the phone: checking its signature, and turning the request
/// `lib/plugin-payload.js payloadFor` built into the headers that go out.
///
/// In KhaytCore, not KhaytApp, because the phone sends connector requests too
/// and must send the same headers. Nothing here touches the network or the
/// Keychain — the caller hands in the secret values it opened.
public enum Connectors {

    // MARK: - Reviewed

    /// The id of the published key a manifest's signature verifies against,
    /// or nil when it is not reviewed.
    ///
    /// `canonical` is `KhaytEngine.pluginCanonicalJSON(manifest)` — the same
    /// bytes `scripts/sign-connector.js` signed; `keys` is
    /// `KhaytEngine.pluginSigningKeys()`. Reviewed is never read from the
    /// book: anything there could have been written by anyone.
    public static func reviewedBy(manifest: JSONValue, canonical: String, keys: [JSONValue]) -> String? {
        guard case .object(let m) = manifest,
              case .string(let b64)? = m["signature"],
              let signature = Data(base64Encoded: b64), signature.count == 64 else { return nil }
        let message = Data(canonical.utf8)
        for k in keys {
            guard case .object(let o) = k,
                  case .string(let id)? = o["id"],
                  case .string(let keyB64)? = o["key"],
                  let raw = Data(base64Encoded: keyB64),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { continue }
            if key.isValidSignature(signature, for: message) { return id }
        }
        return nil
    }

    /// Which published key signed the update index — its `signature` is
    /// `{ keyId, sig }` over `message` (`KhaytEngine.pluginIndexMessage`: the
    /// "khayt-index-v1" context, then the canonical JSON). Nil unless the key
    /// named is the one that verifies.
    public static func indexSignedBy(index: JSONValue, message: String, keys: [JSONValue]) -> String? {
        guard case .object(let ix) = index, case .object(let sig)? = ix["signature"],
              case .string(let keyId)? = sig["keyId"], case .string(let b64)? = sig["sig"],
              let signature = Data(base64Encoded: b64), signature.count == 64 else { return nil }
        let data = Data(message.utf8)
        for k in keys {
            guard case .object(let o) = k, case .string(let id)? = o["id"], id == keyId,
                  case .string(let keyB64)? = o["key"], let raw = Data(base64Encoded: keyB64),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { continue }
            if key.isValidSignature(signature, for: data) { return id }
        }
        return nil
    }

    // MARK: - The request

    /// A new idempotency id: "dlv_" + a random lower-case UUID. Minted once
    /// when the press or event happens and kept with anything retried, so
    /// every attempt carries the same one. Random on purpose — an id built
    /// from the order or plugin would put those in every receiver's logs.
    public static func newDeliveryId() -> String {
        "dlv_" + UUID().uuidString.lowercased()
    }

    /// Why a built request may not go.
    public enum Refusal: Error, Equatable, CustomStringConvertible {
        case notBuilt(String)
        case undeclaredHost(String)
        case missingSecret(String)

        public var description: String {
            switch self {
            case .notBuilt(let why): return why
            case .undeclaredHost(let host): return "\(host) is not one of this connector's hosts"
            case .missingSecret(let name): return "the connector's \(name) is not set on this device"
            }
        }
    }

    /// A request, ready for `WebhookClient` (or the phone's sender): a POST,
    /// or — for a refresh that says so — a GET with an empty body.
    public struct Post: Equatable, Sendable {
        public let url: URL
        public let body: Data
        public let headers: [Header]
        /// "POST" or "GET". Only a refresh is ever a GET, and a phone never
        /// runs a refresh.
        public var method: String = "POST"
    }

    public struct Header: Equatable, Sendable {
        public let name: String
        public let value: String
        public init(_ name: String, _ value: String) { self.name = name; self.value = value }
    }

    /// An "open" button's link: the shop's browser goes there.
    public static func link(from payload: JSONValue, manifest: JSONValue) throws -> URL {
        guard case .object(let p) = payload, p["ok"] == .bool(true) else { throw Refusal.notBuilt(reason(payload)) }
        guard p["method"] == .string("OPEN"), case .string(let s)? = p["url"], let url = URL(string: s) else {
            throw Refusal.notBuilt("not a link")
        }
        try checkHost(url, manifest: manifest)
        return url
    }

    /// The POST `payloadFor` described, with the auth header filled in from
    /// `secrets` and, when the manifest says `signWith`, the same three
    /// signature headers a Khayt webhook carries (`X-Khayt-Signature`, bare
    /// hex HMAC-SHA256 of the body; `X-Khayt-Timestamp`; `X-Khayt-Signature-V2`
    /// over "<timestamp>.<body>"), so a developer verifies a connector the way
    /// they already verify a webhook.
    ///
    /// The host is checked AGAIN here against the manifest's own list: the
    /// JavaScript checked it, and a request is the last place to be wrong.
    ///
    /// `delivery` is the idempotency id, sent as `X-Khayt-Delivery`: one per
    /// press or per event, the SAME on every retry of it, so a receiver can
    /// drop a repeat. A header and not a body field, because a json-template
    /// body is the receiver's own format and has no room for it.
    public static func post(from payload: JSONValue, manifest: JSONValue, event: String,
                            secrets: [String: String], delivery: String, now: Date) throws -> Post {
        guard case .object(let p) = payload, p["ok"] == .bool(true) else { throw Refusal.notBuilt(reason(payload)) }
        guard case .string(let method)? = p["method"], method == "POST" || method == "GET",
              case .string(let s)? = p["url"], let url = URL(string: s),
              case .string(let body)? = p["body"] else { throw Refusal.notBuilt("not a POST") }
        try checkHost(url, manifest: manifest)
        // A GET carries nothing but its URL: no body and no body's type.
        guard method == "POST" || body.isEmpty else { throw Refusal.notBuilt("a GET has no body") }
        let bytes = Data(body.utf8)
        var headers = method == "POST" ? [Header("Content-Type", "application/json")] : []
        headers += [Header("X-Khayt-Event", event), Header("X-Khayt-Delivery", delivery)]

        if case .object(let auth)? = p["auth"],
           case .string(let name)? = auth["header"], case .string(let secretName)? = auth["secret"] {
            guard let value = secrets[secretName], !value.isEmpty else { throw Refusal.missingSecret(secretName) }
            var scheme = ""
            if case .string(let s)? = auth["scheme"] { scheme = s }
            // `encode: "basic"` (lib/plugin-payload.js authHeaderValue): HTTP
            // Basic, base64 of "user:password"; a secret with no colon is the
            // user name with an empty password, so ":" is added.
            var sent = value
            if auth["encode"] == .string("basic") {
                sent = Data((value.contains(":") ? value : value + ":").utf8).base64EncodedString()
            }
            headers.append(Header(name, scheme.isEmpty ? sent : "\(scheme) \(sent)"))
        }
        if case .string(let signWith)? = p["signWith"] {
            guard let value = secrets[signWith], !value.isEmpty else { throw Refusal.missingSecret(signWith) }
            let key = SymmetricKey(data: Data(value.utf8))
            let hex = { (data: Data) in
                HMAC<SHA256>.authenticationCode(for: data, using: key).map { String(format: "%02x", $0) }.joined()
            }
            let stamp = String(Int(now.timeIntervalSince1970))
            headers.append(Header("X-Khayt-Signature", hex(bytes)))
            headers.append(Header("X-Khayt-Timestamp", stamp))
            headers.append(Header("X-Khayt-Signature-V2", hex(Data((stamp + ".").utf8) + bytes)))
        }
        return Post(url: url, body: bytes, headers: headers, method: method)
    }

    /// https, no user or password, no port but 443, and exactly a host the
    /// manifest declares — no subdomain, which is what the consent screen
    /// promised.
    static func checkHost(_ url: URL, manifest: JSONValue) throws {
        let host = (url.host ?? "").lowercased()
        // No port but 443: the manifest declares hosts, and a host is not a
        // host-and-any-port. The lib refuses a port when it builds the URL;
        // this guard does not lean on that.
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, !host.isEmpty,
              url.port == nil || url.port == 443 else {
            throw Refusal.undeclaredHost(host)
        }
        guard case .object(let m) = manifest, case .array(let domains)? = m["domains"],
              domains.contains(.string(host)) else { throw Refusal.undeclaredHost(host) }
    }

    private static func reason(_ payload: JSONValue) -> String {
        if case .object(let p) = payload, case .string(let e)? = p["error"] { return e }
        return "the request could not be built"
    }
}
