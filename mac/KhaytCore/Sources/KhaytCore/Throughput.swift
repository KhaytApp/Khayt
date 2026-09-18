import Foundation

/// When work actually finishes — a seven-by-twenty-four grid of finished jobs.
///
/// The point is not the total. It is the SHAPE: which hours a shop really
/// finishes in, and how much of its work lands on days it does not open —
/// either printers running unattended, or somebody coming in on their day off.
public enum Throughput {

    public static let finished: Set<String> = ["completed", "delivered"]

    public struct Day: Sendable, Equatable {
        public let day: Int
        public let jobs: Int
        public let open: Bool
    }

    public struct Hour: Sendable, Equatable {
        public let hour: Int
        public let jobs: Int
    }

    public struct Totals: Sendable, Equatable {
        public let jobs: Int
        /// Is there enough to read a pattern from? Ten finished jobs spread
        /// over 168 cells is noise, and a grid of noise looks exactly like a
        /// finding.
        public let enough: Bool
        public let busiestDay: Int?
        public let busiestHour: Int?
        public let onClosedDays: Int
        public let closedDayShare: Double?
        /// The busiest single cell, which the grid is scaled against.
        public let peak: Int
    }

    public struct Grid: Sendable, Equatable {
        public let matrix: [[Int]]
        public let byDay: [Day]
        public let byHour: [Hour]
        public let totals: Totals
    }

    /// `openDays` is by `getDay()` index, 0 = Sunday — the working week's own
    /// order. Anything other than exactly seven entries means "no idea", and
    /// every day then counts as open rather than as closed.
    public static func grid(orders: [JSONValue], openDays: [Bool],
                            minimum: Double? = nil,
                            inWindow: (JSONValue) -> Bool = { _ in true },
                            whenOf: ((JSONValue) -> Double?)? = nil) -> Grid {
        let minimum = minimum.map { Swift.max(0, $0.isFinite ? $0 : 0) } ?? 10
        let when = whenOf ?? { order in
            guard case .object(let o) = order else { return nil }
            // `Date.parse(String(o.completedAt || ''))` — the default reader,
            // injectable because the HOUR has to come out in the shop's own
            // zone and only the caller knows it.
            return JSDate.parse(JSSemantics.truthy(o["completedAt"])
                                ? JSSemantics.text(o["completedAt"]) : "")
        }

        var matrix = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        var counted = 0
        var closedDay = 0

        for order in orders {
            guard JSSemantics.truthy(order), case .object(let o) = order,
                  !JSSemantics.truthy(o["voidedAt"]) else { continue }
            guard finished.contains(JSSemantics.truthy(o["status"])
                                    ? JSSemantics.text(o["status"]) : "") else { continue }
            guard inWindow(order), let at = when(order), at.isFinite else { continue }
            let parts = JSDate.localDayAndHour(ms: at)
            guard (0..<7).contains(parts.weekday), (0..<24).contains(parts.hour) else { continue }
            matrix[parts.weekday][parts.hour] += 1
            counted += 1
            if openDays.count == 7 && !openDays[parts.weekday] { closedDay += 1 }
        }

        let byDay = (0..<7).map { day in
            Day(day: day, jobs: matrix[day].reduce(0, +),
                open: openDays.count == 7 ? openDays[day] : true)
        }
        let byHour = (0..<24).map { hour in
            Hour(hour: hour, jobs: matrix.reduce(0) { $0 + $1[hour] })
        }

        // `r.jobs > top.jobs` is STRICT, so the FIRST of several equal busiest
        // wins — Sunday over Tuesday, midnight over noon. A shop looking at
        // one answer should get the same one every time it looks.
        let busiestDay = byDay.reduce(into: byDay.first) { top, row in
            if let t = top, row.jobs > t.jobs { top = row }
        }
        let busiestHour = byHour.reduce(into: byHour.first) { top, row in
            if let t = top, row.jobs > t.jobs { top = row }
        }

        return Grid(matrix: matrix, byDay: byDay, byHour: byHour, totals: Totals(
            jobs: counted,
            enough: Double(counted) >= minimum,
            busiestDay: counted > 0 && (busiestDay?.jobs ?? 0) > 0 ? busiestDay?.day : nil,
            busiestHour: counted > 0 && (busiestHour?.jobs ?? 0) > 0 ? busiestHour?.hour : nil,
            onClosedDays: closedDay,
            closedDayShare: counted > 0 ? Double(closedDay) / Double(counted) : nil,
            peak: Swift.max(0, matrix.map { $0.max() ?? 0 }.max() ?? 0)))
    }
}
