import XCTest
import KhaytCore
@testable import KhaytCompanion

/// The phone writes a connector's own fields (`record.plugins[<id>][<key>]`)
/// on a job or a customer, typed in or from a reply, and the Mac takes them
/// through `lib/plugin-host.js` `phoneRecord`. These hold the merge, the
/// checks, and that no other write on the phone loses `plugins`.
final class ConnectorFieldsWriteTests: XCTestCase {

    private var dir: URL!
    private var book: CompanionBook!
    private static let sharedEngine = Result { try KhaytEngine() }
    private var engine: KhaytEngine!

    private let lamhaId = "app.khayt.samples.lamha"
    private let otherPlugins: JSONValue = .object(["gone.connector": .object(["x": .number(1)])])

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "connector-fields-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        book = CompanionBook(directory: dir)
        engine = try Self.sharedEngine.get()
        try book.replace(with: shop(), scope: nil)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func shop() -> [String: JSONValue] {
        let plugins: JSONValue = .object([
            lamhaId: .object(["lamhaOrderId": .string("OLD")]),
            "gone.connector": .object(["x": .number(1)]),
        ])
        func job(_ id: String, _ status: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
            var o: [String: JSONValue] = ["id": .string(id), "status": .string(status), "project": .string("P \(id)"),
                                          "client": .string("Ward"), "clientId": .string("C-1"),
                                          "date": .string("2026-11-01"), "price": .number(100), "rev": .number(1),
                                          "plugins": plugins]
            for (k, v) in extra { o[k] = v }
            return .object(o)
        }
        return [
            "settings": .object(["shopName": .string("Ward"), "currency": .string("SAR"),
                                 "plugins": SampleShop.sampleConnectors]),
            "printLog": .array([
                job("J-1", "pending"),
                job("Q-1", "quote"),
                job("D-1", "completed", ["paidAmount": .number(0), "paymentStatus": .string("unpaid")]),
                .object(["id": .string("J-2"), "status": .string("pending"), "rev": .number(1)]),
            ]),
            "clients": .array([.object(["id": .string("C-1"), "name": .string("Ward"), "rev": .number(1),
                                        "plugins": .object(["gone.connector": .object(["y": .string("kept")])])])]),
            "machines": .array([.object(["id": .string("M-1"), "name": .string("P1S")])]),
        ]
    }

    private func row(_ collection: String, _ id: String) throws -> [String: JSONValue] {
        guard case .array(let rows)? = try book.read()[collection] else { return [:] }
        for case .object(let o) in rows where o["id"] == .string(id) { return o }
        return [:]
    }

    /// The sample shop's signed Lamha connector, as the phone reads it.
    private func lamha(granted: Bool = true) throws -> Connector {
        guard case .array(let rows) = SampleShop.sampleConnectors,
              let e = rows.compactMap({ r -> [String: JSONValue]? in
                  if case .object(let o) = r, o["id"] == .string(lamhaId) { return o }; return nil }).first
        else { throw XCTSkip("no Lamha sample") }
        var entry = e
        if !granted, case .object(var g)? = e["granted"] { g["scopes"] = .array([]); entry["granted"] = .object(g) }
        return try XCTUnwrap(ConnectorRules.connector(entry: entry, check: .object(["ok": .bool(true), "paused": .bool(false)]),
                                                      reviewed: true))
    }

