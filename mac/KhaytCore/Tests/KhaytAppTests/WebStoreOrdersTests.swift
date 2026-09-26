import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A paid web-store order becomes a job by itself — once, on the right
/// customer, with the shelf taken down — and its progress goes back out.
///
/// Every write here goes through `Shop.putOnlineOrder` inside a real
/// `StoreWriter.update` against a file, because the three things that matter
/// (never twice, the shelf, the customer) are all read-modify-writes of the
/// book, and a test on a dictionary would prove nothing about the chain.
@MainActor
struct WebStoreOrdersTests {

    static func book() -> [String: JSONValue] {
        [
            "printLog": .array([]),
            "inventory": .array([]),
            "machines": .array([]),
            "products": .array([
                .object(["id": .string("PRD-A"), "nameEn": .string("Flexi Dragon")]),
            ]),
            "clients": .array([
                .object(["id": .string("CLI-1"), "nameEn": .string("Nora"),
                         "email": .string("NORA@example.com"), "phone": .string("")]),
                .object(["id": .string("CLI-2"), "nameEn": .string("Fahad"),
                         "email": .string(""), "phone": .string("+966 50 123 4567")]),
            ]),
            "settings": .object([
                "currency": .string("SAR"),
                "invNumNext": .number(1),
                "storefront": .object([
                    "stockQty": .object(["PRD-A": .number(5)]),
                    "stockCountedAt": .object(["PRD-A": .string("2026-09-01T00:00:00.000Z")]),
                ]),
            ]),
        ]
    }

    /// A queue item as khayt-cloud's `mapPlatformOrder` files a Medusa order.
    static func payload(ref: String = "medusa:#1042", qty: Int = 2,
                        contact: String = "nora@example.com", name: String = "Nora Alqahtani",
                        source: String = "medusa") -> JSONValue {
        .object([
            "name": .string(name), "contact": .string(contact),
            "title": .string("Medusa order — \(ref)"),
            "description": .string("• Flexi Dragon × \(qty)"),
            "qty": .string(String(qty)), "source": .string(source), "ref": .string(ref),
        ])
    }

    /// A job input the way `onlineJobInput` hands one over: a priced part.
    static let input: [String: JSONValue] = [
        "project": .string("Medusa order — #1042"),
        "source": .string("medusa"),
        "sourceOrderId": .string("medusa:#1042"),
        "parts": .array([.object([
            "name": .string("Flexi Dragon"), "qty": .number(2),
            "printWeight": .number(40), "baseCost": .number(30), "unitCost": .number(30),
        ])]),
    ]

    struct Scratch {
        let url: URL
        let dir: URL
        func read() throws -> [String: JSONValue] {
            try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
        }
    }

    static func scratch() throws -> Scratch {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "khayt-webstore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "khayt-store.json")
        try JSONEncoder().encode(book()).write(to: url)
        return Scratch(url: url, dir: dir)
    }

    /// Read the order against the book on disk, then put it in, in one write —
    /// the same two steps `writeOnlineOrder` takes.
    static func put(_ payload: JSONValue, intakeId: String, input: [String: JSONValue] = input,
                    into scratch: Scratch, engine: KhaytEngine) async throws -> Shop.Recorded {
        let now = Date()
        let root = try scratch.read()
        let order = try await Shop.onlineOrder(
            CloudIntake.Item(id: intakeId, payload: payload, createdAt: now),
            products: Shop.rows(root, "products"),
            stock: Shop.stockCounts(Shop.settings(root)), engine: engine)
        let deductions = Shop.deductions(try await engine.shelfSaleEffects(order.reading, at: now))
        let paid = order.decision?.paid ?? false
        var recorded: Shop.Recorded = .alreadyThere
        try await StoreWriter.update(storeURL: scratch.url, owns: { true }, whoHasIt: { nil }) { root in
            recorded = try await Shop.putOnlineOrder(order, input: input, paid: paid,
                                                     deductions: deductions, into: &root,
                                                     engine: engine, now: now).recorded
        }
        return recorded
    }

    static func jobs(_ root: [String: JSONValue]) -> [[String: JSONValue]] {
        Shop.rows(root, "printLog").compactMap { if case .object(let o) = $0 { return o } else { return nil } }
    }

    // MARK: - Never twice

