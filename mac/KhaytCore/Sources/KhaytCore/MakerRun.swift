import Foundation

/// MakerRun on the Mac: the public catalogue, a design's files, the download
/// into the library, and publishing a library file as a new listing.
///
/// ── THE SAME CONTRACT THE DESKTOP SPEAKS ──────────────────────────────────
///
/// This is the Swift side of `lib/makerrun-v1.js`, `lib/makerrun-catalog.js`,
/// `lib/makerrun-publish.js` and `lib/makerrun-account.js` — the files Bed
/// Ready's main process runs. Those cannot run here: they are built on Node's
/// `fetch`, `FormData`, `fs` and `crypto`, none of which JavaScriptCore has.
/// So the TRANSPORT is ported, line for line where it decides something, and
/// pinned by `MakerRunTests` against the same cases the desktop's tests use.
/// The vocabularies (categories, licences, materials, the licence mapping)
/// are NOT ported: they are `lib/makerrun-terms.js`, read through the engine
/// (`KhaytEngine.makerRunTerms`).
///
/// `/api/app-token`, `/api/library` and `/api/v1` are MakerRun's stable
/// contract and nothing here changes them.
///
/// ── WHAT IS BRANCHED ON ───────────────────────────────────────────────────
///
/// `error.code`, never the status (403 is three different answers, 503 two).
/// A design's `listingKind` — "hosted", "linked", "print" or nil — never
/// `external` or a missing download URL.
///
/// ── THE TOKEN ─────────────────────────────────────────────────────────────
///
/// A Supabase refresh token, exchanged at `/api/app-token` for an access token
/// and ROTATED on every exchange: replaying a used one revokes the session.
/// So refreshes are single-flighted (`MakerRunClient.accessToken`), and the
/// store is told which refresh token it is clearing, so a 401 on a token a
/// racing refresh already replaced cannot sign the Mac out. It is never
/// logged and never leaves `MakerRunTokenStore`.
public enum MakerRun {

    public static let base = URL(string: "https://makerrun.com")!

    /// Where a shop connects the app to its account. The page shows a code to
    /// copy when the app cannot be opened by link.
    public static func signInURL(base: URL = base) -> URL { base.appendingPathComponent("app-link") }

    /// A design's page on the website, where the Buy button and the full
    /// gallery live.
    public static func pageURL(slug: String, base: URL = base) -> URL? {
        guard validSlug(slug) else { return nil }
        return base.appendingPathComponent("designs").appendingPathComponent(slug)
    }

    // MARK: - Limits (MakerRun's own, mirrored so a refusal costs no request)

    public static let listDefault = 24
    public static let listMax = 100
    public static let maxQueryChars = 200
    public static let maxModelBytes = 100 * 1024 * 1024
    public static let modelExtensions = ["3mf", "stl", "obj", "step", "stp"]
    public static let maxImagesPerRequest = 8
    public static let maxImageBytes = 15 * 1024 * 1024
    public static let imageTypes = ["image/jpeg", "image/png", "image/webp"]
    public static let maxTitle = 120
    public static let maxDescription = 20000
    /// One design file, downloaded (`makerrun-library.js` MAX_FILE_BYTES).
    public static let maxFileBytes = 512 * 1024 * 1024
    public static let maxCoverBytes = 4 * 1024 * 1024
    public static let readTimeout: TimeInterval = 30
    public static let uploadTimeoutBase: TimeInterval = 120
    public static let uploadTimeoutMax: TimeInterval = 30 * 60
    public static let uploadFloorBytesPerSecond = 256.0 * 1024

    /// How long an upload of `bytes` may take: 120 s, plus a second per 256 KiB,
    /// at most 30 minutes (`makerrun-v1.js` uploadTimeoutFor).
    public static func uploadTimeout(bytes: Int) -> TimeInterval {
        let n = Double(max(0, bytes))
        return min(uploadTimeoutMax, (uploadTimeoutBase + n / uploadFloorBytesPerSecond).rounded())
    }

    // MARK: - Errors

    public struct Detail: Codable, Sendable, Hashable {
        public let field: String
        public let message: String
        public init(field: String, message: String) { self.field = field; self.message = message }
    }

    /// A refusal with a code the screen branches on: `mfa_required`,
    /// `age_required`, `relink`, `not_linked`, `maintenance`, `invalid`,
    /// `rate_limited`, `timeout`, `network`, `bad_response`, …
    public struct Failure: Error, Sendable, Equatable, CustomStringConvertible {
        public let code: String
        public let message: String
        public var status: Int = 0
        public var details: [Detail] = []
        public var retryAfter: Int?
        public init(_ code: String, _ message: String, status: Int = 0, details: [Detail] = [], retryAfter: Int? = nil) {
            self.code = code; self.message = message; self.status = status
            self.details = details; self.retryAfter = retryAfter
        }
        public var description: String { message }
    }

    static let fallback: [String: String] = [
        "unauthorized": "Your MakerRun session expired — sign in again.",
        "forbidden": "MakerRun refused that request.",
        "rejected": "MakerRun refused that request.",
        "not_found": "MakerRun could not find that design.",
        "conflict": "That listing cannot accept this change in its current state.",
        "invalid": "MakerRun rejected some of the fields.",
        "mfa_required": "This MakerRun account has two-factor authentication on, and this sign-in has not completed it.",
        "age_required": "This design is marked 18+. Confirm your age on makerrun.com, then try again.",
        "rate_limited": "MakerRun is asking for a pause. Wait a minute and try again.",
        "unavailable": "MakerRun is unavailable right now. If it does not clear shortly, this needs reporting.",
        "bad_request": "MakerRun could not read that request.",
    ]

    static func statusFallbackCode(_ status: Int) -> String {
        switch status {
        case 401: "unauthorized"
        case 403: "forbidden"
        case 404: "not_found"
        case 409: "conflict"
        case 422: "invalid"
        case 429: "rate_limited"
        case 503: "unavailable"
        default: "http_\(status)"
        }
    }

