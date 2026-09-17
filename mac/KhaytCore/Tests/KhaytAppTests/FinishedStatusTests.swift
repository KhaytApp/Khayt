import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The two spellings of finished.
///
/// Khayt wrote `delivered` before it wrote `completed` with a `deliveredAt`
/// beside it, and both are still in shops' books — thirteen of them in the
/// sample. "Is this job finished" is therefore a two-value test, and it was
/// written out by hand in at least eight modules.
///
/// Written out by hand is written out wrongly eventually, and it was: the
/// machine P&L filtered `status == "completed"` alone, here and in the other
/// app both, so every delivered job was missing from what a printer had
/// earned. Nothing threw; the figures were just quietly of a subset.
@MainActor
struct FinishedStatusTests {

    @Test("the Swift list is the rule's own list, not a second opinion")
    func matchesTheRule() async throws {
        let engine = try KhaytEngine()
        let fromRule = Set(try await engine.finishedStatuses())
        #expect(fromRule == Shop.finishedStatuses,
                Comment(rawValue: "rule says \(fromRule.sorted()), this app says \(Shop.finishedStatuses.sorted())"))
        #expect(fromRule.contains("delivered") && fromRule.contains("completed"))
    }

    @Test("the sample book's delivered jobs reach the machine figures")
    func deliveredJobsCount() async throws {
        let shop = Shop()
        await shop.load(.sample)
        var delivered = 0, completed = 0
        for row in shop.orderRows {
            guard case .object(let o) = row, case .string(let status)? = o["status"] else { continue }
            if status == "delivered" { delivered += 1 }
            if status == "completed" { completed += 1 }
        }
        // The sample is built to span this on purpose; without delivered rows
        // the test below proves nothing.
        #expect(delivered > 0, "the sample book no longer has a legacy delivered job")
        #expect(completed > 0)

        let picked = await shop.completedInPeriod().orders
        var seen: Set<String> = []
        for row in picked {
            guard case .object(let o) = row, case .string(let status)? = o["status"] else { continue }
            seen.insert(status)
        }
        // Whatever the period holds, it must never hold ONLY completed while
        // the book has delivered jobs in the same range — that was the bug.
        #expect(seen.isSubset(of: Shop.finishedStatuses),
                Comment(rawValue: "an unfinished job reached the machine figures: \(seen.sorted())"))
    }

    /// Every Swift file the app is built from.
    ///
    /// The rule is one line and easy to agree with, and that is the problem:
    /// it is just as easy to write `status == "completed"` beside a comment
    /// saying "finished" and never notice. That is what the Reports screen's
    /// monthly target did — it filtered `completed` alone while the quarters it
    /// was drawn beside counted both spellings through `lib/pnl-report.js`, so
    /// the target and the actual were two answers pretending to be one.
    ///
    /// Reading did not catch it. This does.
    static func appSources() throws -> [(name: String, text: String)] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        let fm = FileManager.default
        var out: [(String, String)] = []
        guard let walk = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return out }
        for case let url as URL in walk where url.pathExtension == "swift" {
            out.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return out
    }

    /// Sites that mean the modern spelling and only the modern spelling.
    ///
    /// Each is matched by a distinctive piece of the line, and each needs a
    /// sentence. If the sentence is hard to write, the site is a bug.
    static let allowed: [(snippet: String, why: String)] = [
        ("if order.status == \"completed\", order.deliveredAt != nil { return .delivered }",
         "This is what DECIDES a job is delivered: a modern book says so with a date beside completed."),
        ("state == \"completed\" { total += 1 }",
         "A cache key. It has to change when the answer would, which moving a job in or out of completed does."),
        ("case .string(let state)? = job[\"status\"], state == \"completed\",",
         "The maintenance card's cache key, same reason: the real meter is KhaytMaintenance.hoursMeter."),
    ]

    @Test("no screen decides on its own what finished means")
    func noHandWrittenFinishedCheck() throws {
        var offences: [String] = []
        for (name, text) in try Self.appSources() {
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let l = String(line)
                guard l.contains("\"completed\"") else { continue }
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("//") || t.hasPrefix("///") || t.hasPrefix("*") { continue }
                // The line names both spellings, so it already knows.
                if l.contains("\"delivered\"") { continue }
                // A status being WRITTEN, or a cache key, asks nothing.
                guard l.contains("== \"completed\"") else { continue }
                if Self.allowed.contains(where: { l.contains($0.snippet) }) { continue }
                offences.append("\(name):\(i + 1)  \(t.prefix(90))")
            }
        }
        #expect(offences.isEmpty, Comment(rawValue:
            "use Shop.finishedStatuses.contains(status) — a job finished in an older book "
            + "says \"delivered\":\n" + offences.joined(separator: "\n")))
    }

    @Test("every allowed exception still exists, so the list cannot rot")
    func allowedListStaysHonest() throws {
        let all = try Self.appSources().map(\.text).joined(separator: "\n")
        for entry in Self.allowed {
            #expect(all.contains(entry.snippet),
                    Comment(rawValue: "delete this exception, nothing matches it: \(entry.snippet)"))
            #expect(entry.why.count > 20, Comment(rawValue: entry.snippet))
        }
    }

    @Test("an unfinished job is not finished, whatever else it carries")
    func unfinishedStaysOut() {
        for status in ["printing", "quote", "pending", "post", "qc", "on_hold", "cancelled", ""] {
            #expect(!Shop.finishedStatuses.contains(status), Comment(rawValue: status))
        }
        // `cancelled` especially: it has an end date and is not earnings.
        #expect(!Shop.finishedStatuses.contains("cancelled"))
    }
}
