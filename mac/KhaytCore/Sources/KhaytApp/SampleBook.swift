import Foundation
import KhaytCore

/// The sample book's dates, moved so they sit where they sat the day it was written.
///
/// ── WHY THIS EXISTS ───────────────────────────────────────────────────────
///
/// `sample-shop.json` is a fixed file and the calendar is not. Every date in it
/// ages a day each day, so the shop it describes drifts: a queue that straddled
/// today becomes a queue entirely in the past, and the screens that draw the
/// difference between the two — the attention panel, the projection, "at risk"
/// — quietly lose their case. It has happened twice, and both times the failure
/// landed on a green branch overnight, in somebody else's pull request, about
/// something they had not touched.
///
/// The chore that was offered instead — move the due dates forward by hand —
/// buys about ten days. That is the width of the window the "at risk" case has
/// to live in: later than today plus the warning, earlier than the day the
/// queue reaches it, and the queue is nineteen days long. No arrangement of
/// fixed dates is worth more than that, which is why this is the fix and the
/// chore was not.
///
/// ── WHAT IT DOES ──────────────────────────────────────────────────────────
///
/// The book carries the day it was written for. Loading it moves EVERY date by
/// the whole number of days between that day and today, so a sample book opened
/// in 2030 describes the same shop, in the same week of its own life, that it
/// described the day it was written.
///
/// Moving everything rather than the queue alone is the point: shifting the due
/// dates on their own would leave jobs raised in 2026 and due in 2030, and a
/// shop exploring the sample would be reading a book that contradicts itself.
///
/// `lib/sample-data.js` — the demo data the other app merges in — has worked
/// this way since it was written: "Dates are relative to `opts.today` so the
/// demo always looks current." This is that rule, applied to the richer book
/// this app ships.
enum SampleBook {

    /// The day `sample-shop.json`'s dates were chosen for.
    ///
    /// It lives here rather than in the file because the file is a store book
    /// and every top-level key in one is a collection the other app also has —
    /// `StoreKeysAreTheOtherAppsTests` says so, and a key added only to carry
    /// this would be the first exception to that.
    ///
    /// Two places that must agree is the usual objection, and the usual answer
    /// applies: `SampleBookAgesTests` reads the book AT this anchor and fails
    /// if the shop it describes is not the one the screens are built against.
    /// Moving the dates without moving this is caught on the next run rather
    /// than noticed in a screenshot.
    static let anchorDay = "2026-09-20"

    static var anchor: Date? { DateFormatter.shopDay.date(from: anchorDay) }

    /// Whole days from the anchor to `today`, in the shop's own calendar.
    ///
    /// Both ends go through `startOfDay`, so a run at 23:00 and a run at 01:00
    /// on the same day give the same answer — and so do two machines an
    /// ordinary timezone apart, which is how the last attempt at keeping this
    /// alive failed CI by exactly one day.
    static func drift(from anchor: Date, to today: Date) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: anchor),
                                  to: cal.startOfDay(for: today)).day ?? 0
    }

    /// The whole book, with every date moved to sit where it sat on the anchor.
    static func rebased(_ root: [String: JSONValue], to today: Date) -> [String: JSONValue] {
        guard let anchor else { return root }
        let days = drift(from: anchor, to: today)
        guard days != 0 else { return root }
        guard case .object(let moved) = shift(.object(root), by: days) else { return root }
        return moved
    }

    /// Every string in the tree, offered to `shiftingDay`.
    ///
    /// The walk is over VALUES and not keys: a key is a field name, and a field
    /// named like a date is still a field name.
    private static func shift(_ value: JSONValue, by days: Int) -> JSONValue {
        switch value {
        case .string(let s):  return .string(shiftingDay(s, by: days))
        case .array(let a):   return .array(a.map { shift($0, by: days) })
        case .object(let o):  return .object(o.mapValues { shift($0, by: days) })
        case .number, .bool, .null: return value
        }
    }

    /// A string that IS a day, or a timestamp that starts with one, moved.
    ///
    /// Anything else comes back exactly as it went in. The two shapes the store
    /// holds are `2026-08-08` and `2026-08-08T09:00:00.000Z`, and the test for
    /// the second is that the eleventh character is a `T` — not that the string
    /// merely contains ten characters that parse, which would move the front of
    /// a version string or an id that happened to start with digits.
    static func shiftingDay(_ s: String, by days: Int) -> String {
        guard s.count >= 10 else { return s }
        let head = String(s.prefix(10))
        let tail = String(s.dropFirst(10))
        guard tail.isEmpty || tail.hasPrefix("T") else { return s }
        guard let day = DateFormatter.shopDay.date(from: head),
              // And the formatter agreed it was that day rather than repairing
              // it: `31-02` parses to 3 March in a lenient formatter, and a
              // book that quietly corrected its own dates would be a book that
              // disagreed with the file on disk.
              DateFormatter.shopDay.string(from: day) == head,
              let moved = Calendar(identifier: .gregorian)
                  .date(byAdding: .day, value: days, to: day)
        else { return s }
        return DateFormatter.shopDay.string(from: moved) + tail
    }
}
