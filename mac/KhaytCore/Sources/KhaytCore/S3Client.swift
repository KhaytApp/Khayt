import Foundation
import CryptoKit

/// A bucket a print library can live in: S3, Cloudflare R2, Backblaze B2 and
/// every other SigV4 store. `settings.printLibrary.s3` in the book, the same
/// fields the other app writes.
public struct S3Config: Sendable, Equatable {
    public var endpoint: String
    public var bucket: String
    public var region: String
    public var accessKeyId: String
    /// OPENED, never sealed: the caller opens it at the point of use.
    public var secretAccessKey: String
    public var prefix: String

    public init(endpoint: String, bucket: String, region: String = "auto",
                accessKeyId: String, secretAccessKey: String, prefix: String = "") {
        self.endpoint = endpoint; self.bucket = bucket
        self.region = region.trimmingCharacters(in: .whitespaces).isEmpty ? "auto" : region
        self.accessKeyId = accessKeyId; self.secretAccessKey = secretAccessKey; self.prefix = prefix
    }

    /// Enough to talk to a bucket at all — `lib/s3-client.js isConfigured`.
    public var isConfigured: Bool {
        ![endpoint, bucket, accessKeyId, secretAccessKey].contains {
            $0.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
}

/// `lib/s3-client.js`, in Swift: PUT, GET, HEAD and DELETE one object, path
/// style, SigV4-signed with no SDK. The signer is the same function the other
/// app runs, checked against the same published AWS test vector, so a bucket
/// set up in either app is the bucket the other one talks to — the object keys
/// (`objectKey`) are identical, which is what lets both apps share one library.
///
/// Portable (CryptoKit, Foundation), so the phone can use it too.
public enum S3 {
    public static let emptySHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    public enum Failure: Error, LocalizedError, Equatable {
        case notConfigured
        case badEndpoint(String)
        case http(String, Int)
        case notHTTPS(String)
        public var errorDescription: String? {
            switch self {
            case .notConfigured: "the bucket is not set up"
            case .badEndpoint(let e): "the endpoint \(e) is not an address"
            case .http(let op, let code): "the bucket answered \(op) with HTTP \(code)"
            case .notHTTPS(let e): "the endpoint \(e) is not HTTPS, and is not on this network"
            }
        }
    }

    /// `[prefix]/print-files/<id>/<filename>`, empty parts dropped — the key
    /// both apps agree on.
    public static func objectKey(prefix: String, id: String, filename: String) -> String {
        let clean = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return [clean, "print-files", id, filename].filter { !$0.isEmpty }.joined(separator: "/")
    }

    /// RFC 3986: only unreserved characters pass. `encodeURIComponent` plus
    /// `!*'()`, which AWS wants escaped — `lib/s3-client.js enc`.
    public static func encode(_ s: String) -> String {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    /// `20150830T123600Z`.
    public static func amzDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    /// The SigV4 `Authorization` header. Pure, and the port of
    /// `lib/s3-client.js signRequest` — same canonical request, same scope.
    public static func sign(method: String, url: URL, headers: [String: String], payloadHash: String,
                            region: String, service: String, accessKeyId: String,
                            secretAccessKey: String, amzDate: String) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.percentEncodedPath ?? "/"
        let canonicalUri = path.isEmpty ? "/" : path
        let query = (components?.queryItems ?? [])
            .map { (encode($0.name), encode($0.value ?? "")) }
            .sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        let canonicalQuery = query.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        let hdrs = headers.map { key, value in
            (key.lowercased(),
             value.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression))
        }.sorted { $0.0 < $1.0 }
        let signedHeaders = hdrs.map(\.0).joined(separator: ";")
        let canonicalHeaders = hdrs.map { "\($0.0):\($0.1)\n" }.joined()
        let canonicalRequest = [method, canonicalUri, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash]
            .joined(separator: "\n")
        let date = String(amzDate.prefix(8))
        let scope = "\(date)/\(region)/\(service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, sha256Hex(Data(canonicalRequest.utf8))]
            .joined(separator: "\n")
        var key = Data(("AWS4" + secretAccessKey).utf8)
        for part in [date, region, service, "aws4_request"] { key = hmac(key, part) }
        let signature = hex(hmac(key, stringToSign))
        return "AWS4-HMAC-SHA256 Credential=\(accessKeyId)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }

    /// The signed request for one object. The key's segments are encoded
    /// once, and that same encoded path is both sent and signed.
    public static func request(_ c: S3Config, method: String, key: String, body: Data?,
                               now: Date = Date()) throws -> URLRequest {
        guard c.isConfigured else { throw Failure.notConfigured }
        let base = c.endpoint.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let path = ([c.bucket] + key.split(separator: "/").map(String.init)).map(encode).joined(separator: "/")
        guard let url = URL(string: base + "/" + path), let host = url.host else { throw Failure.badEndpoint(base) }
        // HTTPS, except to this Mac or the shop's own network: a customer's
        // model in plain HTTP across the internet is readable by every hop,
        // and a MinIO box on the LAN is the one place plain HTTP is normal.
        guard url.scheme?.lowercased() == "https" || (url.scheme?.lowercased() == "http" && isLocal(host)) else {
            throw Failure.notHTTPS(base)
        }
        let hostHeader = url.port.map { "\(host):\($0)" } ?? host
        let stamp = amzDate(now)
        let payloadHash = body.map(sha256Hex) ?? emptySHA256
        var headers = ["host": hostHeader, "x-amz-content-sha256": payloadHash, "x-amz-date": stamp]
        if body != nil { headers["content-type"] = "application/octet-stream" }
        let auth = sign(method: method, url: url, headers: headers, payloadHash: payloadHash,
                        region: c.region, service: "s3", accessKeyId: c.accessKeyId,
                        secretAccessKey: c.secretAccessKey, amzDate: stamp)
        var r = URLRequest(url: url, timeoutInterval: 120)
        r.httpMethod = method
        for (k, v) in headers where k != "host" { r.setValue(v, forHTTPHeaderField: k) }
        r.setValue(auth, forHTTPHeaderField: "Authorization")
        r.httpBody = body
        return r
    }

    /// Loopback, a private IPv4 range, or a `.local` name.
    static func isLocal(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h == "::1" || h.hasSuffix(".local") { return true }
        let o = h.split(separator: ".").compactMap { Int($0) }
        guard o.count == 4, h.split(separator: ".").count == 4 else { return false }
        return o[0] == 127 || o[0] == 10 || (o[0] == 192 && o[1] == 168) || (o[0] == 172 && (16...31).contains(o[1]))
    }

    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static func status(_ response: URLResponse) -> Int { (response as? HTTPURLResponse)?.statusCode ?? 0 }

    public static func put(_ c: S3Config, key: String, data: Data, fetch: Fetch) async throws {
        let (_, response) = try await fetch(try request(c, method: "PUT", key: key, body: data))
        let code = status(response)
        guard (200..<300).contains(code) else { throw Failure.http("PUT", code) }
    }

    /// The object, or nil when it is not there.
    public static func get(_ c: S3Config, key: String, fetch: Fetch) async throws -> Data? {
        let (data, response) = try await fetch(try request(c, method: "GET", key: key, body: nil))
        let code = status(response)
        if code == 404 { return nil }
        guard (200..<300).contains(code) else { throw Failure.http("GET", code) }
        return data
    }

    public struct Head: Sendable, Equatable {
        public let size: Int
        /// Hex MD5 for a single-part PUT (which is all this does), without
        /// quotes; anything else is not usable as a content check.
        public let etag: String?
    }

    /// Size and etag, or nil when the object is not there.
    public static func head(_ c: S3Config, key: String, fetch: Fetch) async throws -> Head? {
        let (_, response) = try await fetch(try request(c, method: "HEAD", key: key, body: nil))
        let code = status(response)
        if code == 404 { return nil }
        guard (200..<300).contains(code), let http = response as? HTTPURLResponse else {
            throw Failure.http("HEAD", code)
        }
        let size = Int(http.value(forHTTPHeaderField: "Content-Length") ?? "") ?? -1
        let etag = http.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        return Head(size: size, etag: etag)
    }

    public static func delete(_ c: S3Config, key: String, fetch: Fetch) async throws {
        let (_, response) = try await fetch(try request(c, method: "DELETE", key: key, body: nil))
        let code = status(response)
        guard (200..<300).contains(code) || code == 404 else { throw Failure.http("DELETE", code) }
    }
}
