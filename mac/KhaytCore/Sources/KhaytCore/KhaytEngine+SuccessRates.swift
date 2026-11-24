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
    /// - `calendar`: WHOSE day that is. Pass the book's calendar
    ///   (`Calendar.book`), never the device's.
    ///
    /// WHOSE DAY. A real run's `at` is a full UTC timestamp, and left to
    /// itself the rule takes its first ten characters: the UTC day, which in
    /// Riyadh is yesterday until 03:00, and at a month's edge last month.
    /// JavaScript cannot be handed a Swift function and JavaScriptCore has no
    /// time zones to ask, so with a `calendar` the days are worked out HERE,
    /// one per run, and the rule is given them ready-made: its `dayOf` hook
    /// (the Windows/Linux app's #2702) becomes a lookup. That is exact for
    /// any zone, through daylight-saving changes too. A bare `YYYY-MM-DD` is
    /// kept as written; an `at` that cannot be read has no day. A bundled
    /// rule from before the hook ignores it and slices as it always did.
    public func successRates(orders: [JSONValue], machines: [JSONValue],
                             from: String? = nil, to: String? = nil, calendar: Calendar? = nil) throws -> [SuccessRow] {
        var days: JSONValue = .null
        if let calendar, from != nil || to != nil { days = .object(Self.runDays(orders, calendar: calendar)) }
        return try runtime.call2("""
            (function (orders, machines, from, to, days) {
              var input = { orders: orders, machines: machines, from: from, to: to };
              if (days && typeof days === 'object') {
                var has = Object.prototype.hasOwnProperty;
                input.dayOf = function (at) {
                  var key = typeof at === 'number' ? '#' + Math.round(at) : (at == null ? '' : String(at));
                  if (has.call(days, key)) return days[key];
                  return String(at == null ? '' : at).slice(0, 10);
                };
              }
              return globalThis.KhaytPrinterSuccess.successRates(input);
            })(ARG0, ARG1, ARG2, ARG3, ARG4)
            """, [.array(orders), .array(machines), from.map(JSONValue.string) ?? .null, to.map(JSONValue.string) ?? .null, days],
            as: [SuccessRow].self)
    }

    /// The day each run was sent, in `calendar`, keyed by the run's `at` as
    /// the rule will ask for it (a number as `#<milliseconds>`). "" for an
    /// `at` that is neither a bare day, a timestamp, nor milliseconds.
    static func runDays(_ orders: [JSONValue], calendar: Calendar) -> [String: JSONValue] {
        var days: [String: JSONValue] = [:]
        for order in orders {
            guard case .object(let o) = order, case .array(let runs)? = o["printRuns"] else { continue }
            for run in runs {
                guard case .object(let r) = run else { continue }
                switch r["at"] {
                case .string(let text)?:
                    guard days[text] == nil else { continue }
                    if text.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}/) != nil { days[text] = .string(text) }
                    else if let instant = Calendar.instant(text) { days[text] = .string(calendar.dayString(instant)) }
                    else { days[text] = .string("") }
                case .number(let ms)? where ms.isFinite:
                    let key = "#" + String(Int64(ms.rounded()))
                    days[key] = .string(ms > 0 ? calendar.dayString(Date(timeIntervalSince1970: ms / 1000)) : "")
                default: continue
                }
            }
        }
        return days
    }

    /// A rate as the whole per cent a person reads (95 for 0.95), by the
    /// rule's own `successPercent` (every app says it the same): rounded as
    /// usual, except that a rate under one never reads as 100 (199 of 200 is
    /// 99) and a rate over nothing never reads as 0 (1 of 200 is 1). Nil for
    /// no rate, or for anything that is not a number from 0 to 1: shown "—".
    public func successPercent(_ rate: Double?) throws -> Int? {
        guard let rate, rate.isFinite else { return nil }
        let said = try runtime.call2("""
            (function (rate) {
              var f = globalThis.KhaytPrinterSuccess.successPercent;
              if (typeof f === 'function') return f(rate);
              // The same rule, for a bundled copy from before the helper.
              if (typeof rate !== 'number' || !(rate >= 0 && rate <= 1)) return null;
              var p = Math.round(rate * 100);
              if (p >= 100 && rate < 1) return 99;
              if (p <= 0 && rate > 0) return 1;
              return p;
            })(ARG0)
            """, [.number(rate)], as: JSONValue.self)
        switch said {
        case .number(let n): return Int(n.rounded())
        case .string(let text): return Int(text.prefix { $0.isNumber })
        default: return nil
        }
    }

    /// How many decided runs a printer needs before its rate is shown
    /// ("Not enough prints yet: 3 of 5 needed").
    public func successRunsNeeded() throws -> Int {
        try runtime.call2("globalThis.KhaytPrinterSuccess.MIN_RUNS", [], as: Int.self)
    }
}
