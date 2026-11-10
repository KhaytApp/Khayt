import XCTest
import KhaytCore
@testable import KhaytCompanion

/// A 2xx is not a yes on its own. In the first Lamha end-to-end test
/// (TestFlight 202611091953, job ORD-00005B, Nov 10) the phone said "Sent."
/// and Lamha had made nothing: Lamha answers a refusal with HTTP 200 and
/// `success: false`, and the job had no customer. These hold what the phone
/// says now, and what Diagnostics keeps of a reply (keys, never values).
final class ConnectorReplyTests: XCTestCase {

    private let lamhaId = "app.khayt.samples.lamha"

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

    private func send(_ c: Connector) throws -> Connector.Action {
        try XCTUnwrap(c.actions.first { $0.kind == "post" && $0.placement == "order" })
    }

    private func json(_ s: String) throws -> JSONValue { try JSONValue.parse(Data(s.utf8)) }

    // MARK: Judging a 2xx

    func testLamhasSuccessFalseIsARefusalWithItsOwnWords() throws {
        let c = try lamha(), a = try send(c)
        let reply = try json(#"{"success":false,"msg":"The customer phone is required"}"#)
        let verdict = ConnectorReply.judge(reply: reply, mapped: .object([:]), action: a, connector: c)
        XCTAssertEqual(verdict, .refused("The customer phone is required"))
        let said = try XCTUnwrap(verdict.failure(connector: c))
        XCTAssertTrue(said.contains("The customer phone is required"), said)
        XCTAssertTrue(said.contains(c.name), said)
        XCTAssertNotEqual(said, L10n.tr("connectors.sent"))
    }

    func testStatusFalseAndAnErrorObjectAreRefusalsToo() throws {
        let c = try lamha(), a = try send(c)
        XCTAssertEqual(ConnectorReply.judge(reply: try json(#"{"status":false,"error":{"message":"bad token"}}"#),
                                            mapped: nil, action: a, connector: c), .refused("bad token"))
        XCTAssertEqual(ConnectorReply.judge(reply: try json(#"{"success":false}"#), mapped: nil, action: a, connector: c),
                       .refused(nil))
        // A numeric status (Lamha's order objects carry one) is not a refusal.
        XCTAssertEqual(ConnectorReply.judge(reply: try json(#"{"status":1,"order_id":7}"#),
                                            mapped: .object(["lamhaOrderId": .string("7")]), action: a, connector: c),
                       .confirmed)
    }

    func testAReplyThatFillsTheOrderIdIsConfirmed() throws {
        let c = try lamha(), a = try send(c)
        XCTAssertEqual(ConnectorReply.judge(reply: try json(#"{"order_id":48213}"#),
                                            mapped: .object(["lamhaOrderId": .string("48213")]), action: a, connector: c),
                       .confirmed)
    }

    /// The studio's client sees the id under `data.id` too; the 1.x manifest
    /// reads only `order_id`, so that reply maps nothing. Not "Sent.".
    func testAReplyThatFillsNothingIsNotSent() throws {
        let c = try lamha(), a = try send(c)
        let lamhaOrder = try XCTUnwrap(c.fields.first { $0.key == "lamhaOrderId" }).label
        for (body, mapped) in [(#"{"success":true,"data":{"id":456}}"#, JSONValue.object([:])),
                               ("{}", .object([:])), (#"[1,2]"#, .null)] {
            let verdict = ConnectorReply.judge(reply: try json(body), mapped: mapped, action: a, connector: c)
            XCTAssertEqual(verdict, .unconfirmed([lamhaOrder]), body)
            XCTAssertTrue(try XCTUnwrap(verdict.failure(connector: c)).contains(lamhaOrder), body)
        }
        // A 2xx with no body, or one that is not JSON.
        XCTAssertEqual(ConnectorReply.judge(reply: nil, mapped: nil, action: a, connector: c), .unconfirmed([lamhaOrder]))
    }

    func testWithoutFieldsWriteNothingCanBeMappedSoA2xxIsEnough() throws {
        let c = try lamha(granted: false), a = try send(c)
        XCTAssertEqual(ConnectorReply.expectedFields(action: a, connector: c), [])
        XCTAssertEqual(ConnectorReply.judge(reply: try json("{}"), mapped: nil, action: a, connector: c), .confirmed)
        // A refusal is still a refusal.
        XCTAssertEqual(ConnectorReply.judge(reply: try json(#"{"success":false,"msg":"no"}"#), mapped: nil,
                                            action: a, connector: c), .refused("no"))
    }

    func testAnActionThatDeclaresNoReplyIsConfirmedByA2xx() throws {
        let m = try json(#"""
        {"khayt":{"manifest":1},"id":"com.example.ping","name":{"en":"Ping"},"publisher":"Example","version":"1.0.0",
         "domains":["api.example.com"],"scopes":["fields.write"],
         "fields":[{"key":"t","label":{"en":"T"},"type":"text","attach":"order"}],
         "actions":[{"id":"go","label":{"en":"Go"},"placement":"order","kind":"post","url":"https://api.example.com/go",
                     "body":{"format":"json-template","template":{"n":"{order.number}"}}}]}
        """#)
        let c = try XCTUnwrap(ConnectorRules.connector(
            entry: ConnectorsTests.entry(m, granted: .object(["scopes": .array([.string("fields.write")])])),
            check: .object(["ok": .bool(true), "paused": .bool(false)]), reviewed: true))
        let a = try XCTUnwrap(c.actions.first)
        XCTAssertEqual(ConnectorReply.judge(reply: try json("{}"), mapped: nil, action: a, connector: c), .confirmed)
        XCTAssertFalse(ConnectorReply.needsCustomer(action: a, manifest: c.manifest))
    }

    func testTheServicesMessageIsOneShortLine() {
        XCTAssertEqual(ConnectorReply.message(["msg": .string("  line one\nline two  ")]), "line one line two")
        let long = String(repeating: "x", count: 500)
        XCTAssertEqual(ConnectorReply.message(["message": .string(long)])?.count, ConnectorReply.messageLimit + 1)
        XCTAssertNil(ConnectorReply.message(["msg": .string("   ")]))
        XCTAssertNil(ConnectorReply.message(["msg": .number(3)]))
    }

    // MARK: A job with no customer

    func testLamhaNeedsACustomerOnTheJob() throws {
        let c = try lamha(), a = try send(c)
        XCTAssertTrue(ConnectorReply.needsCustomer(action: a, manifest: c.manifest))
        let said = L10n.format("connectors.error.no_customer", c.name)
        XCTAssertTrue(said.contains(c.name))
    }

    /// The real tap refuses before reading a key or sending anything; the
    /// sample shop is walked through on its own path and is not affected.
    func testTheRealTapChecksTheCustomerBeforeAnyKeyIsRead() throws {
        let src = try Self.source("Services/Connectors.swift")
        let run = try XCTUnwrap(src.range(of: "func runConnector("))
        let body = String(src[run.lowerBound...])
        let guardAt = try XCTUnwrap(body.range(of: "ConnectorReply.needsCustomer(")).lowerBound
        let keyAt = try XCTUnwrap(body.range(of: "ConnectorKeys.get(")).lowerBound
        let sampleAt = try XCTUnwrap(body.range(of: "simulateSampleConnector(")).lowerBound
        XCTAssertLessThan(sampleAt, guardAt)
        XCTAssertLessThan(guardAt, keyAt)
    }

    /// The reply is judged before anything is written or "Sent." is said,
    /// and Diagnostics notes every answer, a refused one included.
    func testTheRealTapJudgesTheReplyBeforeSavingIt() throws {
        let src = try Self.source("Services/Connectors.swift")
        let run = try XCTUnwrap(src.range(of: "func runConnector("))
        let end = try XCTUnwrap(src.range(of: "private func simulateSampleConnector(", range: run.upperBound..<src.endIndex))
        let body = String(src[run.lowerBound..<end.lowerBound])
        let note = try XCTUnwrap(body.range(of: "ConnectorReplyNote.record(ConnectorReplyNote(status: status")).lowerBound
        let status = try XCTUnwrap(body.range(of: "guard (200..<300).contains(status)")).lowerBound
        let judge = try XCTUnwrap(body.range(of: "ConnectorReply.judge(")).lowerBound
        let save = try XCTUnwrap(body.range(of: "Self.saveReply(")).lowerBound
        let sent = try XCTUnwrap(body.range(of: "return .sent(")).lowerBound
        XCTAssertLessThan(note, status)
        XCTAssertLessThan(status, judge)
        XCTAssertLessThan(judge, save)
        XCTAssertLessThan(judge, sent)
        XCTAssertTrue(body.contains("ConnectorReplyNote.record(ConnectorReplyNote(status: 0, body: nil))"),
                      "a send with no answer is noted too")
    }

    // MARK: Diagnostics

    func testTheNoteKeepsKeysAndNeverValues() throws {
        let body = Data(#"{"success":false,"msg":"Customer 0551234567 has no city","token":"sk_live_x"}"#.utf8)
        let note = ConnectorReplyNote(at: Date(timeIntervalSince1970: 0), status: 200, body: body)
        XCTAssertEqual(note.status, 200)
        XCTAssertEqual(note.success, "false")
        XCTAssertEqual(note.keys, ["msg", "success", "token"])
        let stored = String(decoding: try JSONEncoder().encode(note), as: UTF8.self)
        for value in ["0551234567", "no city", "sk_live_x"] {
            XCTAssertFalse(stored.contains(value), value)
            XCTAssertFalse(note.summary.contains(value), value)
        }
        XCTAssertTrue(note.summary.hasPrefix("200 · success false · "), note.summary)
    }

    func testTheNoteForNoAnswerAndForANonJSONBody() {
        let none = ConnectorReplyNote(status: 0, body: nil)
        XCTAssertEqual(none.keys, [])
        XCTAssertNil(none.success)
        XCTAssertTrue(none.summary.hasPrefix(L10n.tr("diag.reply.no_answer")))
        let html = ConnectorReplyNote(status: 502, body: Data("<html>bad gateway</html>".utf8))
        XCTAssertEqual(html.keys, [])
        XCTAssertFalse(html.summary.contains("bad gateway"))
    }

    func testTheNoteIsCappedAndForgottenOnUnpair() throws {
        let many = Dictionary(uniqueKeysWithValues: (0..<50).map { (String(repeating: "k", count: 60) + "\($0)", $0) })
        let note = ConnectorReplyNote(status: 200, body: try JSONSerialization.data(withJSONObject: many))
        XCTAssertEqual(note.keys.count, ConnectorReplyNote.maxKeys)
        XCTAssertTrue(note.keys.allSatisfy { $0.count <= ConnectorReplyNote.maxKeyLength })

        let suite = "connector-reply-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = SyncDiagnostics.defaults
        SyncDiagnostics.defaults = defaults
        defer { SyncDiagnostics.defaults = saved }
        ConnectorReplyNote.record(note)
        XCTAssertEqual(SyncDiagnostics.recorded().connectorReply, note)
        SyncDiagnostics.forget()
        XCTAssertNil(SyncDiagnostics.recorded().connectorReply)
    }

    // MARK: Helpers

    static func source(_ path: String) throws -> String {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "KhaytCompanion")
        return try String(contentsOf: app.appending(path: path), encoding: .utf8)
    }
}
