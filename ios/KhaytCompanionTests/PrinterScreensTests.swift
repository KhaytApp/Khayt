import XCTest
import SwiftUI
import JavaScriptCore
import KhaytCore
@testable import KhaytCompanion

/// The printer screens from the signed-off frames (iPhone Figma "Printer
/// states · iPhone (Nov 21)", Turki Nov 22): the card's states from the
/// shared state set, what the printer needs, and filament per head.
@MainActor
final class PrinterScreensTests: XCTestCase {

    override func tearDown() { L10n.setLanguage(.system) }

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func reading(_ state: String?, error: String? = nil, api: String? = "prusalink", progress: Int? = nil,
                         problems: [PrinterProblem] = [], waiting: [WaitingReason] = []) -> MachineLiveStatus {
        var m = MachineLiveStatus(id: "M1", name: "Prusa MK4", hasPrinterApi: api != nil, state: state, progress: progress,
                                  filename: "Phone stand.bgcode", timeRemaining: 3600, tempNozzle: 215, tempBed: 60,
                                  error: error, lastUpdated: "2026-11-22T10:00:00.000Z", apiType: api)
        m.problems = problems
        m.waiting = waiting
        return m
    }

    func testEachStateGetsItsLook() {
        func mode(_ m: MachineLiveStatus, offline: Bool = false) -> MachineCard.Mode {
            MachineCard.mode(m, offline: offline, fallbackStatus: nil)
        }
        XCTAssertEqual(mode(reading("PRINTING", progress: 40)), .printing)
        XCTAssertEqual(mode(reading("PAUSED", progress: 64)), .paused, "busy, never free")
        XCTAssertEqual(mode(reading("ATTENTION")), .needsYou)
        XCTAssertEqual(mode(reading("halted", api: "duet")), .needsYou)
        XCTAssertEqual(mode(reading(nil, error: "timed out")), .reconnecting)
        XCTAssertEqual(mode(reading("Offline", api: "octoprint")), .reconnecting, "a word that says it is not linked")
        XCTAssertEqual(mode(reading(nil, error: "HTTP 401")), .refused)
        XCTAssertEqual(mode(reading("IDLE")), .idle)
        XCTAssertEqual(mode(reading(nil)), .idle, "no live reading is not reconnecting")
        XCTAssertEqual(mode(reading(nil, api: nil)), .idle, "a printer with no link")
        XCTAssertEqual(mode(reading("IDLE"), offline: true), .offline, "the shop's own out-of-service flag")
        XCTAssertEqual(mode(reading("PRINTING", progress: 5), offline: true), .printing, "a print still on the bed shows")
    }