    @Test("the same platform order is one job, however many times it is put")
    func idempotent() async throws {
        let engine = try KhaytEngine()
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch.dir) }

        let first = try await Self.put(Self.payload(), intakeId: "12", into: scratch, engine: engine)
        guard case .made = first else { Issue.record("the first put made nothing: \(first)"); return }
        // The same queue item again — a drain that failed last pass.
        #expect(try await Self.put(Self.payload(), intakeId: "12", into: scratch, engine: engine)
                == .alreadyThere)
        // The same platform order under a DIFFERENT queue item — the store
        // retried and the cloud filed it twice, or a webhook got there first.
        #expect(try await Self.put(Self.payload(), intakeId: "13", into: scratch, engine: engine)
                == .alreadyThere)

        let book = try scratch.read()
        #expect(Self.jobs(book).count == 1, "one platform order became \(Self.jobs(book).count) jobs")
        #expect(Shop.stockCount(of: "PRD-A", in: .object(Shop.settings(book))) == 3,
                "a repeat took the shelf down a second time")
    }

    // MARK: - The shelf

    @Test("what the shelf has is reserved, and an order it covers is already done")
    func reservesStock() async throws {
        let engine = try KhaytEngine()
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch.dir) }

        _ = try await Self.put(Self.payload(qty: 2), intakeId: "1", into: scratch, engine: engine)
        var book = try scratch.read()
        #expect(Shop.stockCount(of: "PRD-A", in: .object(Shop.settings(book))) == 3)
        let sold = try #require(Self.jobs(book).first)
        #expect(sold["status"] == .string("completed"),
                "an order the shelf answered in full was left for a machine")

        // Four more, with three left: three come off, one is printed.
        _ = try await Self.put(Self.payload(ref: "medusa:#1043", qty: 4), intakeId: "2",
                               into: scratch, engine: engine)
        book = try scratch.read()
        #expect(Shop.stockCount(of: "PRD-A", in: .object(Shop.settings(book))) == 0)
        let printing = try #require(Self.jobs(book).first)
        #expect(printing["status"] != .string("completed"),
                "an order with printing left in it was marked done")
    }

    // MARK: - The customer

    @Test("the same email is the customer already in the book")
    func linksExistingCustomer() async throws {
        let engine = try KhaytEngine()
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch.dir) }

        let made = try await Self.put(Self.payload(), intakeId: "1", into: scratch, engine: engine)
        guard case .made(_, let clientId, let newCustomer, _) = made else {
            Issue.record("nothing made"); return
        }
        #expect(clientId == "CLI-1")
        #expect(!newCustomer)
        let book = try scratch.read()
        #expect(Self.jobs(book).first?["clientId"] == .string("CLI-1"))
        #expect(Shop.rows(book, "clients").count == 2, "a known customer was made twice")
    }

    @Test("the same phone, written another way, is the same customer")
    func linksByPhone() async throws {
        let engine = try KhaytEngine()
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch.dir) }
        let made = try await Self.put(Self.payload(contact: "0501234567", name: "F"),
                                      intakeId: "1", into: scratch, engine: engine)
        guard case .made(_, let clientId, _, _) = made else { Issue.record("nothing made"); return }
        #expect(clientId == "CLI-2")
    }

    @Test("a new customer is created once, and the next order finds them")
    func createsCustomerOnce() async throws {
        let engine = try KhaytEngine()
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch.dir) }

        let first = try await Self.put(Self.payload(contact: "sara@example.com", name: "Sara"),
                                       intakeId: "1", into: scratch, engine: engine)
        guard case .made(_, let created?, true, _) = first else {
            Issue.record("no new customer: \(first)"); return
        }
        var book = try scratch.read()
        let clients = Shop.rows(book, "clients")
        #expect(clients.count == 3)
        let record = try #require(clients.compactMap { row -> [String: JSONValue]? in
            if case .object(let o) = row, o["id"] == .string(created) { return o }
            return nil
        }.first)
        #expect(record["nameEn"] == .string("Sara"))
        #expect(record["email"] == .string("sara@example.com"))
        #expect(record["source"] == .string("online"))
        #expect(record["rev"] != nil, "a new customer was written without a revision, so it never syncs")

        let second = try await Self.put(Self.payload(ref: "medusa:#2000", contact: "SARA@example.com",
                                                     name: "Sara"),
                                        intakeId: "2", into: scratch, engine: engine)
        guard case .made(_, let again, let newAgain, _) = second else { Issue.record("nothing made"); return }
        #expect(again == created)
        #expect(!newAgain)
        book = try scratch.read()
        #expect(Shop.rows(book, "clients").count == 3, "a returning customer was made twice")
    }

    // MARK: - Paid

    @Test("a paid web-store order is recorded as paid, through the payment rule")
    func paid() async throws {
        let engine = try KhaytEngine()
        let scratch = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: scratch.dir) }
        let made = try await Self.put(Self.payload(), intakeId: "1", into: scratch, engine: engine)
        guard case .made(_, _, _, let paid) = made else { Issue.record("nothing made"); return }
        #expect(paid)
        let job = try #require(Self.jobs(try scratch.read()).first)
        #expect(job["paymentStatus"] == .string("paid"))
        #expect(Shop.plainNumber(job["paidAmount"]) == Shop.plainNumber(job["price"]))
        #expect(job["sourceOrderId"] == .string("medusa:#1042"))
        #expect(job["intakeId"] == .string("1"))
    }

    @Test("an order the store has not said is paid is left for a person")
    func unpaidWaits() async throws {
        let engine = try KhaytEngine()
        let salla = try await engine.webStoreDecision(Self.payload(ref: "salla:SL-1", source: "salla"))
        #expect(!salla.auto)
        #expect(salla.reason == "payment_unknown")
        let medusa = try await engine.webStoreDecision(Self.payload())
        #expect(medusa.auto && medusa.paid)
        let typed = try await engine.webStoreDecision(.object(["title": .string("A vase?")]))
        #expect(typed.reason == "hand_request")
    }

    // MARK: - Out

    @Test("progress is owed once per change, and remembered by fingerprint")
    func statusesOwed() async throws {
        let engine = try KhaytEngine()
        let log: [JSONValue] = [
            .object(["id": .string("J1"), "status": .string("printing"), "source": .string("medusa"),
                     "sourceOrderId": .string("medusa:#1042"),
                     "timestamp": .string("2026-09-26T08:00:00Z")]),
            .object(["id": .string("J2"), "status": .string("pending"), "source": .string("walk_in")]),
        ]
        let owed = try await engine.webStoreStatusesOwed(printLog: log, sent: [:], notBefore: "")
        #expect(owed.map(\.ref) == ["medusa:#1042"])
        #expect(owed.first?.status == "printing")
        let sent = [owed[0].ref: try await engine.webStoreFingerprint(owed[0])]
        #expect(try await engine.webStoreStatusesOwed(printLog: log, sent: sent, notBefore: "").isEmpty)
    }

    @Test("the update is POSTed to the contract's path, with the header sync depends on")
    func publisherRequest() async throws {
        let connection = CloudReader.Connection(url: "https://cloud.khaytapp.com",
                                                shopId: "shop_a1", storedToken: "")
        let update = try JSONDecoder().decode(KhaytEngine.WebStoreStatus.self, from: Data("""
            {"ref":"medusa:#1042","platform":"medusa","jobId":"J1","status":"shipped",
             "trackingNumber":"SM1","carrier":"smsa","carrierName":"SMSA",
             "trackingUrl":"https://example.com/t","shippedAt":"2026-09-27T10:00:00Z",
             "deliveredAt":null,"updatedAt":"2026-09-27T10:00:00Z"}
            """.utf8))
        var seen: URLRequest?
        try await WebStoreStatusPublisher.publish(connection, token: "t", updates: [update]) { request in
            seen = request
            return (Data(#"{"ok":true}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let request = try #require(seen)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/shops/shop_a1/order-status")
        #expect(request.value(forHTTPHeaderField: "x-delta-capable") == "1")
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        let updates = body?["updates"] as? [[String: Any]]
        #expect(updates?.first?["trackingNumber"] as? String == "SM1")
        #expect(updates?.first?["status"] as? String == "shipped")

        // A cloud without the route answers 404, which is "not yet", not a fault.
        await #expect(throws: WebStoreStatusPublisher.Failure.notOffered) {
            try await WebStoreStatusPublisher.publish(connection, token: "t", updates: [update]) { request in
                (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
        }
    }
}
