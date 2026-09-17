import Foundation
import Testing
@testable import KhaytCore

/// What a shop spent by category, against the JavaScript it came from.
///
/// The module exists because two screens disagreed about the same money by the
/// whole of the reclaimable tax — 15% of every category with a receipt, at the
/// Saudi rate. So a port of it that is a little bit off is the original bug
/// coming back wearing a different hat, and the comparison is over the whole
/// envelope: every row, in order, with its share, and the three figures above.
@MainActor
struct ExpenseCategoriesParityTests {

    private func js() throws -> JSModule { try JSModule(["expense-categories"]) }

    private func theirs(_ js: JSModule, _ expenses: [JSONValue],
                        _ reclaims: Bool) throws -> ExpenseCategories.Spending {
        guard case .object(let o) = try js.value(
            "globalThis.KhaytExpenseCategories.byCategory(ARG0, { reclaimsTax: ARG1 })",
            [.array(expenses), .bool(reclaims)]) else {
            Issue.record("the answer was not an object")
            return ExpenseCategories.Spending(rows: [], total: 0, reclaimed: 0, biggest: 0)
        }
        var rows: [ExpenseCategories.Row] = []
        if case .array(let list)? = o["rows"] {
            for row in list {
                guard case .object(let r) = row else { continue }
                rows.append(.init(category: text(r["category"]),
                                  amount: number(r["amount"]),
                                  reclaimed: number(r["reclaimed"]),
                                  share: number(r["share"])))
            }
        }
        return ExpenseCategories.Spending(rows: rows, total: number(o["total"]),
                                          reclaimed: number(o["reclaimed"]),
                                          biggest: number(o["biggest"]))
    }

    private func number(_ v: JSONValue?) -> Double { if case .number(let n)? = v { return n }; return .nan }
    /// The category as it reaches Swift.
    ///
    /// The JavaScript keys its `Map` on the RAW value, so a category stored as
    /// the number 7 comes back as the number 7 — see
    /// `numericCategoriesAreWhereThePortDiverges`. Coerced here with the same
    /// `String()` the port applies, so the comparison is about the arithmetic
    /// rather than about which side stringifies.
    private func text(_ v: JSONValue?) -> String { JSSemantics.text(v) }

