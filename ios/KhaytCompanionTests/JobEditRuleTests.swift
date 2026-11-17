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
        for file in ["lib/tax.js", "lib/product-price.js", "lib/pricing.js", "lib/working-week.js", "lib/calculator-cost.js",
                     "lib/order-money.js", "lib/order-payment.js", "lib/order-new.js", "lib/order-edit.js"] {
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

    // MARK: - The markup (Mac #2494): the 11 shared vectors

    /// `test/order-parts-edit.test.js`'s `part`, `jobOf` and markup cases,
    /// built in JavaScript exactly as there: a job priced the way newOrder
    /// prices one (`quoteTotal` over its parts).
    private static let vectorScript = #"""
    (function () {
      var Pricing = globalThis.KhaytPricing;
      function part(id, baseCost, extra) { return Object.assign({ id: id, name: 'Part ' + id, material: 'PLA', filamentId: 'sp-1',
        printWeight: 100, supportWeight: 0, printTime: 2, qty: 1, unitCost: baseCost, baseCost: baseCost, partStatus: 'pending' }, extra || {}); }
      function jobOf(parts, terms, extra) {
        var t = Object.assign({ margin: 50, discountPct: 0, shippingCost: 0, extraLines: [], rushEnabled: false, rushPct: 25 }, terms || {});
        var costed = parts.reduce(function (s, p) { return s + (p.agreedPrice != null ? 0 : p.baseCost); }, 0);
        var agreed = parts.reduce(function (s, p) { return s + (p.agreedPrice != null ? p.agreedPrice * (p.qty || 1) : 0); }, 0);
        var q = Pricing.quoteTotal(Object.assign({}, t, { baseCost: costed, agreedAmount: agreed, qty: 1 }));
        var rush = q.rushFee > 0 ? +q.rushFee.toFixed(2) : 0;
        return Object.assign({ id: 'J1', status: 'pending', project: 'Bracket', parts: parts.map(function (p) { return Object.assign({}, p); }),
          price: +q.total.toFixed(2), discountPct: t.discountPct,
          priceBeforeDiscount: t.discountPct > 0 ? +q.priceBeforeDiscount.toFixed(2) : null,
          shippingCost: t.shippingCost, extraLines: t.extraLines,
          printTime: parts.reduce(function (s, p) { return s + p.printTime; }, 0), material: 'PLA', paidAmount: 0 },
          agreed > 0 ? { agreedAmount: agreed } : {}, rush > 0 ? { rushFee: rush, rushFeeAmount: rush } : { rushFeeAmount: 0 },
          q.priceSource !== 'base' ? { computedPrice: +q.computedTotal.toFixed(2), priceSource: q.priceSource } : {},
          q.priceSource === 'rounded' ? { priceRound: t.priceRound } : {},
          q.priceSource === 'override' ? { priceOverride: +q.total.toFixed(2) } : {}, extra || {});
      }
      function draftQuote(terms, extra) { return jobOf([part('A', 80), part('B', 40)], terms, Object.assign({ status: 'quote', quoteShareStamped: true }, extra || {})); }
      var extras = { discountPct: 10, rushEnabled: true, shippingCost: 20, extraLines: [{ label: 'Paint', amount: 15 }] };
      var c = [];
      function add(name, order, fields, seen, ids) { c.push({ name: name, order: order, fields: fields, seen: !!seen, ids: ids || [] }); }
      add('reprice', draftQuote(), { marginPct: 25 });
      add('same', draftQuote(), { marginPct: 50 });
      add('terms stay', draftQuote(extras), { marginPct: 25 });
      add('agreed', jobOf([part('A', 80), part('B', 40, { agreedPrice: 100 })], {}, { status: 'quote', quoteShareStamped: true }), { marginPct: 25 });
      add('rounding', draftQuote({ priceRound: { step: 5, mode: 'up' } }), { marginPct: 33 });
      add('typed', draftQuote({ priceOverride: 199 }), { marginPct: 25 });
      add('all agreed', jobOf([part('A', 80, { agreedPrice: 90 })], {}, { status: 'quote', quoteShareStamped: true }), { marginPct: 25 });
      [{ quoteSharedAt: '2026-11-14T10:00:00Z' }, { status: 'pending' }, { status: 'printing' },
       { status: 'pending', invoiceNumber: 'INV-2026-0007' }].forEach(function (x, i) {
        add('seen ' + i, draftQuote({}, x), { marginPct: 25 });
        add('seen ok ' + i, draftQuote({}, x), { marginPct: 25 }, true);
      });
      [[{ status: 'completed' }, 'deducted'], [{ status: 'pending', materialDeducted: true }, 'deducted'],
       [{ status: 'cancelled' }, 'cancelled'], [{ status: 'pending', zatcaUuid: 'u-1' }, 'zatca'],
       [{ status: 'pending', voidedAt: '2026-11-10' }, 'voided']].forEach(function (x) {
        add('lock ' + x[1], draftQuote({}, x[0]), { marginPct: 25 }, true);
      });
      var paid = draftQuote({}, { status: 'pending', paidAmount: 170, paymentStatus: 'partial' });
      add('under paid', paid, { marginPct: 25 }, true);
      add('over paid', paid, { marginPct: 60 }, true);
      add('negative', draftQuote(), { marginPct: -5 });
      add('unreadable', draftQuote(), { marginPct: 'lots' });
      add('parts and markup', draftQuote(), { parts: [part('A', 80), part('B', 40), part('C', 30)], marginPct: 20 }, false, ['C']);
      add('fresh terms', jobOf([part('A', 80), part('B', 40)], Object.assign({ margin: 25 }, extras)), {});
      return c;
    })()
    """#

    func testTheMarkupVectorsGiveLibsAnswerOnThePhone() async throws {
        let store = SampleShop.book()
        let engine = try await BookReader(book: { let b = CompanionBook(directory: dir); try b.replace(with: store, scope: nil); return b }()).sharedEngine()
        guard case .array(let cases) = try ask(Self.vectorScript) else { return XCTFail("the vectors") }
        var results: [String: (ok: Bool, reason: String?, step: String?, changed: Bool, order: [String: JSONValue])] = [:]
        var freshTermsPrice: Double?
        for item in cases {
            guard case .object(let c) = item, case .string(let name)? = c["name"], let order = c["order"],
                  case .object(let fields)? = c["fields"], case .bool(let seen)? = c["seen"],
                  case .array(let idValues)? = c["ids"] else { return XCTFail("a vector") }
            let ids = idValues.compactMap { if case .string(let s) = $0 { return s }; return nil }
            if name == "fresh terms" {
                if case .object(let o) = order, case .number(let p)? = o["price"] { freshTermsPrice = p }
                continue
            }
            // The phone's engine (KhaytCore's bundled lib)…
            let swift = try await engine.applyJobEdit(order: order, fields: fields, priceSeenOk: seen,
                                                      newPartIds: ids, now: now, editId: "edit-1", priceId: "price-1")
            // …and the repo's lib, called the same way.
            let lib = try ask("""
                (function () { var o = \(json(order));
                  var r = KhaytOrderEdit.applyJobEdit(o, \(json(.object(fields))), { clients: [], settings: {},
                    keepPrice: false, marginPct: null, ids: \(json(.array(idValues))), now: \(now.timeIntervalSince1970 * 1000),
                    id: 'edit-1', priceId: 'price-1', priceSeenOk: \(seen) });
                  return { ok: r.ok, reason: r.reason || null, step: r.step || null, changed: !!r.changed, order: o }; })()
                """)
            guard case .object(let l) = lib, case .object(let after) = swift.order else { return XCTFail(name) }
            XCTAssertEqual(.bool(swift.ok), l["ok"], "\(name): ok")
            XCTAssertEqual(swift.reason.map(JSONValue.string) ?? .null, l["reason"], "\(name): reason")
            XCTAssertEqual(swift.step.map(JSONValue.string) ?? .null, l["step"], "\(name): step")
            XCTAssertEqual(swift.order, l["order"], "\(name): the job after")
            results[name] = (swift.ok, swift.reason, swift.step, swift.changed, after)
        }
        func price(_ n: String) -> JSONValue? { results[n]?.order["price"] }
        // The vectors' own figures.
        XCTAssertEqual(price("reprice"), .number(150), "120 at 25%")
        XCTAssertEqual(results["reprice"]?.order["marginPct"], .number(25))
        let back = try await engine.marginOf(.object(try XCTUnwrap(results["reprice"]?.order)))
        XCTAssertEqual(back, 25)
        XCTAssertEqual(results["same"]?.changed, false)
        XCTAssertEqual(price("same"), .number(180))
        XCTAssertEqual(price("terms stay"), freshTermsPrice.map(JSONValue.number))
        XCTAssertEqual(results["terms stay"]?.order["priceBeforeDiscount"], .number(150))
        XCTAssertEqual(price("agreed"), .number(200), "80 at 25% + 100 agreed")
        XCTAssertEqual(price("rounding"), .number(160))
        XCTAssertEqual(results["rounding"]?.order["computedPrice"], .number(159.6))
        XCTAssertEqual(results["typed"]?.reason, "price_fixed")
        XCTAssertEqual(price("typed"), .number(199))
        XCTAssertEqual(results["all agreed"]?.reason, "price_fixed")
        for i in 0..<4 {
            XCTAssertEqual(results["seen \(i)"]?.reason, "ask_price", "seen \(i)")
            XCTAssertEqual(results["seen \(i)"]?.step, "markup")
            XCTAssertEqual(price("seen \(i)"), .number(180), "nothing written while asking")
            XCTAssertEqual(results["seen ok \(i)"]?.ok, true)
            XCTAssertEqual(price("seen ok \(i)"), .number(150))
        }
        for code in ["deducted", "cancelled", "zatca", "voided"] {
            XCTAssertEqual(results["lock \(code)"]?.reason, code)
            XCTAssertEqual(price("lock \(code)"), .number(180))
        }
        XCTAssertEqual(results["under paid"]?.reason, "paid_exceeds_price")
        XCTAssertEqual(results["under paid"]?.step, "markup")
        XCTAssertEqual(results["over paid"]?.ok, true, "raising it is fine")
        XCTAssertEqual(price("over paid"), .number(192))
        XCTAssertEqual(results["negative"]?.reason, "bad_markup")
        XCTAssertEqual(results["unreadable"]?.reason, "bad_markup")
        XCTAssertEqual(price("parts and markup"), .number(180), "150 at 20%")
    }

    // MARK: - The markup, as Edit job uses it

    /// A cost-plus job at 50%, accepted (so the customer has seen the price).
    private static let seenJob: JSONValue = .object([
        "id": .string("T-SEEN"), "project": .string("Bracket"), "status": .string("pending"),
        "price": .number(150), "paidAmount": .number(0), "priority": .bool(false),
        "parts": .array([part("a", base: 60), part("b", base: 40)]),
    ])

    func testEditJobOffersTheMarkupOnlyWhereTheRuleTakesOne() async throws {
        let done: JSONValue = { guard case .object(var o) = Self.seenJob else { return .null }
            o["id"] = .string("T-DONE"); o["status"] = .string("completed"); return .object(o) }()
        let (api, _) = try client(orders: [Self.seenJob, Self.typed, Self.foreign, done, Self.costPlus])
        let seen = await api.markupState(orderId: "T-SEEN")
        XCTAssertEqual(seen?.typed, "50")
        XCTAssertEqual(seen?.askPrice, true, "an accepted job's price has been seen")
        let forty = await api.markupState(orderId: "T-40")
        XCTAssertEqual(forty?.typed, "40")
        let typed = await api.markupState(orderId: "T-TYPED")
        XCTAssertNil(typed, "a typed price: no field")
        let fx = await api.markupState(orderId: "T-FX")
        XCTAssertNil(fx, "another currency: no field")
        let finished = await api.markupState(orderId: "T-DONE")
        XCTAssertNil(finished, "a finished job: no field")
        XCTAssertEqual(KhaytAPIClient.MarkupState(percent: 12.5, askPrice: false).typed, "12.5")
        XCTAssertEqual(KhaytAPIClient.MarkupState(percent: 33.333, askPrice: false).typed, "33.33")
        // Only a changed markup is sent; an unreadable one is sent as typed.
        let state = KhaytAPIClient.MarkupState(percent: 50, askPrice: true)
        XCTAssertNil(EditOrderSheet.markupField("50", opened: state))
        XCTAssertNil(EditOrderSheet.markupField(" ", opened: state))
        XCTAssertNil(EditOrderSheet.markupField("50.00", opened: state))
        XCTAssertEqual(EditOrderSheet.markupField("25", opened: state), .number(25))
        XCTAssertEqual(EditOrderSheet.markupField("lots", opened: state), .string("lots"))
        XCTAssertNil(EditOrderSheet.markupField("25", opened: nil))
    }

    func testASeenPriceIsAskedThenSavedWithPriceSeenOk() async throws {
        let (api, book) = try client(orders: [Self.seenJob])
        let before = try book.read()
        // The new total, before saving: the same rule on a copy.
        let preview = try await api.previewJobEdit(orderId: "T-SEEN", fields: ["marginPct": .number(25)], now: now)
        XCTAssertEqual(preview, 125, "100 of cost at 25%")
        XCTAssertEqual(try book.read(), before, "a preview writes nothing")
        do {
            try await api.editOrder(orderId: "T-SEEN", fields: ["marginPct": .number(25)], now: now)
            XCTFail("a seen price is asked first")
        } catch let refusal as BookWriter.JobEditRefused {
            XCTAssertTrue(refusal.needsAsking)
            XCTAssertEqual(refusal.localizedDescription, L10n.tr("mac.js_markup_q"))
        }
        XCTAssertEqual(try book.read(), before, "nothing written while asking")
        let wrote = try await api.editOrder(orderId: "T-SEEN", fields: ["marginPct": .number(25)],
                                            priceSeenOk: true, now: now)
        XCTAssertTrue(wrote)
        guard case .object(let o) = try row(book, "T-SEEN") else { return XCTFail() }
        XCTAssertEqual(o["price"], .number(125))
        XCTAssertEqual(o["marginPct"], .number(25))
        let margin = await api.jobMargin(orderId: "T-SEEN")
        XCTAssertEqual(margin?.text, "25%", "the money card reads back what was typed")
    }

    func testMarkupRefusalsAreInTheMacsWordsUnderTheMarkup() async throws {
        let (api, book) = try client(orders: [Self.seenJob, Self.typed])
        let before = try book.read()
        for (id, value, reason, key) in [("T-SEEN", JSONValue.number(-5), "bad_markup", "mac.js_markup_bad"),
                                         ("T-SEEN", .string("lots"), "bad_markup", "mac.js_markup_bad"),
                                         ("T-TYPED", .number(25), "price_fixed", "mac.js_markup_fixed")] {
            do {
                try await api.editOrder(orderId: id, fields: ["marginPct": value], priceSeenOk: true, now: now)
                XCTFail("\(id) \(value) is refused")
            } catch let refusal as BookWriter.JobEditRefused {
                XCTAssertEqual(refusal.reason, reason)
                XCTAssertTrue(refusal.isMarkup, "shown under the Markup row")
                XCTAssertEqual(refusal.localizedDescription, L10n.tr(key))
            }
        }
        XCTAssertEqual(try book.read(), before)
    }

    // MARK: - The markup on a job in another currency (Mac #2506)

    /// `test/order-markup-currency.test.js`: jobs taken by `newOrder` at 50%
    /// and at 60%, in the shop's currency and for a USD customer at 3.75
    /// (parts 100 SAR). Built by lib's own `newOrder`, as the Mac takes one.
    private static let currencyScript = #"""
    (function () {
      var N = globalThis.KhaytOrderNew;
      function part() { return { name: 'p.stl', material: 'PLA', qty: 1, printWeight: 100, printTime: 2, unitCost: 100, baseCost: 100 }; }
      function take(margin, clientId) {
        return N.newOrder({ parts: [part()], clientId: clientId, margin: margin }, {
          settings: { currency: 'SAR', invNumNext: 7, quoteNumNext: 3, rushFeePct: 25, exchangeRates: { USD: 3.75 } },
          orders: [], clients: [{ id: 'C-USD', currency: 'USD' }], now: new Date('2026-11-16T08:00:00Z'),
          tokens: { tracking: new Uint8Array(N.TOKEN_BYTES), quoteApproval: new Uint8Array(N.TOKEN_BYTES), id: new Uint8Array(4) } });
      }
      return { sar50: take(50), sar60: take(60), usd50: take(50, 'C-USD'), usd60: take(60, 'C-USD') };
    })()
    """#

    func testAUSDJobsMarkupIsPricedInItsOwnCurrency() async throws {
        guard case .object(let jobs) = try ask(Self.currencyScript),
              case .object(var usd50)? = jobs["usd50"], case .object(let usd60)? = jobs["usd60"],
              case .object(var sar50)? = jobs["sar50"], case .object(let sar60)? = jobs["sar60"] else { return XCTFail("the jobs") }
        XCTAssertEqual(usd50["fxRate"], .number(3.75), "the fixture is a USD job")
        XCTAssertEqual(usd50["price"], .number(40), "100 SAR × 1.5 ÷ 3.75")
        XCTAssertEqual(usd60["price"], .number(42.67), "100 SAR × 1.6 ÷ 3.75")
        usd50["id"] = .string("T-USD"); sar50["id"] = .string("T-SAR")
        let (api, book) = try client(orders: [.object(usd50), .object(sar50)])
        for (id, at60) in [("T-USD", usd60), ("T-SAR", sar60)] {
            // The money card's Markup row and Edit job's field…
            let row = await api.jobMargin(orderId: id)
            XCTAssertEqual(row?.text, "50%", "\(id): the row")
            let field = await api.markupState(orderId: id)
            XCTAssertEqual(field?.typed, "50", "\(id): the field is offered")
            // …the new total shown before saving…
            let preview = try await api.previewJobEdit(orderId: id, fields: ["marginPct": .number(60)], now: now)
            XCTAssertEqual(preview.map(JSONValue.number), at60["price"], "\(id): 50% changed to 60% costs what a job taken at 60% costs")
            // …and what is saved, with the money card reading it back.
            let wrote = try await api.editOrder(orderId: id, fields: ["marginPct": .number(60)], priceSeenOk: true, now: now)
            XCTAssertTrue(wrote)
            guard case .object(let o) = try self.row(book, id) else { return XCTFail(id) }
            XCTAssertEqual(o["price"], at60["price"], "\(id): saved")
            XCTAssertEqual(o["marginPct"], .number(60))
            let after = await api.jobMargin(orderId: id)
            XCTAssertEqual(after?.text, "60%", "\(id): the row after")
        }
    }

    // MARK: - A quote the phone makes is a draft until it is sent (#2524)

    /// `lib/order-edit.js` quoteIsDraft: a draft needs `quoteShareStamped`
    /// (the app that made it stamps `quoteSharedAt` when it goes out) and no
    /// sign of a send. The phone makes quotes itself (`BookWriter.orderRecord`)
    /// and stamps the send (`markQuoteShared`), so it writes the stamp too.
    func testAQuoteThePhoneMakesIsADraftUntilItIsSent() async throws {
        var draft = NewOrderDraft()
        draft.project = "Bracket"; draft.isQuote = true
        let made = try BookWriter.orderRecord(from: draft, settings: [:], machines: [], existing: [], now: now)
        XCTAssertEqual(made["quoteShareStamped"], .bool(true), "stamped as newOrder stamps it")
        XCTAssertNotNil(made["quoteSentAt"], "written at creation, as before")
        guard case .string(let id)? = made["id"] else { return XCTFail("no id") }
        XCTAssertEqual(try ask("KhaytOrderEdit.quoteIsDraft(\(json(.object(made))))"), .bool(true), "lib: a draft")

        let (api, book) = try client(orders: [.object(made)])
        let engine = try await BookReader(book: book).sharedEngine()
        let fresh = try row(book, id)
        let before = try await engine.partsLock(fresh)
        XCTAssertFalse(before.askPrice, "never sent: its price follows without asking")

        try await api.markQuoteShared(orderId: id, now: now)
        let sent = try row(book, id)
        guard case .object(let o) = sent else { return XCTFail("the quote") }
        XCTAssertNotNil(o["quoteSharedAt"])
        let after = try await engine.partsLock(sent)
        XCTAssertTrue(after.askPrice, "sent from this phone: a re-price asks first")
        XCTAssertEqual(try ask("KhaytOrderEdit.quoteIsDraft(\(json(sent)))"), .bool(false), "lib agrees")
    }

    /// Every way the phone sends a quote stamps it, so the stamp's promise
    /// holds: Send quote and the customer-page card's share (both
    /// `quoteShareEnded`), and a WhatsApp follow-up, whose message carries the
    /// total (`recordFollowUp`). After each, a re-price asks.
    func testEveryWayThePhoneSendsAQuoteMakesARepriceAsk() async throws {
        var draft = NewOrderDraft()
        draft.project = "Bracket"; draft.isQuote = true
        var made = try BookWriter.orderRecord(from: draft, settings: [:], machines: [], existing: [], now: now)
        guard case .string(let shareId)? = made["id"] else { return XCTFail("no id") }
        made["parts"] = .array([Self.part("a", base: 100)])
        var second = made; second["id"] = .string("Q-FOLLOW")
        let (api, book) = try client(orders: [.object(made), .object(second)])
        let engine = try await BookReader(book: book).sharedEngine()
        for id in [shareId, "Q-FOLLOW"] {
            let lock = try await engine.partsLock(try row(book, id))
            XCTAssertFalse(lock.askPrice, "\(id): a draft before it goes out")
        }
        // A share the sheet reports cancelled is no send.
        let cancelled = try await api.quoteShareEnded(orderId: shareId, completed: false, now: now)
        XCTAssertFalse(cancelled)
        let stillDraft = try await engine.partsLock(try row(book, shareId))
        XCTAssertFalse(stillDraft.askPrice)
        // Shared (Send quote, or the customer-page card): it asks.
        let shared = try await api.quoteShareEnded(orderId: shareId, completed: true, now: now)
        XCTAssertTrue(shared)
        let afterShare = try await engine.partsLock(try row(book, shareId))
        XCTAssertTrue(afterShare.askPrice, "shared: a re-price asks")
        // Followed up on WhatsApp, never shared: the message had its total.
        try await BookWriter(book: book).recordFollowUp(orderId: "Q-FOLLOW", engine: engine, now: now)
        let followed = try row(book, "Q-FOLLOW")
        guard case .object(let f) = followed else { return XCTFail("the quote") }
        XCTAssertEqual(f["followUpCount"], .number(1))
        XCTAssertNotNil(f["quoteSharedAt"], "a follow-up is a send")
        let afterFollowUp = try await engine.partsLock(followed)
        XCTAssertTrue(afterFollowUp.askPrice, "followed up: a re-price asks")
        // A second follow-up keeps the first send's stamp.
        try await BookWriter(book: book).recordFollowUp(orderId: "Q-FOLLOW", engine: engine, now: now.addingTimeInterval(86_400))
        guard case .object(let again) = try row(book, "Q-FOLLOW") else { return XCTFail("the quote") }
        XCTAssertEqual(again["quoteSharedAt"], f["quoteSharedAt"], "the first send is kept")
    }

    /// The `quoteSentAt` every quote is given when it is made is not a send;
    /// a quote with no stamp (an older app's) asks whatever it holds.
    func testQuoteSentAtIsNoSendAndAnUnstampedQuoteAsks() async throws {
        let engine = try await BookReader(book: {
            let b = CompanionBook(directory: dir); try b.replace(with: SampleShop.book(), scope: nil); return b }()).sharedEngine()
        func quote(_ extra: [String: JSONValue]) -> JSONValue {
            var o: [String: JSONValue] = ["id": .string("Q-1"), "project": .string("Plate"), "status": .string("quote"),
                                          "price": .number(150), "quoteSentAt": .string("2026-11-14"),
                                          "quoteVersion": .number(1), "parts": .array([Self.part("a", base: 100)])]
            for (k, v) in extra { o[k] = v }
            return .object(o)
        }
        let cases: [(String, JSONValue, Bool)] = [
            ("stamped, quoteSentAt only", quote(["quoteShareStamped": .bool(true)]), false),
            ("unstamped (an older app's)", quote([:]), true),
            ("shared", quote(["quoteShareStamped": .bool(true), "quoteSharedAt": .string("2026-11-15T10:00:00Z")]), true),
            ("accepted", quote(["quoteShareStamped": .bool(true), "quoteAcceptedAt": .string("2026-11-15T10:00:00Z")]), true),
            ("revised", quote(["quoteShareStamped": .bool(true), "quoteVersion": .number(2)]), true),
        ]
        for (name, order, asks) in cases {
            let lock = try await engine.partsLock(order)
            XCTAssertEqual(lock.askPrice, asks, name)
            XCTAssertEqual(try ask("KhaytOrderEdit.quoteIsDraft(\(json(order)))"), .bool(!asks), "lib: \(name)")
        }
    }

    // MARK: - The customer's messages about a quote (#2528)

    /// The shared rule reads the job's customer from the book's clients: a
    /// quote its customer was messaged about (`commLog` entry with this
    /// job's `orderId`) is not a draft, so a re-price asks. The phone passes
    /// the book's clients to every `applyJobEdit` (Edit job, its preview, and
    /// Revise), so its saves see the same.
    func testAQuoteItsCustomerWasMessagedAboutAsksBeforeARePrice() async throws {
        func quote(_ id: String) -> JSONValue {
            .object(["id": .string(id), "project": .string("Bracket"), "status": .string("quote"),
                     "quoteShareStamped": .bool(true), "quoteVersion": .number(1), "clientId": .string("C-MSG"),
                     "price": .number(150), "marginPct": .number(50), "paidAmount": .number(0),
                     "priority": .bool(false), "parts": .array([Self.part("a", base: 60), Self.part("b", base: 40)])])
        }
        let log: JSONValue = .array([.object(["id": .string("m1"), "at": .string("2026-11-15T09:00:00Z"),
                                              "orderId": .string("Q-MSG"), "text": .string("Your quote")])])
        var store = SampleShop.book()
        store["printLog"] = .array([quote("Q-MSG"), quote("Q-QUIET")])
        var clients: [JSONValue] = []
        if case .array(let c)? = store["clients"] { clients = c }
        clients.append(.object(["id": .string("C-MSG"), "name": .string("Sample customer"), "commLog": log]))
        store["clients"] = .array(clients)
        let book = CompanionBook(directory: dir)
        try book.replace(with: store, scope: nil)
        let api = KhaytAPIClient(settings: settings, book: book)

        // Messaged about it: asked first, nothing written.
        let before = try book.read()
        do {
            try await api.editOrder(orderId: "Q-MSG", fields: ["marginPct": .number(25)], now: now)
            XCTFail("a quote its customer was messaged about is asked first")
        } catch let refusal as BookWriter.JobEditRefused {
            XCTAssertTrue(refusal.needsAsking, String(describing: refusal.reason))
        }
        XCTAssertEqual(try book.read(), before, "nothing written while asking")
        // Revise asks the same.
        do {
            try await api.reviseQuote(orderId: "Q-MSG", fields: ["marginPct": .number(25)])
            XCTFail("Revise asks too")
        } catch let refusal as BookWriter.JobEditRefused {
            XCTAssertTrue(refusal.needsAsking)
        }
        // The same customer's other quote, never messaged about: a draft.
        let wrote = try await api.editOrder(orderId: "Q-QUIET", fields: ["marginPct": .number(25)], now: now)
        XCTAssertTrue(wrote)
        guard case .object(let quiet) = try row(book, "Q-QUIET") else { return XCTFail("the quote") }
        XCTAssertEqual(quiet["price"], .number(125))
    }

    /// `test/fixtures/quote-draft-vectors.json` (#2528) through the phone's
    /// engine, the customer handed over as `client` and as `clients`: a draft
    /// does not ask, anything else does — and lib in JSC says the same.
    func testTheSharedQuoteDraftVectorsGiveLibsAnswerOnThePhone() async throws {
        struct Case: Decodable {
            let why: String; let order: JSONValue; let ctx: Ctx?; let draft: Bool
            struct Ctx: Decodable { let client: JSONValue?; let clients: [JSONValue]? }
        }
        struct Vectors: Decodable { let cases: [Case] }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "test/fixtures/quote-draft-vectors.json")
        let cases = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url)).cases
        XCTAssertGreaterThanOrEqual(cases.count, 12)
        let engine = try await BookReader(book: {
            let b = CompanionBook(directory: dir); try b.replace(with: SampleShop.book(), scope: nil); return b }()).sharedEngine()
        for c in cases {
            let lock = try await engine.partsLock(c.order, client: c.ctx?.client, clients: c.ctx?.clients)
            XCTAssertEqual(lock.askPrice, !c.draft, c.why)
            var ctx: [String: JSONValue] = [:]
            if let client = c.ctx?.client { ctx["client"] = client }
            if let clients = c.ctx?.clients { ctx["clients"] = .array(clients) }
            XCTAssertEqual(try ask("KhaytOrderEdit.quoteIsDraft(\(json(c.order)), \(json(.object(ctx))))"),
                           .bool(c.draft), "lib: \(c.why)")
        }
    }

    /// Edit job's "asked first" reads the same customers as the save.
    func testEditJobAsksFirstForAQuoteItsCustomerWasMessagedAbout() async throws {
        let quote: JSONValue = .object(["id": .string("Q-MSG"), "project": .string("Bracket"), "status": .string("quote"),
                                        "quoteShareStamped": .bool(true), "clientId": .string("C-MSG"),
                                        "price": .number(150), "marginPct": .number(50), "paidAmount": .number(0),
                                        "priority": .bool(false), "parts": .array([Self.part("a", base: 60), Self.part("b", base: 40)])])
        var store = SampleShop.book()
        store["printLog"] = .array([quote])
        var clients: [JSONValue] = []
        if case .array(let c)? = store["clients"] { clients = c }
        let api: KhaytAPIClient
        clients.append(.object(["id": .string("C-MSG"), "commLog": .array([
            .object(["id": .string("m1"), "orderId": .string("Q-MSG"), "channel": .string("whatsapp")])])]))
        store["clients"] = .array(clients)
        let book = CompanionBook(directory: dir)
        try book.replace(with: store, scope: nil)
        api = KhaytAPIClient(settings: settings, book: book)
        let state = await api.markupState(orderId: "Q-MSG")
        XCTAssertEqual(state?.askPrice, true, "messaged about: the price is asked about before it changes")
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
            for key in ["mac.parts_paid_exceeds", "mac.markup", "mac.js_markup_fixed", "mac.js_markup_bad",
                        "mac.js_markup_q", "mac.js_markup_change", "mac.js_new_total"] {
                let v = b.localizedString(forKey: key, value: "∅", table: nil)
                XCTAssertNotEqual(v, "∅", "\(lang): \(key)")
                XCTAssertNotEqual(v, key, "\(lang): \(key)")
            }
        }
    }
}
