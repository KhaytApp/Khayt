import Foundation
import Testing
@testable import KhaytCore

/// MakerRun on the Mac: the transport ported from `lib/makerrun-v1.js`,
/// `makerrun-catalog.js`, `makerrun-publish.js` and `makerrun-account.js`,
/// held to the cases the desktop's tests hold those files to. No test here
/// reaches makerrun.com: every request goes to `MakerRunStub`.
struct MakerRunRulesTests {

    @Test("a slug is letters and numbers of any script, joined by hyphens")
    func slugs() {
        #expect(MakerRun.validSlug("cable-clip-2"))
        #expect(MakerRun.validSlug("مشبك-كابل"))
        #expect(MakerRun.validSlug("挂钩"))
        #expect(!MakerRun.validSlug(""))
        #expect(!MakerRun.validSlug("-leading"))
        #expect(!MakerRun.validSlug("a/b"))
        #expect(!MakerRun.validSlug("a.b"))
        #expect(!MakerRun.validSlug("a%2Fb"))
        #expect(!MakerRun.validSlug("a b"))
        #expect(!MakerRun.validSlug(String(repeating: "a", count: 201)))
    }

    @Test("a downloaded design is named as the desktop names it")
    func names() {
        #expect(MakerRun.safeBase("Cable Clip (v2)!") == "Cable_Clip_v2")
        #expect(MakerRun.safeBase("مشبك") == "design")
        #expect(MakerRun.safeBase(nil) == "design")
        #expect(MakerRun.safeBase(String(repeating: "x", count: 80)).count == 60)
        #expect(MakerRun.extFor(filename: "part.STL") == ".stl")
        #expect(MakerRun.extFor(filename: "part.stp") == ".step")
        #expect(MakerRun.extFor(filename: "part.command") == ".3mf")
        #expect(MakerRun.extFor(filename: nil) == ".3mf")
        #expect(MakerRun.safeName("my model.3mf", fallback: "model.3mf") == "my_model.3mf")
        #expect(MakerRun.safeName("..hidden", fallback: "x") == "_hidden")
        #expect(MakerRun.safeName("", fallback: "model.3mf") == "model.3mf")
        #expect(!MakerRun.validFilename("../x.3mf"))
        #expect(!MakerRun.validFilename(".."))
        #expect(MakerRun.validFilename("x.3mf"))
    }

    @Test("the list query drops what the vocabularies do not know")
    func listQuery() {
        var q = MakerRun.Query()
        q.q = "  cable+clip  "
        q.category = "tools"
        q.material = "wood"
        q.verified = true
        q.forSale = false
        q.limit = 500
        q.offset = 48
        let s = MakerRun.listQuery(q, categories: ["tools"], materials: ["rigid"])
        #expect(s == "q=cable%2Bclip&category=tools&verified=true&forSale=false&limit=100&offset=48")
        #expect(MakerRun.listQuery(MakerRun.Query(), categories: [], materials: []) == "limit=24")
    }

    static func designJSON(_ extra: [String: JSONValue] = [:]) -> JSONValue {
        var d: [String: JSONValue] = [
            "slug": .string("clip"), "title": .string("Clip"), "license": .string("CC-BY-4.0"),
            "material": .string("rigid"), "listingKind": .string("linked"), "external": .bool(false),
            "url": .string("https://makerrun.com/designs/clip"),
            "cover": .object(["url": .string("http://insecure.example/c.jpg"), "aiGenerated": .bool(true)]),
            "verification": .object(["badge": .bool(true), "printer": .object(["brand": .string("Snapmaker"), "model": .string("U1")])]),
            "sale": .object(["kind": .string("fixed"), "price": .number(5), "currency": .string("SAR"),
                             "url": .string("https://pay.example/secret")]),
        ]
        for (k, v) in extra { d[k] = v }
        return .object(d)
    }

