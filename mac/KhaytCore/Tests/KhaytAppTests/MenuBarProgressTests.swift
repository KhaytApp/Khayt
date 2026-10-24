import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The menu bar item's ring and figures, the fleet panel's order, and the
/// print notices this Mac sends once per print (`MenuBarProgress.swift`,
/// `PrintNotices.swift`).
@MainActor
struct MenuBarProgressTests {

    static func printing(_ pct: Int, left: Double?, file: String = "part.gcode") -> KhaytEngine.PrinterStatus {
        KhaytEngine.PrinterStatus(state: "printing", progress: pct, progressSource: nil, filename: file,
                                  timeRemaining: left, tempNozzle: nil, tempBed: nil, type: "moonraker")
    }

    static func state(_ s: String, pct: Int = 0, out: Bool? = nil) -> KhaytEngine.PrinterStatus {
        var status = KhaytEngine.PrinterStatus(state: s, progress: pct, progressSource: nil, filename: "part.gcode",
                                               timeRemaining: nil, tempNozzle: nil, tempBed: nil, type: "moonraker")
        status.filamentOut = out
        return status
    }

    static func line(_ id: String, _ status: KhaytEngine.PrinterStatus?, quiet: Shop.Quiet? = nil,
                     bed: Bool = false) -> FloorLine {
        FloorRead.line(id: id, name: id, status: status, quiet: status == nil ? quiet : nil, bedNotClear: bed)
    }

    // MARK: - The label

    @Test("one print: the ring, then \"64% · 1h 02m\"")
    func onePrint() {
        let words = Words()
        let label = FloorRead.label([Self.line("a", Self.printing(64, left: 62 * 60 + 10))],
                                    style: .ringAndFigures, words: words)
        #expect(label.ring == 0.64)
        #expect(label.text == "64% · 1h 02m")
        #expect(!label.attention)
    }

    @Test("several prints: the one finishing soonest leads, then +N for the others")
    func severalPrints() {
        let words = Words()
        let lines = [Self.line("long", Self.printing(31, left: 4 * 3600 + 600)),
                     Self.line("soon", Self.printing(88, left: 25 * 60)),
                     Self.line("blind", Self.printing(10, left: nil)),
                     Self.line("idle", Self.state("standby"))]
        let label = FloorRead.label(lines, style: .ringAndFigures, words: words)
        #expect(label.ring == 0.88)
        #expect(label.text == "88% · 25m +2")
        // A print that does not say how long only leads when it is the only one.
        let blind = FloorRead.label([Self.line("blind", Self.printing(10, left: nil))],
                                    style: .ringAndFigures, words: words)
        #expect(blind.text == "10%")
    }

    @Test("nothing printing is the nozzle alone, as before")
    func nothingPrinting() {
        let label = FloorRead.label([Self.line("a", Self.state("standby")), Self.line("b", nil, quiet: .notSetUp)],
                                    style: .ringAndFigures, words: Words())
        #expect(label == FloorRead.Label(ring: nil, text: "", attention: false))
    }

    @Test("the three styles: ring and figures, ring only, glyph only")
    func styles() {
        let words = Words()
        let lines = [Self.line("a", Self.printing(40, left: 600))]
        #expect(FloorRead.label(lines, style: .ringOnly, words: words) == .init(ring: 0.4, text: "", attention: false))
        #expect(FloorRead.label(lines, style: .glyphOnly, words: words) == .init(ring: nil, text: "", attention: false))
        #expect(MenuBarStyle(rawValue: MenuBarStyle.ringAndFigures.rawValue) == .ringAndFigures)
    }

    @Test("attention marks the label in every style, printing or not")
    func attentionMark() {
        let words = Words()
        let paused = [Self.line("p", Self.state("paused", pct: 48))]
        for style in MenuBarStyle.allCases {
            #expect(FloorRead.label(paused, style: style, words: words).attention)
        }
        // A runout mid-print still leads the figures: it is still printing.
        let runout = [Self.line("r", { var s = Self.printing(50, left: 3600); s.filamentOut = true; return s }())]
        let label = FloorRead.label(runout, style: .ringAndFigures, words: words)
        #expect(label.attention && label.ring == 0.5 && label.text == "50% · 1h 00m")
    }

