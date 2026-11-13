import Foundation
import Testing
import KhaytTestWidth

/// No more tests are in flight at once than the bound allows.
///
/// The bound, and what happened without one, are in
/// `Tests/KhaytTestWidth/width.c`: every test started at once, each holding a
/// 20 MB engine while it waited for the main thread, 1,851 engines and 33 GB
/// at the worst on a 32 GB Mac.
///
/// ── IT COUNTS, IT DOES NOT ASK ────────────────────────────────────────────
///
/// The bound is handed to Swift Testing in an environment variable whose
/// name begins "experimental". Checking that the variable is set would go on
/// passing on the day a toolchain stops reading it, which is the day the
/// engines pile up again. So the cases below count themselves: each says it
/// has started, waits, and says it has finished, and there are three times
/// as many of them as may be in flight. Unbounded, they all start together.
///
/// The count is shared by the cases on purpose: it is the thing measured.
struct TestsInFlightAreBoundedTests {

    /// How many of the cases below are running at this moment, and the most
    /// that ever were.
    final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var now = 0
        private var worst = 0
        func started() { lock.lock(); now += 1; worst = max(worst, now); lock.unlock() }
        func finished() { lock.lock(); now -= 1; lock.unlock() }
        var most: Int { lock.lock(); defer { lock.unlock() }; return worst }
    }

    static let count = Count()
    static let bound = Int(khayt_tests_in_flight_at_most())
    /// Three times the bound, so an unbounded run is three times over it.
    static let cases = Array(0..<max(12, bound * 3))

    @Test("no more tests are in flight at once than the bound allows", arguments: cases)
    func inFlightTogether(_ number: Int) async throws {
        try #require(Self.bound > 0, "no bound was set when this test bundle loaded (width.c)")
        Self.count.started()
        defer { Self.count.finished() }
        // Long enough that cases started together are still together.
        try await Task.sleep(for: .milliseconds(40))
        let most = Self.count.most
        #expect(most <= Self.bound, """
            \(most) of these cases were in flight at once and the bound is \(Self.bound): \
            Swift Testing is no longer reading it, and every test is holding its engine at once again
            """)
    }
}
