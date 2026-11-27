import Foundation
import KhaytCore

/// How often a printer's prints come out right (signed frame 6, "Success rate
/// on the machine page"; Turki, Nov 22). The count is the shared rule's
/// (`lib/printer-success.js`, through `KhaytEngine.successRates`, Mac #2696),
/// over the book this phone holds: one result per run, cancelled runs counted
/// and shown but left out of the rate, runs with no result never a success.
struct MachineSuccess: Equatable, Sendable {
    let finished: Int
    let failed: Int
    let cancelled: Int
    /// finished / (finished + failed); nil with no decided runs.
    let rate: Double?
    /// False below `needed` decided runs: one failure in two prints is not a 50% printer.
    let enough: Bool
    let needed: Int
    /// The whole percentage to show, by the SHARED rule
    /// (`KhaytPrinterSuccess.successPercent`, through the engine): never 100
    /// unless every decided run succeeded, never 0 unless none did. Nil with
    /// no rate. The phone does no rounding of its own.
    let whole: Int?

    static let days = 30

    init(finished: Int, failed: Int, cancelled: Int, rate: Double?, enough: Bool, needed: Int, whole: Int?) {
        self.finished = finished; self.failed = failed; self.cancelled = cancelled
        self.rate = rate; self.enough = enough; self.needed = needed; self.whole = whole
    }

    init(_ row: KhaytEngine.SuccessRow, needed: Int, whole: Int?) {
        self.init(finished: row.finished, failed: row.failed, cancelled: row.cancelled, rate: row.rate,
                  enough: row.enough, needed: needed, whole: whole)
    }

    var decided: Int { finished + failed }

    /// "92%", or nil while there are too few prints to say (the frame's dash).
    var percent: String? {
        guard enough, let whole else { return nil }
        return "\(whole)%"
    }

    /// "23 finished, 2 failed · 3 cancelled not counted", or
    /// "Not enough prints yet: 3 of 5 needed".
    var detail: String {
        guard enough else { return L10n.format("success.not_enough", decided, needed) }
        var parts = [L10n.format("success.counts", finished, failed)]
        if cancelled > 0 { parts.append(L10n.format("success.cancelled", cancelled)) }
        return parts.joined(separator: " · ")
    }

    /// The window the rate is counted over: today and the 29 days before it,
    /// as the shop's own days.
    static func window(now: Date, zone: TimeZone = .current) -> (from: String, to: String) {
        (BookWriter.localDay(now.addingTimeInterval(-Double(days - 1) * 86_400), in: zone), BookWriter.localDay(now, in: zone))
    }

    /// The shop's day a run was sent on. The apps write `at` as a full UTC
    /// timestamp (`2026-11-25T01:00:00.000Z`), and slicing that gives the UTC
    /// day: an evening print in a shop west of UTC landed on tomorrow and fell
    /// out of the window, and an early one east of it landed on yesterday
    /// (the desktop met this in `renderer/analytics.js`; review of #2698).
    /// A bare `YYYY-MM-DD` is already a day.
    static func localDay(ofRun at: String, zone: TimeZone = .current) -> String? {
        if at.count == 10 { return at }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = withFraction.date(from: at) ?? ISO8601DateFormatter().date(from: at) else { return nil }
        return BookWriter.localDay(date, in: zone)
    }

    /// (The engine's `successRates(from:to:calendar:)` does this itself once
    /// #2702's rule is in the bundle; until then it still slices the UTC day,
    /// so the phone keeps picking the runs by the shop's day, as the Mac's
    /// Machine profit does, and asks with no dates.)
    ///
    /// One machine's runs inside the window, as the jobs the rule counts:
    /// only jobs with runs on this machine, each with only those runs. The
    /// window is applied HERE, on the shop's day, so the rule is asked with no
    /// dates of its own; and only what is counted crosses into JavaScript.
    static func orders(_ printLog: [JSONValue], machineId: String, from: String, to: String,
                       zone: TimeZone = .current) -> [JSONValue] {
        printLog.compactMap { job -> JSONValue? in
            guard case .object(var o) = job, case .array(let runs)? = o["printRuns"] else { return nil }
            let kept = runs.filter { run in
                guard case .object(let r) = run, r["machineId"] == .string(machineId), case .string(let at)? = r["at"],
                      let day = localDay(ofRun: at, zone: zone) else { return false }
                return day >= from && day <= to
            }
            guard !kept.isEmpty else { return nil }
            o = ["id": o["id"] ?? .null, "deleted": o["deleted"] ?? .null, "printRuns": .array(kept)]
            return .object(o)
        }
    }
}

extension BookReader {
    /// One machine's success over the last 30 days, from the book.
    func machineSuccess(machineId: String, now: Date = Date()) async throws -> MachineSuccess? {
        let store = try wholeBook()
        func list(_ key: String) -> [JSONValue] {
            if case .array(let rows)? = store[key] { return rows }
            return []
        }
        let engine = try sharedEngine()
        let window = MachineSuccess.window(now: now)
        guard list("machines").contains(where: { if case .object(let m) = $0 { return m["id"] == .string(machineId) } else { return false } })
        else { return nil }
        let counted = MachineSuccess.orders(list("printLog"), machineId: machineId, from: window.from, to: window.to)
        let rows = try await engine.successRates(orders: counted, machines: [.object(["id": .string(machineId)])])
        // A printer with no runs at all in the window gets no card: a machine
        // Khayt never sends to would otherwise say "0 of 5 needed" for ever.
        guard let row = rows.first(where: { $0.machineId == machineId }),
              row.finished + row.failed + row.cancelled + row.unknown > 0 else { return nil }
        return MachineSuccess(row, needed: try await engine.successRunsNeeded(), whole: try await engine.successPercent(row.rate))
    }
}

extension KhaytAPIClient {
    /// Nil with no book (a floor phone, the desktop): the rate is counted
    /// from the book, and a phone without one shows no card.
    func machineSuccess(machineId: String, now: Date = Date()) async -> MachineSuccess? {
        guard let book, book.exists, let reader else { return nil }
        return try? await reader.machineSuccess(machineId: machineId, now: now)
    }
}
