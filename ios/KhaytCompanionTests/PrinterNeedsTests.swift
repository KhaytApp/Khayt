import XCTest
import JavaScriptCore
import KhaytCore
@testable import KhaytCompanion

/// The problem catalogue (#2612) and waiting at the machine (#2613) on the
/// phone: the shared vectors through JavaScriptCore with `lib/` itself loaded,
/// as the Mac will run them, and the shapes the phone reads from the Mac.
final class PrinterNeedsTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func context(_ files: [String]) throws -> (JSContext, () -> String?) {
        let ctx = try XCTUnwrap(JSContext())
        var thrown: String?
        ctx.exceptionHandler = { _, e in thrown = e?.toString() }
        for f in files {
            ctx.evaluateScript(try String(contentsOf: root.appending(path: "lib/\(f).js"), encoding: .utf8))
            XCTAssertNil(thrown, "lib/\(f).js did not load: \(thrown ?? "")")
        }
        return (ctx, { thrown })
    }

    /// Runs `call` (a JS function of one case) over a vector file and returns
    /// the cases whose answer is not `want`, compared key-order-free.
    private func failures(_ ctx: JSContext, fixture: String, call: String) throws -> (Int, [String]) {
        let json = try String(contentsOf: root.appending(path: fixture), encoding: .utf8)
        let js = """
        (function (V) {
          function canon(v) {
            if (Array.isArray(v)) return '[' + v.map(canon).join(',') + ']';
            if (v && typeof v === 'object') return '{' + Object.keys(v).sort().map(function (k) { return JSON.stringify(k) + ':' + canon(v[k]); }).join(',') + '}';
            return JSON.stringify(v);
          }
          var run = \(call);
          var fails = [];
          V.cases.forEach(function (c) {
            try { var got = run(c); if (canon(got) !== canon(c.want)) fails.push(c.why + ': ' + canon(got)); }
            catch (e) { fails.push(c.why + ': threw ' + e); }
          });
          return JSON.stringify({ count: V.cases.length, fails: fails });
        })(\(json))
        """
        struct R: Decodable { let count: Int; let fails: [String] }
        let r = try JSONDecoder().decode(R.self, from: Data(try XCTUnwrap(ctx.evaluateScript(js)?.toString()).utf8))
        return (r.count, r.fails)
    }

    func testTheProblemCatalogueVectors() throws {
        let (ctx, thrown) = try context(["printer-activity", "bambu-faults", "moonraker-problems", "printer-problems"])
        let (count, fails) = try failures(ctx, fixture: "test/fixtures/printer-problems-vectors.json",
                                          call: "function (c) { return KhaytPrinterProblems.problemsFor(c.type, c.report); }")
        XCTAssertNil(thrown())
        XCTAssertGreaterThanOrEqual(count, 15)
        for f in fails { XCTFail("problems vector: \(f)") }
        // The phone's closed sets are the rule's.
        let sev = ctx.evaluateScript("JSON.stringify(KhaytPrinterProblems.SEVERITIES)")?.toString()
        XCTAssertEqual(sev.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }.map(Set.init),
                       Set(PrinterProblem.severities))
    }

    func testTheWaitingAtTheMachineVectors() throws {
        let (ctx, thrown) = try context(["printer-activity", "waiting-at-machine"])   // the rule reads the printer's state now (#2613 review)
        let (count, fails) = try failures(ctx, fixture: "test/fixtures/waiting-at-machine-vectors.json",
                                          call: "function (c) { return KhaytWaitingAtMachine.waiting(c.machine, c.opts); }")
        XCTAssertNil(thrown())
        XCTAssertGreaterThanOrEqual(count, 7)
        for f in fails { XCTFail("waiting vector: \(f)") }
        let reasons = ctx.evaluateScript("JSON.stringify(KhaytWaitingAtMachine.REASONS)")?.toString()
        XCTAssertEqual(reasons.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) },
                       WaitingReason.reasons, "same reasons, same order (most urgent first)")
    }

    /// What the Mac will send on the live route: a bad row is dropped, never
    /// the printer; an older Mac that sends neither list is two empty lists.
    func testTheLiveReadingCarriesThemLeniently() throws {
        let json = #"""
        [{"id":"M1","name":"U1","hasPrinterApi":true,"state":"paused","progress":64,
          "problems":[{"code":"filament-runout","severity":"serious","action":"load-filament","source":"moonraker","head":2},
                      {"code":7},
                      {"code":"power-lost","severity":"info","action":"resume-on-printer"}],
          "waiting":[{"reason":"print-to-take-off","since":1795114800000},"junk"]},
         {"id":"M2","hasPrinterApi":true,"state":"IDLE","problems":"not a list"}]
        """#
        let rows = try JSONDecoder().decode([MachineLiveStatus].self, from: Data(json.utf8))
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].problems.map(\.code), ["filament-runout", "power-lost"])
        XCTAssertEqual(rows[0].problems.first?.head, 2)
        XCTAssertTrue(rows[0].problems[0].isBlocking)
        XCTAssertFalse(rows[0].problems[1].isBlocking)
        XCTAssertEqual(rows[0].waiting, [WaitingReason(reason: "print-to-take-off", since: 1795114800000)])
        XCTAssertEqual(rows[0].waiting.first?.sinceDate, Date(timeIntervalSince1970: 1795114800))
        XCTAssertEqual(rows[1].problems, [])
        XCTAssertEqual(rows[1].waiting, [])
    }

    /// Rows exactly as the Mac's live route builds them (#2621,
    /// `LanServer.liveRow`, from its MachinesLiveTests and PrinterNeedsTests):
    /// every key present, nulls where nothing was read, a minimal problem row,
    /// and a live runout with no date and its head.
    func testTheMacsLiveRouteShape() throws {
        let json = #"""
        [{"id":"M-1","name":"U1","hasPrinterApi":true,"state":"printing","progress":42,"filename":"dragon.gcode",
          "timeRemaining":3600,"tempNozzle":215,"tempBed":59,"error":null,"lastUpdated":"2026-09-21T13:33:20.000Z",
          "apiType":"moonraker","problems":[],"waiting":[]},
         {"id":"M-1","name":"U1","hasPrinterApi":true,"state":null,"progress":null,"filename":null,
          "timeRemaining":null,"tempNozzle":null,"tempBed":null,"error":null,"lastUpdated":null,"apiType":"moonraker",
          "problems":[{"code":"power-lost","severity":"info"}],
          "waiting":[{"reason":"print-to-take-off","since":1}]},
         {"id":"u1","name":"U1","hasPrinterApi":true,"state":"paused","progress":64,"filename":null,
          "timeRemaining":null,"tempNozzle":null,"tempBed":null,"error":null,"lastUpdated":null,"apiType":"moonraker",
          "problems":[{"code":"filament-runout","severity":"serious","action":"load-filament","source":"moonraker","head":1}],
          "waiting":[{"reason":"filament-runout","since":null,"head":1}]}]
        """#
        let rows = try JSONDecoder().decode([MachineLiveStatus].self, from: Data(json.utf8))
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].problems, [])
        XCTAssertEqual(rows[0].waiting, [])
        XCTAssertEqual(rows[1].problems.map(\.code), ["power-lost"], "a row without an action is kept")
        XCTAssertNil(rows[1].problems.first?.action)
        XCTAssertEqual(rows[1].waiting.first?.reason, "print-to-take-off")
        XCTAssertEqual(rows[1].waiting.first?.since, 1)
        XCTAssertEqual(rows[2].problems.first?.head, 1)
        XCTAssertEqual(rows[2].problems.first?.action, "load-filament")
        XCTAssertEqual(rows[2].waiting.first?.reason, "filament-runout")
        XCTAssertNil(rows[2].waiting.first?.since, "an undated live reason")
        XCTAssertNil(rows[2].waiting.first?.sinceDate)
        XCTAssertEqual(rows[2].waiting.first?.head, 1)
    }
}