    private func check(_ expenses: [JSONValue], _ what: String) throws {
        let js = try js()
        for reclaims in [true, false] {
            let mine = ExpenseCategories.byCategory(expenses, reclaimsTax: reclaims)
            let theirs = try theirs(js, expenses, reclaims)
            #expect(mine == theirs,
                    Comment(rawValue: "\(what), reclaims \(reclaims)\n  swift \(mine)\n  js    \(theirs)"))
        }
    }

    private func expense(_ category: JSONValue?, _ amount: JSONValue,
                         vat: JSONValue? = nil) -> JSONValue {
        var row: [String: JSONValue] = ["amount": amount]
        if let category { row["category"] = category }
        if let vat { row["vatAmount"] = vat }
        return .object(row)
    }

    @Test("a real month of spending, gross and net of reclaim")
    func realMonthMatches() throws {
        try check([
            expense(.string("filament"), .number(1_240.50), vat: .number(186.08)),
            expense(.string("filament"), .number(320), vat: .number(48)),
            expense(.string("rent"), .number(4_000)),
            expense(.string("electricity"), .number(612.35), vat: .number(91.85)),
            expense(.string("parts"), .number(89.99), vat: .number(13.50)),
            expense(.string("courier"), .number(45), vat: .number(6.75)),
        ], "a month")
    }

    @Test("the tie-break keeps the order the book lists them in")
    func tiesAreStable() throws {
        // JavaScript's sort is STABLE, so two categories that came to the same
        // amount come out in first-seen order. Swift's `sorted` promises
        // nothing of the kind, and a chart whose rows shuffle between two apps
        // looking at one book is a bug nobody can reproduce on purpose.
        try check([
            expense(.string("zebra"), .number(100)),
            expense(.string("apple"), .number(100)),
            expense(.string("mango"), .number(100)),
            expense(.string("banana"), .number(100)),
            expense(.string("apple"), .number(0)),
        ], "four categories at 100")
    }

    @Test("a receipt claiming more tax than it paid is capped, not negative")
    func overClaimIsCapped() throws {
        try check([expense(.string("parts"), .number(50), vat: .number(500))], "over-claim")
        try check([expense(.string("parts"), .number(50), vat: .number(-500))], "negative tax")
        try check([expense(.string("parts"), .number(-50), vat: .number(10))], "a refund")
        try check([expense(.string("parts"), .number(0), vat: .number(10))], "nothing paid")
    }

    @Test("a book that nets to nothing divides by one, and a negative one keeps its sign")
    func denominatorHolds() throws {
        // A shop whose only expense was entirely reclaimable is a real case,
        // not an error.
        try check([expense(.string("parts"), .number(100), vat: .number(100))], "all reclaimed")
        try check([expense(.string("a"), .number(100)), expense(.string("b"), .number(-100))],
                  "nets to zero")
        try check([expense(.string("a"), .number(-100)), expense(.string("b"), .number(-50))],
                  "nets negative")
        try check([], "no expenses at all")
    }

    @Test("an unnamed category falls into the same bucket the editor uses")
    func unnamedGoesToOther() throws {
        try check([expense(nil, .number(10)), expense(.string(""), .number(20)),
                   expense(.string("other"), .number(30)), expense(.null, .number(40)),
                   expense(.number(0), .number(50)), expense(.bool(false), .number(60))],
                  "unnamed")
    }

    @Test("a category name that is not a string")
    func oddCategoryNames() throws {
        try check([expense(.number(7), .number(10)), expense(.bool(true), .number(20)),
                   expense(.array([.string("a"), .string("b")]), .number(30)),
                   expense(.object([:]), .number(40)), expense(.number(1e21), .number(50)),
                   expense(.number(0.1), .number(60))],
                  "odd names")
    }

    @Test("an amount that is not a number")
    func oddAmounts() throws {
        for value in Awkward.notNumbers + Awkward.numbers.map({ JSONValue.number($0) }) {
            try check([expense(.string("parts"), value),
                       expense(.string("rent"), .number(100))],
                      "amount \(value)")
            try check([expense(.string("parts"), .number(100), vat: value)],
                      "vat \(value)")
        }
    }

    /// ── ONE PLACE THE PORT DELIBERATELY DOES NOT AGREE ────────────────────
    ///
    /// The JavaScript keys its `Map` on `e.category` itself, so an expense
    /// filed under the number `7` and one filed under the string `"7"` are two
    /// separate rows, and the row it returns carries a NUMBER in a field
    /// everything downstream reads as text.
    ///
    /// That is not a rule, it is a `Map` doing what a `Map` does — and it was
    /// already breaking this screen. `KhaytEngine.ExpenseCategoryRow.category`
    /// is a `String`, the call site uses `try?`, so one numerically-named
    /// category made the ENTIRE spending panel disappear with nothing said.
    ///
    /// The port reads the key as text, so the two merge and the panel draws.
    /// Recorded rather than quietly changed.
    @Test("a category stored as a number merges with its own spelling, where the original split them")
    func numericCategoriesAreWhereThePortDiverges() throws {
        let js = try js()
        let book = [expense(.number(7), .number(10)), expense(.string("7"), .number(20))]
        let mine = ExpenseCategories.byCategory(book, reclaimsTax: false)
        #expect(mine.rows.count == 1, "the port should merge them")
        #expect(mine.rows.first?.category == "7")
        #expect(mine.rows.first?.amount == 30)

        guard case .object(let theirs) = try js.value(
            "globalThis.KhaytExpenseCategories.byCategory(ARG0, {})", [.array(book)]),
              case .array(let rows)? = theirs["rows"] else {
            Issue.record("no answer"); return
        }
        #expect(rows.count == 2, "if the original stopped splitting these, this test can go")
        // And the field that used to be a number, which is what broke the
        // decode: the panel could not be drawn at all.
        #expect(rows.contains { if case .object(let r) = $0, case .number = r["category"] { return true }; return false },
                "the original returns a number where a string was expected")
        // The totals still agree, which is why nobody noticed it was the
        // DECODE that failed rather than the arithmetic.
        #expect(mine.total == 30)
    }

    @Test("rows that are not expenses at all")
    func degenerateRows() throws {
        try check([.null, .bool(false), .number(0), .string("")], "every falsy row")
        try check([.string("not an expense"), .number(3), .array([]), .bool(true)],
                  "truthy rows that are not objects")
        try check([.null, expense(.string("rent"), .number(10)), .string("x")], "a mix")
    }
}
