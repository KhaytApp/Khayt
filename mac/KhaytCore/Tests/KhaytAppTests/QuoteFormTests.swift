import CryptoKit
import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The embeddable quote form (khayt-cloud #144): Settings › Online's pane,
/// against `GET/PUT /v1/shops/{id}/embed`, and the file a request carries,
/// downloaded and filed BEFORE the queue is drained.
///
/// None of this speaks to the service: every call goes through a fetch seam.
@MainActor
@Suite(.serialized)
struct QuoteFormEmbedTests {

    static let connection = CloudReader.Connection(
        url: "https://cloud.khaytapp.com", shopId: "shop_a1", storedToken: "")

    static func answer(_ json: String, status: Int = 200,
                       seen: ((URLRequest) -> Void)? = nil) -> QuoteFormEmbed.Fetch {
        { request in
            seen?(request)
            return (Data(json.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    static let full = """
        {"enabled":true,"origins":["https://shop.example","https://shop.example:8443"],
         "updatedAt":"2026-10-28T10:00:00.000Z","priceAvailable":false,"keepsFiles":true,
         "files":{"count":3,"bytes":4500000,"maxCount":50,"maxBytes":500000000,"maxFileBytes":50000000},
         "month":{"month":"2026-10","quotes":41,"requests":7},
         "links":{"page":"https://cloud.khaytapp.com/q/shop_a1","frame":"https://cloud.khaytapp.com/q/shop_a1/frame",
                  "script":"https://cloud.khaytapp.com/embed.js"}}
        """

    // MARK: - GET

    @Test("the whole answer is read, through CloudReader.request")
    func readsTheFullShape() async throws {
        var seen: [URLRequest] = []
        let state = try await QuoteFormEmbed.read(Self.connection, token: "t",
                                                  fetch: Self.answer(Self.full) { seen.append($0) })
        #expect(seen.count == 1)
        #expect(seen[0].httpMethod == "GET")
        #expect(seen[0].url?.path == "/v1/shops/shop_a1/embed")
        #expect(seen[0].value(forHTTPHeaderField: "x-delta-capable") == "1",
                "a request without this closes delta sync for every device this shop has")
        #expect(seen[0].value(forHTTPHeaderField: "Authorization") == "Bearer t")

        #expect(state.enabled)
        #expect(state.origins == ["https://shop.example", "https://shop.example:8443"])
        #expect(state.updatedAt == "2026-10-28T10:00:00.000Z")
        #expect(state.priceAvailable == false)
        #expect(state.keepsFiles == true)
        #expect(state.files == .init(count: 3, bytes: 4_500_000, maxCount: 50, maxBytes: 500_000_000,
                                     maxFileBytes: 50_000_000))
        #expect(state.month == .init(month: "2026-10", quotes: 41, requests: 7))
        #expect(state.links?.page == "https://cloud.khaytapp.com/q/shop_a1")
        #expect(state.links?.frame == "https://cloud.khaytapp.com/q/shop_a1/frame")
        #expect(state.links?.script == "https://cloud.khaytapp.com/embed.js")
    }

    @Test("a missing optional field is unknown, never a false the cloud did not say")
    func missingFieldsAreUnknown() async throws {
        let state = try await QuoteFormEmbed.read(Self.connection, token: "t",
                                                  fetch: Self.answer(#"{"enabled":true}"#))
        #expect(state.enabled)
        #expect(state.origins == [])
        #expect(state.priceAvailable == nil, "a missing priceAvailable would show 'cannot price' wrongly")
        #expect(state.keepsFiles == nil)
        #expect(state.files == nil && state.month == nil && state.links == nil && state.updatedAt == nil)
    }

    @Test("200 with enabled:false is the shop's form switched off, not 'not available'")
    func offIsNotUnavailable() async throws {
        let state = try await QuoteFormEmbed.read(Self.connection, token: "t", fetch: Self.answer("""
            {"enabled":false,"origins":[],"priceAvailable":true,"keepsFiles":true,
             "links":{"page":"https://cloud.khaytapp.com/q/shop_a1"}}
            """))
        #expect(state.enabled == false)
        #expect(state.links?.page != nil)
    }

    @Test("404 no-route is 'not available yet'; any other 404 is not")
    func noRouteIsNotAvailable() async {
        await #expect(throws: QuoteFormEmbed.Failure.notAvailable) {
            _ = try await QuoteFormEmbed.read(Self.connection, token: "t", fetch: Self.answer(
                #"{"error":"Not found","reason":"no-route"}"#, status: 404))
        }
        await #expect(throws: QuoteFormEmbed.Failure.notAvailable) {
            _ = try await QuoteFormEmbed.save(enabled: true, origins: ["https://a.com"], Self.connection,
                                              token: "t", fetch: Self.answer(
                                                #"{"error":"Not found","reason":"no-route"}"#, status: 404))
        }
        await #expect(throws: QuoteFormEmbed.Failure.http(404, "Unknown shop")) {
            _ = try await QuoteFormEmbed.read(Self.connection, token: "t", fetch: Self.answer(
                #"{"error":"Unknown shop"}"#, status: 404))
        }
    }

    // MARK: - PUT

    @Test("an origin is exactly https://host[:port]")
    func originRule() {
        for good in ["https://a.com", "https://a.com:8443", "https://shop.example.sa", "https://xn--mgbh0fb.sa",
                     "https://my-shop.salla.sa"] {
            #expect(QuoteFormEmbed.isOrigin(good), "\(good) should be allowed")
        }
        for bad in ["http://a.com", "https://*.a.com", "*", "https://a.com/", "https://a.com/shop",
                    "https://a.com?x=1", "https://a.com#x", "a.com", "https://", "https://a.com:0",
                    "https://a.com:70000", "https://user@a.com", "https://-a.com", "ftp://a.com",
                    " https://a.com/ "] {
            #expect(!QuoteFormEmbed.isOrigin(bad), "\(bad) should be refused")
        }
        #expect(QuoteFormEmbed.problem((0..<10).map { "https://s\($0).com" }) == nil)
        #expect(QuoteFormEmbed.problem((0..<11).map { "https://s\($0).com" }) == .tooMany)
        #expect(QuoteFormEmbed.problem(["https://a.com", "https://a.com/"]) == .badOrigin("https://a.com/"))
    }

    @Test("a bad list is refused before anything is sent")
    func refusedLocally() async {
        var calls = 0
        let spy = Self.answer(Self.full) { _ in calls += 1 }
        await #expect(throws: QuoteFormEmbed.Failure.tooMany) {
            _ = try await QuoteFormEmbed.save(enabled: true, origins: (0..<11).map { "https://s\($0).com" },
                                              Self.connection, token: "t", fetch: spy)
        }
        await #expect(throws: QuoteFormEmbed.Failure.badOrigin("http://a.com")) {
            _ = try await QuoteFormEmbed.save(enabled: true, origins: ["https://b.com", "http://a.com"],
                                              Self.connection, token: "t", fetch: spy)
        }
        #expect(calls == 0)
    }

    @Test("the PUT carries enabled and the tidied origins, and reads the answer")
    func putBody() async throws {
        var seen: [URLRequest] = []
        let state = try await QuoteFormEmbed.save(enabled: true, origins: ["  https://a.com ", "", "https://a.com:8443"],
                                                  Self.connection, token: "t",
                                                  fetch: Self.answer(Self.full) { seen.append($0) })
        #expect(state.enabled)
        let request = try #require(seen.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/v1/shops/shop_a1/embed")
        #expect(request.value(forHTTPHeaderField: "x-delta-capable") == "1")
        let body = try #require(request.httpBody)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(sent["enabled"] as? Bool == true)
        #expect(sent["origins"] as? [String] == ["https://a.com", "https://a.com:8443"])
    }

    @Test("the cloud's bad-embed is surfaced with the value it named")
    func badEmbedFromTheCloud() async {
        await #expect(throws: QuoteFormEmbed.Failure.badOrigin("https://localhost")) {
            _ = try await QuoteFormEmbed.save(enabled: true, origins: ["https://localhost"], Self.connection,
                                              token: "t", fetch: Self.answer(
                                                #"{"error":"Bad origin","reason":"bad-embed","value":"https://localhost"}"#,
                                                status: 400))
        }
    }

    @Test("403 is 'owner or manager only'")
    func notAManager() async {
        await #expect(throws: QuoteFormEmbed.Failure.notAllowed) {
            _ = try await QuoteFormEmbed.save(enabled: true, origins: ["https://a.com"], Self.connection,
                                              token: "t", fetch: Self.answer(#"{"error":"Forbidden"}"#, status: 403))
        }
    }

    @Test("not connected: nothing is asked, and a non-manager may not save")
    func notConnectedAsksNothing() async {
        let shop = Shop()
        await shop.load(.sample)
        var calls = 0
        let was = Shop.embedFetch
        Shop.embedFetch = { r in
            calls += 1
            return (Data(), HTTPURLResponse(url: r.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
        defer { Shop.embedFetch = was }
        #expect(await shop.readQuoteFormEmbed() == .needsCloud)
        #expect(shop.cloudCanManageEmbed == false, "the sample has no cloud role")
        guard case .failure(let failure) = await shop.saveQuoteFormEmbed(enabled: true, origins: ["https://a.com"])
        else { Issue.record("a sign-in with no role saved"); return }
        #expect(failure.sentence == shop.words.callIt("mac.qfe_managers_only"))
        #expect(calls == 0)
    }

    // MARK: - The snippets

    @Test("the snippets are built from the cloud's links, never a base of our own")
    func snippets() {
        #expect(QuoteFormEmbed.page("https://cloud.khaytapp.com/q/shop_a1", lang: "ar", theme: "dark")
                == "https://cloud.khaytapp.com/q/shop_a1?lang=ar&theme=dark")
        // A link that already carries a query keeps it, and a lang is replaced, not doubled.
        #expect(QuoteFormEmbed.page("https://x.example/q?s=1&lang=en", lang: "ar", theme: "light")
                == "https://x.example/q?s=1&lang=ar&theme=light")
        #expect(QuoteFormEmbed.script("https://cloud.khaytapp.com/embed.js", shopId: "shop_a1", lang: "en", theme: "light")
                == #"<script src="https://cloud.khaytapp.com/embed.js" data-shop="shop_a1" data-lang="en" data-theme="light" async></script>"#)
        #expect(QuoteFormEmbed.frame("https://x.example/f?a=1&b=2", title: "Quote \"form\"", lang: "ar", theme: "dark")
                .contains(#"src="https://x.example/f?a=1&amp;b=2&amp;lang=ar&amp;theme=dark" title="Quote &quot;form&quot;""#))
    }
}

/// The file a quote-form request carries: downloaded, checked and filed in
/// the library, the book written, and ONLY THEN the queue drained — because
/// the drain deletes the file on the cloud.
@MainActor
struct QuoteFormImportTests {

    static let connection = QuoteFormEmbedTests.connection

    struct Scratch {
        let dir: URL
        let store: URL
        let library: URL
        func read() throws -> [String: JSONValue] {
            try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: store))
        }
        func jobs() throws -> [[String: JSONValue]] {
            Shop.rows(try read(), "printLog").compactMap { if case .object(let o) = $0 { return o }; return nil }
        }
        func libraryRecords() throws -> [[String: JSONValue]] {
            Shop.rows(try read(), "printFiles").compactMap { if case .object(let o) = $0 { return o }; return nil }
        }
        func libraryFolders() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? []).filter { !$0.hasPrefix(".") }
        }
    }

    static func scratch() throws -> Scratch {
        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-quote-form-test-\(UUID().uuidString)")
        let library = dir.appending(path: "library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let store = dir.appending(path: "khayt-store.json")
        let book: [String: JSONValue] = [
            "printLog": .array([]), "inventory": .array([]), "machines": .array([]),
            "products": .array([]), "clients": .array([]), "printFiles": .array([]),
            "settings": .object(["currency": .string("SAR"), "invNumNext": .number(1)]),
        ]
        try JSONEncoder().encode(book).write(to: store)
        return Scratch(dir: dir, store: store, library: library)
    }

    static let model = MeshTests.binarySTL(MeshTests.boxFacets(10, 10, 10))
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func payload(_ data: Data, sha256: String? = nil, source: String = "quote-form") -> JSONValue {
        .object([
            "title": .string("Phone bracket"), "description": .string("Phone bracket, PLA, black"),
            "name": .string("Sara"), "contact": .string("sara@example.com"), "qty": .number(1),
            "source": .string(source),
            "file": .object([
                "name": .string("../../bracket.stl"), "bytes": .number(Double(data.count)),
                "sha256": .string(sha256 ?? sha(data)), "type": .string("model/stl"),
                "expiresAt": .string("2026-11-05T10:00:00.000Z"),
            ]),
        ])
    }

    static let input: [String: JSONValue] = [
        "project": .string("Phone bracket"), "source": .string("quote-form"),
        "parts": .array([.object(["name": .string("Phone bracket"), "qty": .number(1)])]),
    ]

    /// The cloud: the file route and the drain, with a log of what was asked
    /// and what the BOOK held at the moment of the drain.
    final class Cloud {
        var log: [String] = []
        var bookAtDrain: [[String: JSONValue]]?
        var libraryAtDrain: [String]?
        let file: (status: Int, body: Data, headers: [String: String])
        let scratch: Scratch
        init(scratch: Scratch, status: Int = 200, body: Data, headers: [String: String] = [:]) {
            self.scratch = scratch
            file = (status, body, headers)
        }
        @MainActor var fetch: CloudIntake.Fetch {
            { [self] request in
                let path = request.url?.path ?? ""
                log.append((request.httpMethod ?? "") + " " + path)
                #expect(request.value(forHTTPHeaderField: "x-delta-capable") == "1")
                if request.httpMethod == "DELETE" {
                    bookAtDrain = try scratch.jobs()
                    libraryAtDrain = scratch.libraryFolders()
                    return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                                              httpVersion: nil, headerFields: nil)!)
                }
                return (file.body, HTTPURLResponse(url: request.url!, statusCode: file.status,
                                                   httpVersion: nil, headerFields: file.headers)!)
            }
        }
    }

    static func run(_ payload: JSONValue, cloud: Cloud, scratch: Scratch, engine: KhaytEngine,
                    existing: @escaping (String) -> String? = { _ in nil }) async throws -> Shop.QuoteFormResult {
        let item = CloudIntake.Item(id: "21", payload: payload, createdAt: Date())
        let meta = try #require(item.file)
        let order = try await Shop.onlineOrder(item, products: [], stock: .object([:]), engine: engine)
        let fetch = cloud.fetch
        return await Shop.recordQuoteForm(
            order, meta: meta, input: input, paid: false, engine: engine,
            storeURL: scratch.store, libraryRoot: scratch.library, existingModel: existing,
            expiredNote: "FILE EXPIRED NOTE", owns: { true }, whoHasIt: { nil },
            download: { try await CloudIntake.file(connection, token: "t", id: "21", maxBytes: meta.bytes, fetch: fetch) },
            drain: { try await CloudIntake.drain(connection, token: "t", id: "21", fetch: fetch) })
    }

    static let filePath = "GET /v1/shops/shop_a1/intake/21/file"
    static let drainPath = "DELETE /v1/shops/shop_a1/intake/21"

    @Test("sha ok: downloaded, filed in the library, the book written, THEN drained")
    func importsWithTheFile() async throws {
        let engine = try KhaytEngine()
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch.dir) }
        let cloud = Cloud(scratch: scratch, body: Self.model,
                          headers: ["X-Content-SHA256": Self.sha(Self.model).uppercased(),
                                    "Content-Type": "application/octet-stream"])

        let result = try await Self.run(Self.payload(Self.model), cloud: cloud, scratch: scratch, engine: engine)

        #expect(result.refusal == nil)
        #expect(result.drained)
        #expect(cloud.log == [Self.filePath, Self.drainPath], "download, then drain — in that order, once each")
        // AT THE MOMENT OF THE DRAIN the book already held the job, pointing
        // at a model whose folder was already in the library.
        let atDrain = try #require(cloud.bookAtDrain)
        #expect(atDrain.count == 1, "the drain went before the book write")
        let id = try #require(result.printFileId)
        #expect(cloud.libraryAtDrain == [LibraryLocation.itemDirName(id)])

        let job = try #require(try scratch.jobs().first)
        #expect(job["intakeId"] == .string("21"))
        guard case .object(let facts)? = job["quoteFile"] else { Issue.record("no quoteFile on the job"); return }
        #expect(facts["printFileId"] == .string(id))
        #expect(facts["expired"] == .bool(false))
        #expect(facts["sha256"] == .string(Self.sha(Self.model)))
        guard case .array(let parts)? = job["parts"], case .object(let part)? = parts.first else {
            Issue.record("the job has no parts"); return
        }
        #expect(part["printFileId"] == .string(id))

        let records = try scratch.libraryRecords()
        #expect(records.count == 1)
        #expect(records.first?["id"] == .string(id))
        #expect(records.first?["contentHash"] == .string(Self.sha(Self.model)))
        // The bytes on disk are the bytes that were uploaded, under a safe name.
        let folder = scratch.library.appending(path: LibraryLocation.itemDirName(id))
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".stl") }
        #expect(names.count == 1)
        let onDisk = try Data(contentsOf: folder.appending(path: try #require(names.first)))
        #expect(onDisk == Self.model)
    }

    @Test("a header sha that does not match: nothing written, nothing drained")
    func headerMismatchStaysQueued() async throws {
        let engine = try KhaytEngine()
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch.dir) }
        let cloud = Cloud(scratch: scratch, body: Self.model,
                          headers: ["X-Content-SHA256": String(repeating: "0", count: 64)])
        let result = try await Self.run(Self.payload(Self.model), cloud: cloud, scratch: scratch, engine: engine)
        #expect(result.refusal == .checksum)
        #expect(cloud.log == [Self.filePath], "a file that failed its check must never be drained")
        #expect(try scratch.jobs().isEmpty)
        #expect(try scratch.libraryRecords().isEmpty)
        #expect(scratch.libraryFolders().isEmpty)
    }

    @Test("bytes that are not what the payload hashed: nothing written, nothing drained")
    func payloadMismatchStaysQueued() async throws {
        let engine = try KhaytEngine()
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch.dir) }
        var tampered = Self.model
        tampered[tampered.count - 1] ^= 0xff
        // The header agrees with the tampered bytes; the payload does not.
        let cloud = Cloud(scratch: scratch, body: tampered, headers: ["X-Content-SHA256": Self.sha(tampered)])
        let result = try await Self.run(Self.payload(Self.model), cloud: cloud, scratch: scratch, engine: engine)
        #expect(result.refusal == .checksum)
        #expect(!cloud.log.contains(Self.drainPath))
        #expect(try scratch.jobs().isEmpty)
        #expect(scratch.libraryFolders().isEmpty)
    }

    @Test("a missing checksum header still imports: the payload's hash decides")
    func missingHeaderImports() async throws {
        let engine = try KhaytEngine()
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch.dir) }
        let cloud = Cloud(scratch: scratch, body: Self.model)
        let result = try await Self.run(Self.payload(Self.model), cloud: cloud, scratch: scratch, engine: engine)
        #expect(result.refusal == nil)
        #expect(cloud.log.contains(Self.drainPath))
    }

    @Test("bytes that disagree with the payload are refused even with no header")
    func noHeaderTamperedStaysQueued() async throws {
        let engine = try KhaytEngine()
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch.dir) }
        var tampered = Self.model
        tampered[0] ^= 0xFF
        let cloud = Cloud(scratch: scratch, body: tampered)
        let result = try await Self.run(Self.payload(Self.model), cloud: cloud, scratch: scratch, engine: engine)
        #expect(result.refusal == .checksum)
        #expect(!cloud.log.contains(Self.drainPath))
    }

    @Test("a download larger than the request declared: refused, nothing written, nothing drained")
    func oversizeStaysQueued() async throws {
        let engine = try KhaytEngine()
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch.dir) }
        let big = Self.model + Data(repeating: 0, count: 4096)
        let cloud = Cloud(scratch: scratch, body: big, headers: ["X-Content-SHA256": Self.sha(Self.model)])
        let result = try await Self.run(Self.payload(Self.model), cloud: cloud, scratch: scratch, engine: engine)
        #expect(result.refusal != nil)
        #expect(!cloud.log.contains(Self.drainPath))
    }

    @Test("a short download: nothing written, nothing drained")
    func shortDownloadStaysQueued() async throws {
        let engine = try KhaytEngine()
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch.dir) }
        let short = Self.model.prefix(100)
        let cloud = Cloud(scratch: scratch, body: Data(short), headers: ["X-Content-SHA256": Self.sha(Self.model)])
        let result = try await Self.run(Self.payload(Self.model), cloud: cloud, scratch: scratch, engine: engine)
        #expect(result.refusal == .size(expected: Self.model.count, got: 100))
        #expect(!cloud.log.contains(Self.drainPath))
        #expect(try scratch.jobs().isEmpty)
    }

    @Test("expired (404 no-file): imported without the file, labelled, THEN drained")
    func expiredImportsWithoutTheFile() async throws {
        let engine = try KhaytEngine()
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch.dir) }
        let cloud = Cloud(scratch: scratch, status: 404,
                          body: Data(#"{"error":"Not found","reason":"no-file"}"#.utf8))
        let result = try await Self.run(Self.payload(Self.model), cloud: cloud, scratch: scratch, engine: engine)
        #expect(result.refusal == nil)
        #expect(result.expired)
        #expect(result.drained)
        #expect(cloud.log == [Self.filePath, Self.drainPath])
        #expect(cloud.bookAtDrain?.count == 1, "the drain went before the book write")
        let job = try #require(try scratch.jobs().first)
        guard case .object(let facts)? = job["quoteFile"] else { Issue.record("no quoteFile on the job"); return }
        #expect(facts["expired"] == .bool(true))
        #expect(facts["printFileId"] == nil)
        #expect((Shop.plainString(job["notes"]) ?? "").contains("FILE EXPIRED NOTE"))
        #expect(try scratch.libraryRecords().isEmpty)
    }

    @Test("404 no-route on the file route: the feature is off — nothing written, nothing drained")
    func noRouteStaysQueued() async throws {
        let engine = try KhaytEngine()
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch.dir) }
        let cloud = Cloud(scratch: scratch, status: 404,
                          body: Data(#"{"error":"Not found","reason":"no-route"}"#.utf8))
        let result = try await Self.run(Self.payload(Self.model), cloud: cloud, scratch: scratch, engine: engine)
        #expect(result.refusal == .notOffered)
        #expect(cloud.log == [Self.filePath])
        #expect(try scratch.jobs().isEmpty)
    }

    @Test("a failed download: nothing written, nothing drained")
    func failedDownloadStaysQueued() async throws {
        let engine = try KhaytEngine()
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch.dir) }
        let cloud = Cloud(scratch: scratch, status: 500, body: Data(#"{"error":"boom"}"#.utf8))
        let result = try await Self.run(Self.payload(Self.model), cloud: cloud, scratch: scratch, engine: engine)
        guard case .download? = result.refusal else { Issue.record("not a download refusal: \(String(describing: result.refusal))"); return }
        #expect(cloud.log == [Self.filePath])
        #expect(try scratch.jobs().isEmpty)
    }

    @Test("bytes the library already holds: the job points at that model, no second copy")
    func knownBytesLinkTheExistingModel() async throws {
        let engine = try KhaytEngine()
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch.dir) }
        let cloud = Cloud(scratch: scratch, body: Self.model, headers: ["X-Content-SHA256": Self.sha(Self.model)])
        let hash = Self.sha(Self.model)
        let result = try await Self.run(Self.payload(Self.model), cloud: cloud, scratch: scratch, engine: engine,
                                         existing: { $0 == hash ? "PF-already" : nil })
        #expect(result.printFileId == "PF-already")
        #expect(result.drained)
        #expect(scratch.libraryFolders().isEmpty)
        let job = try #require(try scratch.jobs().first)
        guard case .array(let parts)? = job["parts"], case .object(let part)? = parts.first else { return }
        #expect(part["printFileId"] == .string("PF-already"))
    }

    @Test("a request with no file — a storefront order — is not a quote-form import")
    func storefrontOrderUnaffected() async throws {
        let plain = CloudIntake.Item(id: "5", payload: .object([
            "title": .string("Salla order — SL-4"), "source": .string("salla"), "ref": .string("salla:SL-4"),
        ]), createdAt: nil)
        #expect(plain.file == nil, "a storefront order would be routed through the file step")
        #expect(!plain.isQuoteForm)

        // And the shared write, handed no file, writes no file facts.
        let engine = try KhaytEngine()
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch.dir) }
        let order = try await Shop.onlineOrder(plain, products: [], stock: .object([:]), engine: engine)
        try await StoreWriter.update(storeURL: scratch.store, owns: { true }, whoHasIt: { nil }) { root in
            let put = try await Shop.putOnlineOrder(order, input: Self.input, paid: false, into: &root,
                                                    engine: engine, now: Date())
            #expect(put.fileFiled == false)
        }
        let job = try #require(try scratch.jobs().first)
        #expect(job["quoteFile"] == nil)
        #expect(try scratch.libraryRecords().isEmpty)
    }

    @Test("the visitor's file name is never a path")
    func safeName() {
        func name(_ n: String) -> String { QuoteFormFile.Meta(name: n, bytes: 1, sha256: "").safeName }
        #expect(name("../../etc/passwd") == "passwd")
        #expect(name("..\\..\\x.stl") == "x.stl")
        #expect(name(".hidden.stl") == "hidden.stl")
        #expect(name("a:b\u{0}.stl") == "ab.stl")
        #expect(name("/") == "model")
        #expect(name(String(repeating: "x", count: 300) + ".3mf").count <= 120)
    }

    @Test("the payload's file is read; an intake row shows its name, size and expiry")
    func metaFromPayload() throws {
        let meta = try #require(QuoteFormFile.Meta(Self.payload(Self.model)))
        #expect(meta.name == "../../bracket.stl")
        #expect(meta.bytes == Self.model.count)
        #expect(meta.type == "model/stl")
        #expect(meta.expiresAt != nil)
    }
}

