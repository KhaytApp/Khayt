import XCTest
import JavaScriptCore
import KhaytCore
@testable import KhaytCompanion

/**
 * The phone's job edits run the shared rule (`lib/order-edit.js`
 * `applyJobEdit` and `marginOf`, #2469), and give the answer the REAL
 * JavaScript gives.
 *
 * The parity half loads `lib/` itself into JavaScriptCore, so nothing here is
 * a copied expectation: every job on the sample book, and fixtures for the
 * cases the sample book cannot reach (a job paid in full, a quote with a
 * deposit, a typed price, a job in another currency, a stored margin), is
 * edited by both and must come out the same, refusal and all.
 *
 * The other half is what the shop sees: a price below what was paid is
 * refused in the Mac's words with nothing written (never capped), and the
 * margin row reads "38%" or "—".
 */
@MainActor
final class JobEditRuleTests: XCTestCase {

    /// 2026-11-14T09:00:00Z.
    private let now = Date(timeIntervalSince1970: 1_794_646_800)
    private var js: JSContext!
    private var dir: URL!
    private var settings: ConnectionSettings!
    private var savedSample = false

    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let ctx = try XCTUnwrap(JSContext())
        var thrown: String?
        ctx.exceptionHandler = { _, e in thrown = e?.toString() }
        for file in ["lib/tax.js", "lib/pricing.js", "lib/order-money.js", "lib/order-payment.js", "lib/order-edit.js"] {
            let source = try String(contentsOf: root.appending(path: file), encoding: .utf8)
            ctx.evaluateScript(source)
            XCTAssertNil(thrown, "\(file) did not load: \(thrown ?? "")")
        }
        js = ctx
        dir = FileManager.default.temporaryDirectory.appending(path: "jobedit-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settings = ConnectionSettings()
        savedSample = settings.isSampleShop
        settings.isSampleShop = false
    }

