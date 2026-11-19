import XCTest
import JavaScriptCore
import KhaytCore
@testable import KhaytCompanion

/// `test/fixtures/payment-plan-apply-vectors.json` (#2567, #2572) in
/// JavaScriptCore, with `lib/` itself loaded: the shared payment-plan rule
/// (apply, record, cover, due, allocate, the payment floor, trim, cap) gives
/// the answers `test/payment-plan-apply-vectors.test.js` holds lib to.
///
/// The phone has no payment-plan screen and its Record payment records a
/// total (Dev Hub's option 1: that money is "recorded outside the plan" and
/// `allocate` covers the oldest rows with it), so these run in JSC only, as
/// agreed. The `pay` cases are the floor the phone's Record payment now meets
/// (`BookWriter.recordPayment` refuses with the rule's words; see
/// `RecordPaymentRefusalTests` below).
final class PaymentPlanVectorsTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The node runner's checks, case for case, as JavaScript that returns
    /// what failed instead of throwing — so every case is reported.
    private static let runner = #"""
    (function (V) {
      var PP = globalThis.KhaytPaymentPlan, RX = globalThis.KhaytReceivables, PAY = globalThis.KhaytOrderPayment;
      function clone(o) { return JSON.parse(JSON.stringify(o)); }
      function canon(v) {
        if (Array.isArray(v)) return '[' + v.map(canon).join(',') + ']';
        if (v && typeof v === 'object') return '{' + Object.keys(v).sort().map(function (k) { return JSON.stringify(k) + ':' + canon(v[k]); }).join(',') + '}';
        return JSON.stringify(v);
      }
      var ctx = { settings: {}, today: '2026-11-18' };
      var fails = [];
      V.cases.forEach(function (c) {
        function check(ok, what) { if (!ok) fails.push(c.why + ': ' + what); }
        try {
          var order = Object.assign(clone(V.base), clone(c.order));
          var before = clone(order);
          var r = c.op === 'apply' ? PP.applyPlan(order, clone(c.rows), ctx)
            : c.op === 'record' ? PP.recordRowPayment(order, c.rowId, clone(c.payment), ctx)
            : c.op === 'cover' ? PP.coverRow(order, c.rowId, ctx)
            : c.op === 'due' ? { ok: true, due: PP.dueRows(order, c.now).map(function (x) { return x.id; }) }
            : c.op === 'pay' ? (function (o) { return { ok: !o.refused, reason: o.refused || null }; })(PAY.recordPayment(order, clone(c.payment), ctx))
            : c.op === 'trim' ? { ok: true, trimmed: PP.trimToOwed(order, order.instalments, ctx).filter(function (x) { return !x.paid; }).map(function (x) { return [x.id, Math.round(x.amount * 100) / 100]; }) }
            : c.op === 'cap' ? { ok: true, cap: RX.capInstalments(order, PP.owedNow(order, ctx)).map(function (x) { return [x.ins.id, Math.round(x.amount * 100) / 100]; }) }
            : Object.assign({ ok: true }, PP.allocate(order));
          check(r.ok === c.want.ok, 'ok ' + r.ok + ' (' + r.reason + ')');
          if (!c.want.ok) {
            check(r.reason === c.want.reason, 'reason ' + r.reason);
            if (c.want.over !== undefined) check(r.over === c.want.over, 'over ' + r.over);
            check(canon(order) === canon(before), 'a refusal writes nothing');
            return;
          }
          if (c.want.paidAmount !== undefined) check(order.paidAmount === c.want.paidAmount, 'paidAmount ' + order.paidAmount);
          if (c.op === 'apply') {
            check(order.paymentStatus === before.paymentStatus, 'applyPlan never touches the payment status');
            check(order.paidAmount === before.paidAmount, 'applyPlan never moves paidAmount');
          }
          if (c.want.instalmentBase !== undefined) check(order.instalmentBase === c.want.instalmentBase, 'instalmentBase ' + order.instalmentBase);
          if (c.want.rows !== undefined) check((order.instalments || []).length === c.want.rows, 'rows');
          if (c.want.changed !== undefined) check(r.changed === c.want.changed, 'changed');
          if (c.want.sameRows) check(canon(order.instalments) === canon(before.instalments), 'every row exactly as stored');
          if (c.want.legacyRow) {
            var row = order.instalments.find(function (x) { return x.id === c.want.legacyRow; });
            check(PP.rowState(row) === 'legacy', 'legacy state');
            check(canon(row) === canon(before.instalments.find(function (x) { return x.id === c.want.legacyRow; })), 'the legacy row is not rewritten');
          }
          if (c.want.collectionTotalsPaid !== undefined) {
            var tot = PP.collectionTotals({ price: order.price, paidAmount: order.paidAmount, instalments: order.instalments, instalmentBase: order.instalmentBase });
            check(tot.paidAmount === c.want.collectionTotalsPaid, 'collectionTotals paidAmount ' + tot.paidAmount);
          }
          if (c.want.unallocated !== undefined) check(r.unallocated === c.want.unallocated, 'unallocated ' + r.unallocated);
          if (c.want.due) check(canon(r.due) === canon(c.want.due), 'due ' + canon(r.due));
          if (c.want.cap) check(canon(r.cap) === canon(c.want.cap), 'cap ' + canon(r.cap));
          if (c.want.trimmed) check(canon(r.trimmed) === canon(c.want.trimmed), 'trimmed ' + canon(r.trimmed));
          if (c.op === 'trim') check(PP.applyPlan(clone(order), PP.trimToOwed(order, order.instalments, ctx), ctx).ok === true, 'the trimmed plan saves');
          if (c.want.states) {
            var got = {};
            PP.allocate(order).rows.forEach(function (x) { got[x.id] = x.state; });
            check(canon(got) === canon(c.want.states), 'states ' + canon(got));
          }
          if (['cover', 'allocate', 'due', 'cap', 'trim'].indexOf(c.op) !== -1) check(order.paidAmount === before.paidAmount, 'no money moves');
          if (c.want.rowRecorded) {
            var rec = order.instalments.find(function (x) { return x.id === c.want.rowRecorded; });
            check(PP.rowState(rec) === 'recorded', 'row recorded');
            if (c.op === 'record') check(order.paymentStatus === c.want.paymentStatus, 'paymentStatus ' + order.paymentStatus);
            if (c.op === 'record') check(Array.isArray(r.effects) && r.effects.some(function (e) { return e.type === 'save'; }), "recordPayment's effects come back");
            if (c.op === 'cover') check(r.effects === undefined, 'a cover moves no money');
          }
        } catch (e) { fails.push(c.why + ': threw ' + e); }
      });
      return { count: V.cases.length, fails: fails };
    })
    """#

    func testTheSharedPaymentPlanVectorsGiveLibsAnswer() throws {
        let ctx = try XCTUnwrap(JSContext())
        var thrown: String?
        ctx.exceptionHandler = { _, e in thrown = e?.toString() }
        for file in ["lib/tax.js", "lib/product-price.js", "lib/pricing.js", "lib/working-week.js", "lib/calculator-cost.js",
                     "lib/order-money.js", "lib/order-payment.js", "lib/part-ids.js", "lib/order-new.js", "lib/order-edit.js",
                     "lib/payment-terms.js", "lib/content-languages.js", "lib/payment-plan.js", "lib/receivables.js"] {
            let url = root.appending(path: file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            ctx.evaluateScript(try String(contentsOf: url, encoding: .utf8))
            XCTAssertNil(thrown, "\(file) did not load: \(thrown ?? "")")
        }
        let fixture = try String(contentsOf: root.appending(path: "test/fixtures/payment-plan-apply-vectors.json"), encoding: .utf8)
        let result = try XCTUnwrap(ctx.evaluateScript("JSON.stringify((\(Self.runner))(\(fixture)))")?.toString())
        XCTAssertNil(thrown, thrown ?? "")
        struct Result: Decodable { let count: Int; let fails: [String] }
        let r = try JSONDecoder().decode(Result.self, from: Data(result.utf8))
        XCTAssertGreaterThanOrEqual(r.count, 44)
        for fail in r.fails { XCTFail("payment-plan vector: \(fail)") }
    }
}

/// Record payment below a payment plan's recorded rows (`plan_recorded`,
/// #2572): refused in the rule's own words, nothing written, never "saved".
@MainActor
final class RecordPaymentRefusalTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "payfloor-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// Base 1,000, row A recorded by its own payment (373.34), paid 1,373.34.
    private static let planned: JSONValue = .object([
        "id": .string("PP-FLOOR"), "project": .string("Bracket set"), "status": .string("pending"),
        "price": .number(2120), "paidAmount": .number(1373.34), "paymentStatus": .string("partial"),
        "priority": .bool(false), "parts": .array([]), "instalmentBase": .number(1000),
        "instalments": .array([
            .object(["id": .string("A"), "amount": .number(373.34), "dueDate": .string("2026-12-18"), "note": .string(""),
                     "paid": .bool(true), "paidAt": .string("2026-11-18"), "recorded": .bool(true)]),
            .object(["id": .string("B"), "amount": .number(373.33), "dueDate": .string("2027-01-18"), "note": .string(""),
                     "paid": .bool(false), "paidAt": .null]),
        ]),
    ])

    private func book() throws -> CompanionBook {
        var store = SampleShop.book()
        store["printLog"] = .array([Self.planned])
        let b = CompanionBook(directory: dir)
        try b.replace(with: store, scope: nil)
        return b
    }

    func testATotalBelowThePlansRecordedRowsIsRefusedInTheRulesWordsAndNothingIsWritten() async throws {
        L10n.setLanguage(.en)
        defer { L10n.setLanguage(.system) }
        let b = try book()
        let engine = try await BookReader(book: b).sharedEngine()
        let before = try b.read()
        do {
            try await BookWriter(book: b).recordPayment(orderId: "PP-FLOOR", totalPaid: 1300, method: "cash", engine: engine)
            XCTFail("below base + the recorded row: refused")
        } catch let refusal as BookWriter.Refusal {
            guard case .paymentRefused(let code, let words) = refusal else { return XCTFail("\(refusal)") }
            XCTAssertEqual(code, "plan_recorded")
            let en = try await engine.translations(language: "en")
            XCTAssertEqual(words, en["pay.plan_recorded"], "the shared words, not a phone copy")
            XCTAssertFalse(words.isEmpty)
            XCTAssertEqual(refusal.errorDescription, words, "what the sheet shows")
        }
        XCTAssertEqual(try b.read(), before, "nothing written")
        // Exactly the floor is taken.
        try await BookWriter(book: b).recordPayment(orderId: "PP-FLOOR", totalPaid: 1373.34, method: "cash", engine: engine)
    }

    func testTheRefusalIsInTheAppsLanguage() async throws {
        L10n.setLanguage(.ar)
        defer { L10n.setLanguage(.system) }
        let b = try book()
        let engine = try await BookReader(book: b).sharedEngine()
        do {
            try await BookWriter(book: b).recordPayment(orderId: "PP-FLOOR", totalPaid: 1300, method: "cash", engine: engine)
            XCTFail("refused")
        } catch BookWriter.Refusal.paymentRefused(_, let words) {
            let ar = try await engine.translations(language: "ar")
            XCTAssertEqual(words, ar["pay.plan_recorded"])
        }
        XCTAssertEqual(L10n.engineLanguage, "ar")
        L10n.setLanguage(.zhHans)
        XCTAssertEqual(L10n.engineLanguage, "zh", "the engine's catalogue is locale-zh")
        L10n.setLanguage(.ptBR)
        XCTAssertEqual(L10n.engineLanguage, "pt-BR")
    }
}
