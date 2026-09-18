import Foundation

/// What customers have said about the work, month by month.
///
/// A finished job can carry `survey.rating`, one to five. The Reports screen
/// draws the last six months of that as a line and captions it with a count and
/// an average.
///
/// ── TWO THINGS THE RULE CARRIES A FIX FOR ─────────────────────────────────
///
/// The caption used to be computed from a DIFFERENT SET of jobs than the line:
/// the line covered six months, the count and average covered every rating the
/// shop had ever collected. A shop two years in, whose work has got better, saw
/// six dots at 4.8 under the words "Avg 3.2 / 5" — a figure that contradicts
/// every point above it. The caption describes the window now.
///
/// And a rated job was taken only if it carried `completedAt`. A book written
/// before that stamp existed, an imported one, or a job that went straight to
/// `delivered` has a rating and no `completedAt` — so a rating a customer
/// actually gave was dropped. It falls back to the job's own date.
public enum RatingTrend {

    /// How many ratings there must be before a trend is worth drawing.
    public static let minResponses = 3
    public static let minRating = 1.0
    public static let maxRating = 5.0

    /// The month a rated job belongs to, as `YYYY-MM`.
    ///
    /// A TIMESTAMP is converted through the reader's own clock, because that is
    /// the month the shop thinks the job finished in. A plain `YYYY-MM-DD` is
    /// SLICED rather than parsed: parsing it would put it at midnight UTC and
    /// move it a day for half the world.
    public static func monthOf(_ order: JSONValue?) -> String {
        var o: [String: JSONValue] = [:]
        if case .object(let fields)? = order { o = fields }
        let stamp = o["completedAt"]
        if JSSemantics.truthy(stamp), JSSemantics.text(stamp).utf16.count > 10,
           let ms = JSDate.parse(JSSemantics.text(stamp)), ms.isFinite {
            let parts = JSDate.localYearMonth(ms: ms)
            // `getMonth()` is ZERO-BASED, which is why the original adds one.
            let month = parts.month + 1
            return "\(parts.year)-" + (month < 10 ? "0\(month)" : "\(month)")
        }
        let fallback = JSSemantics.truthy(stamp)
            ? JSSemantics.text(stamp)
            : (JSSemantics.truthy(o["date"]) ? JSSemantics.text(o["date"]) : "")
        guard fallback.range(of: "^[0-9]{4}-[0-9]{2}", options: .regularExpression) != nil
        else { return "" }
        return String(decoding: Array(fallback.utf16.prefix(7)), as: UTF16.self)
    }

    /// The rating on a job, or nil when it carries none.
    public static func ratingOf(_ order: JSONValue?) -> Double? {
        guard case .object(let o)? = order, case .object(let survey)? = o["survey"],
              let raw = survey["rating"], JSSemantics.truthy(raw) else { return nil }
        let n = JSSemantics.number(raw)
        guard n.isFinite, n >= minRating, n <= maxRating else { return nil }
        return n
    }

    public struct Point: Sendable, Equatable, Identifiable {
        public let month: String
        public let responses: Int
        /// Nil where that month had no responses, so the caller can leave a gap
        /// rather than draw a zero nobody gave.
        public let average: Double?
        public var id: String { month }
    }

    public struct Report: Sendable, Equatable {
        public let points: [Point]
        /// Over the MONTHS ASKED FOR, which is what the caption under the chart
        /// is describing.
        public let responses: Int
        public let average: Double?
        /// Every rating in the book, for a caller that wants to say so
        /// explicitly rather than by accident.
        public let allTimeResponses: Int
        public let enough: Bool
    }

    public static func trend(orders: [JSONValue], months: [String],
                             minResponses: Int = RatingTrend.minResponses) -> Report {
        var total: [String: Double] = [:], count: [String: Int] = [:]
        for key in months { total[key] = 0; count[key] = 0 }

        var allTime = 0
        for order in orders {
            guard let rating = ratingOf(order) else { continue }
            allTime += 1
            let key = monthOf(order)
            guard count[key] != nil else { continue }
            total[key]! += rating
            count[key]! += 1
        }

        var responses = 0, sum = 0.0
        let points = months.map { key -> Point in
            let n = count[key] ?? 0
            responses += n
            sum += total[key] ?? 0
            return Point(month: key, responses: n,
                         average: n > 0 ? (total[key] ?? 0) / Double(n) : nil)
        }

        return Report(points: points, responses: responses,
                      average: responses > 0 ? sum / Double(responses) : nil,
                      allTimeResponses: allTime,
                      enough: responses >= minResponses)
    }
}