    override func tearDownWithError() throws {
        settings.isSampleShop = savedSample
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Fixtures (sample data only)

    private static func part(_ id: String, base: Double) -> JSONValue {
        .object(["id": .string(id), "name": .string("Arm \(id)"), "qty": .number(1), "material": .string("PLA"),
                 "printWeight": .number(40), "printTime": .number(2), "unitCost": .number(base), "baseCost": .number(base)])
    }

    /// Paid in full and printing: a lower price must be refused.
    static let paidJob: JSONValue = .object([
        "id": .string("T-PAID"), "project": .string("Drone arm set"), "status": .string("printing"),
        "price": .number(1200), "paidAmount": .number(1200), "paymentStatus": .string("paid"),
        "priority": .bool(false), "parts": .array([part("a", base: 500), part("b", base: 369.57)]),
    ])
    /// Cost-plus at 40%: parts cost 100, priced 140.
    static let costPlus: JSONValue = .object([
        "id": .string("T-40"), "project": .string("Bracket"), "status": .string("pending"),
        "price": .number(140), "paidAmount": .number(0), "priority": .bool(false),
        "parts": .array([part("a", base: 60), part("b", base: 40)]),
    ])
    /// A typed total: no margin can be said.
    static let typed: JSONValue = .object([
        "id": .string("T-TYPED"), "project": .string("Sign"), "status": .string("pending"),
        "price": .number(1500), "computedPrice": .number(1320), "priceSource": .string("override"),
        "priceOverride": .number(1500), "paidAmount": .number(1500), "priority": .bool(false),
        "parts": .array([part("a", base: 1000)]),
    ])
    /// Another currency: the rate is folded into the factor, so no margin.
    static let foreign: JSONValue = .object([
        "id": .string("T-FX"), "project": .string("Case"), "status": .string("pending"), "fxRate": .number(3.75),
        "price": .number(140), "priority": .bool(false), "parts": .array([part("a", base: 100)]),
    ])
    /// The margin as typed on the job.
    static let stored: JSONValue = .object([
        "id": .string("T-STORED"), "project": .string("Plate"), "status": .string("pending"), "marginPct": .number(25),
        "price": .number(500), "priority": .bool(false), "parts": .array([part("a", base: 100)]),
    ])
    /// A quote with a deposit already paid.
    static let depositQuote: JSONValue = .object([
        "id": .string("T-QUOTE"), "project": .string("Prototype housing"), "status": .string("quote"),
        "price": .number(340), "paidAmount": .number(100), "priority": .bool(false),
        "parts": .array([part("a", base: 200)]),
    ])
    static let fixtures = [paidJob, costPlus, typed, foreign, stored, depositQuote]

    private func client(orders: [JSONValue]) throws -> (KhaytAPIClient, CompanionBook) {
        var store = SampleShop.book()
        store["printLog"] = .array(orders)
        let book = CompanionBook(directory: dir)
        try book.replace(with: store, scope: nil)
        return (KhaytAPIClient(settings: settings, book: book), book)
    }

    private func row(_ book: CompanionBook, _ id: String) throws -> JSONValue {
        guard case .array(let rows)? = try book.read()["printLog"],
              let r = rows.first(where: { if case .object(let o) = $0 { return o["id"] == .string(id) }; return false })
        else { throw XCTSkip("no \(id)") }
        return r
    }

    // MARK: - Asking the JavaScript

    private func json(_ v: JSONValue) -> String { String(data: try! JSONEncoder().encode(v), encoding: .utf8)! }

    private func ask(_ expression: String) throws -> JSONValue {
        let out = try XCTUnwrap(js.evaluateScript("JSON.stringify(\(expression))")?.toString(), expression)
        return try JSONDecoder().decode(JSONValue.self, from: Data(out.utf8))
    }

    /// `applyJobEdit` in lib, as the bridge calls it.
    private func libEdit(_ order: JSONValue, _ fields: [String: JSONValue], _ s: [String: JSONValue]) throws -> JSONValue {
        try ask("""
            (function () { var o = \(json(order));
              var r = KhaytOrderEdit.applyJobEdit(o, \(json(.object(fields))), { clients: [], settings: \(json(.object(s))),
                keepPrice: false, marginPct: null, ids: [], now: \(now.timeIntervalSince1970 * 1000), id: 'edit-1', priceId: 'price-1' });
              return { ok: r.ok, reason: r.reason || null, changed: !!r.changed, order: o }; })()
            """)
    }

    // MARK: - Parity

    func testTheEditAndTheMarginAreLibsAnswerForEveryJob() async throws {
        let store = SampleShop.book()
        guard case .array(let sample)? = store["printLog"], case .object(let shopSettings)? = store["settings"] else {
            return XCTFail("the sample book has jobs and settings")
        }
        let engine = try await BookReader(book: { let b = CompanionBook(directory: dir); try b.replace(with: store, scope: nil); return b }()).sharedEngine()
        var refused = 0, edited = 0, margins = 0, dashes = 0
        for order in sample + Self.fixtures {
            guard case .object(let o) = order, case .string(let id)? = o["id"] else { continue }
            // The margin.
            let swiftMargin = try await engine.marginOf(order)
            let libMargin = try ask("KhaytOrderEdit.marginOf(\(json(order)))")
            switch (swiftMargin, libMargin) {
            case (nil, .null): dashes += 1
            case (let m?, .number(let n)): XCTAssertEqual(m, n, accuracy: 1e-9, "\(id): margin"); margins += 1
            default: XCTFail("\(id): margin swift \(String(describing: swiftMargin)) lib \(libMargin)")
            }
            // Three edits each: a price under what was paid, one above, and a due date.
            var paid = 0.0
            if case .number(let p)? = o["paidAmount"] { paid = p }
            var price = 0.0
            if case .number(let p)? = o["price"] { price = p }
            let edits: [[String: JSONValue]] = [
                ["price": .number(max(0, paid - 1))],
                ["price": .number(price + 10), "priorityLevel": .string("urgent")],
                ["dueDate": .string("2026-12-01")],
            ]
            for fields in edits {
                let swift = try await engine.applyJobEdit(order: order, fields: fields, settings: shopSettings,
                                                          now: now, editId: "edit-1", priceId: "price-1")
                let lib = try libEdit(order, fields, shopSettings)
                guard case .object(let l) = lib else { return XCTFail() }
                XCTAssertEqual(.bool(swift.ok), l["ok"], "\(id) \(fields): ok")
                XCTAssertEqual(swift.reason.map(JSONValue.string) ?? .null, l["reason"], "\(id) \(fields): reason")
                XCTAssertEqual(.bool(swift.changed), l["changed"], "\(id) \(fields): changed")
                if swift.ok, swift.changed { XCTAssertEqual(swift.order, l["order"], "\(id) \(fields): the job after") }
                if !swift.ok { refused += 1 } else if swift.changed { edited += 1 }
            }
        }
        // The cases are all reached, or the parity proves less than it says.
        XCTAssertGreaterThanOrEqual(refused, 2, "the paid job and the deposit quote are refused")
        XCTAssertGreaterThan(edited, sample.count, "edits that land")
        XCTAssertGreaterThanOrEqual(margins, 2, "a margin read off the parts, and one stored")
        XCTAssertGreaterThanOrEqual(dashes, 2, "a typed price and another currency give —")
    }

    // MARK: - What the shop sees

    func testAPriceBelowWhatWasPaidIsRefusedInTheMacsWordsAndNothingIsWritten() async throws {
        let (api, book) = try client(orders: [Self.paidJob])
        let before = try book.read()
        do {
            try await api.editOrder(orderId: "T-PAID", fields: ["price": .number(900)], now: now)
            XCTFail("a bill below what was paid is refused")
        } catch let refusal as BookWriter.JobEditRefused {
            XCTAssertEqual(refusal.reason, "paid_exceeds_price")
            XCTAssertEqual(refusal.localizedDescription, L10n.tr("mac.parts_paid_exceeds"))
            XCTAssertTrue(refusal.localizedDescription.contains("credit note"))
        }
        XCTAssertEqual(try book.read(), before, "nothing written: paid is never capped to fit")
    }

    func testAnEditThatStandsIsWrittenOnceWithWhatWasPaidUntouched() async throws {
        let (api, book) = try client(orders: [Self.paidJob])
        let wrote = try await api.editOrder(orderId: "T-PAID", fields: ["price": .number(1300),
                                                                       "priorityLevel": .string("high")], now: now)
        XCTAssertTrue(wrote)
        guard case .object(let o) = try row(book, "T-PAID") else { return XCTFail() }
        XCTAssertEqual(o["price"], .number(1300))
        XCTAssertEqual(o["paidAmount"], .number(1200))
        XCTAssertEqual(o["priorityLevel"], .string("high"))
        XCTAssertEqual(o["priceSource"], .string("override"), "a typed total is marked as one")
        guard case .array(let history)? = o["editHistory"] else { return XCTFail("written down") }
        XCTAssertFalse(history.isEmpty)
    }

    func testARevisionUnderADepositIsRefusedAndNoVersionIsKept() async throws {
        let (_, book) = try client(orders: [Self.depositQuote])
        let engine = try await BookReader(book: book).sharedEngine()
        let before = try book.read()
        do {
            try await BookWriter(book: book).reviseQuote(orderId: "T-QUOTE", fields: ["price": .number(50)],
                                                         engine: engine, now: now)
            XCTFail("a revision below the deposit is refused")
        } catch let refusal as BookWriter.JobEditRefused {
            XCTAssertEqual(refusal.reason, "paid_exceeds_price")
        }
        XCTAssertEqual(try book.read(), before, "no revision kept, nothing written")
    }

    func testTheMarginRowReadsTheRule() async throws {
        let (api, _) = try client(orders: [Self.costPlus, Self.typed, Self.foreign, Self.stored])
        let forty = await api.jobMargin(orderId: "T-40")
        XCTAssertEqual(forty?.text, "40%")
        let typed = await api.jobMargin(orderId: "T-TYPED")
        XCTAssertNotNil(typed, "the row is shown")
        XCTAssertNil(typed?.percent)
        XCTAssertEqual(typed?.text, "—", "a typed price: —, never a figure worked backwards")
        let fx = await api.jobMargin(orderId: "T-FX")
        XCTAssertEqual(fx?.text, "—")
        let stored = await api.jobMargin(orderId: "T-STORED")
        XCTAssertEqual(stored?.text, "25%", "a stored margin is the answer")
        let missing = await api.jobMargin(orderId: "nope")
        XCTAssertNil(missing, "no job, no row")
        XCTAssertEqual(BookWriter.JobMargin(percent: 12.5).text, "12.5%")
        XCTAssertEqual(BookWriter.JobMargin(percent: 33.333).text, "33.3%")
        XCTAssertEqual(BookWriter.JobMargin(percent: -10).text, "-10%")
    }

    func testThePhonesStringsCarryTheMacsKeysInEveryLanguage() throws {
        let bundle = Bundle(for: KhaytAPIClient.self)
        for lang in ["en", "ar", "de", "es", "fr", "ja", "pt-BR", "tr", "zh-Hans"] {
            let path = try XCTUnwrap(bundle.path(forResource: lang, ofType: "lproj"), lang)
            let b = try XCTUnwrap(Bundle(path: path))
            for key in ["mac.parts_paid_exceeds", "mac.markup"] {
                let v = b.localizedString(forKey: key, value: "∅", table: nil)
                XCTAssertNotEqual(v, "∅", "\(lang): \(key)")
                XCTAssertNotEqual(v, key, "\(lang): \(key)")
            }
        }
    }
}