    @Test("what counts as needing somebody")
    func attentionRules() {
        #expect(FloorRead.attention(Self.state("paused"), bedNotClear: false) == .paused)
        #expect(FloorRead.attention(Self.state("pausing"), bedNotClear: false) == .paused)
        #expect(FloorRead.attention(Self.state("paused", out: true), bedNotClear: false) == .runout)
        #expect(FloorRead.attention(Self.state("error"), bedNotClear: false) == .fault)
        #expect(FloorRead.attention(Self.state("FAILED"), bedNotClear: false) == .fault)
        #expect(FloorRead.attention(Self.state("standby"), bedNotClear: true) == .bedNotClear)
        // A stale bed verdict about a machine now printing does not win, and
        // one about a machine not answering is not drawn either.
        #expect(FloorRead.attention(Self.printing(5, left: 60), bedNotClear: true) == nil)
        #expect(FloorRead.attention(nil, bedNotClear: true) == nil)
        #expect(FloorRead.attention(Self.state("standby"), bedNotClear: false) == nil)
        #expect(FloorRead.attention(Self.state("complete"), bedNotClear: false) == nil)
    }

    @Test("durations pad their minutes so the width holds still")
    func durations() {
        let words = Words()
        #expect(FloorRead.duration(3600 + 9 * 60, words) == "1h 09m")
        #expect(FloorRead.duration(3600 + 10 * 60, words) == "1h 10m")
        #expect(FloorRead.duration(25 * 60, words) == "25m")
        #expect(FloorRead.duration(20, words) == words.callIt("mac.dur_under_1m"))
    }

    @Test("the finish time is a clock time, with the weekday only when it is not today")
    func finishTime() throws {
        let words = Words()
        let noon = try #require(Calendar.book.date(bySettingHour: 12, minute: 0, second: 0, of: Date()))
        let today = FloorRead.finishes(30 * 60, now: noon, words: words)
        #expect(today == "done " + words.say(noon.addingTimeInterval(1800), .dateTime.hour().minute()))
        let tomorrow = FloorRead.finishes(20 * 3600, now: noon, words: words)
        #expect(tomorrow != "done " + words.say(noon.addingTimeInterval(20 * 3600), .dateTime.hour().minute()))
    }

    @Test("the Arabic figures and machine names are isolated")
    func arabicIsolated() throws {
        for key in ["mac.mbp_figures", "mac.mbp_pct", "mac.mbp_hm", "mac.mbp_m", "mac.mbp_more",
                    "mac.mbp_left", "mac.mbp_done_at", "mac.mbp_open_machine",
                    "mac.mbp_notice_finished", "mac.mbp_notice_failed", "mac.mbp_notice_paused"] {
            let ar = try #require(Words.own[key]?["ar"], "\(key) has no Arabic")
            let en = try #require(Words.own[key]?["en"], "\(key) has no English")
            // Same placeholders both sides.
            let holders = { (s: String) in Set(s.matches(of: /\{[a-z]+\}/).map { String($0.output) }) }
            #expect(holders(ar) == holders(en), "\(key)")
            #expect(ar.contains("\u{2068}") && ar.contains("\u{2069}"), "\(key) is not isolated in Arabic")
        }
    }

    // MARK: - The fleet's order

    @Test("attention first, then printing soonest-first, then idle, then offline")
    func sortOrder() {
        let lines = FloorRead.sorted([
            Self.line("off", nil, quiet: .notAnswering),
            Self.line("idle", Self.state("standby")),
            Self.line("late", Self.printing(10, left: 5 * 3600)),
            Self.line("blind", Self.printing(10, left: nil)),
            Self.line("soon", Self.printing(90, left: 300)),
            Self.line("paused", Self.state("paused")),
            Self.line("unset", nil, quiet: .notSetUp),
            Self.line("fault", Self.state("error")),
        ])
        #expect(lines.map(\.id) == ["paused", "fault", "soon", "late", "blind", "idle", "unset", "off"])
        #expect(lines.map(\.rank) == [.attention, .attention, .printing, .printing, .printing, .idle, .idle, .offline])
    }

    @Test("the sample floor in the snapshot's attention scene sorts the way the panel draws it")
    func sampleFloor() async throws {
        let shop = Shop()
        await shop.load(.sample)
        defer { shop.printers.clearReadingsForTesting(); shop.dispatch = nil }
        Snapshot.plant(.attention, on: shop)
        let lines = FloorRead.lines(shop)
        #expect(lines.first?.id == "MACH-u1" && lines.first?.attention == .runout)
        #expect(lines[1].id == "MACH-LASER" && lines[1].attention == .bedNotClear)
        #expect(lines[2].id == "MACH-core-one" && lines[3].id == "MACH-x1c", "soonest finish first")
        #expect(lines.last?.id == "MACH-UVFLAT" && lines.last?.rank == .offline)
        // No retired machine, and nothing the book has not got.
        #expect(Set(lines.map(\.id)) == Set(shop.machinesInUse.map(\.id)))
    }

    // MARK: - Notices, once per print

