import Testing

/// The calibration behind the library's clock bounds (see `SpeedBudget`).
/// Prints what this machine measures, which is how `referenceIdleMs` was set.
struct SpeedBudgetTests {

    @Test("the reference workload is deterministic and the slowdown stays within 1×…cap")
    func calibration() {
        #expect(SpeedBudget.referenceWorkload() == SpeedBudget.referenceChecksum)
        let budget = SpeedBudget.calibrate()
        print("SpeedBudget:", budget)
        #expect(budget.slowdown >= 1 && budget.slowdown <= SpeedBudget.cap)
        #expect(budget.ms(1_000) == 1_000 * budget.slowdown)
        #expect(budget.seconds(2) == .milliseconds(2_000 * budget.slowdown))
    }

    @Test("a budget is never tighter than its base, and never wider than the cap allows")
    func bounds() {
        let idle = SpeedBudget(slowdown: 1, referenceMs: 0)
        #expect(idle.ms(10_000) == 10_000)
        let capped = SpeedBudget(slowdown: SpeedBudget.cap, referenceMs: 0)
        #expect(capped.ms(10_000) == 10_000 * SpeedBudget.cap)
    }
}
