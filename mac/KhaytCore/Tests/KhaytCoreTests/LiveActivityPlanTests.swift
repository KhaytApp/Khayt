import Foundation
import Testing
@testable import KhaytCore

/// `LiveActivityPlan` is the phone's `PrintActivityPlan`, ported. These are the
/// phone's rules, case by case — the Mac's pushes and the phone's own
/// activities must agree about when a print starts, moves and ends.
struct LiveActivityPlanTests {
    typealias Plan = LiveActivityPlan
    static let now = Date(timeIntervalSince1970: 1_788_000_000)

    static func r(_ state: String?, progress: Int? = 40, file: String? = "bracket.gcode",
                  left: Int? = 3600, error: String? = nil, name: String? = "U1") -> Plan.Reading {
        Plan.Reading(name: name, state: state, progress: progress, filename: file, timeRemaining: left, error: error)
    }

    static func printing(_ progress: Int = 40, started: Date = now) -> Plan.State {
        Plan.State(phase: .printing, job: "bracket.gcode", progress: progress, startedAt: started,
                   endsAt: now.addingTimeInterval(3600))
    }

    @Test("a machine seen printing for the first time starts, with its name, job and finish")
    func starts() {
        let steps = Plan.steps(readings: ["m1": Self.r("printing")], running: [:], now: Self.now)
        #expect(steps == [.start(machineId: "m1", name: "U1", Self.printing())])
    }

    @Test("a machine first seen paused does not start one — the phone's rule")
    func pausedDoesNotStart() {
        #expect(Plan.steps(readings: ["m1": Self.r("paused")], running: [:], now: Self.now).isEmpty)
    }

    @Test("a machine that drops out of the readings has NOT ended")
    func dropOutIsNotAnEnd() {
        #expect(Plan.steps(readings: [:], running: ["m1": Self.printing()], now: Self.now).isEmpty)
    }

    @Test("seen printing, then seen not printing: finished at 100, failed or cancelled as it says")
    func ends() {
        let was = ["m1": Self.printing(70)]
        let done = Plan.steps(readings: ["m1": Self.r("standby")], running: was, now: Self.now)
        #expect(done == [.end(machineId: "m1", Plan.State(phase: .finished, job: "bracket.gcode", progress: 100,
                                                          startedAt: Self.now, endsAt: Self.now))])
        let failed = Plan.steps(readings: ["m1": Self.r("error")], running: was, now: Self.now)
        guard case let .end(_, f)? = failed.first else { Issue.record("no end"); return }
        #expect(f.phase == .failed && f.progress == 70)
        let errored = Plan.steps(readings: ["m1": Self.r("idle", error: "Nozzle clog")], running: was, now: Self.now)
        guard case let .end(_, e)? = errored.first else { Issue.record("no end"); return }
        #expect(e.phase == .failed)
        let cancelled = Plan.steps(readings: ["m1": Self.r("cancelled")], running: was, now: Self.now)
        guard case let .end(_, c)? = cancelled.first else { Issue.record("no end"); return }
        #expect(c.phase == .cancelled)
    }

    @Test("a pause is a print still on the bed: an update, not an end")
    func pauseIsAnUpdate() {
        let steps = Plan.steps(readings: ["m1": Self.r("paused")], running: ["m1": Self.printing()], now: Self.now)
        guard case let .update(_, s)? = steps.first else { Issue.record("not an update: \(steps)"); return }
        #expect(s.phase == .paused)
    }

    @Test("only a change a person would notice is sent, and the first start time is kept")
    func onChangeOnly() {
        let started = Self.now.addingTimeInterval(-900)
        let same = Plan.steps(readings: ["m1": Self.r("printing")], running: ["m1": Self.printing(started: started)],
                              now: Self.now)
        #expect(same.isEmpty, "nothing changed and something was sent")
        let moved = Plan.steps(readings: ["m1": Self.r("printing", progress: 41)],
                               running: ["m1": Self.printing(started: started)], now: Self.now)
        guard case let .update(_, s)? = moved.first else { Issue.record("no update"); return }
        #expect(s.progress == 41 && s.startedAt == started)
        // The finish moving by under a minute is not news; by more is.
        let slight = Plan.steps(readings: ["m1": Self.r("printing", left: 3630)],
                                running: ["m1": Self.printing(started: started)], now: Self.now)
        #expect(slight.isEmpty)
        let far = Plan.steps(readings: ["m1": Self.r("printing", left: 3700)],
                             running: ["m1": Self.printing(started: started)], now: Self.now)
        #expect(!far.isEmpty)
    }

    @Test("progress is a whole percent between 0 and 100")
    func progressClamped() {
        let over = Plan.steps(readings: ["m1": Self.r("printing", progress: 140)], running: [:], now: Self.now)
        let under = Plan.steps(readings: ["m1": Self.r("printing", progress: -5)], running: [:], now: Self.now)
        guard case let .start(_, _, a)? = over.first, case let .start(_, _, b)? = under.first else {
            Issue.record("no start"); return
        }
        #expect(a.progress == 100 && b.progress == 0)
    }

    @Test("a routine update waits out the cloud's 15 s; a phase change, a start and an end never wait")
    func floor() {
        let running = ["m1": Self.printing()]
        let update = Plan.Step.update(machineId: "m1", Self.printing(41))
        let sentJustNow = ["m1": Self.now.addingTimeInterval(-5)]
        #expect(!Plan.due(update, running: running, lastSent: sentJustNow, now: Self.now))
        #expect(Plan.due(update, running: running, lastSent: ["m1": Self.now.addingTimeInterval(-15)], now: Self.now))
        var paused = Self.printing(41); paused.phase = .paused
        #expect(Plan.due(.update(machineId: "m1", paused), running: running, lastSent: sentJustNow, now: Self.now))
        #expect(Plan.due(.end(machineId: "m1", paused), running: running, lastSent: sentJustNow, now: Self.now))
        #expect(Plan.due(.start(machineId: "m2", name: "X", paused), running: running, lastSent: sentJustNow,
                         now: Self.now))
    }
}
