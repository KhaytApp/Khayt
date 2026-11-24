import Foundation
import KhaytCore

extension Shop {
    /// The shop's own day a run was sent on, or nil for a run with no usable
    /// date. `at` is a full timestamp (UTC) on a real run, a bare day in old
    /// records, and milliseconds in some.
    nonisolated static func runDay(_ at: JSONValue?) -> String? {
        switch at {
        case .string(let text)?:
            let day = Calendar.localDay(ofInstant: text)
            return day.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}/) != nil ? day : nil
        case .number(let ms)? where ms.isFinite && ms > 0:
            return Calendar.book.dayString(Date(timeIntervalSince1970: ms / 1000))
        default: return nil
        }
    }

    /// Every job's print runs sent on a day `keep` accepts, each job reduced
    /// to its runs: what `KhaytEngine.successRates` is asked with when the
    /// range is the shop's days, not UTC's. A deleted job's runs are nobody's.
    nonisolated static func runsSent(_ orders: [JSONValue], keep: (String) -> Bool) -> [JSONValue] {
        orders.compactMap { row -> JSONValue? in
            guard case .object(let o) = row, o["deleted"] != .bool(true), case .array(let runs)? = o["printRuns"] else { return nil }
            let kept = runs.filter { run in
                guard case .object(let r) = run, let day = runDay(r["at"]) else { return false }
                return keep(day)
            }
            return kept.isEmpty ? nil : .object(["printRuns": .array(kept)])
        }
    }
}
