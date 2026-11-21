import Foundation

/// What each printer needs from a person: its problems (C3,
/// `lib/printer-problems.js`) and why it is waiting at the machine (C4,
/// `lib/waiting-at-machine.js`). Worked out on the Mac and handed to the
/// phone and the cloud as they are, so no two apps can disagree.
extension KhaytEngine {

    public struct PrinterNeeds: Decodable, Sendable, Equatable {
        /// `{ code, severity, action, source, head?, message?, ref? }`, worst first.
        public let problems: [JSONValue]
        /// `{ reason, since, head? }`, most urgent first.
        public let waiting: [JSONValue]
        public init(problems: [JSONValue] = [], waiting: [JSONValue] = []) {
            self.problems = problems; self.waiting = waiting
        }
        public static let none = PrinterNeeds()
    }

    /// Extra Moonraker objects worth asking a printer for when it has them: a
    /// Snapmaker U1's exceptions and power-loss flag (`moonraker-problems`).
    /// Only names from this list are ever added to a query, and only when the
    /// printer's own `/printer/objects/list` names them.
    public static let moonrakerProblemObjects = ["exception_manager", "power_loss_check"]

    /// Which of `moonrakerProblemObjects` a printer has, from its objects list
    /// reply. Exact names only.
    public static func moonrakerProblemObjects(in listReply: [String: JSONValue]) -> [String] {
        guard case .object(let result)? = listReply["result"], case .array(let objects)? = result["objects"] else { return [] }
        let have = Set(objects.compactMap { v -> String? in if case .string(let s) = v { return s }; return nil })
        return moonrakerProblemObjects.filter(have.contains)
    }

    /// machine id → what it needs, for every machine Khayt polls.
    ///
    /// - `cache`: the poll cache (`PrinterWatch.statusCache`): each entry's
    ///   `state`, `message` and `error`.
    /// - `polled`: problems a poll already worked out, by machine (Moonraker).
    ///   A machine not in it is read from its state word; a Bambu's faults are
    ///   its poll's to give, so without them it has none here.
    /// - `completions`: the persisted poll completions (`printerCompletions`).
    /// - `orders`: the book's jobs, for the last one finished on each machine.
    ///
    /// A printer that is not answering has no live problems: only what is
    /// stored can still say it waits.
    public func printerNeeds(machines: [JSONValue], cache: [String: JSONValue], polled: [String: [JSONValue]],
                             completions: JSONValue?, orders: [JSONValue]) throws -> [String: PrinterNeeds] {
        try runtime.call2("""
            (function (machines, cache, polled, saved, orders) {
              var PP = globalThis.KhaytPrinterProblems, W = globalThis.KhaytWaitingAtMachine, out = {};
              var lastDone = {};
              (orders || []).forEach(function (o) {
                if (!o || !o.machineId || !o.completedAt) return;
                var at = Date.parse(String(o.completedAt));
                if (isFinite(at) && !(lastDone[o.machineId] >= at)) lastDone[o.machineId] = at;
              });
              (machines || []).forEach(function (m) {
                if (!m || !m.id) return;
                var type = m.printerApi && m.printerApi.type;
                if (!type || type === 'none') return;
                var entry = cache ? cache[m.id] : undefined;
                var answering = !!(entry && !entry.error);
                var problems = [];
                if (answering) {
                  if (Array.isArray(polled && polled[m.id])) problems = polled[m.id];
                  else if (String(type).toLowerCase() !== 'bambu') problems = PP.problemsFor(type, { state: entry.state, message: entry.message });
                }
                var kept = saved && saved[m.id];
                var list = Array.isArray(kept) ? kept : (kept && Array.isArray(kept.completions) ? kept.completions : []);
                var waiting = W.waiting(m, { completions: list, lastFinishedAt: lastDone[m.id], live: answering ? entry : undefined, problems: problems });
                out[m.id] = { problems: problems, waiting: waiting };
              });
              return out;
            })(ARG0, ARG1, ARG2, ARG3, ARG4)
            """, [.array(machines), .object(cache), .object(polled.mapValues(JSONValue.array)), completions ?? .null, .array(orders)],
            as: [String: PrinterNeeds].self)
    }

    /// The fixtures' own calls, for the parity tests.
    public func problemsFor(type: String, report: JSONValue) throws -> JSONValue {
        try runtime.call2("KhaytPrinterProblems.problemsFor(ARG0, ARG1)", [.string(type), report], as: JSONValue.self)
    }

    public func waitingAtMachine(machine: JSONValue, opts: JSONValue) throws -> JSONValue {
        try runtime.call2("KhaytWaitingAtMachine.waiting(ARG0, ARG1 || {})", [machine, opts], as: JSONValue.self)
    }

    /// What to write on a job for a finished print's filament per head
    /// (`perHeadActuals` then `perHeadPatch`), or `.null` when the printer's
    /// history row says nothing per head or the job already holds a split.
    public func perHeadPatch(order: JSONValue, historyJob: JSONValue) throws -> JSONValue {
        try runtime.call2("""
            (function (order, job) {
              var A = globalThis.KhaytPrinterActuals;
              var split = A.perHeadActuals(job, {});
              return split ? A.perHeadPatch(order, split) : null;
            })(ARG0, ARG1)
            """, [order, historyJob], as: JSONValue.self)
    }

    public func rfidTrays(_ filamentDetect: JSONValue) throws -> JSONValue {
        try runtime.call2("KhaytRfidTray.trays(ARG0)", [filamentDetect], as: JSONValue.self)
    }
}