    @Test("a design keeps its listing kind and any brand's printer, and never a sale link")
    func design() throws {
        let d = try MakerRun.design(Self.designJSON(), materials: ["rigid", "flexible", "multi"])
        #expect(d.listingKind == "linked")
        #expect(d.verification.printer?.name == "Snapmaker U1")
        #expect(d.cover == nil, "an http cover is dropped")
        #expect(d.coverAiGenerated)
        #expect(d.sale?.price == 5)
        #expect(d.material == "rigid")
        #expect(throws: MakerRun.Failure.self) {
            try MakerRun.design(.object(["slug": .string("a/b"), "title": .string("x")]), materials: [])
        }
    }

    @Test("an unreadable list is an error, never an empty catalogue")
    func list() throws {
        #expect(throws: MakerRun.Failure.self) {
            try MakerRun.designList(.object(["items": .array([])]), materials: [])
        }
        let list = try MakerRun.designList(.object([
            "designs": .array([Self.designJSON()]),
            "page": .object(["total": .number(31), "offset": .number(24), "limit": .number(24)]),
        ]), materials: [])
        #expect(list.page == MakerRun.Page(limit: 24, offset: 24, total: 31, returned: 1))
    }

    @Test("errors branch on the code, and maintenance and rate limits carry Retry-After")
    func errors() {
        let mfa = MakerRun.parseError(status: 403, body: .object(["error": .object(["code": .string("mfa_required")])]),
                                      retryAfterHeader: nil)
        #expect(mfa.code == "mfa_required")
        #expect(mfa.message.contains("two-factor"))
        let maint = MakerRun.parseError(status: 503, body: .object(["error": .object(["code": .string("maintenance")])]),
                                        retryAfterHeader: "120")
        #expect(maint.code == "maintenance" && maint.retryAfter == 120)
        #expect(maint.message.contains("2 minutes"))
        let cdn = MakerRun.parseError(status: 503, body: nil, retryAfterHeader: nil)
        #expect(cdn.code == "unavailable")
        let rate = MakerRun.parseError(status: 429, body: nil, retryAfterHeader: "9999")
        #expect(rate.code == "rate_limited" && rate.retryAfter == 60)
        let images = MakerRun.parseError(status: 422, body: .object([
            "images": .array([]), "failures": .array([.object(["field": .string("images"), "message": .string("too big")])]),
        ]), retryAfterHeader: nil)
        #expect(images.code == "invalid" && images.message == "too big")
        let http = MakerRun.parseError(status: 418, body: nil, retryAfterHeader: nil)
        #expect(http.code == "http_418")
    }

    @Test("Retry-After reads seconds or an HTTP date, 1…3600, else 60")
    func retryAfter() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(MakerRun.retryAfterSeconds("30", now: now) == 30)
        #expect(MakerRun.retryAfterSeconds("0", now: now) == 60)
        #expect(MakerRun.retryAfterSeconds("", now: now) == 60)
        #expect(MakerRun.retryAfterSeconds("soon", now: now) == 60)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        #expect(MakerRun.retryAfterSeconds(f.string(from: now.addingTimeInterval(90)), now: now) == 90)
    }

    @Test("the publish form is validated before a request, and only allowed keys are sent")
    func validate() {
        var i = MakerRun.CreateInput()
        i.title = "  "
        i.category = "nope"
        i.material = "wood"
        i.license = "MIT"
        let bad = MakerRun.validate(i, categories: ["tools"], materials: ["rigid"], licences: ["CC0-1.0"])
        #expect(bad.errors.map(\.field) == ["title", "category", "material", "license"])
        i.title = " Clip "
        i.category = "tools"
        i.material = ""
        i.license = "CC0-1.0"
        i.description = String(repeating: "d", count: 10)
        let good = MakerRun.validate(i, categories: ["tools"], materials: ["rigid"], licences: ["CC0-1.0"])
        #expect(good.errors.isEmpty)
        #expect(good.body == ["title": .string("Clip"), "description": .string("dddddddddd"),
                              "category": .string("tools"), "license": .string("CC0-1.0"), "nsfw": .bool(false)])
        #expect(MakerRun.checkModel(filename: "x.gcode", size: 10)?.field == "file")
        #expect(MakerRun.checkModel(filename: "x.3mf", size: 0) != nil)
        #expect(MakerRun.checkModel(filename: "x.3mf", size: MakerRun.maxModelBytes + 1) != nil)
        #expect(MakerRun.checkModel(filename: "x.STP", size: 10) == nil)
        #expect(MakerRun.guessMaterial("TPU 95A") == "flexible")
        #expect(MakerRun.guessMaterial("PETG") == "rigid")
        #expect(MakerRun.guessMaterial(nil) == "")
    }

    @Test("an upload may take longer the bigger it is, up to 30 minutes")
    func uploadTimeout() {
        #expect(MakerRun.uploadTimeout(bytes: 0) == 120)
        #expect(MakerRun.uploadTimeout(bytes: 256 * 1024 * 100) == 220)
        #expect(MakerRun.uploadTimeout(bytes: Int.max / 2) == 1800)
    }

    @Test("downloads come over HTTPS from public addresses only")
    func hosts() {
        #expect(MakerRun.safeDownloadHost(URL(string: "https://cdn.makerrun.com/x")!, resolve: false))
        #expect(!MakerRun.safeDownloadHost(URL(string: "http://cdn.makerrun.com/x")!, resolve: false))
        #expect(!MakerRun.safeDownloadHost(URL(string: "https://127.0.0.1/x")!, resolve: false))
        #expect(!MakerRun.safeDownloadHost(URL(string: "https://169.254.169.254/latest")!, resolve: false))
        #expect(!MakerRun.safeDownloadHost(URL(string: "https://10.0.0.5/x")!, resolve: false))
        #expect(!MakerRun.safeDownloadHost(URL(string: "https://192.168.1.2/x")!, resolve: false))
        #expect(!MakerRun.safeDownloadHost(URL(string: "https://[::1]/x")!, resolve: false))
        #expect(!MakerRun.safeDownloadHost(URL(string: "https://[::ffff:10.0.0.1]/x")!, resolve: false))
        #expect(!MakerRun.safeDownloadHost(URL(string: "https://printer.local/x")!, resolve: false))
        #expect(MakerRun.safeDownloadHost(URL(string: "https://8.8.8.8/x")!, resolve: false))
    }

    @Test("pictures are typed from their bytes")
    func sniff() {
        #expect(MakerRun.sniffImageType(Data([0xff, 0xd8, 0xff, 0, 0, 0, 0, 0, 0, 0, 0, 0])) == "image/jpeg")
        #expect(MakerRun.sniffImageType(Data([0x89, 0x50, 0x4e, 0x47, 0, 0, 0, 0, 0, 0, 0, 0])) == "image/png")
        #expect(MakerRun.sniffImageType(Data("RIFF\0\0\0\0WEBP".utf8)) == "image/webp")
        #expect(MakerRun.sniffImageType(Data("GIF89a......".utf8)) == nil)
    }

    @Test("an expiry in milliseconds is read as seconds")
    func expiry() {
        #expect(MakerRunTokens.normExpires(1_800_000_000) == 1_800_000_000)
        #expect(MakerRunTokens.normExpires(1_800_000_000_000) == 1_800_000_000)
        #expect(MakerRunTokens.normExpires(nil) == 0)
        #expect(MakerRunTokens.normExpires(-5) == 0)
    }
}

