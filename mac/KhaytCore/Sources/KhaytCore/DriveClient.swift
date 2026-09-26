import Foundation
import CryptoKit

/// Google Drive as the print library's remote copy — `lib/gdrive-client.js`,
/// on the Mac, deliberately the same where the two meet:
///
/// * the `drive.file` scope, and nothing wider: this app sees only the files
///   it (or the other app, through the SAME OAuth client) created there;
/// * one app folder, found by name, and every file in it tagged
///   `appProperties.khaytKey` with the S3-style key it would have had — so a
///   model moved out by either app is found by the other with one query;
/// * `md5Checksum` reported as the etag, so the tiering rule's `etagVerdict`
///   proves a Drive upload exactly as it proves a bucket's.
///
/// The shop's OWN Google Cloud client id is used, as the other app does:
/// `drive.file` is per client, so a Mac signing in through a different client
/// would see an empty Drive where the other app's models are.
///
/// Pure of the network: `fetch` is injected, as `S3` does it.
public actor DriveClient {

    public static let scope = "https://www.googleapis.com/auth/drive.file"
    static let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenURL = "https://oauth2.googleapis.com/token"
    static let api = "https://www.googleapis.com/drive/v3"
    static let upload = "https://www.googleapis.com/upload/drive/v3"

    public struct Config: Sendable, Equatable {
        public var clientId: String
        public var clientSecret: String
        public var refreshToken: String
        public var folderName: String
        public init(clientId: String, clientSecret: String = "", refreshToken: String,
                    folderName: String = "") {
            self.clientId = clientId; self.clientSecret = clientSecret
            self.refreshToken = refreshToken; self.folderName = folderName
        }
        /// `isConfigured` in the other app: an id and a refresh token.
        public var isConfigured: Bool {
            !clientId.trimmingCharacters(in: .whitespaces).isEmpty
                && !refreshToken.trimmingCharacters(in: .whitespaces).isEmpty
        }
        var folder: String {
            let n = folderName.trimmingCharacters(in: .whitespaces)
            return n.isEmpty ? "Khayt print library" : n
        }
    }

    public enum Failure: Error, Equatable {
        /// Google's own words — "redirect_uri_mismatch", "invalid_grant" —
        /// which tell the shop exactly what to fix in their console.
        case google(String)
        case http(String, Int)
        case noAccessToken
        case noUploadURL
        case noFolder
    }

    let config: Config
    let fetch: S3.Fetch
    let now: @Sendable () -> Date
    private var access = ""
    private var expires = Date.distantPast
    private var folderId: String?

    public init(_ config: Config, fetch: @escaping S3.Fetch, now: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config
        self.fetch = fetch
        self.now = now
    }

    // MARK: - Signing in (static: no client exists until it has succeeded)

    /// A PKCE verifier and its S256 challenge. A desktop app cannot keep a
    /// client secret; PKCE is what makes a stolen redirect worthless.
    public static func pkce() -> (verifier: String, challenge: String) {
        // SystemRandomNumberGenerator is the platform's cryptographic source.
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<48).map { _ in UInt8.random(in: 0...255, using: &rng) }
        let verifier = base64url(Data(bytes))
        return (verifier, challenge(for: verifier))
    }

    /// S256: base64url of the verifier's SHA-256 (RFC 7636 §4.2).
    public static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// Where to send the browser. `access_type=offline` with `prompt=consent`
    /// is what makes Google hand back a refresh token every time.
    public static func authorizeURL(clientId: String, redirectURI: String, challenge: String, state: String) -> URL {
        var c = URLComponents(string: authURL)!
        c.queryItems = [
            .init(name: "client_id", value: clientId.trimmingCharacters(in: .whitespaces)),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
            .init(name: "state", value: state),
        ]
        return c.url!
    }

    /// Swap the one-time code for tokens; the refresh token is what is kept.
    public static func exchange(code: String, verifier: String, redirectURI: String,
                                clientId: String, clientSecret: String,
                                fetch: S3.Fetch) async throws -> (refreshToken: String?, accessToken: String) {
        var form = ["client_id": clientId.trimmingCharacters(in: .whitespaces), "code": code,
                    "code_verifier": verifier, "grant_type": "authorization_code", "redirect_uri": redirectURI]
        if !clientSecret.isEmpty { form["client_secret"] = clientSecret }
        let body = try await postForm(tokenURL, form, fetch: fetch)
        guard let access = body["access_token"] as? String, !access.isEmpty else { throw Failure.noAccessToken }
        return (body["refresh_token"] as? String, access)
    }

    static func formBody(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(form.sorted { $0.key < $1.key }.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").utf8)
    }

    static func postForm(_ url: String, _ form: [String: String], fetch: S3.Fetch) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: url)!, timeoutInterval: 30)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = formBody(form)
        let (data, response) = try await fetch(r)
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = S3.status(response)
        guard (200..<300).contains(code) else {
            throw Failure.google((body["error_description"] as? String) ?? (body["error"] as? String) ?? "HTTP \(code)")
        }
        return body
    }

    // MARK: - Talking to Drive

    /// A valid access token, refreshed a minute before it would expire — a
    /// token that runs out mid-upload fails a 400 MB model at the end.
    func token() async throws -> String {
        if !access.isEmpty, now() < expires.addingTimeInterval(-60) { return access }
        var form = ["client_id": config.clientId.trimmingCharacters(in: .whitespaces),
                    "refresh_token": config.refreshToken, "grant_type": "refresh_token"]
        if !config.clientSecret.isEmpty { form["client_secret"] = config.clientSecret }
        let body = try await Self.postForm(Self.tokenURL, form, fetch: fetch)
        guard let t = body["access_token"] as? String, !t.isEmpty else { throw Failure.noAccessToken }
        access = t
        expires = now().addingTimeInterval((body["expires_in"] as? Double) ?? 3600)
        return t
    }

    func request(_ url: String, method: String = "GET", json: Any? = nil,
                 timeout: TimeInterval = 120) async throws -> URLRequest {
        var r = URLRequest(url: URL(string: url)!, timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        if let json {
            r.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return r
    }

    func object(_ r: URLRequest, _ what: String) async throws -> [String: Any] {
        let (data, response) = try await fetch(r)
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = S3.status(response)
        guard (200..<300).contains(code) else {
            if let e = body["error"] as? [String: Any], let m = e["message"] as? String { throw Failure.google(m) }
            throw Failure.http(what, code)
        }
        return body
    }

    /// Drive's query language quotes with `'` and escapes it with `\`.
    static func quoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    static func query(_ q: String, fields: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return "\(api)/files?q=\(q.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
            + "&fields=\(fields)&pageSize=1"
    }

    /// The app's folder: found by name (not trashed), made on first use.
    func ensureFolder() async throws -> String {
        if let folderId { return folderId }
        let q = "mimeType='application/vnd.google-apps.folder' and name=\(Self.quoted(config.folder)) and trashed=false"
        let found = try await object(try await request(Self.query(q, fields: "files(id)")), "folder")
        if let files = found["files"] as? [[String: Any]], let id = files.first?["id"] as? String {
            folderId = id; return id
        }
        let made = try await object(try await request("\(Self.api)/files?fields=id", method: "POST",
                                                      json: ["name": config.folder,
                                                             "mimeType": "application/vnd.google-apps.folder"]),
                                    "folder")
        guard let id = made["id"] as? String, !id.isEmpty else { throw Failure.noFolder }
        folderId = id
        return id
    }

    struct Found { let id: String; let size: Int; let md5: String? }

    /// The file carrying this key — one indexed query, no path walking.
    func find(_ key: String) async throws -> Found? {
        let q = "appProperties has { key='khaytKey' and value=\(Self.quoted(key)) } and trashed=false"
        let r = try await object(try await request(Self.query(q, fields: "files(id,size,md5Checksum)")), "find")
        guard let f = (r["files"] as? [[String: Any]])?.first, let id = f["id"] as? String else { return nil }
        let size = Int((f["size"] as? String) ?? "") ?? (f["size"] as? Int) ?? 0
        return Found(id: id, size: size, md5: f["md5Checksum"] as? String)
    }

    /// Resumable upload, sent in one request: Drive's simple upload stops at
    /// 5 MB, which most models clear on their own.
    public func put(_ key: String, data: Data) async throws {
        let parent = try await ensureFolder()
        let existing = try await find(key)
        let name = key.split(separator: "/").last.map(String.init) ?? "model"
        let meta: [String: Any] = existing == nil
            ? ["name": name, "parents": [parent], "appProperties": ["khaytKey": key]]
            : ["name": name]
        let start = try await request("\(Self.upload)/files\(existing.map { "/\($0.id)" } ?? "")?uploadType=resumable&fields=id",
                                      method: existing == nil ? "POST" : "PATCH", json: meta)
        let (_, startResponse) = try await fetch(start)
        guard (200..<300).contains(S3.status(startResponse)) else {
            throw Failure.http("upload start", S3.status(startResponse))
        }
        guard let location = (startResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"),
              let url = URL(string: location) else { throw Failure.noUploadURL }
        var body = URLRequest(url: url, timeoutInterval: 600)
        body.httpMethod = "PUT"
        body.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        body.httpBody = data
        let (_, response) = try await fetch(body)
        guard (200..<300).contains(S3.status(response)) else { throw Failure.http("upload", S3.status(response)) }
    }

    /// The bytes, or nil when nothing carries that key.
    public func get(_ key: String) async throws -> Data? {
        guard let f = try await find(key) else { return nil }
        let (data, response) = try await fetch(try await request("\(Self.api)/files/\(f.id)?alt=media", timeout: 600))
        let code = S3.status(response)
        if code == 404 { return nil }
        guard (200..<300).contains(code) else { throw Failure.http("download", code) }
        return data
    }

    /// Size and MD5, in the S3 client's shape.
    public func head(_ key: String) async throws -> S3.Head? {
        guard let f = try await find(key) else { return nil }
        return S3.Head(size: f.size, etag: f.md5)
    }

    /// To Drive's trash, not gone: Drive has an undo, so this uses it.
    public func delete(_ key: String) async throws {
        guard let f = try await find(key) else { return }
        _ = try await object(try await request("\(Self.api)/files/\(f.id)", method: "PATCH", json: ["trashed": true]),
                             "trash")
    }

    /// Every file in the app's folder whose key starts with `keyPrefix`, in
    /// the bucket's listing shape. `nameContains` narrows the query on Drive's
    /// side (a key's last segment is the file's name); the key prefix is then
    /// checked here, against the `khaytKey` each file was tagged with.
    public func list(keyPrefix: String, nameContains: String) async throws -> [S3.Listed] {
        let parent = try await ensureFolder()
        var q = "\(Self.quoted(parent)) in parents and trashed=false"
        if !nameContains.isEmpty { q += " and name contains \(Self.quoted(nameContains))" }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let base = "\(Self.api)/files?q=\(q.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
            + "&fields=nextPageToken,files(id,size,modifiedTime,appProperties)&pageSize=1000"
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out: [S3.Listed] = []
        var page: String?
        for _ in 0..<50 {
            let url = base + (page.map { "&pageToken=\($0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" } ?? "")
            let r = try await object(try await request(url), "list")
            for f in (r["files"] as? [[String: Any]]) ?? [] {
                guard let key = (f["appProperties"] as? [String: Any])?["khaytKey"] as? String,
                      key.hasPrefix(keyPrefix) else { continue }
                let size = Int((f["size"] as? String) ?? "") ?? (f["size"] as? Int) ?? 0
                out.append(S3.Listed(key: key, size: size,
                                     modified: (f["modifiedTime"] as? String).flatMap(stamp.date(from:))))
            }
            guard let next = r["nextPageToken"] as? String, !next.isEmpty else { return out }
            page = next
        }
        return out
    }

    /// Who is signed in, and how full their Drive is (nil limit: unlimited).
    public func about() async throws -> (email: String, usage: Double, limit: Double?) {
        let r = try await object(try await request("\(Self.api)/about?fields=user(emailAddress),storageQuota(limit,usage)"),
                                 "about")
        let user = r["user"] as? [String: Any]
        let quota = r["storageQuota"] as? [String: Any]
        return ((user?["emailAddress"] as? String) ?? "",
                Double((quota?["usage"] as? String) ?? "") ?? 0,
                (quota?["limit"] as? String).flatMap(Double.init))
    }
}

/// Wherever the library's remote copy lives: a bucket or a Drive. The same
/// four calls over the same opaque keys, so backing up, freeing space and
/// bringing back are written once — as `printLibRemote()` in the other app.
public enum LibraryRemote: Sendable {
    case bucket(S3Config)
    case drive(DriveClient)

    public func put(_ key: String, data: Data, fetch: S3.Fetch) async throws {
        switch self {
        case .bucket(let c): try await S3.put(c, key: key, data: data, fetch: fetch)
        case .drive(let d): try await d.put(key, data: data)
        }
    }
    public func get(_ key: String, fetch: S3.Fetch) async throws -> Data? {
        switch self {
        case .bucket(let c): try await S3.get(c, key: key, fetch: fetch)
        case .drive(let d): try await d.get(key)
        }
    }
    public func head(_ key: String, fetch: S3.Fetch) async throws -> S3.Head? {
        switch self {
        case .bucket(let c): try await S3.head(c, key: key, fetch: fetch)
        case .drive(let d): try await d.head(key)
        }
    }
    public func delete(_ key: String, fetch: S3.Fetch) async throws {
        switch self {
        case .bucket(let c): try await S3.delete(c, key: key, fetch: fetch)
        case .drive(let d): try await d.delete(key)
        }
    }
}
