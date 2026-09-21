import Foundation
import Testing
@testable import KhaytApp

/// A fixed clock against a book that moves is a test with a fuse in it.
///
/// ── WHAT HAPPENED ─────────────────────────────────────────────────────────
///
/// The sample book is rebased to `Date()` every time it is read, so that a
/// shop opening it never finds a queue entirely in the past. Two tests asked
/// the consumables rule what the shelf looked like *at a literal date*, and a
/// literal is fixed while the book slides forward a day every day.
///
/// They passed for as long as the gap stayed inside a threshold. On 22 Sep
/// 2026 it did not: a consumable crossed from "above its minimum but running
/// out inside the lead time" into "low", the category emptied, and both tests
/// failed **on `main`** — having passed on that same commit the evening
/// before. Five open pull requests went red at once, each looking as though it
/// had broken something.
///
/// Nothing is wrong with pinning a clock. It is pinning a clock over data that
/// MOVES that decays — so this asks the question a reviewer would: does this
/// file pin a date, and does it also read the rebased book?
///
/// ── WHY AN ALLOW-LIST AND NOT A BAN ───────────────────────────────────────
///
/// A file can legitimately do both, and one does. `CampaignTests` pins
/// `2026-09-19` and builds its own orders dated `2026-09-18` and `2026-01-01`
/// — both sides literal, a self-contained fixture that cannot drift. It also
/// loads the sample book, in *different* tests. A rule that just banned the
/// combination would fail on it forever and be switched off.
///
/// So: named, with the reason. A new file appearing here is a prompt to work
/// out which kind it is, not an automatic fault.
@MainActor
struct SampleClockTests {

    /// Files that pin a date AND touch the sample book, each checked by hand.
    static let allowed: [String: String] = [
        "CampaignTests.swift":
            "pins 2026-09-19 against orders it writes itself at 2026-09-18 and "
            + "2026-01-01 — both sides literal, so nothing drifts. Its sample-book "
            + "tests are separate and use Date().",
    ]

    @Test("no test pins a clock over the sample book, which moves under it")
    func noFixedClockOverAMovingBook() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir,
                     includingPropertiesForKeys: nil)) ?? []
        #expect(!files.isEmpty, "no tests were read — this would pass vacuously")

        var offenders: [String] = []
        var checked = 0
        for url in files where url.pathExtension == "swift"
            && url.lastPathComponent != "SampleClockTests.swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            checked += 1
            // A literal date handed to something, and the rebased book in the
            // same file. `load(.sample)` and `SampleBook.rebased` are the two
            // ways to get a book that moves.
            let pinsAClock = text.contains("date(from: \"20")
            let readsTheMovingBook = text.contains("load(.sample)")
                || text.contains("SampleBook.rebased")
            guard pinsAClock && readsTheMovingBook else { continue }
            if Self.allowed[url.lastPathComponent] == nil {
                offenders.append(url.lastPathComponent)
            }
        }
        #expect(checked > 100, "hardly any tests were scanned — this proves nothing")
        #expect(offenders.isEmpty, Comment(rawValue:
            "these pin a date and also read the sample book, which is rebased to "
            + "Date() and slides under them: \(offenders). Use `Date()` for the "
            + "clock, or add the file to `allowed` with the reason it cannot drift."))
    }

    /// The allow-list has to name files that exist, or it is a list of excuses
    /// for tests that were deleted.
    @Test("every allowed file is still there and still both things")
    func theAllowListIsHonest() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for (name, why) in Self.allowed {
            let url = dir.appending(path: name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                Issue.record(Comment(rawValue: "`\(name)` is allow-listed and gone"))
                continue
            }
            #expect(!why.isEmpty, "\(name) is allowed with no reason given")
            #expect(text.contains("date(from: \"20"),
                    Comment(rawValue: "`\(name)` no longer pins a clock — take it off the list"))
        }
    }
}