// MARK: - The client, against a stub

/// A canned makerrun.com: answers by path, records every request. Nothing
/// leaves the process.
final class MakerRunStub: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable { let method: String; let path: String; let auth: String; let body: Data? }
    nonisolated(unsafe) static var answers: [String: [(Int, String)]] = [:]
    nonisolated(unsafe) static var seen: [Seen] = []
    static let lock = NSLock()

    static func session(_ answers: [String: [(Int, String)]]) -> URLSession {
        lock.lock(); defer { lock.unlock() }
        Self.answers = answers; seen = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MakerRunStub.self]
        return URLSession(configuration: config)
    }
    static func requests() -> [Seen] { lock.lock(); defer { lock.unlock() }; return seen }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            body = data
        }
        let path = request.url?.path ?? ""
        Self.lock.lock()
        Self.seen.append(Seen(method: request.httpMethod ?? "GET", path: path,
                              auth: request.value(forHTTPHeaderField: "authorization") ?? "", body: body))
        var queue = Self.answers[path] ?? []
        let (status, text) = queue.isEmpty ? (404, "{}") : queue.removeFirst()
        if queue.isEmpty, let last = Self.answers[path]?.last { queue = [last] }
        Self.answers[path] = queue
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["content-type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

actor TestTokenStore: MakerRunTokenStore {
    var tokens: MakerRunTokens?
    init(_ t: MakerRunTokens? = nil) { tokens = t }
    func load() async -> MakerRunTokens? { tokens }
    func save(_ t: MakerRunTokens) async { tokens = t }
    func clear(onlyIf refresh: String?) async {
        if let refresh, let t = tokens, t.refresh != refresh { return }
        tokens = nil
    }
}

@Suite(.serialized)
struct MakerRunClientTests {
    static let base = URL(string: "https://makerrun.test")!
    static let now: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) }

    @Test("a pasted code is exchanged at once, and the rotated refresh token is kept")
    func link() async throws {
        let session = MakerRunStub.session([
            "/api/app-token": [(200, #"{"access_token":"A1","refresh_token":"R2","expires_at":1800003600}"#)],
        ])
        let store = TestTokenStore()
        let client = MakerRunClient(base: Self.base, session: session, store: store, now: Self.now)
        try await client.link(code: "  R1 \n")
        let saved = await store.tokens
        #expect(saved == MakerRunTokens(access: "A1", refresh: "R2", expires: 1_800_003_600))
        let sent = MakerRunStub.requests().first
        #expect(sent?.method == "POST")
        #expect(String(data: sent?.body ?? Data(), encoding: .utf8)?.contains("\"R1\"") == true)
        // Fresh: no second exchange.
        #expect(try await client.accessToken() == "A1")
        #expect(MakerRunStub.requests().count == 1)
    }

    @Test("a refused code is said and nothing is kept")
    func refusedCode() async {
        let session = MakerRunStub.session(["/api/app-token": [(401, #"{"error":"invalid"}"#)]])
        let store = TestTokenStore()
        let client = MakerRunClient(base: Self.base, session: session, store: store, now: Self.now)
        await #expect(throws: MakerRun.Failure.self) { try await client.link(code: "R1") }
        #expect(await store.tokens == nil)
        #expect(await client.isLinked() == false)
    }

    @Test("a server error leaves the link alone — only a 401 means reconnect")
    func refreshOutage() async {
        let session = MakerRunStub.session(["/api/app-token": [(502, "{}")]])
        let store = TestTokenStore(MakerRunTokens(access: "", refresh: "R1", expires: 0))
        let client = MakerRunClient(base: Self.base, session: session, store: store, now: Self.now)
        do { _ = try await client.accessToken(); Issue.record("expected a refusal") }
        catch let f as MakerRun.Failure { #expect(f.code == "unavailable") }
        catch { Issue.record("\(error)") }
        #expect(await store.tokens?.refresh == "R1")
    }

    @Test("two callers at once share ONE refresh, so the refresh token is never replayed")
    func singleFlight() async throws {
        let session = MakerRunStub.session([
            "/api/app-token": [(200, #"{"access_token":"A1","refresh_token":"R2","expires_at":1800003600}"#)],
        ])
        let store = TestTokenStore(MakerRunTokens(access: "", refresh: "R1", expires: 0))
        let client = MakerRunClient(base: Self.base, session: session, store: store, now: Self.now)
        async let a = client.accessToken()
        async let b = client.accessToken()
        let (x, y) = try await (a, b)
        #expect(x == "A1" && y == "A1")
        #expect(MakerRunStub.requests().filter { $0.path == "/api/app-token" }.count == 1)
    }

    @Test("a 401 from /v1 forces one refresh and retries; a second 401 is relink")
    func withTokenRetry() async throws {
        let session = MakerRunStub.session([
            "/api/app-token": [(200, #"{"access_token":"A2","refresh_token":"R2","expires_at":1800003600}"#)],
            "/api/v1/designs/clip/files/clip.3mf/download": [(401, #"{"error":{"code":"unauthorized"}}"#),
                                                             (401, #"{"error":{"code":"unauthorized"}}"#)],
        ])
        let store = TestTokenStore(MakerRunTokens(access: "A1", refresh: "R1", expires: 1_800_003_600))
        let client = MakerRunClient(base: Self.base, session: session, store: store, now: Self.now)
        do {
            _ = try await client.download(slug: "clip", filename: "clip.3mf", title: "Clip",
                                          into: FileManager.default.temporaryDirectory)
            Issue.record("expected relink")
        } catch let f as MakerRun.Failure {
            #expect(f.code == "relink")
        }
        let auths = MakerRunStub.requests().filter { $0.path.hasSuffix("/download") }.map(\.auth)
        #expect(auths == ["Bearer A1", "Bearer A2"])
    }

    @Test("browsing needs no token and narrows each design")
    func browse() async throws {
        let body = #"{"designs":[{"slug":"clip","title":"Clip","listingKind":"hosted","verification":{}}],"page":{"total":1,"limit":24,"offset":0,"returned":1}}"#
        let session = MakerRunStub.session(["/api/v1/designs": [(200, body)]])
        let client = MakerRunClient(base: Self.base, session: session, store: TestTokenStore(), now: Self.now)
        let list = try await client.listDesigns(MakerRun.Query())
        #expect(list.designs.map(\.slug) == ["clip"])
        #expect(list.designs.first?.listingKind == "hosted")
        #expect(MakerRunStub.requests().first?.auth == "")
    }

    @Test("a create with field errors costs no request")
    func createRefusedLocally() async {
        let session = MakerRunStub.session([:])
        let client = MakerRunClient(base: Self.base, session: session,
                                    store: TestTokenStore(MakerRunTokens(access: "A", refresh: "R", expires: 1_800_003_600)),
                                    now: Self.now)
        await client.setTerms(categories: ["tools"], materials: ["rigid"], licences: ["CC0-1.0"])
        var input = MakerRun.CreateInput()
        input.title = "Clip"
        do { _ = try await client.create(input); Issue.record("expected invalid") }
        catch let f as MakerRun.Failure { #expect(f.code == "invalid" && f.details.map(\.field) == ["category", "license"]) }
        catch { Issue.record("\(error)") }
        #expect(MakerRunStub.requests().isEmpty)
    }

    @Test("the publish steps send the model as multipart and read the verification")
    func publish() async throws {
        let session = MakerRunStub.session([
            "/api/v1/designs": [(201, #"{"design":{"slug":"clip","url":"https://makerrun.test/designs/clip"},"status":"pending"}"#)],
            "/api/v1/designs/clip/files": [(200, #"{"file":{"filename":"clip.3mf"},"verification":{"verified":true,"printer":"U1","brand":"Snapmaker"},"status":"pending"}"#)],
            "/api/v1/me": [(200, #"{"user":{},"designs":[{"slug":"clip","title":"Clip","status":"published","verification":{"badge":true,"fileChecked":true}}]}"#)],
        ])
        let client = MakerRunClient(base: Self.base, session: session,
                                    store: TestTokenStore(MakerRunTokens(access: "A", refresh: "R", expires: 1_800_003_600)),
                                    now: Self.now)
        await client.setTerms(categories: ["tools"], materials: ["rigid"], licences: ["CC0-1.0"])
        var input = MakerRun.CreateInput()
        input.title = "Clip"; input.category = "tools"; input.license = "CC0-1.0"
        let made = try await client.create(input)
        #expect(made == MakerRun.Created(slug: "clip", status: "pending", url: "https://makerrun.test/designs/clip"))
        let up = try await client.uploadModel(slug: "clip", filename: "my clip.3mf", data: Data("PK".utf8))
        #expect(up.verification.verified && up.verification.brand == "Snapmaker")
        let multipart = String(decoding: MakerRunStub.requests()[1].body ?? Data(), as: UTF8.self)
        #expect(multipart.contains(#"name="file"; filename="my_clip.3mf""#))
        let status = try await client.status(slug: "clip")
        #expect(status.found && status.status == "published" && status.badge == true)
    }
}

// MARK: - The planner and the vocabularies, through the engine

struct ColourPlanEngineTests {
    static let shelf: [JSONValue] = [
        .object(["id": .string("red"), "color": .string("#E01010"), "cost": .number(100), "weight": .number(1000)]),
        .object(["id": .string("blue"), "color": .string("#1030D0"), "cost": .number(80), "weight": .number(1000)]),
        .object(["id": .string("white"), "color": .string("#FAFAFA"), "cost": .number(60), "weight": .number(500)]),
    ]

    @Test("the plan opens as lib/color-plan.js opens it on the desktop")
    func initial() async throws {
        let engine = try KhaytEngine()
        let colours: [JSONValue] = [.object(["hex": .string("#FF0000"), "grams": .number(12)]),
                                    .object(["hex": .string("#0000FF"), "grams": .number(3), "label": .string("Sky")])]
        let saved: [JSONValue] = [.object(["hex": .string("#0000ff"), "filamentId": .string("white"), "grams": .number(7)])]
        let plan = try await engine.initialColourPlan(colours: colours, saved: saved, inventory: Self.shelf)
        #expect(plan == [
            KhaytEngine.ColourPlanRow(hex: "#FF0000", label: "#1", grams: 12, filamentId: "red"),
            KhaytEngine.ColourPlanRow(hex: "#0000FF", label: "Sky", grams: 7, filamentId: "white"),
        ])
        let s = try await engine.summariseColourPlan(plan, inventory: Self.shelf)
        #expect(abs((s.rows[0].cost ?? 0) - 1.2) < 1e-9)
        #expect(abs(s.totalCost - (1.2 + 0.84)) < 1e-9)
        #expect(s.slots == ["red", "white"])
        #expect(s.overflow == 0)
        #expect(try await engine.amsSlots() == 4)
        #expect(try await engine.colourCloseness(2) == "good")
        #expect(try await engine.colourCloseness(nil) == "")
    }

    @Test("MakerRun's vocabularies and the licence mapping are lib/makerrun-terms.js's")
    func terms() async throws {
        let engine = try KhaytEngine()
        let t = try await engine.makerRunTerms()
        #expect(t.categories.count == 14)
        #expect(t.categories.first == .init(value: "art", label: "Art & design"))
        #expect(t.materials == ["rigid", "flexible", "multi"])
        #expect(t.licences.contains("CC0-1.0"))
        #expect(try await engine.recordLicence(fromMakerRun: "CC-BY-NC-SA-4.0") == "cc-by-nc-sa")
        #expect(try await engine.recordLicence(fromMakerRun: "All rights reserved") == nil)
        #expect(try await engine.makerRunLicence(fromRecord: "cc-by") == "CC-BY-4.0")
        #expect(try await engine.makerRunLicence(fromRecord: "own") == nil)
        #expect(try await engine.commercialUse("CC-BY-NC-4.0") == false)
        #expect(try await engine.commercialUse("CC0-1.0") == true)
    }
}

// MARK: - The 3D viewer's 3MF reader

struct ViewerMeshTests {
    /// Two triangles of one object: the first painted filament 2, the second
    /// unpainted on the object's filament (1).
    static let model = """
    <?xml version="1.0" encoding="UTF-8"?>
    <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
     <resources>
      <object id="1" type="model">
       <mesh>
        <vertices>
         <vertex x="0" y="0" z="0"/><vertex x="10" y="0" z="0"/><vertex x="0" y="10" z="0"/><vertex x="0" y="0" z="10"/>
        </vertices>
        <triangles>
         <triangle v1="0" v2="1" v3="2" paint_color="8"/>
         <triangle v1="0" v2="1" v3="3"/>
        </triangles>
       </mesh>
      </object>
     </resources>
     <build><item objectid="1" transform="1 0 0 0 1 0 0 0 1 5 5 0"/></build>
    </model>
    """

    @Test("a painted 3MF comes back with each face's filament and the project's colours")
    func painted() async throws {
        let studio = try StudioEngine()
        let members: [JSONValue] = [
            .object(["name": .string("3D/3dmodel.model"), "meshVar": .string("__m0")]),
            .object(["name": .string("Metadata/project_settings.config"),
                     "data": .string(##"{"filament_colour":["#ff0000","#00ff00"]}"##)]),
        ]
        let mesh = try await studio.viewerMesh(members, meshes: ["__m0": Self.model], maxFaces: 4_000_000)
        #expect(mesh.triangleCount == 2)
        #expect(mesh.faceState.count == 2)
        #expect(mesh.positions.count == 18)
        #expect(mesh.palette == ["#FF0000", "#00FF00"])
        #expect(mesh.faceState[0] == 2, "paint code 8 is filament 2")
        // The build's transform is applied: the first vertex moved by (5, 5).
        #expect(Array(mesh.positions.prefix(3)) == [5, 5, 0])
        #expect(!mesh.sampled && !mesh.skipped)
    }

    @Test("past the budget the faces are stride-sampled, as the desktop samples")
    func sampled() async throws {
        let studio = try StudioEngine()
        let members: [JSONValue] = [.object(["name": .string("3D/3dmodel.model"), "meshVar": .string("__m0")])]
        let mesh = try await studio.viewerMesh(members, meshes: ["__m0": Self.model], maxFaces: 1)
        #expect(mesh.sampled)
        #expect(mesh.faceState.count == 1)
    }

    @Test("the viewer's budgets are lib/mf-mesh.js's")
    func budgets() async throws {
        let b = try await StudioEngine().viewerBudgets()
        #expect(b.preview == 4_000_000 && b.hardCap == 30_000_000)
    }
}