    @Test("a pause is told once per print, never on every tick")
    func pauseOnce() {
        var ledger = PrintNoticeLedger()
        #expect(ledger.observe("m", state: "printing", filamentOut: nil).isEmpty, "the first reading is the baseline")
        #expect(ledger.observe("m", state: "paused", filamentOut: nil) == [.paused])
        for _ in 0..<5 { #expect(ledger.observe("m", state: "paused", filamentOut: nil).isEmpty) }
        // Resumed and paused again: the same print, already told.
        #expect(ledger.observe("m", state: "printing", filamentOut: nil).isEmpty)
        #expect(ledger.observe("m", state: "paused", filamentOut: nil).isEmpty)
        // The print ends; the next one is news again.
        #expect(ledger.observe("m", state: "standby", filamentOut: nil).isEmpty)
        #expect(ledger.observe("m", state: "printing", filamentOut: nil).isEmpty)
        #expect(ledger.observe("m", state: "paused", filamentOut: nil) == [.paused])
        // Another machine has its own memory.
        #expect(ledger.observe("n", state: "printing", filamentOut: nil).isEmpty)
        #expect(ledger.observe("n", state: "paused", filamentOut: nil) == [.paused])
    }

    @Test("already paused when the app opened is not news; a runout pause is the runout alert's")
    func pauseBaselineAndRunout() {
        var ledger = PrintNoticeLedger()
        #expect(ledger.observe("m", state: "paused", filamentOut: nil).isEmpty)
        #expect(ledger.observe("m", state: "paused", filamentOut: nil).isEmpty)
        #expect(ledger.observe("r", state: "printing", filamentOut: nil).isEmpty)
        #expect(ledger.observe("r", state: "paused", filamentOut: true).isEmpty)
        #expect(ledger.observe("r", state: "paused", filamentOut: false).isEmpty, "the same pause, not told late")
    }

    @Test("a finish and a failure are told once; a cancel is not; a failure the fault alert told is not told twice")
    func endings() {
        var ledger = PrintNoticeLedger()
        _ = ledger.observe("m", state: "printing", filamentOut: nil)
        _ = ledger.observe("m", state: "complete", filamentOut: nil)
        #expect(ledger.ended("m", outcome: "finished") == .finished)
        #expect(ledger.ended("m", outcome: "finished") == nil)
        #expect(ledger.ended("m", outcome: "cancelled") == nil)
        // The next print fails.
        _ = ledger.observe("m", state: "printing", filamentOut: nil)
        #expect(ledger.ended("m", outcome: "failed") == .failed)
        #expect(ledger.ended("m", outcome: "failed") == nil)
        // And the one after faults first.
        _ = ledger.observe("m", state: "standby", filamentOut: nil)
        _ = ledger.observe("m", state: "printing", filamentOut: nil)
        ledger.faultTold("m")
        #expect(ledger.ended("m", outcome: "failed") == nil)
        // Forgotten (deleted, retired) starts from nothing.
        ledger.forget("m")
        #expect(ledger.ended("m", outcome: "finished") == .finished)
    }

    @Test("each notice has its own Mac-local switch, on by default")
    func switches() {
        #expect(Set(PrintNoticeKind.allCases.map(\.defaultsKey)).count == 3)
        for kind in PrintNoticeKind.allCases {
            #expect(kind.defaultsKey.hasPrefix("mac.notify."))
            #expect(Words.own[kind.toggleKey]?["ar"] != nil && Words.own[kind.titleKey]?["ar"] != nil)
        }
    }

    // MARK: - The item

    @Test("the item draws the floor on install, and remove() still stops the clock")
    func itemLifetime() async throws {
        let shop = Shop()
        await shop.load(.sample)
        defer { shop.printers.clearReadingsForTesting() }
        Snapshot.plant(.one, on: shop)
        let defaults = UserDefaults.standard
        let was = defaults.object(forKey: "mac.menuBar")
        let style = defaults.object(forKey: MenuBarStyle.defaultsKey)
        defaults.set(true, forKey: "mac.menuBar")
        defaults.removeObject(forKey: MenuBarStyle.defaultsKey)
        defer {
            defaults.set(was, forKey: "mac.menuBar")
            defaults.set(style, forKey: MenuBarStyle.defaultsKey)
        }
        let floor = FloorStatus.shared
        floor.remove()
        floor.install(shop: shop)
        #expect(floor.isTicking)
        #expect(floor.shown?.text == "64% · 1h 02m")
        #expect(floor.shown?.ring == 0.64)
        floor.remove()
        #expect(!floor.isTicking, "removed means the timer is gone")
        #expect(floor.shown == nil)
        // A restyle after removal draws nothing and starts nothing.
        floor.restyle()
        #expect(!floor.isTicking)
    }

    @Test("the glyph is a template image, so the menu bar tints it")
    func templateGlyph() {
        for ring in [nil, 0.0, 0.5, 1.0] as [Double?] {
            for attention in [false, true] {
                #expect(StatusGlyph.image(ring: ring, attention: attention).isTemplate)
            }
        }
    }
}
