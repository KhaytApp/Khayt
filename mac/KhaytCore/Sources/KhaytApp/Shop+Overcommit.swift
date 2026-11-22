import Foundation
import KhaytCore

/// SPOOLS A NEW JOB WOULD PROMISE MORE THAN THEY HOLD.
///
/// The desktop asks before saving a job whose parts, with what the open jobs
/// already reserve, come to more than a spool has on it — "Spool PLA needs
/// 300g but only 120g available after existing reservations. Save anyway?".
/// The Mac took the job without a word. Same question, same sums:
/// `KhaytReorder.overcommitWarnings` through `KhaytEngine.overcommit`.
extension Shop {
    /// What the warning would say, one sentence per spool; empty when nothing
    /// is over-committed, on the sample book, or when the book cannot be read
    /// (a check that cannot run must not stop a job being taken).
    func overcommitWarnings(for parts: [NewJobSheet.Draft]) async -> [String] {
        guard let build = source.build, let engine else { return [] }
        guard let root = try? StoreReader(build: build).raw else { return [] }
        let rows = Self.partRows(parts, spools: spools, unnamed: "")
        let found = (try? await engine.overcommit(
            parts: rows, orders: Self.rows(root, "printLog"),
            spools: Self.rows(root, "inventory"))) ?? []
        return found.map { Self.overcommitSentence($0, words: words) }
    }

    /// The desktop's sentence, rounded to the gram as it rounds.
    static func overcommitSentence(_ w: KhaytEngine.Overcommit, words: Words) -> String {
        words.callIt("inv.overcommit_confirm", [
            "name": .string(w.spoolName),
            "needed": .number(w.needed.rounded()),
            "available": .number(w.available.rounded()),
        ])
    }
}
