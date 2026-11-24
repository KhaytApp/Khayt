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
    /// - `utcOffsetMinutes`: whose day that is, as a fixed offset from UTC.
    ///
    /// WHOSE DAY. A real run's `at` is a full UTC timestamp, and with no
    /// offset the rule takes its first ten characters: the UTC day, which in
    /// Riyadh is yesterday until 03:00. Two ways to count by the shop's day:
    ///   - pick the runs yourself by the book's calendar and pass NO dates.
    ///     This is what the Mac's Machine profit and the phone do, and it is
    ///     the right one for a calendar whose offset changes through the year.
    ///   - pass `utcOffsetMinutes`, for a zone with one offset. The rule is
    ///     then handed a `dayOf` (its own hook, from the Windows/Linux app's
    ///     #2702); a bundled rule from before that hook ignores it and slices
    ///     as it always did.
    /// A bare `YYYY-MM-DD` is kept as written either way.
    public func successRates(orders: [JSONValue], machines: [JSONValue],
                             from: String? = nil, to: String? = nil, utcOffsetMinutes: Int? = nil) throws -> [SuccessRow] {
        try runtime.call2("""
            (function (orders, machines, from, to, offset) {
              var input = { orders: orders, machines: machines, from: from, to: to };
              if (typeof offset === 'number' && isFinite(offset)) {
                input.dayOf = function (at) {
                  var s = at == null ? '' : String(at);
                  if (/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(s)) return s;
                  var ms = typeof at === 'number' ? at : Date.parse(s);
                  if (typeof ms !== 'number' || !isFinite(ms)) return '';
                  return new Date(ms + offset * 60000).toISOString().slice(0, 10);
                };
              }
              return globalThis.KhaytPrinterSuccess.successRates(input);
            })(ARG0, ARG1, ARG2, ARG3, ARG4)
            """, [.array(orders), .array(machines), from.map(JSONValue.string) ?? .null, to.map(JSONValue.string) ?? .null,
                  utcOffsetMinutes.map { .number(Double($0)) } ?? .null],
            as: [SuccessRow].self)
    }

    /// How many decided runs a printer needs before its rate is shown
    /// ("Not enough prints yet: 3 of 5 needed").
    public func successRunsNeeded() throws -> Int {
        try runtime.call2("globalThis.KhaytPrinterSuccess.MIN_RUNS", [], as: Int.self)
    }
}