/// The DELETE says this app downloads a request's file first — and only the
/// DELETE says it.
@MainActor
struct IntakeFileCapableTests {
    static let connection = CloudReader.Connection(url: "https://cloud.example", shopId: "shop_a1", storedToken: "")

    @Test("every intake DELETE carries X-Intake-File-Capable; a list does not")
    func header() async throws {
        var seen: [URLRequest] = []
        let fetch: CloudIntake.Fetch = { r in
            seen.append(r)
            let body = r.httpMethod == "GET" ? Data(#"{"items":[]}"#.utf8) : Data("{}".utf8)
            return (body, HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        try await CloudIntake.drain(Self.connection, token: "t", id: "21", fetch: fetch)
        _ = try await CloudIntake.list(Self.connection, token: "t", fetch: fetch)
        #expect(seen[0].value(forHTTPHeaderField: "X-Intake-File-Capable") == "1")
        #expect(seen[0].value(forHTTPHeaderField: "x-delta-capable") == "1")
        #expect(seen[1].value(forHTTPHeaderField: "X-Intake-File-Capable") == nil)
    }

    @Test("409 file-not-downloaded is its own failure; another 409 is a refusal")
    func conflict() async throws {
        func answer(_ json: String) -> CloudIntake.Fetch {
            { r in (Data(json.utf8), HTTPURLResponse(url: r.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!) }
        }
        await #expect(throws: CloudIntake.Failure.self) {
            try await CloudIntake.drain(Self.connection, token: "t", id: "21",
                                        fetch: answer(#"{"error":"Conflict","reason":"file-not-downloaded"}"#))
        }
        do {
            try await CloudIntake.drain(Self.connection, token: "t", id: "21",
                                        fetch: answer(#"{"error":"Conflict","reason":"file-not-downloaded"}"#))
        } catch CloudIntake.Failure.fileNotDownloaded {
        } catch { Issue.record("expected fileNotDownloaded, got \(error)") }
        do {
            try await CloudIntake.drain(Self.connection, token: "t", id: "21",
                                        fetch: answer(#"{"error":"Busy","reason":"other"}"#))
            Issue.record("expected a refusal")
        } catch CloudIntake.Failure.refused(let code, _) {
            #expect(code == 409)
        } catch { Issue.record("expected refused, got \(error)") }
    }
}
