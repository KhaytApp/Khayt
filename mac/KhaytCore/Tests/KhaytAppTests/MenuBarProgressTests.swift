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

    @Test("one print: the ring, then \"64%\"")
    func onePrint() {
        let words = Words()
        let label = FloorRead.label([Self.line("a", Self.printing(64, left: 62 * 60 + 10))],
                                    style: .ringAndFigures, words: words)
        #expect(label.ring == 0.64)
        #expect(label.text == "64%")
        #expect(!label.attention && !label.tick)
    }

    @Test("several prints: the ring of the one finishing soonest, and how many are printing")
    func severalPrints() {
        let words = Words()
        let lines = [Self.line("long", Self.printing(31, left: 4 * 3600 + 600)),
                     Self.line("soon", Self.printing(88, left: 25 * 60)),
                     Self.line("blind", Self.printing(10, left: nil)),
                     Self.line("idle", Self.state("standby"))]
        let label = FloorRead.label(lines, style: .ringAndFigures, words: words)
        #expect(label.ring == 0.88)
        #expect(label.text == "3")
        // Two is a count too; one is back to its percentage.
        #expect(FloorRead.label(Array(lines.prefix(2)), style: .ringAndFigures, words: words).text == "2")
        #expect(FloorRead.label(Array(lines.dropFirst(3)), style: .ringAndFigures, words: words).text == "")
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
        #expect(label.attention && label.ring == 0.5 && label.text == "50%")
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
        #expect(today == "done at " + words.say(noon.addingTimeInterval(1800), .dateTime.hour().minute()))
        let tomorrow = FloorRead.finishes(20 * 3600, now: noon, words: words)
        #expect(tomorrow != "done at " + words.say(noon.addingTimeInterval(20 * 3600), .dateTime.hour().minute()))
    }

    @Test("the Arabic figures and machine names are isolated")
    func arabicIsolated() throws {
        for key in ["mac.mbp_figures", "mac.mbp_pct", "mac.mbp_hm", "mac.mbp_m", "mac.mbp_more",
                    "mac.mbp_left", "mac.mbp_done_at", "mac.mbp_open_machine",
                    "mac.mbp_notice_finished", "mac.mbp_notice_failed", "mac.mbp_notice_paused",
                    "mac.mbh_next_free_at", "mac.mbh_left_est", "mac.mbh_free_since", "mac.mbh_plates_free",
                    "mac.mbh_next_up", "mac.mbh_next_up_today", "mac.mbh_next_up_due", "mac.mbh_done_title",
                    "mac.mbh_vo_printing", "mac.mbh_vo_percent"] {
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
        #expect(ledger.faultTold("m") == false, "nothing was told yet: the fault alert is the banner")
        #expect(ledger.ended("m", outcome: "failed") == nil)
        // And one where the finish seam lands first (the usual order: the
        // alerts run after the sweep): the fault alert is not a second banner.
        _ = ledger.observe("m", state: "standby", filamentOut: nil)
        _ = ledger.observe("m", state: "printing", filamentOut: nil)
        #expect(ledger.ended("m", outcome: "failed") == .failed)
        #expect(ledger.faultTold("m") == true)
        // A fault long after that failure is news of its own.
        #expect(ledger.faultTold("m", now: Date().addingTimeInterval(PrintNoticeLedger.sameFailure + 1)) == false)
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
        #expect(floor.shown?.text == "64%")
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
                #expect(StatusGlyph.image(ring: ring, attention: attention, tick: true).isTemplate)
            }
        }
    }

    @Test("the same figure is the same cached picture, and a different one is not")
    func cachedGlyph() {
        let a = StatusGlyph.image(ring: 0.64, attention: false)
        #expect(StatusGlyph.image(ring: 0.64, attention: false) === a)
        #expect(StatusGlyph.image(ring: 0.65, attention: false) !== a)
        #expect(StatusGlyph.image(ring: 0.64, attention: true) !== a)
        #expect(StatusGlyph.image(ring: 1, attention: false, tick: true) !== StatusGlyph.image(ring: 1, attention: false))
    }

    // MARK: - The hero

    static func runout(_ pct: Int) -> KhaytEngine.PrinterStatus { state("paused", pct: pct, out: true) }

    @Test("the hero is the print that finishes soonest")
    func heroSoonest() {
        let lines = FloorRead.sorted([Self.line("long", Self.printing(31, left: 4 * 3600)),
                                      Self.line("soon", Self.printing(20, left: 25 * 60)),
                                      Self.line("idle", Self.state("standby"))])
        #expect(FloorRead.hero(lines)?.id == "soon")
        #expect(FloorRead.hero([Self.line("idle", Self.state("standby")), Self.line("off", nil, quiet: .notAnswering)]) == nil)
        #expect(FloorRead.hero([]) == nil)
    }

    @Test("a print that does not say how long comes after those that do, the furthest along first")
    func heroWithoutTimes() {
        let blind = [Self.line("a", Self.printing(10, left: nil)),
                     Self.line("b", Self.printing(70, left: nil)),
                     Self.line("c", Self.printing(40, left: nil))]
        #expect(FloorRead.hero(blind)?.id == "b")
        // A time beats any progress.
        #expect(FloorRead.hero(blind + [Self.line("timed", Self.printing(1, left: 9 * 3600))])?.id == "timed")
        // Ties keep the book's order.
        let tied = [Self.line("first", Self.printing(50, left: nil)), Self.line("second", Self.printing(50, left: nil))]
        #expect(FloorRead.hero(tied)?.id == "first")
        let same = [Self.line("first", Self.printing(10, left: 600)), Self.line("second", Self.printing(90, left: 600))]
        #expect(FloorRead.hero(same)?.id == "first")
    }

    @Test("a stopped print is eligible, keeps its attention, and yields to one with a finish time")
    func heroStopped() {
        // Alone, the runout is the hero, and it is still a runout.
        let alone = [Self.line("idle", Self.state("standby")), Self.line("r", Self.runout(48))]
        #expect(FloorRead.hero(alone)?.id == "r")
        #expect(FloorRead.hero(alone)?.attention == .runout)
        #expect(FloorRead.hero(alone)?.rank == .attention, "the hero is the line itself, not the copy it was ranked by")
        // Paused, and a fault part-way through, the same.
        #expect(FloorRead.hero([Self.line("p", Self.state("paused", pct: 30))])?.attention == .paused)
        #expect(FloorRead.hero([Self.line("f", Self.state("error", pct: 30))])?.attention == .fault)
        // A fault with no print under it (0%, or done) is not a print.
        #expect(FloorRead.hero([Self.line("f", Self.state("error", pct: 0))]) == nil)
        #expect(FloorRead.hero([Self.line("f", Self.state("error", pct: 100))]) == nil)
        #expect(FloorRead.hero([Self.line("bed", Self.state("standby"), bed: true)]) == nil)
        // Beside a print that says when it finishes, the stopped one waits in its row.
        let mixed = [Self.line("r", Self.runout(90)), Self.line("go", Self.printing(5, left: 6 * 3600))]
        #expect(FloorRead.hero(mixed)?.id == "go")
        // Beside one that does not say, the further along leads.
        #expect(FloorRead.hero([Self.line("blind", Self.printing(20, left: nil)), Self.line("r", Self.runout(48))])?.id == "r")
    }

    // MARK: - The time left between readings

    @Test("the time left counts down from the reading, never below nothing")
    func leftCountsDown() {
        let read = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(FloorRead.leftNow(left: 600, readAt: read, now: read) == .init(seconds: 600, estimate: false))
        #expect(FloorRead.leftNow(left: 600, readAt: read, now: read.addingTimeInterval(7)).seconds == 593)
        #expect(FloorRead.leftNow(left: 600, readAt: read, now: read.addingTimeInterval(600)).seconds == 0)
        #expect(FloorRead.leftNow(left: 600, readAt: read, now: read.addingTimeInterval(9000)).seconds == 0)
        // A clock set back does not add time.
        #expect(FloorRead.leftNow(left: 600, readAt: read, now: read.addingTimeInterval(-300)) == .init(seconds: 600, estimate: false))
        // No reading time at all: the figure as given.
        #expect(FloorRead.leftNow(left: 600, readAt: nil, now: read) == .init(seconds: 600, estimate: false))
        #expect(FloorRead.leftNow(left: -5, readAt: nil, now: read).seconds == 0)
    }

    @Test("a reading older than two polls is an estimate, and exactly two is not")
    func estimateBoundary() {
        #expect(FloorRead.pollEvery == 10, "the poller's interval moved: the threshold moves with it")
        #expect(FloorRead.estimateAfter == 20)
        let read = Date(timeIntervalSince1970: 1_800_000_000)
        func estimate(_ age: TimeInterval) -> Bool {
            FloorRead.leftNow(left: 3600, readAt: read, now: read.addingTimeInterval(age)).estimate
        }
        #expect(!estimate(0) && !estimate(10) && !estimate(19.9) && !estimate(20))
        #expect(estimate(20.1) && estimate(45))
        // A missed poll rewrites the reading's time; the status is older by a poll for each miss.
        let status = Self.printing(50, left: 600)
        let fresh = PrinterWatch.Reading(status: status, problem: nil, at: read, lastGood: status)
        #expect(FloorRead.goodAt(fresh) == read)
        let missed = PrinterWatch.Reading(status: nil, problem: "x", at: read, consecutiveFailures: 2, lastGood: status)
        #expect(FloorRead.goodAt(missed) == read.addingTimeInterval(-20))
    }

    @Test("the words say \"about\" for an estimate, and the time twice")
    func estimateWords() {
        let words = Words()
        #expect(FloorRead.leftPhrase(.init(seconds: 72 * 60, estimate: false), words: words) == "1h 12m left")
        #expect(FloorRead.leftPhrase(.init(seconds: 72 * 60, estimate: true), words: words) == "about 1h 12m left")
    }

    // MARK: - The icon

    @Test("just finished: a closed ring with a tick until it expires, in the ring styles only")
    func tickAndExpiry() {
        let words = Words()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let until = now.addingTimeInterval(FloorRead.iconHold)
        let idle = [Self.line("a", Self.state("complete"))]
        let ticking = FloorRead.label(idle, style: .ringAndFigures, words: words, tickUntil: until, now: now)
        #expect(ticking == .init(ring: 1, text: "", attention: false, tick: true))
        #expect(FloorRead.label(idle, style: .ringOnly, words: words, tickUntil: until, now: now).tick)
        #expect(!FloorRead.label(idle, style: .glyphOnly, words: words, tickUntil: until, now: now).tick)
        // The last instant before, and the instant of, expiry.
        #expect(FloorRead.label(idle, style: .ringOnly, words: words, tickUntil: until,
                                now: until.addingTimeInterval(-0.001)).tick)
        let after = FloorRead.label(idle, style: .ringAndFigures, words: words, tickUntil: until, now: until)
        #expect(after == .init(ring: nil, text: "", attention: false))
        // While others print, the tick still shows for its while, then the count returns.
        let busy = [Self.line("a", Self.printing(10, left: 600)), Self.line("b", Self.printing(20, left: 900))]
        #expect(FloorRead.label(busy, style: .ringAndFigures, words: words, tickUntil: until, now: now).tick)
        #expect(FloorRead.label(busy, style: .ringAndFigures, words: words, tickUntil: until, now: until).text == "2")
        // Somebody is still wanted during it.
        let wanted = [Self.line("p", Self.state("paused", pct: 4))]
        #expect(FloorRead.label(wanted, style: .ringOnly, words: words, tickUntil: until, now: now).attention)
        // No finish, no tick.
        #expect(!FloorRead.label(busy, style: .ringAndFigures, words: words).tick)
    }

    // MARK: - The finish moment

    static func finishedLine(_ id: String, at: Date, cleared: Date? = nil,
                             status: KhaytEngine.PrinterStatus? = state("complete", pct: 100)) -> FloorLine {
        FloorRead.line(id: id, name: id, status: status, quiet: nil, bedNotClear: false,
                       ended: (at: at, finished: true), bedClearedAt: cleared)
    }

    @Test("a line is finished from the seam's word until the plate is cleared or the next print starts")
    func finishedLines() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(Self.finishedLine("m", at: at).finished)
        #expect(Self.finishedLine("m", at: at).isFinished)
        // Cleared before that print ended does not count; cleared after does.
        #expect(Self.finishedLine("m", at: at, cleared: at.addingTimeInterval(-60)).finished)
        #expect(!Self.finishedLine("m", at: at, cleared: at.addingTimeInterval(60)).finished)
        // In the next job, or not answering: not a finished plate.
        #expect(!Self.finishedLine("m", at: at, status: Self.printing(3, left: 900)).finished)
        #expect(!Self.finishedLine("m", at: at, status: Self.state("paused", pct: 3)).finished)
        #expect(!Self.finishedLine("m", at: at, status: nil).finished)
        // A print that failed or was cancelled ended, and is not finished.
        let failed = FloorRead.line(id: "m", name: "m", status: Self.state("standby"), quiet: nil, bedNotClear: false,
                                    ended: (at: at, finished: false))
        #expect(!failed.finished && failed.endedAt == at)
        // The dispatcher's bed verdict reads as finished too.
        #expect(Self.line("bed", Self.state("standby"), bed: true).isFinished)
        // A finished plate is listed before an empty one.
        let sorted = FloorRead.sorted([Self.line("idle", Self.state("standby")), Self.finishedLine("done", at: at)])
        #expect(sorted.map(\.id) == ["done", "idle"])
    }

    @Test("the finish moment: only a line that TURNED finished, held for a few seconds")
    func finishMoment() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let before = [Self.line("a", Self.printing(99, left: 30)), Self.line("b", Self.printing(40, left: 3000)),
                      Self.finishedLine("old", at: now.addingTimeInterval(-3600))]
        let after = [Self.finishedLine("a", at: now), Self.line("b", Self.printing(41, left: 2990)),
                     Self.finishedLine("old", at: now.addingTimeInterval(-3600)),
                     Self.finishedLine("new", at: now)]
        let moment = FloorRead.justFinished(previous: before, current: after, now: now)
        #expect(moment == ["a": now.addingTimeInterval(FloorRead.cardHold)])
        // Nothing to compare with (the panel just opened): no moment.
        #expect(FloorRead.justFinished(previous: [], current: after, now: now).isEmpty)
        // Nothing changed: no moment twice.
        #expect(FloorRead.justFinished(previous: after, current: after, now: now).isEmpty)
        // A print that stopped without the seam calling it finished is not one.
        let cancelled = [Self.line("a", Self.state("standby")), Self.line("b", Self.printing(41, left: 2990))]
        #expect(FloorRead.justFinished(previous: before, current: cancelled, now: now).isEmpty)
        #expect(FloorRead.cardHold > 0 && FloorRead.iconHold >= FloorRead.cardHold)
    }

    // MARK: - What the panel says

    @Test("VoiceOver reads a card as one sentence")
    func spokenSentence() throws {
        let words = Words()
        let now = try #require(Calendar.book.date(bySettingHour: 15, minute: 23, second: 0, of: Date()))
        var line = FloorRead.line(id: "u1", name: "Snapmaker U1", status: Self.printing(64, left: 72 * 60),
                                  quiet: nil, bedNotClear: false, readAt: now)
        let done = words.say(now.addingTimeInterval(72 * 60), .dateTime.hour().minute())
        #expect(FloorRead.spoken(line, job: "Drone arm v4", now: now, words: words)
                == "Snapmaker U1, printing Drone arm v4, 64 percent, 1 hour, 12 minutes left, done at \(done)")
        // Stopped: its word, and no time that is not counting.
        line = Self.line("r", Self.runout(48))
        #expect(FloorRead.spoken(line, job: "Kings", now: now, words: words) == "r, Out of filament, Kings, 48 percent")
        #expect(FloorRead.spoken(Self.line("i", Self.state("standby")), job: "", now: now, words: words) == "i, Idle")
        #expect(FloorRead.spoken(Self.finishedLine("f", at: now), job: "Bracket", now: now, words: words)
                == "f, Finished, Bracket")
    }

    @Test("the header counts the prints and says when the first plate is free")
    func headline() throws {
        let words = Words()
        let now = try #require(Calendar.book.date(bySettingHour: 15, minute: 23, second: 0, of: Date()))
        let lines = [Self.line("a", Self.printing(64, left: 72 * 60)), Self.line("b", Self.printing(31, left: 4 * 3600)),
                     Self.line("i", Self.state("standby"))]
        let free = words.say(now.addingTimeInterval(72 * 60), .dateTime.hour().minute())
        #expect(FloorRead.headline(lines, now: now, words: words) == "2 printing · next free \(free)")
        #expect(FloorRead.headline([Self.line("i", Self.state("standby"))], now: now, words: words)
                == words.callIt("mac.nothing_printing"))
    }

    @Test("next up: the dispatcher's proposal, else the waiting job due soonest")
    func nextUp() async throws {
        let shop = Shop()
        await shop.load(.sample)
        // The sample book moves with the calendar, so "today" is taken from it.
        let due = try #require(shop.orders.last { ($0.status == "pending" || $0.status == "queued") && Order.day($0.dueDate) != nil })
        let today = try #require(Order.day(due.dueDate))
        let waiting = shop.orders.filter { $0.status == "pending" || $0.status == "queued" }
        #expect(waiting.count > 2, "the sample has waiting jobs to choose from")
        let next = try #require(FloorRead.nextUp(shop.orders, proposed: [], today: today))
        let soonest = try #require(waiting.compactMap { Order.day($0.dueDate) }.min())
        #expect(Order.day(shop.orders.first { $0.id == next.id }?.dueDate) == soonest)
        // A proposal wins, when it is a job that is waiting.
        let other = try #require(waiting.last { $0.id != next.id })
        #expect(FloorRead.nextUp(shop.orders, proposed: ["no-such-job", other.id], today: today)?.id == other.id)
        // Due today is said as today; another day as its date; nothing waiting is nothing.
        #expect(FloorRead.nextUp([due], proposed: [], today: today)?.due == .today)
        #expect(FloorRead.nextUp([due], proposed: [], today: today.addingTimeInterval(-86400 * 3))?.due == .on(today))
        #expect(FloorRead.nextUp(shop.orders.filter { $0.status == "completed" }, proposed: [], today: today) == nil)
        #expect(FloorRead.nextUpLine(.init(id: "x", name: "Bracket", due: .today), words: Words())
                .contains("due today"))
    }

    // MARK: - The chime

    @Test("the finish chime is off by default, and silent when off")
    func chime() {
        let defaults = UserDefaults.standard
        let was = defaults.object(forKey: FinishChime.defaultsKey)
        defer { defaults.set(was, forKey: FinishChime.defaultsKey) }
        defaults.removeObject(forKey: FinishChime.defaultsKey)
        #expect(!FinishChime.wanted, "nobody asked for a sound")
        var played: [String] = []
        // Through the setting as it stands (off): nothing reaches the player.
        #expect(!FinishChime.ring(play: { played.append($0) }))
        #expect(played.isEmpty)
        #expect(!FinishChime.ring(wanted: false, play: { played.append($0) }))
        #expect(played.isEmpty)
        // Switched on, it plays once, a system sound.
        defaults.set(true, forKey: FinishChime.defaultsKey)
        #expect(FinishChime.wanted)
        #expect(FinishChime.ring(play: { played.append($0) }))
        #expect(played == [FinishChime.sound])
        #expect(Words.own["mac.mbh_chime"]?["ar"] != nil)
    }

    @Test("Pause and Resume are one offer, with the machine card's own gates")
    func printStep() async throws {
        let shop = Shop()
        await shop.load(.sample)
        defer { shop.pretendsControl = false; shop.printerVerbs = [:] }
        shop.pretendMachine("MACH-u1", ["printerApi": .object(["type": .string("moonraker"),
                                                               "host": .string("192.168.1.40")])])
        let machine = try #require(shop.machines.first { $0.id == "MACH-u1" })
        // Not asked yet: nothing is drawn.
        #expect(shop.printStep(machine, paused: false) == nil)
        shop.printerVerbs["moonraker"] = [.pause, .resume, .cancel]
        // The sample book is not one this Mac may move jobs in: drawn, greyed.
        #expect(shop.printStep(machine, paused: false) == .init(verb: .pause, wordKey: "mac.printer_pause", enabled: false))
        shop.pretendsControl = true
        #expect(shop.printStep(machine, paused: false)?.enabled == true)
        #expect(shop.printStep(machine, paused: true) == .init(verb: .resume, wordKey: "mac.printer_resume", enabled: true))
        // A command already on its way greys it.
        shop.printerBusy.insert(machine.id)
        #expect(shop.printStep(machine, paused: false)?.enabled == false)
        shop.printerBusy.remove(machine.id)
        // A protocol that cannot pause draws no Pause.
        shop.printerVerbs["moonraker"] = [.cancel]
        #expect(shop.printStep(machine, paused: false) == nil)
        // A machine with no connection is offered nothing.
        let bare = try #require(shop.machines.first { $0.id == "MACH-LASER" })
        #expect(shop.printStep(bare, paused: false) == nil)
    }
}
