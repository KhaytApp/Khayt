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

    // MARK: Judging a 2xx (the shared replyVerdict, through the engine)

    private func judge(_ body: String?, mapped: JSONValue?, _ a: Connector.Action, _ c: Connector) async throws -> ConnectorReply {
        await ConnectorReply.judge(reply: try body.map(json), mapped: mapped, action: a, connector: c, engine: try KhaytEngine())
    }

    func testLamhasSuccessFalseIsARefusalWithItsOwnWords() async throws {
        let c = try lamha(), a = try send(c)
        let verdict = try await judge(#"{"success":false,"msg":"The customer phone is required"}"#, mapped: .object([:]), a, c)
        XCTAssertEqual(verdict, .refused("The customer phone is required"))
        let said = try XCTUnwrap(verdict.failure(connector: c))
        XCTAssertTrue(said.contains("The customer phone is required"), said)
        XCTAssertTrue(said.contains(c.name), said)
        XCTAssertNotEqual(said, L10n.tr("connectors.sent"))
    }

    func testStatusFalseAndAnErrorObjectAreRefusalsToo() async throws {
        let c = try lamha(), a = try send(c)
        let bad = try await judge(#"{"status":false,"error":{"message":"bad token"}}"#, mapped: nil, a, c)
        XCTAssertEqual(bad, .refused("bad token"))
        let bare = try await judge(#"{"success":false}"#, mapped: nil, a, c)
        XCTAssertEqual(bare, .refused(nil))
        XCTAssertTrue(try XCTUnwrap(bare.failure(connector: c)).contains(c.name))
        // A numeric status (Lamha's order objects carry one) is not a refusal,
        // nor is a "false" string.
        let numeric = try await judge(#"{"status":1,"order_id":7}"#, mapped: .object(["lamhaOrderId": .string("7")]), a, c)
        XCTAssertEqual(numeric, .confirmed)
        let text = try await judge(#"{"success":"false","order_id":7}"#, mapped: .object(["lamhaOrderId": .string("7")]), a, c)
        XCTAssertEqual(text, .confirmed)
    }

    func testAReplyThatFillsTheOrderIdIsConfirmed() async throws {
        let c = try lamha(), a = try send(c)
        let verdict = try await judge(#"{"order_id":48213}"#, mapped: .object(["lamhaOrderId": .string("48213")]), a, c)
        XCTAssertEqual(verdict, .confirmed)
    }

    /// Lamha 1.1.1 reads `order_id` or `data.id`, so both shapes map; a
    /// reply that maps nothing is still not "Sent.".
    func testLamhasDataIdShapeMapsAndAnEmptyReplyIsNotSent() async throws {
        let c = try lamha(), a = try send(c), engine = try KhaytEngine()
        let mapped = try await engine.pluginApplyResponse(c.manifest, actionId: a.id,
                                                          reply: try json(#"{"success":true,"data":{"id":456}}"#), entry: c.entry)
        XCTAssertEqual(mapped, .object(["lamhaOrderId": .string("456")]))
        let lamhaOrder = try XCTUnwrap(c.fields.first { $0.key == "lamhaOrderId" }).label
        for (body, mapped) in [("{}", JSONValue.object([:])), (#"[1,2]"#, .null)] {
            let verdict = try await judge(body, mapped: mapped, a, c)
            XCTAssertEqual(verdict, .unconfirmed([lamhaOrder]), body)
            XCTAssertTrue(try XCTUnwrap(verdict.failure(connector: c)).contains(lamhaOrder), body)
        }
        // A 2xx with no body, or one that is not JSON.
        let none = try await judge(nil, mapped: nil, a, c)
        XCTAssertEqual(none, .unconfirmed([lamhaOrder]))
    }

    func testWithoutFieldsWriteNothingCanBeMappedSoA2xxIsEnough() async throws {
        let c = try lamha(granted: false), a = try send(c)
        let plain = try await judge("{}", mapped: nil, a, c)
        XCTAssertEqual(plain, .confirmed)
        // A refusal is still a refusal.
        let no = try await judge(#"{"success":false,"msg":"no"}"#, mapped: nil, a, c)
        XCTAssertEqual(no, .refused("no"))
    }

    func testAnActionThatDeclaresNoReplyIsConfirmedByA2xx() async throws {
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
        let verdict = try await judge("{}", mapped: nil, a, c)
        XCTAssertEqual(verdict, .confirmed)
        let needs = await ConnectorReply.needsCustomer(action: a, connector: c, engine: try KhaytEngine())
        XCTAssertFalse(needs)
    }

    func testTheServicesMessageIsOneShortLine() async throws {
        let c = try lamha(), a = try send(c)
        let joined = try await judge(#"{"success":false,"msg":"  line one\nline two  "}"#, mapped: nil, a, c)
        XCTAssertEqual(joined, .refused("line one line two"))
        let long = String(repeating: "x", count: 500)
        guard case .refused(let cut?) = try await judge(#"{"success":false,"message":"\#(long)"}"#, mapped: nil, a, c) else {
            return XCTFail("not refused")
        }
        XCTAssertEqual(cut.count, 201)
        XCTAssertTrue(cut.hasSuffix("…"))
        let blank = try await judge(#"{"success":false,"msg":"   "}"#, mapped: nil, a, c)
        XCTAssertEqual(blank, .refused(nil))
    }

    /// The phone's words for a reply are the shared connector words, in
    /// every language: the desktop's `plg.*` strings with `{name}` as the
    /// first argument and `{msg}`/`{field}` as the second.
    func testTheReplyWordsAreTheSharedOnesInEveryLanguage() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let langs = ["en": "en", "ar": "ar", "de": "de", "es": "es", "fr": "fr", "ja": "ja",
                     "pt-BR": "pt-BR", "tr": "tr", "zh-Hans": "zh"]
        for (lproj, js) in langs {
            let shared = try String(contentsOf: repo.appending(path: "renderer/locales/\(js).js"), encoding: .utf8)
            let table = try XCTUnwrap(NSDictionary(contentsOf: repo.appending(
                path: "ios/KhaytCompanion/Resources/\(lproj).lproj/Localizable.strings")) as? [String: String], lproj)
            for key in ["plg.err_declined", "plg.err_declined_nomsg", "plg.sent_unconfirmed"] {
                let pattern = "\"" + NSRegularExpression.escapedPattern(for: key) + "\":\\s*(\"(?:[^\"\\\\]|\\\\.)*\")"
                let re = try NSRegularExpression(pattern: pattern)
                let m = try XCTUnwrap(re.firstMatch(in: shared, range: NSRange(shared.startIndex..., in: shared)), "\(js) \(key)")
                let literal = String(shared[Range(m.range(at: 1), in: shared)!])
                let value = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(literal.utf8), options: .fragmentsAllowed) as? String)
                let expected = value.replacingOccurrences(of: "{name}", with: "%1$@")
                    .replacingOccurrences(of: "{msg}", with: "%2$@").replacingOccurrences(of: "{field}", with: "%2$@")
                XCTAssertEqual(table[key], expected, "\(lproj) \(key)")
            }
            for gone in ["connectors.reply.refused_said", "connectors.reply.refused", "connectors.reply.unconfirmed"] {
                XCTAssertNil(table[gone], "\(lproj) \(gone)")
            }
        }
    }

    // MARK: A job with no customer

    func testLamhaNeedsACustomerOnTheJob() async throws {
        let c = try lamha(), a = try send(c)
        let needs = await ConnectorReply.needsCustomer(action: a, connector: c, engine: try KhaytEngine())
        XCTAssertTrue(needs)
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
