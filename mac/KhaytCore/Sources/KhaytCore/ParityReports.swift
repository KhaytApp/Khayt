import Foundation

// The answers of the desktop's reports the Mac now draws too, as the shared
// modules return them. Portable: the phone links this package (CLAUDE.md).

/// `lib/filament-report.js` — profit by filament and material usage by month.
public struct FilamentReport: Decodable, Sendable, Equatable {
    public let rows: [Row]
    public let usage: Usage
    /// The window the usage covers, oldest first.
    public let months: [String]

    public struct Row: Decodable, Sendable, Equatable, Identifiable {
        public let key: String
        public let label: String
        public let color: String
        public let orders: Int
        public let revenue: Double
        public let matCost: Double
        public let marginPct: Double
        /// Hours per gram from measured prints, or nil.
        public let avgTimePerGram: Double?
        public var id: String { key }
    }

    public struct Usage: Decodable, Sendable, Equatable {
        public let materials: [String]
        public let colors: [String: String]
        /// material → month → grams; every month of the window is present.
        public let grams: [String: [String: Double]]
        public let monthTotals: [Double]
        public let maxGrams: Double

        public func grams(_ material: String, _ month: String) -> Double {
            grams[material]?[month] ?? 0
        }
    }
}

/// One month of `lib/pnl-trend.js`: revenue against spending, and the margin.
public struct PnlTrendMonth: Decodable, Sendable, Equatable, Identifiable {
    public let month: String
    public let revenue: Double
    public let expenses: Double
    public let profit: Double
    /// Nil for a month the P&L has no margin for.
    public let marginPct: Double?
    public var id: String { month }

    /// The colour band the other app draws a margin in: 40% and up good,
    /// 20% and up fair, below that poor (`KhaytPnlTrend.marginBand`).
    public static func band(_ pct: Double) -> String {
        pct >= 40 ? "good" : pct >= 20 ? "fair" : "poor"
    }
}

/// `lib/completion-heatmap.js` — twelve weeks of finished work by weekday.
public struct CompletionHeatmap: Decodable, Sendable, Equatable {
    /// `matrix[weekday][week]`, weekday 0 = Sunday, week 11 = this one.
    public let matrix: [[Int]]
    public let maxVal: Int
    public let jobs: Int
    public let hasData: Bool
    /// The tint each cell is drawn at, 0.12…0.97, as the other app's grid.
    public let intensity: [[Double]]
}

/// `lib/vat-return.js` — the box-form return and its document.
public struct VatReturnDocument: Decodable, Sendable, Equatable {
    public let from: String
    public let to: String
    public let taxName: String
    public let ratePct: Double
    public let mode: String
    public let vatRegistered: Bool
    public let isSaudiForm: Bool
    public let box1: Double
    public let box2: Double
    public let box3: Double
    public let adjSales: Double
    public let adjVat: Double
    public let box6: Double
    public let box7: Double
    public let box7Known: Bool
    public let netVat: Double
    public let invoices: Int
    public let html: String
}

/// `lib/reorder.js shoppingList` — what to buy, by supplier.
public struct ShoppingList: Decodable, Sendable, Equatable {
    public let groups: [Group]
    /// The list as the other app copies it.
    public let text: String

    public struct Group: Decodable, Sendable, Equatable, Identifiable {
        public let supplier: String
        public let items: [Item]
        public var id: String { supplier }
    }

    public struct Item: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let have: Double
        public let buy: Double
        public let color: String
    }

    public var isEmpty: Bool { groups.allSatisfy { $0.items.isEmpty } }
}

/// `lib/test-prints.js` — the log and the spool after a change.
public struct TestPrintChange: Decodable, Sendable {
    public let testPrints: [JSONValue]
    /// Nil when the spool was not given (it is gone).
    public let item: JSONValue?
}

public extension Calendar {
    /// `YYYY-MM` for the `count` months ending with the one `date` is in,
    /// oldest first — the window the desktop's six-month charts draw
    /// (`KhaytFilamentReport.lastMonths`), in the book's calendar.
    func monthKeys(endingAt date: Date, count: Int) -> [String] {
        let n = Swift.max(1, count)
        let first = self.date(from: dateComponents([.year, .month], from: date)) ?? date
        return (0..<n).reversed().compactMap { back -> String? in
            guard let d = self.date(byAdding: .month, value: -back, to: first) else { return nil }
            let c = dateComponents([.year, .month], from: d)
            return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
        }
    }
}