    /// A connector with one field of each type, for the checks.
    private func typed() throws -> Connector {
        let m = try JSONValue.parse(Data(#"""
        {"khayt":{"manifest":1},"id":"com.example.typed","name":{"en":"Typed"},"publisher":"Example","version":"1.0.0",
         "domains":["api.example.com"],"scopes":["fields.write"],
         "fields":[{"key":"n","label":{"en":"N"},"type":"number","attach":"order"},
                   {"key":"b","label":{"en":"B"},"type":"bool","attach":"order"},
                   {"key":"d","label":{"en":"D"},"type":"date","attach":"order"},
                   {"key":"e","label":{"en":"E"},"type":"enum","attach":"order","options":[{"value":"air","label":{"en":"Air"}},{"value":"sea","label":{"en":"Sea"}}]},
                   {"key":"t","label":{"en":"T"},"type":"text","attach":"order"},
                   {"key":"c","label":{"en":"C"},"type":"text","attach":"customer"}],
         "actions":[]}
        """#.utf8))
        return try XCTUnwrap(ConnectorRules.connector(entry: ConnectorsTests.entry(m, granted: .object([:])),
                                                      check: .object(["ok": .bool(true), "paused": .bool(false)]),
                                                      reviewed: true))
    }

    // MARK: The merge

    func testTheMergeKeepsOtherConnectorsAndNeverDropsPlugins() {
        let record: [String: JSONValue] = ["id": .string("J-1"), "notes": .string("n"), "plugins": .object([
            "a": .object(["k": .string("1"), "j": .string("2")]), "b": .object(["x": .number(1)])])]
        let set = BookWriter.withConnectorValues(record, connectorId: "a", values: ["k": .string("9")])
        XCTAssertEqual(set["plugins"], .object(["a": .object(["k": .string("9"), "j": .string("2")]),
                                                "b": .object(["x": .number(1)])]))
        XCTAssertEqual(set["notes"], .string("n"), "every other key is kept")

        let cleared = BookWriter.withConnectorValues(record, connectorId: "a", values: ["k": .null, "j": .null])
        XCTAssertEqual(cleared["plugins"], .object(["b": .object(["x": .number(1)])]),
                       "clearing a connector's last value removes its id, not the others")

        let only: [String: JSONValue] = ["id": .string("J-1"), "plugins": .object(["a": .object(["k": .string("1")])])]
        let empty = BookWriter.withConnectorValues(only, connectorId: "a", values: ["k": .null])
        XCTAssertEqual(empty["plugins"], .object([:]),
                       "the last value cleared leaves plugins: {} — a record without the key keeps the Mac's values")

        let none: [String: JSONValue] = ["id": .string("J-2")]
        XCTAssertEqual(BookWriter.withConnectorValues(none, connectorId: "a", values: ["k": .null]), none,
                       "nothing to clear on a record that never had plugins: unchanged")
    }

    func testSettingAFieldWritesOnlyDeclaredKeysOnTheRightRecord() async throws {
        let c = try lamha()
        let wrote = try await BookWriter(book: book).setConnectorValues(
            ["lamhaOrderId": .string("LM-77"), "city": .string("Riyadh"), "injected": .string("x")],
            connector: c, attach: "order", recordId: "J-1", engine: engine)
        XCTAssertTrue(wrote)
        let job = try row("printLog", "J-1")
        XCTAssertEqual(job["plugins"], .object([lamhaId: .object(["lamhaOrderId": .string("LM-77")]),
                                                "gone.connector": .object(["x": .number(1)])]),
                       "a customer field and an undeclared key are not written on a job")
        XCTAssertEqual(job["rev"], .number(2), "stamped, so it travels")

        try await BookWriter(book: book).setConnectorValues(["city": .string("Jeddah")], connector: c,
                                                            attach: "customer", recordId: "C-1", engine: engine)
        XCTAssertEqual(try row("clients", "C-1")["plugins"],
                       .object([lamhaId: .object(["city": .string("Jeddah")]),
                                "gone.connector": .object(["y": .string("kept")])]))

        // Cleared: the id goes, plugins stays.
        try await BookWriter(book: book).setConnectorValues(["lamhaOrderId": .null], connector: c,
                                                            attach: "order", recordId: "J-1", engine: engine)
        XCTAssertEqual(try row("printLog", "J-1")["plugins"], otherPlugins)

        do {
            try await BookWriter(book: book).setConnectorValues(["city": .string("x")], connector: c,
                                                                attach: "customer", recordId: "C-404", engine: engine)
            XCTFail("a customer this book does not hold")
        } catch let r as BookWriter.Refusal {
            XCTAssertEqual(r, .noSuchRecord)
        }
    }

    // MARK: The checks: lib's coerceField, through the engine

    func testValuesAreCoercedByLibsRule() async throws {
        let c = try typed()
        func f(_ k: String) -> Connector.Field { c.fields.first { $0.key == k }! }
        func co(_ k: String, _ v: JSONValue) async -> JSONValue? { await ConnectorRules.coerce(f(k), v, in: c, engine: engine) }

        let n1 = await co("n", .string("12.5")), n2 = await co("n", .string("twelve")), n3 = await co("n", .bool(true))
        XCTAssertEqual(n1, .number(12.5), "a number typed as text is sent as a number")
        XCTAssertNil(n2); XCTAssertNil(n3)
        let b1 = await co("b", .string("on")), b2 = await co("b", .bool(false))
        XCTAssertEqual(b1, .bool(true)); XCTAssertEqual(b2, .bool(false))
        let d1 = await co("d", .string("2026-11-09T10:00:00Z")), d2 = await co("d", .string("9/11/2026"))
        XCTAssertEqual(d1, .string("2026-11-09")); XCTAssertNil(d2)
        let e1 = await co("e", .string("sea")), e2 = await co("e", .string("rail"))
        XCTAssertEqual(e1, .string("sea")); XCTAssertNil(e2, "a choice it does not offer")
        let t1 = await co("t", .string(String(repeating: "x", count: 600))), t2 = await co("t", .string(""))
        XCTAssertEqual(t1, .string(String(repeating: "x", count: 500)))
        XCTAssertNil(t2, "empty is no value")

        let wrote = try await BookWriter(book: book).setConnectorValues(
            ["n": .string("7"), "e": .string("rail"), "b": .string("true"), "c": .string("customer only")],
            connector: c, attach: "order", recordId: "J-2", engine: engine)
        XCTAssertTrue(wrote)
        XCTAssertEqual(try row("printLog", "J-2")["plugins"],
                       .object(["com.example.typed": .object(["n": .number(7), "b": .bool(true)])]))
    }

    // MARK: A reply

    func testAReplyIsWrittenOnlyWithFieldsWrite() async throws {
        let reply: JSONValue = .object(["success": .bool(true), "order_id": .number(48213)])

        let narrow = try lamha(granted: false)
        let none = try await engine.pluginApplyResponse(narrow.manifest, actionId: "record", reply: reply, entry: narrow.entry)
        let unsaved = await KhaytAPIClient.saveReply(none, connector: narrow, at: .order("J-1"), book: book, engine: engine)
        XCTAssertTrue(unsaved, "nothing mapped is nothing to write")
        XCTAssertEqual(try row("printLog", "J-1")["plugins"],
                       .object([lamhaId: .object(["lamhaOrderId": .string("OLD")]), "gone.connector": .object(["x": .number(1)])]),
                       "without fields.write the reply is not written")
        XCTAssertEqual(try row("printLog", "J-1")["rev"], .number(1))

        let c = try lamha()
        let mapped = try await engine.pluginApplyResponse(c.manifest, actionId: "record", reply: reply, entry: c.entry)
        XCTAssertEqual(KhaytAPIClient.replyLines(mapped, connector: c).count, 1, "and still shown")
        let saved = await KhaytAPIClient.saveReply(mapped, connector: c, at: .order("J-1"), book: book, engine: engine)
        XCTAssertTrue(saved)
        XCTAssertEqual(try row("printLog", "J-1")["plugins"],
                       .object([lamhaId: .object(["lamhaOrderId": .string("48213")]), "gone.connector": .object(["x": .number(1)])]))

        let lost = await KhaytAPIClient.saveReply(mapped, connector: c, at: .order("J-404"), book: book, engine: engine)
        XCTAssertFalse(lost, "a reply that could not be saved says so")
    }

    // MARK: Read-only

    func testOnlyAnActiveConnectorOnAnEditingPhoneIsEditable() throws {
        let active = try lamha()
        XCTAssertTrue(ConnectorRules.canEditFields(active, canWrite: true))
        XCTAssertFalse(ConnectorRules.canEditFields(active, canWrite: false), "a viewer's phone shows them read-only")
        guard case .object(let e) = active.entry else { return XCTFail() }
        var off = e; off["enabled"] = .bool(false)
        for c in [ConnectorRules.connector(entry: e, check: .object(["ok": .bool(true), "paused": .bool(true)]), reviewed: true),
                  ConnectorRules.connector(entry: e, check: .object(["ok": .bool(true), "paused": .bool(false)]), reviewed: false),
                  ConnectorRules.connector(entry: off, check: .object(["ok": .bool(true), "paused": .bool(false)]), reviewed: true),
                  ConnectorRules.connector(entry: e, check: nil, reviewed: true)] {
            let c = try XCTUnwrap(c)
            XCTAssertFalse(c.isActive)
            XCTAssertFalse(ConnectorRules.canEditFields(c, canWrite: true), "\(c.status) is read-only")
        }
    }

    // MARK: Every other write keeps plugins

    func testEveryOtherRewriteOfAJobOrCustomerCarriesPluginsThrough() async throws {
        let writer = BookWriter(book: book)
        let jobPlugins = try row("printLog", "J-1")["plugins"]
        XCTAssertNotNil(jobPlugins)

        try await writer.setOrderStatus(orderId: "J-1", to: "printing", engine: engine)
        XCTAssertNotEqual(try row("printLog", "J-1")["rev"], .number(1), "the move wrote")
        XCTAssertEqual(try row("printLog", "J-1")["plugins"], jobPlugins, "a status move")

        let machines = try JSONDecoder().decode([MachineInfo].self, from: Data(#"[{"id":"M-1","name":"P1S"}]"#.utf8))
        try writer.assignMachine(orderId: "J-1", machineId: "M-1", machines: machines)
        XCTAssertEqual(try row("printLog", "J-1")["machineId"], .string("M-1"))
        XCTAssertEqual(try row("printLog", "J-1")["plugins"], jobPlugins, "a machine assignment")

        try await writer.reviseQuote(orderId: "Q-1", fields: ["price": .number(150)], engine: engine)
        XCTAssertEqual(try row("printLog", "Q-1")["quoteVersion"], .number(2))
        XCTAssertEqual(try row("printLog", "Q-1")["plugins"], jobPlugins, "a quote revision")

        try await writer.recordFollowUp(orderId: "Q-1", engine: engine)
        XCTAssertNotNil(try row("printLog", "Q-1")["followUpSentAt"])
        XCTAssertEqual(try row("printLog", "Q-1")["plugins"], jobPlugins, "a follow-up")

        try await writer.recordPayment(orderId: "D-1", totalPaid: 40, method: "cash", engine: engine)
        XCTAssertEqual(try row("printLog", "D-1")["paidAmount"], .number(40))
        XCTAssertEqual(try row("printLog", "D-1")["plugins"], jobPlugins, "a payment")

        let clientPlugins = try row("clients", "C-1")["plugins"]
        try writer.addCommEntry(clientId: "C-1", entry: .object(["type": .string("note"), "text": .string("hi")]))
        XCTAssertNotNil(try row("clients", "C-1")["commLog"])
        XCTAssertEqual(try row("clients", "C-1")["plugins"], clientPlugins, "a customer's log line")
    }
}