    /// `makerrun-maintenance.js` retryAfterSeconds: whole seconds or an HTTP
    /// date, 1…3600, else 60.
    public static func retryAfterSeconds(_ header: String?, now: Date = Date()) -> Int {
        let raw = (header ?? "").trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { return 60 }
        if raw.allSatisfy({ $0.isASCII && $0.isNumber }) {
            let n = Int(raw) ?? 0
            return n > 0 && n <= 3600 ? n : 60
        }
        guard let at = httpDate(raw) else { return 60 }
        let secs = Int((at.timeIntervalSince(now)).rounded())
        return secs > 0 && secs <= 3600 ? secs : 60
    }

    static func httpDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return ISO8601DateFormatter().date(from: s)
    }

    public static func isMaintenance(status: Int, body: JSONValue?) -> Bool {
        guard status == 503, case .object(let o)? = body, case .object(let e)? = o["error"],
              case .string(let code)? = e["code"] else { return false }
        return code == "maintenance"
    }

    public static func maintenanceFailure(retryAfter: Int, status: Int = 503) -> Failure {
        let mins = max(1, Int((Double(retryAfter) / 60).rounded()))
        return Failure("maintenance",
                       "MakerRun is briefly unavailable for maintenance — try again in about \(mins) minute\(mins == 1 ? "" : "s").",
                       status: status, retryAfter: retryAfter)
    }

    static func cleanDetails(_ value: JSONValue?) -> [Detail] {
        guard case .array(let list)? = value else { return [] }
        return list.compactMap { item -> Detail? in
            guard case .object(let o) = item, case .string(let field)? = o["field"] else { return nil }
            if case .string(let m)? = o["message"] { return Detail(field: field, message: m) }
            return Detail(field: field, message: "")
        }.prefix(50).map { $0 }
    }

    /// `makerrun-v1.js` parseV1Error: a failing response as a coded refusal.
    public static func parseError(status: Int, body: JSONValue?, retryAfterHeader: String?,
                                  now: Date = Date()) -> Failure {
        if isMaintenance(status: status, body: body) {
            return maintenanceFailure(retryAfter: retryAfterSeconds(retryAfterHeader, now: now), status: status)
        }
        var env: [String: JSONValue]?
        if case .object(let o)? = body, case .object(let e)? = o["error"] { env = e }
        var code = ""
        if let env, case .string(let c)? = env["code"] { code = c }
        var details = cleanDetails(env?["details"])
        if code.isEmpty, case .object(let o)? = body, case .array = o["failures"] {
            code = "invalid"
            details = cleanDetails(o["failures"])
        }
        if code.isEmpty { code = statusFallbackCode(status) }
        var serverMessage = ""
        if let env, case .string(let m)? = env["message"] { serverMessage = m.trimmingCharacters(in: .whitespacesAndNewlines) }
        let message = !serverMessage.isEmpty ? serverMessage
            : (details.first.map(\.message).flatMap { $0.isEmpty ? nil : $0 }
               ?? fallback[code] ?? "MakerRun request failed (HTTP \(status)).")
        var failure = Failure(code, message, status: status, details: details)
        if code == "rate_limited" { failure.retryAfter = retryAfterSeconds(retryAfterHeader, now: now) }
        return failure
    }

    static func badResponse(_ what: String) -> Failure {
        Failure("bad_response", "MakerRun replied, but not with \(what) Khayt recognises. Try again shortly, and if it persists this needs reporting.")
    }

    // MARK: - Names and slugs

    /// Letters (any script) and numbers joined by hyphens or underscores.
    public static func validSlug(_ slug: String) -> Bool {
        guard !slug.isEmpty, slug.count <= 200, let first = slug.unicodeScalars.first else { return false }
        // `\p{L}` and `\p{N}`, as the desktop's pattern says: letters and
        // numbers of any script, and nothing else — not a combining mark.
        func letterOrNumber(_ u: Unicode.Scalar) -> Bool {
            switch u.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber: true
            default: false
            }
        }
        guard letterOrNumber(first) else { return false }
        return slug.unicodeScalars.allSatisfy { letterOrNumber($0) || $0 == "-" || $0 == "_" }
    }

    /// A filename as GET /designs/{slug} reports it.
    public static func validFilename(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 255 else { return false }
        if name.contains("/") || name.contains("\\") || name.contains("\u{0}") { return false }
        return !name.allSatisfy { $0 == "." }
    }

    /// `makerrun-library.js` safeBase: a title as a filename base.
    public static func safeBase(_ title: String?) -> String {
        let s = title ?? "design"
        var out = ""
        var lastUnderscore = false
        for u in s.unicodeScalars {
            let ok = (u.value < 128) && (CharacterSet.alphanumerics.contains(u) || u == "." || u == "_" || u == "-")
            if ok { out.unicodeScalars.append(u); lastUnderscore = false }
            else if !lastUnderscore { out.append("_"); lastUnderscore = true }
        }
        while out.hasPrefix("_") { out.removeFirst() }
        while out.hasSuffix("_") { out.removeLast() }
        let cut = String(out.prefix(60))
        return cut.isEmpty ? "design" : cut
    }

    /// `makerrun-library.js` extFor, from a filename: one of four model
    /// extensions, `.stp` written as `.step`, else `.3mf`.
    public static func extFor(filename: String?) -> String {
        let e = ((filename ?? "") as NSString).pathExtension.lowercased()
        if e == "stp" { return ".step" }
        return ["3mf", "stl", "obj", "step"].contains(e) ? "." + e : ".3mf"
    }

    /// `makerrun-publish.js` safeName: MakerRun's storage-safe filename rule.
    public static func safeName(_ name: String?, fallback: String) -> String {
        var out = ""
        for u in (name ?? "").unicodeScalars {
            let ok = u.value < 128 && (CharacterSet.alphanumerics.contains(u) || u == "." || u == "_" || u == "-")
            out.unicodeScalars.append(ok ? u : "_")
        }
        if out.isEmpty { out = fallback }
        if out.hasPrefix(".") {
            let dropped = out.drop { $0 == "." }
            out = "_" + dropped
        }
        let cut = String(out.prefix(120))
        return cut.isEmpty ? fallback : cut
    }

    /// The image type named from the bytes themselves, never from a filename.
    public static func sniffImageType(_ data: Data) -> String? {
        guard data.count >= 12 else { return nil }
        let b = [UInt8](data.prefix(12))
        if b[0] == 0xff, b[1] == 0xd8, b[2] == 0xff { return "image/jpeg" }
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4e, b[3] == 0x47 { return "image/png" }
        if b[0...3] == [0x52, 0x49, 0x46, 0x46], b[8...11] == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        return nil
    }

    // MARK: - The catalogue

    public struct Query: Sendable, Equatable {
        public var q = ""
        public var category = ""
        public var material = ""
        public var verified = false
        /// nil: either. true: for sale only. false: free only.
        public var forSale: Bool?
        public var limit = MakerRun.listDefault
        public var offset = 0
        public init() {}
    }

    /// `makerrun-catalog.js` buildListQuery. `categories` and `materials` are
    /// the terms module's — an unknown one is dropped, not sent.
    public static func listQuery(_ o: Query, categories: [String], materials: [String]) -> String {
        var items: [URLQueryItem] = []
        let q = String(o.q.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxQueryChars))
        if !q.isEmpty { items.append(URLQueryItem(name: "q", value: q)) }
        if categories.contains(o.category) { items.append(URLQueryItem(name: "category", value: o.category)) }
        if materials.contains(o.material) { items.append(URLQueryItem(name: "material", value: o.material)) }
        if o.verified { items.append(URLQueryItem(name: "verified", value: "true")) }
        if let forSale = o.forSale { items.append(URLQueryItem(name: "forSale", value: forSale ? "true" : "false")) }
        items.append(URLQueryItem(name: "limit", value: String(o.limit > 0 ? min(o.limit, listMax) : listDefault)))
        if o.offset > 0 { items.append(URLQueryItem(name: "offset", value: String(o.offset))) }
        var c = URLComponents()
        c.queryItems = items
        // URLComponents leaves `+` alone; URLSearchParams writes a space as `+`
        // and the server reads either. Encoded strictly so a `+` in a search is
        // a plus and not a space.
        return (c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
    }

    public struct Printer: Sendable, Hashable, Codable {
        public let brand: String?
        public let model: String?
        public var name: String { [brand, model].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ") }
    }

    public struct Verification: Sendable, Hashable, Codable {
        public let badge: Bool
        public let fileChecked: Bool
        public let printPhotoConfirmed: Bool
        public let printer: Printer?
    }

    public struct Sale: Sendable, Hashable, Codable {
        public let kind: String?
        public let price: Double?
        public let currency: String?
        public let provider: String?
    }

    /// One DesignDTO, narrowed to what the screen draws. The sale link is
    /// never kept: the design's page on makerrun.com is where Buy lives.
    public struct Design: Sendable, Hashable, Identifiable, Codable {
        public var id: String { slug }
        public let slug: String
        public let title: String
        public let description: String
        public let creator: String?
        public let license: String?
        public let category: String?
        public let material: String?
        public let colorCount: Double?
        public let nsfw: Bool
        public let createdAt: String?
        public let downloadCount: Double
        public let url: String?
        public let cover: String?
        public let coverAiGenerated: Bool
        /// "hosted", "linked", "print" or nil — what the listing IS.
        public let listingKind: String?
        public let verification: Verification
        public let sale: Sale?
    }

    static func optString(_ v: JSONValue?) -> String? { if case .string(let s)? = v { return s }; return nil }
    static func optNumber(_ v: JSONValue?) -> Double? {
        if case .number(let n)? = v, n.isFinite { return n }
        return nil
    }
    static func isTrue(_ v: JSONValue?) -> Bool { if case .bool(true)? = v { return true }; return false }
    static func https(_ v: JSONValue?) -> String? {
        guard let s = optString(v), s.lowercased().hasPrefix("https://") else { return nil }
        return s
    }
    static func object(_ v: JSONValue?) -> [String: JSONValue]? { if case .object(let o)? = v { return o }; return nil }

    /// `makerrun-catalog.js` normalizeDesign. A row that is not a design is
    /// refused, never skipped: a grid that drops rows is one nobody trusts.
    public static func design(_ value: JSONValue, materials: [String]) throws -> Design {
        guard let d = object(value), let slug = optString(d["slug"]), validSlug(slug),
              let title = optString(d["title"]) else { throw badResponse("a design") }
        let v = object(d["verification"]) ?? [:]
        let printer = object(v["printer"]).map { Printer(brand: optString($0["brand"]), model: optString($0["model"])) }
        let cover = object(d["cover"]) ?? [:]
        var sale: Sale?
        if let s = object(d["sale"]), let kind = optString(s["kind"]), !kind.isEmpty {
            sale = Sale(kind: kind, price: optNumber(s["price"]), currency: optString(s["currency"]),
                        provider: optString(s["provider"]))
        }
        let material = optString(d["material"]).flatMap { materials.contains($0) ? $0 : nil }
        return Design(
            slug: slug, title: title, description: optString(d["description"]) ?? "",
            creator: optString(d["creator"]), license: optString(d["license"]),
            category: optString(d["category"]), material: material,
            colorCount: optNumber(d["colorCount"]), nsfw: isTrue(d["nsfw"]),
            createdAt: optString(d["createdAt"]), downloadCount: optNumber(d["downloadCount"]) ?? 0,
            url: https(d["url"]), cover: https(cover["url"]), coverAiGenerated: isTrue(cover["aiGenerated"]),
            listingKind: optString(d["listingKind"]),
            verification: Verification(badge: isTrue(v["badge"]), fileChecked: isTrue(v["fileChecked"]),
                                       printPhotoConfirmed: isTrue(v["printPhotoConfirmed"]), printer: printer),
            sale: sale)
    }

    public struct Page: Sendable, Equatable {
        public let limit: Int
        public let offset: Int
        public let total: Int
        public let returned: Int
    }

    public struct DesignList: Sendable {
        public let designs: [Design]
        public let page: Page
    }

    public static func designList(_ body: JSONValue, materials: [String]) throws -> DesignList {
        guard let o = object(body), case .array(let rows)? = o["designs"], let pg = object(o["page"]),
              let total = optNumber(pg["total"]) else { throw badResponse("a design list") }
        let designs = try rows.map { try design($0, materials: materials) }
        return DesignList(designs: designs, page: Page(
            limit: Int(optNumber(pg["limit"]) ?? Double(designs.count)),
            offset: Int(optNumber(pg["offset"]) ?? 0),
            total: Int(total),
            returned: Int(optNumber(pg["returned"]) ?? Double(designs.count))))
    }

    public struct File: Sendable, Hashable, Identifiable {
        public var id: String { filename }
        public let filename: String
        public let sizeBytes: Double?
        public let hosted: Bool
    }

    public struct Image: Sendable, Hashable {
        public let url: String
        public let kind: String
        public let printConfirmed: Bool
    }

    public struct Profile: Sendable, Hashable {
        public let printerBrand: String?
        public let printerModel: String?
        public let filamentType: String?
        public let colorCount: Double?
        public let badge: Bool
        public let fileChecked: Bool
        public let printPhotoConfirmed: Bool
    }

    public struct DesignDetail: Sendable {
        public let design: Design
        public let files: [File]
        public let images: [Image]
        public let profiles: [Profile]
        /// The files that can come into the library: the ones MakerRun hosts.
        public var downloadable: [File] { files.filter(\.hosted) }
    }

    public static func designDetail(_ body: JSONValue, materials: [String]) throws -> DesignDetail {
        guard let o = object(body), let d = o["design"], case .array(let files)? = o["files"],
              case .array(let images)? = o["images"], case .array(let profiles)? = o["profiles"] else {
            throw badResponse("a design")
        }
        let fileRows = try files.map { f -> File in
            guard let fo = object(f), let name = optString(fo["filename"]) else { throw badResponse("a file list") }
            return File(filename: name, sizeBytes: optNumber(fo["sizeBytes"]), hosted: isTrue(fo["hosted"]))
        }
        let imageRows = images.compactMap { i -> Image? in
            guard let io = object(i), let url = https(io["url"]) else { return nil }
            return Image(url: url, kind: optString(io["kind"]) ?? "gallery", printConfirmed: isTrue(io["printConfirmed"]))
        }
        let profileRows = profiles.compactMap { p -> Profile? in
            guard let po = object(p) else { return nil }
            return Profile(printerBrand: optString(po["printerBrand"]), printerModel: optString(po["printerModel"]),
                           filamentType: optString(po["filamentType"]), colorCount: optNumber(po["colorCount"]),
                           badge: isTrue(po["badge"]), fileChecked: isTrue(po["fileChecked"]),
                           printPhotoConfirmed: isTrue(po["printPhotoConfirmed"]))
        }
        return DesignDetail(design: try design(d, materials: materials), files: fileRows,
                            images: imageRows, profiles: profileRows)
    }

    // MARK: - Publishing

    /// What the publish form sends. Only these keys reach the body: a sale
    /// field or a `status` cannot be sent by mistake.
    public struct CreateInput: Sendable, Equatable {
        public var title = ""
        public var description = ""
        public var category = ""
        public var material = ""
        public var license = ""
        public var nsfw = false
        public init() {}
    }

    /// `makerrun-publish.js` validateCreateInput.
    public static func validate(_ i: CreateInput, categories: [String], materials: [String],
                                licences: [String]) -> (errors: [Detail], body: [String: JSONValue]) {
        var errors: [Detail] = []
        var body: [String: JSONValue] = [:]
        let title = i.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { errors.append(Detail(field: "title", message: "A title is required.")) }
        else if title.count > maxTitle { errors.append(Detail(field: "title", message: "The title must be \(maxTitle) characters or fewer.")) }
        else { body["title"] = .string(title) }
        let description = i.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if description.count > maxDescription { errors.append(Detail(field: "description", message: "The description is too long.")) }
        else if !description.isEmpty { body["description"] = .string(description) }
        if !categories.contains(i.category) { errors.append(Detail(field: "category", message: "Choose a category.")) }
        else { body["category"] = .string(i.category) }
        if !i.material.isEmpty {
            if !materials.contains(i.material) { errors.append(Detail(field: "material", message: "Choose rigid, flexible or multi-material.")) }
            else { body["material"] = .string(i.material) }
        }
        if !licences.contains(i.license) { errors.append(Detail(field: "license", message: "Choose a licence MakerRun offers.")) }
        else { body["license"] = .string(i.license) }
        body["nsfw"] = .bool(i.nsfw)
        return (errors, body)
    }

    /// `makerrun-publish.js` checkModel: refusals for a model file, no network.
    public static func checkModel(filename: String, size: Int) -> Detail? {
        let ext = (filename as NSString).pathExtension.lowercased()
        if !modelExtensions.contains(ext) {
            return Detail(field: "file", message: "MakerRun accepts .3mf, .stl, .obj, .step, .stp files.")
        }
        if size <= 0 { return Detail(field: "file", message: "That file is empty.") }
        if size > maxModelBytes { return Detail(field: "file", message: "MakerRun accepts model files up to 100 MB.") }
        return nil
    }

    /// The publish form's material guess from a record's material
    /// (`bedready-makerrun.js` guessMaterial).
    public static func guessMaterial(_ m: String?) -> String {
        let s = (m ?? "").lowercased()
        if s.isEmpty { return "" }
        if s.contains("tpu") || s.contains("tpe") || s.contains("flex") { return "flexible" }
        return "rigid"
    }

    /// A listing being made, as the record keeps it (`rec.makerrunListing`):
    /// each step is written before the next starts, so a failure — or a quit —
    /// leaves a record that knows what exists on MakerRun.
    public struct Created: Sendable, Equatable {
        public let slug: String
        public let status: String
        public let url: String?
    }

    public struct UploadVerification: Sendable, Equatable {
        public let verified: Bool
        public let printer: String?
        public let brand: String?
        public let reason: String?
    }

    public struct Uploaded: Sendable, Equatable {
        public let verification: UploadVerification
        public let status: String
    }

    public struct ImagesStored: Sendable, Equatable {
        public let stored: Int
        public let failures: [String]
    }

    public struct Mine: Sendable, Equatable {
        public let slug: String
        public let title: String
        public let status: String?
        public let createdAt: String?
        public let badge: Bool?
        public let fileChecked: Bool?
    }

    public struct ListingStatus: Sendable, Equatable {
        public let found: Bool
        public let status: String?
        public let badge: Bool?
        public let fileChecked: Bool?
        /// False when the listing was not among the ones read — never "gone".
        public let complete: Bool
        public let searched: Int
    }

    static func mine(_ v: JSONValue) -> Mine? {
        guard let d = object(v), let slug = optString(d["slug"]), validSlug(slug) else { return nil }
        let ver = object(d["verification"])
        return Mine(slug: slug, title: optString(d["title"]) ?? "", status: optString(d["status"]),
                    createdAt: optString(d["createdAt"]),
                    badge: ver.map { isTrue($0["badge"]) }, fileChecked: ver.map { isTrue($0["fileChecked"]) })
    }

    // MARK: - Multipart

    /// One part of a multipart body.
    public struct Part: Sendable {
        public let name: String
        public let filename: String?
        public let type: String?
        public let data: Data
        public init(name: String, filename: String? = nil, type: String? = nil, data: Data) {
            self.name = name; self.filename = filename; self.type = type; self.data = data
        }
    }

    public static func multipart(_ parts: [Part], boundary: String) -> Data {
        var out = Data()
        func line(_ s: String) { out.append(Data((s + "\r\n").utf8)) }
        for p in parts {
            line("--" + boundary)
            if let filename = p.filename {
                let safe = filename.replacingOccurrences(of: "\"", with: "_")
                line("Content-Disposition: form-data; name=\"\(p.name)\"; filename=\"\(safe)\"")
                line("Content-Type: " + (p.type ?? "application/octet-stream"))
            } else {
                line("Content-Disposition: form-data; name=\"\(p.name)\"")
            }
            line("")
            out.append(p.data)
            line("")
        }
        line("--" + boundary + "--")
        return out
    }

    // MARK: - Download addresses

    /// May a design file be fetched from here? HTTPS, and not a loopback,
    /// private, link-local or metadata address — by name or by any address
    /// the name resolves to (the desktop's `assertSafeDownloadUrl`).
    public static func safeDownloadHost(_ url: URL, resolve: Bool = true) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal") {
            return false
        }
        if let literal = blockedLiteral(host) { return !literal }
        guard resolve else { return true }
        return !resolvesToBlocked(host)
    }

    /// Nil when `host` is not an IP literal; else whether it is blocked.
    static func blockedLiteral(_ host: String) -> Bool? {
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var v4 = in_addr()
        if inet_pton(AF_INET, h, &v4) == 1 { return blockedV4(UInt32(bigEndian: v4.s_addr)) }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, h, &v6) == 1 { return blockedV6(v6) }
        return nil
    }

    static func blockedV4(_ a: UInt32) -> Bool {
        let b0 = a >> 24, b1 = (a >> 16) & 0xff
        if b0 == 0 || b0 == 10 || b0 == 127 { return true }
        if b0 == 169 && b1 == 254 { return true }
        if b0 == 172 && (16...31).contains(b1) { return true }
        if b0 == 192 && b1 == 168 { return true }
        if b0 == 100 && (64...127).contains(b1) { return true }
        if b0 >= 224 { return true }
        return false
    }

    static func blockedV6(_ a: in6_addr) -> Bool {
        let b = withUnsafeBytes(of: a) { [UInt8]($0) }
        if b.allSatisfy({ $0 == 0 }) { return true }
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }
        if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true }
        if (b[0] & 0xfe) == 0xfc { return true }
        if b[0] == 0xff { return true }
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
            let v4 = UInt32(b[12]) << 24 | UInt32(b[13]) << 16 | UInt32(b[14]) << 8 | UInt32(b[15])
            return blockedV4(v4)
        }
        return false
    }

    /// Blocking: a DNS lookup. Called only off the main thread, by a download.
    static func resolvesToBlocked(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return false }
        defer { freeaddrinfo(first) }
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            if ai.pointee.ai_family == AF_INET, let sa = ai.pointee.ai_addr {
                let a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                if blockedV4(UInt32(bigEndian: a.s_addr)) { return true }
            } else if ai.pointee.ai_family == AF_INET6, let sa = ai.pointee.ai_addr {
                let a = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                if blockedV6(a) { return true }
            }
            p = ai.pointee.ai_next
        }
        return false
    }
}

