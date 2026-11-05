import Foundation
import Testing

/// A wall-clock budget that knows how slow the machine is right now.
///
/// The library's speed tests carry clock bounds because they guard real
/// regressions — the Library once went from 6 s to 0.35 s, and a change that
/// put it back must go red. But a fixed number cannot tell a regression from
/// a crowded runner: on GitHub's macOS runners, in the full suite, trivial
/// tests reported 350–800 s of wall time (Nov 2026), and a facet recount over
/// 600 models that takes ~100 ms here took 26.7 s against a 10 s budget —
/// on a build that had not regressed, and passed on re-run.
///
/// So the budget is scaled by a measured slowdown. A fixed, pure-CPU
/// reference workload is timed (best of three) and compared with what the
/// same workload takes on an idle developer Mac; the base budget is
/// multiplied by the ratio. The base budgets stay the numbers they were.
///
/// - Measured once per process, lazily, AND again right before each timed
///   section — the larger slowdown wins, because load changes during a run.
///   A section that misses its budget is measured once more before it is
///   failed, so load that arrived mid-section is seen too.
/// - Never below 1×: an idle fast machine gets the base budget, not less.
/// - Capped at `cap`: a runner more than that slow still fails, honestly,
///   and the message says the runner was slow, so the log shows which.
struct SpeedBudget: Sendable, CustomStringConvertible {

    /// The reference workload's time on an idle developer Mac, in ms.
    ///
    /// Measured Nov 5 2026 on an Apple M5 (10 cores), macOS 27.2, the debug
    /// build `swift test` makes: best of three per process, over ~25
    /// processes, 34.5–53 ms — the high end while other builds shared the
    /// machine (load average up to 25), the low end at load average ~2.5.
    /// `SpeedBudgetTests` prints it (`swift test --filter SpeedBudgetTests`).
    /// Rounded just under the best seen, so an idle machine like this one
    /// reads as 1×. A debug build: if `swift test` ever runs optimised, this
    /// number has to be measured again, or every machine reads as fast.
    static let referenceIdleMs = 34.0

    /// The most a budget is ever widened. Beyond this the runner is too slow
    /// to say anything about the code, and the test says so by failing.
    static let cap = 8.0

    /// The slowdown this budget scales by, 1...cap.
    let slowdown: Double

    /// The workload's best-of-three time when this budget was taken, in ms.
    let referenceMs: Double

    // MARK: Taking a budget

    /// The slowdown measured the first time anything asked, once per process.
    private static let processBudget: SpeedBudget = measureNow()

    /// A budget for the section about to be timed: the larger of the
    /// process's first measurement and one taken now.
    static func calibrate() -> SpeedBudget {
        let now = measureNow()
        return now.slowdown >= processBudget.slowdown ? now : processBudget
    }

    /// `base` ms scaled for this machine, taking a fresh measurement.
    static func ms(_ base: Double) -> Double { calibrate().ms(base) }

    /// `base` seconds scaled for this machine, taking a fresh measurement.
    static func seconds(_ base: Double) -> Duration { calibrate().seconds(base) }

    /// `base` ms scaled by this budget's slowdown.
    func ms(_ base: Double) -> Double { base * slowdown }

    /// `base` seconds scaled by this budget's slowdown.
    func seconds(_ base: Double) -> Duration { .milliseconds(ms(base * 1000)) }

    var description: String {
        String(format: "slowdown %.2fx (reference workload %.1f ms, idle %.1f ms, cap %.0fx)",
               slowdown, referenceMs, Self.referenceIdleMs, Self.cap)
    }

    /// Expect `measuredMs` to fit `baseMs` scaled by this budget. On a miss
    /// the machine is measured once more — load can arrive mid-section — and
    /// only a miss against that budget too is recorded, with the slowdown and
    /// the scaled budget in the message.
    func expect(_ measuredMs: Double, under baseMs: Double, _ what: @autoclosure () -> String,
                sourceLocation: SourceLocation = #_sourceLocation) {
        if measuredMs < ms(baseMs) { return }
        let after = Self.measureNow()
        let widest = after.slowdown > slowdown ? after : self
        if measuredMs < widest.ms(baseMs) { return }
        Issue.record(Comment(rawValue: String(
            format: "%@: %.1f ms against a budget of %.0f ms (base %.0f ms × %.2f; %@)",
            what(), measuredMs, widest.ms(baseMs), baseMs, widest.slowdown, widest.description)),
            sourceLocation: sourceLocation)
    }

    /// The same, for a `Duration`.
    func expect(_ measured: Duration, under base: Duration, _ what: @autoclosure () -> String,
                sourceLocation: SourceLocation = #_sourceLocation) {
        expect(Self.ms(of: measured), under: Self.ms(of: base), what(), sourceLocation: sourceLocation)
    }

    // MARK: The reference workload

    /// Time the reference workload three times and keep the best.
    static func measureNow() -> SpeedBudget {
        let clock = ContinuousClock()
        var best = Double.infinity
        for _ in 0..<3 {
            let t = clock.now
            let sum = referenceWorkload()
            let took = ms(of: clock.now - t)
            // The answer is fixed, so checking it both keeps the work from
            // being optimised away and proves the workload did not change.
            precondition(sum == referenceChecksum, "the reference workload changed: \(sum)")
            best = min(best, took)
        }
        return SpeedBudget(slowdown: min(cap, max(1, best / referenceIdleMs)), referenceMs: best)
    }

    /// Pure Swift, no I/O, no allocation after the first: sort 60,000
    /// pseudo-random integers from a fixed seed, then fold them into a hash.
    static func referenceWorkload() -> UInt64 {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var values = [UInt64](repeating: 0, count: 60_000)
        for i in values.indices {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            values[i] = state >> 11
        }
        values.sort()
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for v in values { hash = (hash ^ v) &* 0x0000_0100_0000_01B3 }
        return hash
    }

    /// `referenceWorkload()`'s answer.
    static let referenceChecksum: UInt64 = 14_552_818_198_820_478_458

    static func ms(of d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
}
