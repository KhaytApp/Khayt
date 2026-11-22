import Foundation
import KhaytCore

/// What each head of a multi-head printer used on a job (U1, #2611
/// `perHeadPatch`): `order.actualHeads` as the Mac or the desktop wrote it,
/// once per print. The split is proportional to the slicer's weights, so no
/// head is measured on its own (`actualHeadsBasis: "proportional"`).
struct HeadFilament: Equatable, Sendable {
    struct Head: Equatable, Sendable, Identifiable {
        /// 0-based, as the printer numbers its extruders; shown as T1, T2, …
        let head: Int
        let grams: Double
        var id: Int { head }
    }
    let heads: [Head]
    let basis: String?
    var totalGrams: Double { heads.reduce(0) { $0 + $1.grams } }
}

extension KhaytAPIClient {
    func headFilament(orderId: String) -> HeadFilament? {
        guard let book, book.exists, let store = try? book.read() else { return nil }
        return Self.headFilament(in: store, orderId: orderId)
    }

    /// Pure, for the tests. Nil when the job has no split; a row without a
    /// whole head number or a finite, non-negative weight is skipped.
    nonisolated static func headFilament(in store: [String: JSONValue], orderId: String) -> HeadFilament? {
        guard case .array(let rows)? = store["printLog"] else { return nil }
        for row in rows {
            guard case .object(let job) = row, job["id"] == .string(orderId) else { continue }
            guard case .array(let list)? = job["actualHeads"] else { return nil }
            let heads: [HeadFilament.Head] = list.compactMap { item in
                guard case .object(let h) = item, case .number(let n)? = h["head"], n >= 0, n < 64, n == n.rounded(),
                      case .number(let g)? = h["grams"], g.isFinite, g >= 0 else { return nil }
                return HeadFilament.Head(head: Int(n), grams: g)
            }
            // One row per head (review of #2657): a duplicate keeps the first,
            // so ids stay unique and the list is at most 64 rows.
            var seen = Set<Int>()
            let unique = heads.filter { seen.insert($0.head).inserted }.sorted { $0.head < $1.head }
            guard !unique.isEmpty else { return nil }
            var basis: String?
            if case .string(let b)? = job["actualHeadsBasis"] { basis = b }
            return HeadFilament(heads: unique, basis: basis)
        }
        return nil
    }
}
