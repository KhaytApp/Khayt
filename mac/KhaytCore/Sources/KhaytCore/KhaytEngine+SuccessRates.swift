import Foundation

/// How often each printer's prints come out right
/// (`lib/printer-success.js successRates`, the Windows/Linux app's P6).
///
/// Counted from ONE result per run (`lib/run-result.js`), across every job's
/// `printRuns`: a reprint is its own run. A cancelled run is counted and
/// shown but left out of the rate, and a run with no result yet is `unknown`,
/// never a success. Pure: it reads the book it is handed and nothing else.
///
/// In KhaytCore, not KhaytApp, because the iPhone works the rate out for
/// itself from the book an owner's or manager's phone holds (iPhone frame 6,
/// "Success rate"): there is no second copy of this rule in Swift.
extension KhaytEngine {

    /// One printer's count.
    public struct SuccessRow: Decodable, Sendable, Equatable, Identifiable {
        public let machineId: String
        public let finished: Int
        public let failed: Int
        /// Counted and shown, not in the rate: a print the shop no longer
        /// needed is not the printer failing.
        public let cancelled: Int
        /// Runs with no result yet.
        public let unknown: Int
        /// finished / (finished + failed), to three places; nil with no decided runs.
        public let rate: Double?
        /// False below `successRunsNeeded()` decided runs: one failure in two
        /// prints must not read as a 50% printer.
        public let enough: Bool
        public var id: String { machineId }
        /// The runs the rate is made of.
        public var decided: Int { finished + failed }

        public init(machineId: String, finished: Int, failed: Int, cancelled: Int, unknown: Int, rate: Double?, enough: Bool) {
            self.machineId = machineId; self.finished = finished; self.failed = failed
            self.cancelled = cancelled; self.unknown = unknown; self.rate = rate; self.enough = enough
        }
    }

    /// Every machine's count, WORST RATE FIRST, a printer with no decided
    /// runs last. A machine in `machines` with no runs still has a row.
    ///
    /// - `from`, `to`: `YYYY-MM-DD` on the day a run was sent, inclusive; nil
    ///   for no bound. A run with no date is left out of a bounded count.
    public func successRates(orders: [JSONValue], machines: [JSONValue],
                             from: String? = nil, to: String? = nil) throws -> [SuccessRow] {
        try runtime.call2("globalThis.KhaytPrinterSuccess.successRates({ orders: ARG0, machines: ARG1, from: ARG2, to: ARG3 })",
                          [.array(orders), .array(machines), from.map(JSONValue.string) ?? .null, to.map(JSONValue.string) ?? .null],
                          as: [SuccessRow].self)
    }

    /// How many decided runs a printer needs before its rate is shown
    /// ("Not enough prints yet: 3 of 5 needed").
    public func successRunsNeeded() throws -> Int {
        try runtime.call2("globalThis.KhaytPrinterSuccess.MIN_RUNS", [], as: Int.self)
    }
}
