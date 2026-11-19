import XCTest
import JavaScriptCore
import KhaytCore
@testable import KhaytCompanion

/// Labour on a line of work (Turki, Nov 19; #2586): prep ONCE for the line,
/// post-processing per piece, on a part marked `labourPerLine: true`. An
/// unmarked part keeps the old sum, so every stored job costs what it did.
///
/// The phone makes a part in one place, its calculator (which also prices a
/// library model offline), so that is where the mark is set. Quotes go to the
/// Mac's `/api/quote`, which marks its own; the phone's New job writes no
/// parts; and an edit merges each part over its old copy, so the mark stays.
@MainActor
final class LineLabourTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "linelabour-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// `test/line-labour-vectors.test.js`, case for case, returning what
    /// failed instead of throwing so every case is reported.
    private static let runner = #"""
    (function (V) {
      var Mo = globalThis.KhaytOrderMoney, CC = globalThis.KhaytCalculatorCost, PP = globalThis.KhaytProductPricing;
      var N = globalThis.KhaytOrderNew, SJ = globalThis.KhaytStoreOrderJob;
      function r2(v) { return Math.round(v * 100) / 100; }
      function canon(v) {
        if (Array.isArray(v)) return '[' + v.map(canon).join(',') + ']';
        if (v && typeof v === 'object') return '{' + Object.keys(v).sort().map(function (k) { return JSON.stringify(k) + ':' + canon(v[k]); }).join(',') + '}';
        return JSON.stringify(v);
      }
      var settings = V.settings;
      var product = { id: 'PR', rates: V.rates, parts: [
        { name: 'a', printWeight: 0, printTime: 0, qty: 1 },
        { name: 'b', printWeight: 0, printTime: 0, qty: 2 }] };
      function part(c) {
        return Object.assign({ name: 'p', printWeight: c.printWeight || 0, printTime: 0, spoolCost: c.spoolCost || 0, spoolWeight: c.spoolWeight || 1000, qty: c.qty },
          c.perBox ? { perBox: c.perBox } : {}, c.unmarked ? {} : { labourPerLine: true }, V.rates);
      }
      var fails = [];
      V.cases.forEach(function (c) {
        function eq(got, want, what) { if (canon(got) !== canon(want)) fails.push(c.why + ': ' + what + ' ' + canon(got) + ' != ' + canon(want)); }
        try {
          if (c.kind === 'lineLabour') {
            eq(r2(Mo.lineLabour(Object.assign({ qty: c.qty }, c.unmarked ? {} : { labourPerLine: true }, V.rates))), c.want, 'lineLabour');
          } else if (c.kind === 'part') {
            var s = c.packaging ? settings : Object.assign({}, settings, { defaultPackagingCost: 0 });
            eq(r2(CC.partTotalCost(part(c), { inventory: [], settings: s })), c.want, 'partTotalCost');
          } else if (c.kind === 'product') {
            var prod = c.perBox ? Object.assign({}, product, { perBox: c.perBox }) : product;
            var jp = PP.productJobParts(prod, { inventory: [], settings: settings, units: c.units });
            eq(r2(jp.labourCost), c.want.labourCost, 'labourCost');
            eq(r2(jp.packagingCost), c.want.packagingCost, 'packagingCost');
            eq(jp.parts.map(function (p) { return p.qty; }), c.want.partQty, 'partQty');
            if (c.want.partsWithoutLabour) jp.parts.forEach(function (p) { eq(p.baseCost, 0, 'part baseCost'); });
          } else if (c.kind === 'agreed') {
            var p = part(c);
            p.baseCost = CC.partTotalCost(p, { inventory: [], settings: Object.assign({}, settings, { defaultPackagingCost: 0 }) });
            p.agreedPrice = c.agreedPrice;
            var job = N.newOrder({ parts: [p], project: 'A', margin: 30, asQuote: true },
              { settings: settings, orders: [], clients: [], now: new Date('2026-11-19T08:00:00Z'),
                tokens: { tracking: new Uint8Array(N.TOKEN_BYTES), quoteApproval: new Uint8Array(N.TOKEN_BYTES), id: new Uint8Array(4) } });
            eq(job.price, c.want.price, 'price');
            eq(r2(job.parts[0].baseCost), c.want.baseCost, 'baseCost');
          } else if (c.kind === 'store') {
            var out = SJ.build({ lines: [{ name: 'PR', productId: 'PR', qty: c.units, toPrint: c.units }] }, { products: [product], settings: settings, inventory: [], consumables: [] }, 'S1');
            eq(r2(out.labourCost), c.want.labourCost, 'labourCost');
            eq(r2(out.packagingCost), c.want.packagingCost, 'packagingCost');
            eq(out.parts.map(function (p) { return p.qty; }), c.want.partQty, 'partQty');
            var sj = SJ.apply({ id: 'S1', parts: [] }, out);
            eq(r2(Mo.jobFixedCost(sj, { components: false, overhead: false })), r2(c.want.labourCost + c.want.packagingCost), 'on the job, once');
          } else if (c.kind === 'legacyProduct') {
            var old = { id: 'OLD', defaultMargin: 30, parts: [Object.assign({ name: 'p', printWeight: 0, printTime: 0, qty: c.qty }, V.rates)] };
            if (c.newCost) old.rates = V.rates;
            var book = { inventory: [], settings: settings, consumables: [] };
            eq(PP.priceProduct(old, book).cost, c.want.cost, 'catalogue');
            var lj = PP.productJobParts(old, book);
            eq(r2(lj.parts.reduce(function (s, p) { return s + p.baseCost; }, 0) + lj.labourCost + lj.packagingCost), c.want.cost, 'a job from it');
            lj.parts.forEach(function (p) { eq(p.labourPerLine === true, !!c.newCost, 'mark only with own rates'); });
            var so = SJ.build({ lines: [{ name: 'OLD', productId: 'OLD', qty: 1, toPrint: 1 }] }, { products: [old], settings: settings, inventory: [], consumables: [] }, 'S2');
            eq(r2(so.parts.reduce(function (s, p) { return s + p.baseCost; }, 0) + (so.labourCost || 0) + (so.packagingCost || 0)), c.want.cost, 'a store order from it');
          } else {
            fails.push(c.why + ': unknown kind ' + c.kind);
          }
        } catch (e) { fails.push(c.why + ': threw ' + e); }
      });
      return { count: V.cases.length, fails: fails };
    })
    """#

    func testTheSharedLineLabourVectorsGiveLibsAnswer() throws {
        let ctx = try XCTUnwrap(JSContext())
        var thrown: String?
        ctx.exceptionHandler = { _, e in thrown = e?.toString() }
        for file in ["tax", "product-price", "pricing", "working-week", "depreciation", "print-rates", "order-money",
                     "order-payment", "calculator-cost", "part-ids", "product-pricing", "order-new", "store-order-job",
                     "payment-terms", "content-languages"] {
            let url = root.appending(path: "lib/\(file).js")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            ctx.evaluateScript(try String(contentsOf: url, encoding: .utf8))
            XCTAssertNil(thrown, "lib/\(file).js did not load: \(thrown ?? "")")
        }
        let fixture = try String(contentsOf: root.appending(path: "test/fixtures/line-labour-vectors.json"), encoding: .utf8)
        let result = try XCTUnwrap(ctx.evaluateScript("JSON.stringify((\(Self.runner))(\(fixture)))")?.toString())
        XCTAssertNil(thrown, thrown ?? "")
        struct Result: Decodable { let count: Int; let fails: [String] }
        let r = try JSONDecoder().decode(Result.self, from: Data(result.utf8))
        XCTAssertGreaterThanOrEqual(r.count, 18)
        for fail in r.fails { XCTFail("line-labour vector: \(fail)") }
    }

    /// The phone's own engine, the one the calculator runs: `order-money` is
    /// in it before `calculator-cost` costs anything (lib throws otherwise).
    func testThePhonesEngineCostsAMarkedPartOnTheNewRule() async throws {
        let b = CompanionBook(directory: dir)
        try b.replace(with: SampleShop.book(), scope: nil)
        let engine = try await BookReader(book: b).sharedEngine()
        let rates: [String: JSONValue] = ["laborRate": .number(90), "prepTime": .number(0.25), "postTime": .number(0.5),
                                          "wearRate": .number(0), "powerDraw": .number(0), "elecRate": .number(0),
                                          "failureRate": .number(0)]
        func line(_ qty: Int, marked: Bool) async throws -> Double {
            var extra = rates
            if marked { extra["labourPerLine"] = .bool(true) }
            let part = CalculatorPart.input(lines: [], purge: 0, hours: 0, qty: qty, extra: extra)
            let costed = try await engine.costPart(part, inventory: [], settings: ["defaultPackagingCost": .number(0)])
            return (costed.cost * Double(qty) * 100).rounded() / 100
        }
        let marked10 = try await line(10, marked: true)
        let unmarked10 = try await line(10, marked: false)
        XCTAssertEqual(marked10, 472.5, "(0.25 + 0.5 × 10) × 90: prep once")
        XCTAssertEqual(unmarked10, 675, "a stored, unmarked part keeps the old sum")
    }

    /// The calculator marks its part: ten pieces cost nine more pieces' POST
    /// time over one piece, not nine more pieces' prep and post.
    func testTheCalculatorChargesPrepOnceForTheLine() async throws {
        let b = CompanionBook(directory: dir)
        try b.replace(with: SampleShop.book(), scope: SampleShop.scope())
        let reader = BookReader(book: b)
        func cost(_ qty: Int) async throws -> Double {
            let q = CalculatorQuestion(lines: [], purge: 0, hours: 0, qty: qty, machineId: nil, presetId: nil,
                                       rates: ["laborRate": 90, "prepTime": 0.25, "postTime": 0.5, "failureRate": 0,
                                               "wearRate": 0, "powerDraw": 0, "elecRate": 0],
                                       pieces: [], margin: 30, discount: 0, rush: false)
            return try await reader.calculate(q).cost
        }
        let one = try await cost(1)
        let ten = try await cost(10)
        XCTAssertEqual(ten - one, 9 * 0.5 * 90, accuracy: 0.01, "post per piece; prep once (old rule: 9 × 0.75 × 90 = 607.50)")
    }

    /// An edit keeps the mark (and `perBox`): `applyParts` merges each part
    /// over its old copy, so a phone edit never drops a part back to the old sum.
    func testAnEditKeepsTheMark() async throws {
        let b = CompanionBook(directory: dir)
        try b.replace(with: SampleShop.book(), scope: nil)
        let engine = try await BookReader(book: b).sharedEngine()
        let order: JSONValue = .object([
            "id": .string("LL-1"), "project": .string("Brackets"), "status": .string("pending"),
            "price": .number(600), "paidAmount": .number(0), "paymentStatus": .string("unpaid"), "priority": .bool(false),
            "parts": .array([.object(["id": .string("P1"), "name": .string("Bracket"), "qty": .number(10),
                                      "printWeight": .number(0), "printTime": .number(0), "baseCost": .number(47.25),
                                      "laborRate": .number(90), "prepTime": .number(0.25), "postTime": .number(0.5),
                                      "labourPerLine": .bool(true), "perBox": .number(5)])]),
        ])
        let r = try await engine.applyJobEdit(order: order, fields: ["parts": .array([.object(["id": .string("P1"), "qty": .number(12)])])],
                                              now: Date(timeIntervalSince1970: 1_795_000_000), editId: "e1", priceId: "p1")
        XCTAssertTrue(r.ok, r.reason ?? "")
        guard case .object(let o) = r.order, case .array(let parts)? = o["parts"], case .object(let p)? = parts.first
        else { return XCTFail("parts") }
        XCTAssertEqual(p["qty"], .number(12))
        XCTAssertEqual(p["labourPerLine"], .bool(true))
        XCTAssertEqual(p["perBox"], .number(5))
    }
}