    /// Every code, action, severity and reason the shared rules can send has
    /// words, in all nine languages: read from the rules themselves, so a
    /// code added in lib without phone words fails here.
    func testEveryCodeTheRulesSendHasWordsInEveryLanguage() throws {
        let ctx = try XCTUnwrap(JSContext())
        for f in ["printer-activity", "bambu-faults", "moonraker-problems", "printer-problems", "waiting-at-machine"] {
            ctx.evaluateScript(try String(contentsOf: root.appending(path: "lib/\(f).js"), encoding: .utf8))
        }
        func list(_ js: String) throws -> [String] {
            try JSONDecoder().decode([String].self, from: Data(try XCTUnwrap(ctx.evaluateScript("JSON.stringify(\(js))")?.toString()).utf8))
        }
        var keys = try list("KhaytPrinterProblems.CODES").map { "problem." + $0 }
        keys += try list("KhaytPrinterProblems.ACTIONS").filter { $0 != "none" }.map { "problem.action." + $0 }
        keys += try list("KhaytPrinterProblems.SEVERITIES").map { "problem.severity." + $0 }
        keys += try list("KhaytWaitingAtMachine.REASONS").map { "waiting.reason." + $0 }
        XCTAssertGreaterThan(keys.count, 30)
        // The panel looks words up only for these, so they must be the rules' sets.
        XCTAssertEqual(PrinterNeedsPanel.codes, Set(try list("KhaytPrinterProblems.CODES")))
        XCTAssertEqual(PrinterNeedsPanel.actions, Set(try list("KhaytPrinterProblems.ACTIONS")))
        XCTAssertEqual(Set(PrinterProblem.severities), Set(try list("KhaytPrinterProblems.SEVERITIES")))
        keys += ["machines.state.paused", "machines.state.needs_you", "machines.state.reconnecting", "machines.state.refused",
                 "machines.needs_you.title", "machines.reconnecting.title", "machines.refused.title", "heads.title", "heads.note"]
        for lang in ["en", "ar", "de", "es", "fr", "ja", "pt-BR", "tr", "zh-Hans"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: "Localizable", ofType: "strings",
                                                      inDirectory: nil, forLocalization: lang), lang)
            let table = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String], lang)
            for key in keys { XCTAssertFalse((table[key] ?? "").isEmpty, "\(lang): \(key)") }
        }
    }

    func testProblemAndWaitingWords() {
        L10n.setLanguage(.en)
        let runout = PrinterProblem(code: "filament-runout", severity: "serious", action: "load-filament",
                                    source: "moonraker", head: 1, message: nil, ref: nil)
        XCTAssertEqual(PrinterNeedsPanel.title(runout), "Filament ran out · head 2", "the printer's e1 is the second head")
        XCTAssertEqual(PrinterNeedsPanel.problemSub(runout), "Serious")
        XCTAssertEqual(PrinterNeedsPanel.actionWords("load-filament"), "Load filament")
        XCTAssertNil(PrinterNeedsPanel.actionWords("none"))
        let lost = PrinterProblem(code: "power-lost", severity: "info", action: "resume-on-printer", source: nil,
                                  head: nil, message: nil, ref: nil)
        XCTAssertEqual(PrinterNeedsPanel.problemSub(lost), "Information · Khayt never resumes or discards it")
        let odd = PrinterProblem(code: "made-up", severity: "weird", action: nil, source: nil, head: nil, message: "E42", ref: nil)
        XCTAssertEqual(PrinterNeedsPanel.title(odd), "Printer error", "an unknown code is never nothing")
        XCTAssertEqual(PrinterNeedsPanel.problemSub(odd), "Information · E42")
        XCTAssertEqual(PrinterNeedsPanel.reasonWords(WaitingReason(reason: "bed-to-clear", since: nil)), "Bed to clear")
        XCTAssertNil(PrinterNeedsPanel.since(WaitingReason(reason: "filament-runout", since: nil)))
        // A head from the wire outside a printer's range is not shown, never overflows.
        let wild = PrinterProblem(code: "filament-runout", severity: "serious", action: nil, source: nil,
                                  head: Int.max, message: nil, ref: nil)
        XCTAssertEqual(PrinterNeedsPanel.title(wild), "Filament ran out")
        let negative = PrinterProblem(code: "head", severity: "severity.fatal", action: "head", source: nil,
                                      head: -3, message: nil, ref: nil)
        XCTAssertEqual(PrinterNeedsPanel.title(negative), "Printer error", "a code that is another key's name")
        XCTAssertEqual(PrinterNeedsPanel.problemSub(negative), "Information")
        XCTAssertNil(PrinterNeedsPanel.actionWords("head"))
    }

    func testFilamentPerHeadFromTheBook() {
        let store: [String: JSONValue] = ["printLog": .array([
            .object(["id": .string("J1"), "actualHeadsBasis": .string("proportional"),
                     "actualHeads": .array([
                        .object(["head": .number(1), "grams": .number(18), "estimateG": .number(17)]),
                        .object(["head": .number(0), "grams": .number(42.3)]),
                        .object(["head": .number(2.5), "grams": .number(1)]),       // not a whole head
                        .object(["head": .number(3), "grams": .number(-1)]),        // not a weight
                        .object(["head": .number(1), "grams": .number(99)]),        // a duplicate head
                        .string("junk")])]),
            .object(["id": .string("J2")]),
        ])]
        let split = KhaytAPIClient.headFilament(in: store, orderId: "J1")
        XCTAssertEqual(split?.heads.map(\.head), [0, 1])
        XCTAssertEqual(split?.totalGrams ?? 0, 60.3, accuracy: 0.001)
        XCTAssertEqual(split?.basis, "proportional")
        XCTAssertNil(KhaytAPIClient.headFilament(in: store, orderId: "J2"))
        XCTAssertNil(KhaytAPIClient.headFilament(in: store, orderId: "nope"))
    }

    // ── Screenshots beside the frames ──────────────────────────────────

    private func render(_ view: some View, dark: Bool, ar: Bool) throws -> UIImage {
        let framed = view.padding(16).frame(width: 393).background(KhaytDesign.ground)
            .environment(\.layoutDirection, ar ? .rightToLeft : .leftToRight)
            .environment(\.colorScheme, dark ? .dark : .light)
        let r = ImageRenderer(content: framed)
        r.scale = 3
        return try XCTUnwrap(r.uiImage)
    }

    /// With `TEST_RUNNER_KHAYT_SHOTS=<dir>`, each look is written there as a
    /// PNG for the PR, beside the frame.
    func testTheSignedOffLooksDraw() throws {
        let out = ProcessInfo.processInfo.environment["KHAYT_SHOTS"].map { URL(filePath: $0) }
        let problems = [
            PrinterProblem(code: "filament-runout", severity: "serious", action: "load-filament", source: "moonraker", head: 1, message: nil, ref: nil),
            PrinterProblem(code: "power-lost", severity: "info", action: "resume-on-printer", source: "moonraker", head: nil, message: nil, ref: nil),
        ]
        let today = Date().timeIntervalSince1970 * 1000
        let waiting = [WaitingReason(reason: "print-to-take-off", since: today - 3_600_000),
                       WaitingReason(reason: "bed-to-clear", since: today - 7_200_000)]
        let split = HeadFilament(heads: [.init(head: 0, grams: 42.3), .init(head: 1, grams: 18), .init(head: 2, grams: 7.6)],
                                 basis: "proportional")
        let looks: [(String, AnyView)] = [
            ("paused", AnyView(MachineCard(live: reading("PAUSED", api: "moonraker", progress: 64), fallbackStatus: nil))),
            ("needs-you", AnyView(MachineCard(live: reading("ATTENTION", progress: 64), fallbackStatus: nil))),
            ("reconnecting", AnyView(MachineCard(live: reading(nil, error: "timed out", api: "moonraker"), fallbackStatus: nil))),
            ("refused", AnyView(MachineCard(live: reading(nil, error: "HTTP 401", api: "bambu"), fallbackStatus: nil))),
            ("problems", AnyView(PrinterNeedsPanel(live: reading("paused", api: "moonraker", problems: problems)))),
            ("waiting", AnyView(PrinterNeedsPanel(live: reading("IDLE", waiting: waiting)))),
            ("heads", AnyView(HeadFilamentCard(split: split))),
        ]
        for lang in [AppLanguage.en, .ar] {
            L10n.setLanguage(lang)
            for dark in [false, true] {
                for (name, view) in looks {
                    let image = try render(view, dark: dark, ar: lang == .ar)
                    XCTAssertGreaterThan(image.size.height, 100, "\(name) \(lang) drew")
                    if let out, let png = image.pngData() {
                        try png.write(to: out.appending(path: "printer-\(name)-\(lang.rawValue)-\(dark ? "dark" : "light").png"))
                    }
                }
            }
        }
    }
}