// MARK: - The account

/// The linked account's tokens. Kept by the app (the Keychain), never logged.
public struct MakerRunTokens: Sendable, Equatable, Codable {
    public var access: String
    public var refresh: String
    /// Unix seconds; 0 is "unknown".
    public var expires: Double
    public init(access: String, refresh: String, expires: Double) {
        self.access = access; self.refresh = refresh; self.expires = expires
    }

    /// `makerrun-account.js` normExpiresSeconds: seconds, even when a server
    /// sends milliseconds.
    public static func normExpires(_ v: Double?) -> Double {
        guard let n = v, n.isFinite, n > 0 else { return 0 }
        return n > 1e12 ? (n / 1000).rounded(.down) : n
    }
}

public protocol MakerRunTokenStore: Sendable {
    func load() async -> MakerRunTokens?
    func save(_ tokens: MakerRunTokens) async
    /// Forget the link — but only while `refresh` is still the one stored,
    /// when it is given: a refresh that raced ahead may have rotated in a new
    /// one, and that live session must not be clobbered.
    func clear(onlyIf refresh: String?) async
}

/// The MakerRun API, for one Mac's linked account.
public actor MakerRunClient {
    public let base: URL
    let session: URLSession
    let store: MakerRunTokenStore
    /// The terms module's lists, for narrowing and validating. Empty is
    /// "unknown", which drops every category and material from a query.
    public var categories: [String] = []
    public var materials: [String] = []
    public var licences: [String] = []
    private var refreshing: Task<String, Error>?
    let now: @Sendable () -> Date

    public init(base: URL = MakerRun.base, session: URLSession = .shared, store: MakerRunTokenStore,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.base = base
        self.session = session
        self.store = store
        self.now = now
    }

    public func setTerms(categories: [String], materials: [String], licences: [String]) {
        self.categories = categories; self.materials = materials; self.licences = licences
    }

    // MARK: Account

    public func isLinked() async -> Bool { !((await store.load())?.refresh ?? "").isEmpty }

    /// Link with the code makerrun.com/app-link shows (the refresh token):
    /// exchanged at once, so a mistyped code is said now and not at the first
    /// download.
    public func link(code: String) async throws {
        let refresh = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refresh.isEmpty, refresh.count < 4096, !refresh.contains(where: \.isWhitespace) else {
            throw MakerRun.Failure("invalid", "That is not a MakerRun connection code.")
        }
        await store.save(MakerRunTokens(access: "", refresh: refresh, expires: 0))
        do { _ = try await accessToken(force: true) }
        catch {
            await store.clear(onlyIf: refresh)
            throw error
        }
    }

    public func unlink() async { await store.clear(onlyIf: nil) }

    /// A valid access token, refreshed when within 60 s of expiry or when
    /// `force`d. Concurrent refreshes share ONE request: the refresh token
    /// rotates, and replaying a used one revokes the session.
    public func accessToken(force: Bool = false) async throws -> String {
        guard let t = await store.load(), !t.refresh.isEmpty else {
            throw MakerRun.Failure("not_linked", "Not linked. Connect the app from makerrun.com/app-link.")
        }
        let nowSecs = now().timeIntervalSince1970
        if !force, !t.access.isEmpty, t.expires > 0, t.expires - nowSecs > 60 { return t.access }
        if let refreshing { return try await refreshing.value }
        let task = Task { try await self.doRefresh(t.refresh, nowSecs: nowSecs) }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func doRefresh(_ used: String, nowSecs: Double) async throws -> String {
        var req = URLRequest(url: base.appendingPathComponent("api/app-token"), timeoutInterval: MakerRun.readTimeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONValue.encode(.object(["refresh_token": .string(used)]))
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: req) }
        catch { throw Self.transportFailure(error) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after")
        if status == 401 {
            await store.clear(onlyIf: used)
            throw MakerRun.Failure("relink", "Your MakerRun link expired — connect the app again.", status: 401)
        }
        let body = try? JSONValue.parse(data)
        if MakerRun.isMaintenance(status: status, body: body) {
            throw MakerRun.maintenanceFailure(retryAfter: MakerRun.retryAfterSeconds(header, now: now()))
        }
        if status == 429 {
            throw MakerRun.Failure("rate_limited", "MakerRun is asking for a pause. Wait a minute and try again.",
                                   status: 429, retryAfter: MakerRun.retryAfterSeconds(header, now: now()))
        }
        if status >= 500 {
            throw MakerRun.Failure("unavailable", "MakerRun could not refresh your session right now (HTTP \(status)). Try again shortly.", status: status)
        }
        guard (200..<300).contains(status) else {
            throw MakerRun.Failure("auth", "Could not refresh your MakerRun session (HTTP \(status)).", status: status)
        }
        guard case .object(let o)? = body, case .string(let access)? = o["access_token"], !access.isEmpty else {
            throw MakerRun.Failure("auth", "Could not refresh your MakerRun session.")
        }
        var expires = MakerRunTokens.normExpires(MakerRun.optNumber(o["expires_at"]))
        if expires == 0 { expires = nowSecs + 3600 }
        let rotated = MakerRun.optString(o["refresh_token"]).flatMap { $0.isEmpty ? nil : $0 } ?? used
        await store.save(MakerRunTokens(access: access, refresh: rotated, expires: expires))
        return access
    }

    /// Run `body` with a token, retrying ONCE after a forced refresh on a 401.
    /// A second 401 cannot be fixed by retrying: `relink`.
    public func withToken<T: Sendable>(_ body: @Sendable (String) async throws -> T) async throws -> T {
        let token = try await accessToken()
        do { return try await body(token) }
        catch let f as MakerRun.Failure where f.code == "unauthorized" {}
        let fresh = try await accessToken(force: true)
        do { return try await body(fresh) }
        catch let f as MakerRun.Failure where f.code == "unauthorized" {
            throw MakerRun.Failure("relink", "MakerRun no longer accepts this sign-in. Connect the app to your MakerRun account again.", status: 401)
        }
    }

    // MARK: Transport

    static func transportFailure(_ error: Error) -> MakerRun.Failure {
        if let u = error as? URLError, u.code == .timedOut {
            return MakerRun.Failure("timeout", "MakerRun took too long to answer. Check your connection and try again.")
        }
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return MakerRun.Failure("cancelled", "Cancelled.")
        }
        return MakerRun.Failure("network", "Could not reach MakerRun. Check your connection and try again.")
    }

    /// One /v1 request: the parsed body of a 2xx, a coded refusal otherwise.
    func request(_ method: String, _ pathAndQuery: String, token: String? = nil,
                 json: JSONValue? = nil, parts: [MakerRun.Part]? = nil,
                 timeout: TimeInterval? = nil) async throws -> JSONValue {
        guard let url = URL(string: base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/v1" + pathAndQuery) else {
            throw MakerRun.Failure("bad_request", "MakerRun could not read that request.")
        }
        var req = URLRequest(url: url, timeoutInterval: timeout ?? (parts == nil ? MakerRun.readTimeout : MakerRun.uploadTimeoutBase))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "accept")
        if let token { req.setValue("Bearer " + token, forHTTPHeaderField: "authorization") }
        if let parts {
            let boundary = "khayt-" + UUID().uuidString
            req.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "content-type")
            req.httpBody = MakerRun.multipart(parts, boundary: boundary)
        } else if let json {
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONValue.encode(json)
        }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: req) }
        catch { throw Self.transportFailure(error) }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let body = try? JSONValue.parse(data)
        guard (200..<300).contains(status) else {
            throw MakerRun.parseError(status: status, body: body,
                                      retryAfterHeader: http?.value(forHTTPHeaderField: "retry-after"), now: now())
        }
        guard let body, case .object = body else {
            throw MakerRun.Failure("bad_response", "MakerRun replied, but not in a shape Khayt recognises. Try again shortly.")
        }
        return body
    }

    static func slugPath(_ slug: String) throws -> String {
        guard MakerRun.validSlug(slug),
              let enc = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) else {
            throw MakerRun.Failure("bad_request", "That is not a MakerRun design id.")
        }
        return "/designs/" + enc
    }

    // MARK: Catalogue

    /// GET /designs — public, no token.
    public func listDesigns(_ query: MakerRun.Query) async throws -> MakerRun.DesignList {
        let qs = MakerRun.listQuery(query, categories: categories, materials: materials)
        return try MakerRun.designList(try await request("GET", "/designs?" + qs), materials: materials)
    }

    /// GET /designs/{slug} — public.
    public func design(_ slug: String) async throws -> MakerRun.DesignDetail {
        try MakerRun.designDetail(try await request("GET", try Self.slugPath(slug)), materials: materials)
    }

    /// A design's file, into `dir`, named as the desktop names it
    /// (`safeBase(title)` + the model extension). Two steps: the 300-second
    /// signed link, fetched at once and never stored; then the bytes, over
    /// HTTPS from a public address only, at most 512 MB. Blocking work —
    /// the lookup and the write — runs on a queue, never the main thread.
    public func download(slug: String, filename: String, title: String, into dir: URL) async throws -> URL {
        guard MakerRun.validFilename(filename) else {
            throw MakerRun.Failure("bad_request", "That is not a file on this design.")
        }
        let path = try Self.slugPath(slug) + "/files/"
            + (filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? "")
            + "/download"
        let signed = try await withToken { token in try await self.request("GET", path, token: token) }
        guard let url = MakerRun.https(MakerRun.object(signed)?["url"]).flatMap(URL.init(string:)) else {
            throw MakerRun.badResponse("a download link")
        }
        let named = MakerRun.optString(MakerRun.object(signed)?["filename"]) ?? filename
        let dest = dir.appendingPathComponent(MakerRun.safeBase(title.isEmpty ? slug : title) + MakerRun.extFor(filename: named))
        try await fetch(url, to: dest, limit: MakerRun.maxFileBytes, label: title.isEmpty ? slug : title)
        return dest
    }

    /// A design's cover, at most 4 MB, from a public HTTPS address.
    public func cover(_ address: String) async throws -> Data {
        guard let url = URL(string: address) else { throw MakerRun.Failure("bad_request", "Not an address.") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mr-cover-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await fetch(url, to: tmp, limit: MakerRun.maxCoverBytes, label: "cover", timeout: 15)
        return try Data(contentsOf: tmp)
    }

    private func fetch(_ url: URL, to dest: URL, limit: Int, label: String,
                       timeout: TimeInterval = 120) async throws {
        let guardedSession = session
        let check: @Sendable (URL) -> Bool = { MakerRun.safeDownloadHost($0) }
        // The first hop is checked here, off the main thread (it looks the
        // name up); every redirect hop again in the delegate.
        let firstOK = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: check(url)) }
        }
        guard firstOK else { throw MakerRun.Failure("refused", "Refusing a download from a private or non-HTTPS address.") }
        let delegate = RedirectGuard(check: check)
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        let (tmp, response): (URL, URLResponse)
        do { (tmp, response) = try await guardedSession.download(for: req, delegate: delegate) }
        catch {
            if delegate.refused { throw MakerRun.Failure("refused", "Refusing a download from a private or non-HTTPS address.") }
            throw Self.transportFailure(error)
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw MakerRun.Failure("download", "Download failed for \"\(label)\" (HTTP \(status)).", status: status)
        }
        let size = (try? tmp.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= limit else { throw MakerRun.Failure("too_large", "\"\(label)\" is too large to download.") }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                done.resume(with: Result {
                    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                    try FileManager.default.moveItem(at: tmp, to: dest)
                })
            }
        }
    }

    // MARK: Publishing

    /// POST /designs. A form error is refused here and costs no request.
    public func create(_ input: MakerRun.CreateInput) async throws -> MakerRun.Created {
        let (errors, body) = MakerRun.validate(input, categories: categories, materials: materials, licences: licences)
        if !errors.isEmpty {
            throw MakerRun.Failure("invalid", "Some fields need attention before this can be published.", details: errors)
        }
        let res = try await withToken { token in try await self.request("POST", "/designs", token: token, json: .object(body)) }
        guard let d = MakerRun.object(MakerRun.object(res)?["design"]), let slug = MakerRun.optString(d["slug"]),
              MakerRun.validSlug(slug) else {
            throw MakerRun.Failure("bad_response", "MakerRun created something, but did not say what. Check your MakerRun account before trying again.")
        }
        return MakerRun.Created(slug: slug, status: MakerRun.optString(MakerRun.object(res)?["status"]) ?? "pending",
                                url: MakerRun.optString(d["url"]))
    }

    /// POST /designs/{slug}/files — the model, verified by MakerRun.
    public func uploadModel(slug: String, filename: String, data: Data) async throws -> MakerRun.Uploaded {
        if let issue = MakerRun.checkModel(filename: filename, size: data.count) {
            throw MakerRun.Failure("invalid", issue.message, details: [issue])
        }
        let path = try Self.slugPath(slug) + "/files"
        let part = MakerRun.Part(name: "file", filename: MakerRun.safeName((filename as NSString).lastPathComponent, fallback: "model.3mf"),
                                 type: "application/octet-stream", data: data)
        let res = try await withToken { token in
            try await self.request("POST", path, token: token, parts: [part], timeout: MakerRun.uploadTimeout(bytes: data.count))
        }
        let o = MakerRun.object(res) ?? [:]
        let v = MakerRun.object(o["verification"]) ?? [:]
        return MakerRun.Uploaded(
            verification: MakerRun.UploadVerification(verified: MakerRun.isTrue(v["verified"]),
                                                      printer: MakerRun.optString(v["printer"]),
                                                      brand: MakerRun.optString(v["brand"]),
                                                      reason: MakerRun.optString(v["reason"])),
            status: MakerRun.optString(o["status"]) ?? "pending")
    }

    /// POST /designs/{slug}/images — one picture, its type named from its bytes.
    public func uploadImage(slug: String, data: Data, kind: String) async throws -> MakerRun.ImagesStored {
        guard let type = MakerRun.sniffImageType(data) else {
            throw MakerRun.Failure("invalid", "That photo is not a JPEG, PNG or WebP image.")
        }
        guard data.count <= MakerRun.maxImageBytes else {
            throw MakerRun.Failure("invalid", "photo: larger than 15 MB.")
        }
        let ext = type == "image/png" ? ".png" : type == "image/webp" ? ".webp" : ".jpg"
        let path = try Self.slugPath(slug) + "/images"
        let parts = [MakerRun.Part(name: "images", filename: "photo" + ext, type: type, data: data),
                     MakerRun.Part(name: "kind", data: Data((kind == "print" ? "print" : "gallery").utf8))]
        let res = try await withToken { token in
            try await self.request("POST", path, token: token, parts: parts, timeout: MakerRun.uploadTimeout(bytes: data.count))
        }
        let o = MakerRun.object(res) ?? [:]
        var stored = 0
        if case .array(let a)? = o["images"] { stored = a.count }
        var failures: [String] = []
        if case .array(let a)? = o["failures"] {
            failures = a.compactMap { MakerRun.optString(MakerRun.object($0)?["message"]) }
        }
        return MakerRun.ImagesStored(stored: stored, failures: failures)
    }

    static let mePage = 100
    static let meMaxPages = 20

    private func mePage(_ offset: Int) async throws -> [MakerRun.Mine] {
        let qs = "?limit=\(Self.mePage)" + (offset > 0 ? "&offset=\(offset)" : "")
        let res = try await withToken { token in try await self.request("GET", "/me" + qs, token: token) }
        guard let o = MakerRun.object(res), MakerRun.object(o["user"]) != nil, case .array(let rows)? = o["designs"] else {
            throw MakerRun.Failure("bad_response", "MakerRun replied, but not with an account Khayt recognises.")
        }
        return rows.compactMap(MakerRun.mine)
    }

    /// Where one of the account's listings stands (`getStatus`).
    public func status(slug: String) async throws -> MakerRun.ListingStatus {
        _ = try Self.slugPath(slug)
        var seen: [MakerRun.Mine] = []
        var complete = false
        for page in 0..<Self.meMaxPages {
            let rows = try await mePage(page * Self.mePage)
            seen += rows
            if let hit = seen.first(where: { $0.slug == slug }) {
                return MakerRun.ListingStatus(found: true, status: hit.status, badge: hit.badge,
                                              fileChecked: hit.fileChecked, complete: true, searched: seen.count)
            }
            if rows.count < Self.mePage { complete = true; break }
        }
        return MakerRun.ListingStatus(found: false, status: nil, badge: nil, fileChecked: nil,
                                      complete: complete, searched: seen.count)
    }

    /// After a create whose answer was lost: the account's newest pending or
    /// draft listing with the same title, made since `since`.
    public func findRecent(title: String, since: Date) async throws -> MakerRun.Mine? {
        let want = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !want.isEmpty else { return nil }
        let rows = try await mePage(0)
        return rows.first { d in
            guard d.title.trimmingCharacters(in: .whitespacesAndNewlines) == want,
                  d.status == "pending" || d.status == "draft",
                  let at = d.createdAt.flatMap(JSDate.parse) else { return false }
            return at >= since.timeIntervalSince1970 * 1000
        }
    }

    /// DELETE /designs/{slug} — only on an explicit, confirmed action.
    public func delete(slug: String) async throws -> Bool {
        let path = try Self.slugPath(slug)
        let res = try await withToken { token in try await self.request("DELETE", path, token: token) }
        return MakerRun.isTrue(MakerRun.object(res)?["deleted"])
    }
}

/// Re-checks every redirect hop of a download, so a signed link that bounces
/// to a private address is refused exactly as one that pointed there.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let check: @Sendable (URL) -> Bool
    private let lock = NSLock()
    private var hops = 0
    private var _refused = false
    var refused: Bool { lock.lock(); defer { lock.unlock() }; return _refused }

    init(check: @escaping @Sendable (URL) -> Bool) { self.check = check }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        lock.lock(); hops += 1; let n = hops; lock.unlock()
        let check = self.check
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            guard n <= 5, let url = request.url, check(url) else {
                lock.lock(); _refused = true; lock.unlock()
                task.cancel()
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }
}
