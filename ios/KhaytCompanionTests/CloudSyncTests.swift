import XCTest
import KhaytCore
@testable import KhaytCompanion

/**
 * The phone's cloud sync, against a fake Khayt Cloud that holds real
 * ciphertext. Nothing here touches the network, and the fake answers the way
 * `docs/api-contract.md` in khayt-cloud says the real one does.
 */
@MainActor
final class CloudSyncTests: XCTestCase {

    /// A cloud with a base and a delta chain, answering GET /store and POST /deltas.
    final class FakeCloud: @unchecked Sendable {
        let dek: Data
        var base: SyncCrypto.Blob?
        var baseRev = 0
        var chain: [(rev: Int, blob: SyncCrypto.Blob)] = []
        var chainFull = false
        var requests: [URLRequest] = []

        init(dek: Data) { self.dek = dek }
        var head: Int { chain.last?.rev ?? baseRev }

        func setBase(_ store: [String: JSONValue], rev: Int) throws {
            base = try SyncCrypto.seal(store, dek: dek); baseRev = rev; chain = []
        }
        func append(_ payload: [String: JSONValue]) throws {
            chain.append((rev: head + 1, blob: try SyncCrypto.seal(payload, dek: dek)))
        }

        func answer(_ request: URLRequest) throws -> (Data, URLResponse) {
            requests.append(request)
            let url = request.url!
            func reply(_ code: Int, _ body: Any) throws -> (Data, URLResponse) {
                (try JSONSerialization.data(withJSONObject: body),
                 HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
            }
            func blob(_ b: SyncCrypto.Blob) throws -> Any {
                try JSONSerialization.jsonObject(with: JSONEncoder().encode(b))
            }
            switch (request.httpMethod, url.path.hasSuffix("/store"), url.path.hasSuffix("/deltas")) {
            case ("GET", true, _):
                guard let base else { return (Data(), HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)!) }
                let since = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "since" }.flatMap { Int($0.value ?? "") }
                var body: [String: Any] = ["rev": head,
                                           "deltas": try chain.filter { $0.rev > (since ?? -1) }
                                               .map { ["rev": $0.rev, "ciphertext": try blob($0.blob)] }]
                if since == nil || since! < baseRev { body["ciphertext"] = try blob(base) }
                return try reply(200, body)
            case ("POST", _, true):
                if chainFull { return try reply(409, ["rev": head, "compact": true]) }
                let sent = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
                guard (sent["baseRev"] as? Int) == head else { return try reply(409, ["rev": head]) }
                let b = try JSONDecoder().decode(SyncCrypto.Blob.self,
                                                 from: JSONSerialization.data(withJSONObject: sent["ciphertext"] as Any))
                chain.append((rev: head + 1, blob: b))
                return try reply(200, ["rev": head, "deltaCount": chain.count])
            default:
                return try reply(404, ["error": "Not found"])
            }
        }
    }

    private var dir: URL!
    private var book: CompanionBook!
    private var engine: KhaytEngine!
    private var cloud: FakeCloud!
    private var session: CloudSession!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "cloud-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        book = CompanionBook(directory: dir)
        engine = try KhaytEngine()
        var key = Data(count: 32)
        _ = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        cloud = FakeCloud(dek: key)
        session = CloudSession(url: "https://cloud.test", shopId: "shop_1", token: "tok",
                               dek: key, role: "owner", seenRev: nil)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func sync() -> CloudSync {
        var s = CloudSync(book: book, engine: engine)
        let fake = cloud!
        s.fetch = { try fake.answer($0) }
        return s
    }

    private func shop(orders: Int, finished: Int) -> [String: JSONValue] {
        var log: [JSONValue] = []
        for i in 0..<orders {
            log.append(.object(["id": .string("O-\(i)"), "status": .string("printing"),
                                "project": .string("Job \(i)"), "date": .string("2026-09-20"), "rev": .number(1)]))
        }
        for i in 0..<finished {
            log.append(.object(["id": .string("F-\(i)"), "status": .string("completed"),
                                "date": .string("2024-01-01"), "rev": .number(1)]))
        }
        return ["settings": .object(["shopName": .string("Ward")]), "printLog": .array(log),
                "inventory": .array([]), "clients": .array([])]
    }

    private func order(_ id: String) throws -> [String: JSONValue]? {
        guard case .array(let rows)? = try book.read()["printLog"] else { return nil }
        for case .object(let o) in rows where o["id"] == .string(id) { return o }
        return nil
    }

    private func pending() async throws -> Int {
        try await BookReader(book: book).pendingChanges()?.count ?? 0
    }

    // MARK: -

    func testEveryRequestSaysThisPhoneCanReadDeltas() async throws {
        // One device without it closes the delta gate for the whole shop.
        try cloud.setBase(shop(orders: 2, finished: 0), rev: 1)
        var (s, _) = try await sync().pull(session)
        try BookWriter(book: book).setOrderStatus(orderId: "O-0", to: "post")
        (s, _) = try await sync().push(s)
        XCTAssertFalse(cloud.requests.isEmpty)
        for r in cloud.requests {
            XCTAssertEqual(r.value(forHTTPHeaderField: "x-delta-capable"), "1", r.url?.absoluteString ?? "")
            XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        }
    }

    func testAFirstPullIsTheCloudsBookSlicedToWhatAPhoneCarries() async throws {
        try cloud.setBase(shop(orders: 3, finished: 450), rev: 7)
        let (s, pulled) = try await sync().pull(session)
        XCTAssertEqual(s.seenRev, 7)
        guard case .whole = pulled else { return XCTFail("\(pulled)") }
        XCTAssertNotNil(try order("O-2"), "every open job comes down")
        guard case .array(let log)? = try book.read()["printLog"] else { return XCTFail() }
        XCTAssertLessThan(log.count, 453, "and not the whole history")
        XCTAssertNotNil(book.scope(), "the book says it is a slice")
        let waiting = try await pending()
        XCTAssertEqual(waiting, 0, "nothing the cloud sent is pending")
    }

    func testAFirstPullKeepsWhatWasChangedHereAndNotSent() async throws {
        // A phone that worked offline against the Mac, then signs in to the cloud.
        try book.replace(with: shop(orders: 2, finished: 0), scope: nil)
        try BookWriter(book: book).setOrderStatus(orderId: "O-1", to: "qc")
        try cloud.setBase(shop(orders: 2, finished: 0), rev: 3)

        _ = try await sync().pull(session)
        XCTAssertEqual(try order("O-1")?["status"], .string("qc"), "the edit survived the pull")
        let waiting = try await pending()
        XCTAssertEqual(waiting, 1, "and is still on its way")
    }

    func testChangesFromTheCloudAreNotSentStraightBack() async throws {
        try cloud.setBase(shop(orders: 2, finished: 0), rev: 1)
        var (s, _) = try await sync().pull(session)
        // The Mac moves a job and adds one, through the cloud.
        try cloud.append(["deltas": .array([
            .object(["collection": .string("printLog"), "record": .object([
                "id": .string("O-0"), "status": .string("qc"), "rev": .number(2)])]),
            .object(["collection": .string("printLog"), "record": .object([
                "id": .string("O-9"), "status": .string("pending"), "project": .string("New"), "rev": .number(1)])]),
        ]), "tombstones": .array([]), "cursor": .object(["rev": .number(0), "ts": .string("")])])

        let pulled: CloudSync.Pulled
        (s, pulled) = try await sync().pull(s)
        XCTAssertEqual(pulled, .changes(2))
        XCTAssertEqual(s.seenRev, 2)
        XCTAssertEqual(try order("O-0")?["status"], .string("qc"))
        XCTAssertNotNil(try order("O-9"))
        let waiting = try await pending()
        XCTAssertEqual(waiting, 0, "what came from the cloud is not an edit made here")
    }

    func testAnEditGoesUpAsOneAppendedChange() async throws {
        try cloud.setBase(shop(orders: 2, finished: 0), rev: 1)
        var (s, _) = try await sync().pull(session)
        try BookWriter(book: book).setOrderStatus(orderId: "O-0", to: "post")

        let pushed: CloudSync.Pushed
        (s, pushed) = try await sync().push(s)
        XCTAssertEqual(pushed, .sent(count: 1, rev: 2))
        XCTAssertEqual(s.seenRev, 2)
        XCTAssertEqual(cloud.chain.count, 1)
        let waiting = try await pending()
        XCTAssertEqual(waiting, 0)
        XCTAssertFalse(cloud.requests.contains { $0.httpMethod == "PUT" }, "never a whole store")

        // And another device reads it: decrypt what arrived.
        let arrived = try SyncCrypto.store(cloud.chain[0].blob, dek: cloud.dek)
        guard case .array(let deltas)? = arrived["deltas"], case .object(let d)? = deltas.first,
              case .object(let rec)? = d["record"] else { return XCTFail("\(arrived)") }
        XCTAssertEqual(rec["status"], .string("post"))
    }

    func testAFullChainLeavesTheEditsHereAndNeverUploadsTheSlice() async throws {
        try cloud.setBase(shop(orders: 2, finished: 0), rev: 1)
        var (s, _) = try await sync().pull(session)
        try BookWriter(book: book).setOrderStatus(orderId: "O-0", to: "post")
        cloud.chainFull = true

        let pushed: CloudSync.Pushed
        (s, pushed) = try await sync().push(s)
        XCTAssertEqual(pushed, .needsTheMac)
        let waiting = try await pending()
        XCTAssertEqual(waiting, 1, "kept, not dropped")
        XCTAssertFalse(cloud.requests.contains { $0.httpMethod == "PUT" },
                       "a PUT from a phone would replace the shop with the phone's slice")
    }

    func testARaceIsPulledAgainAndRetried() async throws {
        try cloud.setBase(shop(orders: 2, finished: 0), rev: 1)
        let (s, _) = try await sync().pull(session)
        try BookWriter(book: book).setOrderStatus(orderId: "O-0", to: "post")
        // Somebody else writes after this phone's pull, before its send.
        try cloud.append(["deltas": .array([.object(["collection": .string("printLog"), "record": .object([
            "id": .string("O-1"), "status": .string("qc"), "rev": .number(2)])])]),
            "tombstones": .array([]), "cursor": .object(["rev": .number(0), "ts": .string("")])])

        let (after, pushed) = try await sync().push(s)
        XCTAssertEqual(pushed, .sent(count: 1, rev: 3))
        XCTAssertEqual(after.seenRev, 3)
        XCTAssertEqual(try order("O-1")?["status"], .string("qc"), "the other device's change came down too")
    }

    func testAViewerNeverSends() async throws {
        try cloud.setBase(shop(orders: 1, finished: 0), rev: 1)
        var viewer = session!
        viewer.role = "viewer"
        let (_, pushed) = try await sync().push(viewer)
        XCTAssertEqual(pushed, .readOnly)
        XCTAssertTrue(cloud.requests.isEmpty)
    }
}
