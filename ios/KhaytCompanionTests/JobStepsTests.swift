import KhaytCore
import XCTest
@testable import KhaytCompanion

/// The job page's next step comes from the SHARED rule (`lib/order-next-step.js`,
/// Mac #2462), not a table of the phone's own (S1, Nov 2026).
@MainActor
final class JobStepsTests: XCTestCase {
    private var dir: URL!
    private var settings: ConnectionSettings!
    private var savedSample = false

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "steps-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settings = ConnectionSettings()
        savedSample = settings.isSampleShop
        settings.isSampleShop = false
    }
    override func tearDownWithError() throws {
        settings.isSampleShop = savedSample
        try? FileManager.default.removeItem(at: dir)
    }

    private func client(_ store: [String: JSONValue]) throws -> (KhaytAPIClient, CompanionBook) {
        let book = CompanionBook(directory: dir)
        try book.replace(with: store, scope: nil)
        return (KhaytAPIClient(settings: settings, book: book), book)
    }

    // MARK: Parity with lib on the sample book

    /// The phone asks with the job and the jobs in working stages only; that
    /// must be the whole book's answer, for EVERY job on the sample book.
    func testThePhonesAnswerIsTheWholeBooksAnswerForEveryJob() async throws {
        let store = SampleShop.book()
        let (api, book) = try client(store)
        let engine = try await BookReader(book: book).sharedEngine()
        let all = JSRead.rows(store, "printLog")
        var shopSettings: [String: JSONValue] = [:]
        if case .object(let s)? = store["settings"] { shopSettings = s }
        let late = try await engine.lateOrders(all, machines: JSRead.rows(store, "machines"), settings: shopSettings)
        let whole = try await engine.orderNextSteps(all, settings: shopSettings, lateIds: Array(late), canWrite: api.canWrite)
        XCTAssertGreaterThan(whole.count, 5)
        var stages = Set<String>()
        for case .object(let o) in all {
            guard case .string(let id)? = o["id"] else { continue }
            let phone = await api.nextSteps(orderId: id)
            XCTAssertEqual(phone, whole[id], id)
            if let st = whole[id]?.stage { stages.insert(st) }
        }
        XCTAssertTrue(stages.isSuperset(of: ["quote", "pending", "printing"]), "the sample book spans the stages: \(stages)")
    }

    func testAWipLimitStillBlocksWhenOnlyWorkingJobsAreSent() async throws {
        var store = SampleShop.book()
        guard case .object(var s)? = store["settings"] else { return XCTFail("settings") }
        s["wipLimits"] = .object(["printing": .number(1)])
        s["wipEnforceHardLimit"] = .bool(true)
        store["settings"] = .object(s)
        let (api, _) = try client(store)
        let pending = JSRead.rows(store, "printLog").compactMap { row -> String? in
            guard case .object(let o) = row, o["status"] == .string("pending"), o["voidedAt"] == nil,
                  case .string(let id)? = o["id"] else { return nil }
            return id
        }
        let id = try XCTUnwrap(pending.first)
        let answer = await api.nextSteps(orderId: id)
        XCTAssertEqual(answer?.primary?.code, "start_printing")
        XCTAssertEqual(answer?.primary?.blocked?.code, "wip_blocked", "a printing column at its limit")
    }

    // MARK: The one phone-side adjustment

    private func rule(_ json: String) throws -> JobSteps.Rule {
        try JSONDecoder().decode(JobSteps.Rule.self, from: Data(json.utf8))
    }
    private let unsharedQuote = #"""
    {"stage":"quote","pill":{"stage":"quote","tone":"steel"},"late":false,"owed":0,"heldFrom":null,
     "primary":{"code":"send_quote","to":null,"asks":"send","blocked":null},
     "secondary":[{"code":"take_job","to":"pending","asks":null,"blocked":null}],"track":[]}
    """#

    func testAQuoteWithNoCustomerLinkLeadsWithTakeJob() throws {
        let r = try rule(unsharedQuote)
        let without = JobSteps.arranged(r, hasCustomerLink: false)
        XCTAssertEqual(without.primary?.code, "take_job")
        XCTAssertTrue(without.secondary.isEmpty, "Send quote is not offered with nothing to send")
        let with = JobSteps.arranged(r, hasCustomerLink: true)
        XCTAssertEqual(with.primary?.code, "send_quote", "the rule's own answer")
        XCTAssertEqual(with.secondary.map(\.code), ["take_job"])
    }

    func testOtherStagesAreLeftAsTheRuleSaysThem() throws {
        let r = try rule(#"{"stage":"qc","pill":{"stage":"qc","tone":"amber"},"late":false,"owed":0,"heldFrom":null,"primary":{"code":"mark_ready","to":"completed","asks":"actuals","blocked":null},"secondary":[{"code":"fail_check","to":"post","asks":"qc_fail","blocked":null}],"track":[]}"#)
        for link in [true, false] {
            let a = JobSteps.arranged(r, hasCustomerLink: link)
            XCTAssertEqual(a.primary?.code, "mark_ready")
            XCTAssertEqual(a.secondary.map(\.code), ["fail_check"])
        }
    }

    // MARK: Sharing a quote stamps quoteSharedAt — only when done

    private func aQuote(_ store: [String: JSONValue]) throws -> String {
        let ids = JSRead.rows(store, "printLog").compactMap { row -> String? in
            guard case .object(let o) = row, o["status"] == .string("quote"), o["voidedAt"] == nil,
                  case .string(let id)? = o["id"] else { return nil }
            return id
        }
        return try XCTUnwrap(ids.first)
    }

    private func sharedAt(_ book: CompanionBook, _ id: String) throws -> JSONValue? {
        for case .object(let o) in JSRead.rows(try book.read(), "printLog") where o["id"] == .string(id) { return o["quoteSharedAt"] }
        return nil
    }

    func testACompletedShareStampsTheQuoteAndTakeJobLeads() async throws {
        var store = SampleShop.book()
        // A quote not yet shared, whatever the sample says.
        if case .array(var rows)? = store["printLog"] {
            for i in rows.indices { if case .object(var o) = rows[i] { o["quoteSharedAt"] = nil; rows[i] = .object(o) } }
            store["printLog"] = .array(rows)
        }
        let (api, book) = try client(store)
        let id = try aQuote(store)
        let step1 = await api.nextSteps(orderId: id)
        XCTAssertEqual(step1?.primary?.code, "send_quote")
        let stamped = try await api.quoteShareEnded(orderId: id, completed: true)
        XCTAssertTrue(stamped)
        guard case .string(let at)? = try sharedAt(book, id) else { return XCTFail("no quoteSharedAt") }
        XCTAssertNotNil(ISO8601DateFormatter().date(from: at))
        let step2 = await api.nextSteps(orderId: id)
        XCTAssertEqual(step2?.primary?.code, "take_job", "a shared quote leads with Take job")
        // A second share keeps the first stamp.
        try await api.quoteShareEnded(orderId: id, completed: true, now: Date().addingTimeInterval(3600))
        XCTAssertEqual(try sharedAt(book, id), .string(at))
    }

    func testACancelledShareStampsNothing() async throws {
        var store = SampleShop.book()
        if case .array(var rows)? = store["printLog"] {
            for i in rows.indices { if case .object(var o) = rows[i] { o["quoteSharedAt"] = nil; rows[i] = .object(o) } }
            store["printLog"] = .array(rows)
        }
        let (api, book) = try client(store)
        let id = try aQuote(store)
        let stamped = try await api.quoteShareEnded(orderId: id, completed: false)
        XCTAssertFalse(stamped)
        XCTAssertNil(try sharedAt(book, id))
        let step3 = await api.nextSteps(orderId: id)
        XCTAssertEqual(step3?.primary?.code, "send_quote")
    }

    /// The job page's "Sent" line reads quoteSharedAt, never the
    /// quoteSentAt every quote is given at creation.
    func testSentIsTheShareStampNotTheCreationStamp() throws {
        let unshared = try JSONDecoder().decode(OrderLogEntry.self, from: Data(#"{"id":"Q-1","status":"quote","date":"2026-11-12","quoteExpiresAt":"2026-11-19","quoteSentAt":"2026-11-12"}"#.utf8))
        XCTAssertNil(unshared.quoteSharedAt)
        let shared = try JSONDecoder().decode(OrderLogEntry.self, from: Data(#"{"id":"Q-1","status":"quote","date":"2026-11-12","quoteExpiresAt":"2026-11-19","quoteSharedAt":"2026-11-13T09:00:00Z"}"#.utf8))
        XCTAssertEqual(shared.quoteSharedAt, "2026-11-13T09:00:00Z")
    }

    // MARK: Words

    func testEveryCodeTheRuleNamesHasWordsInEveryLanguage() {
        let codes = ["send_quote", "take_job", "start_printing", "mark_printed", "send_to_check", "mark_ready",
                     "resume", "hand_over", "record_payment", "hold", "fail_check", "ship"]
        let blocks = ["production_paused", "wip_blocked", "assembly_not_assembled", "assembly_parts", "read_only", "something_new"]
        for lang in AppLanguage.allCases where lang != .system {
            L10n.setLanguage(lang)
            for code in codes {
                let key = JobSteps.verbKey(code)
                XCTAssertNotNil(key, code)
                if let key { XCTAssertNotEqual(L10n.tr(key), key, "\(lang) \(code)") }
            }
            for code in blocks {
                let json = #"{"code":"\#(code)","params":{"col":"printing","n":2,"parts":"Arm"}}"#
                guard let b = try? JSONDecoder().decode(JobSteps.Blocked.self, from: Data(json.utf8)) else { return XCTFail(code) }
                let text = JobSteps.blockedText(b)
                XCTAssertFalse(text.hasPrefix("job.blocked"), "\(lang) \(code)")
            }
            XCTAssertNotEqual(L10n.tr("job.pill.paid"), "job.pill.paid")
        }
        L10n.setLanguage(.system)
        XCTAssertNil(JobSteps.verbKey("something_new"), "an unknown step is not offered")
    }

    func testAHeldJobStandsWhereItWasHeld() throws {
        let r = try rule(#"{"stage":"on_hold","pill":{"stage":"on_hold","tone":"purple"},"late":false,"owed":0,"heldFrom":"post","primary":{"code":"resume","to":"post","asks":null,"blocked":null},"secondary":[],"track":[{"stage":"pending","state":"done","at":""},{"stage":"printing","state":"done","at":""},{"stage":"post","state":"current","at":""},{"stage":"qc","state":"todo","at":""},{"stage":"completed","state":"todo","at":""}]}"#)
        XCTAssertEqual(JobSteps.trackCurrent(r), .post)
    }
}
