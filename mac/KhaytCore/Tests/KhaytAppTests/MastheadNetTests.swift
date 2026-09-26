import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The month's net, in the masthead's largest slot.
///
/// ── WHAT THIS REPLACED ────────────────────────────────────────────────────
///
/// `monthNet` was `var monthNet: Double? { nil }` — a permanent em dash in the
/// most prominent figure on the app's main screen, labelled with the month,
/// with a note under it saying the number lives in Reports. Every shop, every
/// month, for ever.
///
/// The reason given was sound and had an unexamined premise: net-of-tax depends
/// on whether the shop prices tax-inclusive, and that mode "is not given" to
/// this reading. It was not unavailable — it simply was not asked for.
///
/// ── AND THE TEST THAT MATTERS IS THE AGREEMENT ────────────────────────────
///
/// §5 protects ONE reconciliation, not two. So the check that earns this
/// change is not that the figure is plausible: it is that it is the same
/// arithmetic on the same inputs as the P&L table, for every shape of book.
@MainActor
struct MastheadNetTests {

    static func loaded() async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        return shop
    }

    @Test("the masthead is no longer a permanent dash")
    func thereIsAFigure() async {
        let shop = await Self.loaded()
        #expect(shop.monthNet != nil,
                "the largest figure on the main screen is still an em dash")
    }

    @Test("it is the same figure the P&L prints for this month")
    func itAgreesWithReports() async throws {
        // The whole point. Two screens, one rule — asked here the way Reports
        // asks it, so a divergence in either is a failure here.
        let shop = await Self.loaded()
        let engine = try #require(shop.engine)
        let rows = try await engine.pnlByPeriod(
            orders: shop.orderRows, expenses: shop.expenseRows,
            settings: shop.settingsDict, clients: shop.clientRows,
            currencies: Invoice.currencyTable(shop), now: Date(),
            granularity: "month", wasteLog: shop.wasteRows)
        let key = DateRange.localMonth(Date())
        let reports = rows.first { $0.period == key }?.net
        // Hoisted, and stringified with an explicit closure: `String.init` on
        // an optional Double picks an overload the diagnostic engine chokes
        // on, and the same mistake once made `Number("0x10")` come out as
        // 8e-323 elsewhere in this project.
        let mine: Double? = shop.monthNet
        let said = mine.map { "\($0)" } ?? "nil"
        let theirs = reports.map { "\($0)" } ?? "nil"
        #expect(mine == reports,
                Comment(rawValue: "masthead \(said) vs Reports \(theirs) for \(key)"))
    }

    @Test("it is net, so it is not the gross beside it")
    func netIsNotGross() async throws {
        // If these were ever equal by construction rather than by arithmetic,
        // the masthead would be printing one number twice under two labels.
        let shop = await Self.loaded()
        let net = try #require(shop.monthNet)
        guard let gross = shop.monthGross, gross != 0 else { return }
        #expect(net <= gross + 0.005,
                Comment(rawValue: "net \(net) is above gross \(gross)"))
    }

    @Test("NET is net income: revenue less cost of goods, expenses and overhead")
    func netIsNetIncome() async throws {
        // The alpha.51 review: the masthead read "SEPTEMBER · NET 50.00" with
        // "at least 35.91" of material beside it, while Reports read NET
        // INCOME 14.09 (50.00 − 35.91 − 0.00). The header was revenue net of
        // tax. It is the P&L's net income now, off the same row.
        let shop = await Self.loaded()
        let engine = try #require(shop.engine)
        let rows = try await engine.pnlByPeriod(
            orders: shop.orderRows, expenses: shop.expenseRows,
            settings: shop.settingsDict, clients: shop.clientRows,
            currencies: Invoice.currencyTable(shop), now: Date(),
            granularity: "month", wasteLog: shop.wasteRows)
        let row = try #require(rows.first { $0.period == DateRange.localMonth(Date()) })
        let net = try #require(shop.monthNet)
        let expected = row.revenue - (row.cogs ?? 0) - (row.waste ?? 0) - row.expenses - row.fixed
        #expect(abs(net - expected) < 0.011,
                Comment(rawValue: "masthead \(net) vs revenue−cogs−expenses−overhead \(expected)"))
        if (row.cogs ?? 0) > 0 {
            #expect(net < row.revenue, "cost of goods was not taken off the masthead's net")
        }
    }

    @Test("the gross is the same jobs as the net, before the tax comes out")
    func grossIsTheSameJobs() async throws {
        // It summed the month's PAID-UP jobs while the net beside it summed the
        // FINISHED ones, so a job finished and not yet paid for counted in one
        // and not the other. The sample book is re-dated to today on every
        // load, and on 23 September 2026 that put exactly such a job into the
        // month: 1,671.90 net beside 1,243.09 gross, and `netIsNotGross` red
        // on `main` for every pull request in the repository.
        //
        // Asked the way Reports asks it, so the gross cannot come from a
        // different set of jobs again without this noticing.
        let shop = await Self.loaded()
        let engine = try #require(shop.engine)
        let rows = try await engine.pnlByPeriod(
            orders: shop.orderRows, expenses: shop.expenseRows,
            settings: shop.settingsDict, clients: shop.clientRows,
            currencies: Invoice.currencyTable(shop), now: Date(),
            granularity: "month", wasteLog: shop.wasteRows)
        let row = rows.first { $0.period == DateRange.localMonth(Date()) }
        let expected = row.map { $0.revenue + $0.vatCollected }
        let said = shop.monthGross.map { "\($0)" } ?? "nil"
        let theirs = expected.map { "\($0)" } ?? "nil"
        #expect(shop.monthGross == expected,
                Comment(rawValue: "masthead gross \(said) vs Reports' charged \(theirs)"))
    }

    @Test("the note explaining the dash is gone once there is a number")
    func theNoteFollowsTheFigure() async {
        // A line saying "reconciled in Reports, not here" printed UNDER a
        // figure that is present reads as a warning about that figure.
        let shop = await Self.loaded()
        if shop.monthNet == nil {
            #expect(shop.monthNetNote != nil, "a dash with nothing to explain it")
        } else {
            #expect(shop.monthNetNote == nil,
                    Comment(rawValue: "a figure is shown and still carries: \(shop.monthNetNote ?? "")"))
        }
    }

    @Test("the label still names the month, because a figure with no period lies by omission")
    func theLabelNamesThePeriod() async {
        let shop = await Self.loaded()
        let month = Date().formatted(.dateTime.month(.wide)).uppercased()
        #expect(shop.monthNetLabel.contains(month),
                Comment(rawValue: "\(shop.monthNetLabel) does not name \(month)"))
    }

    @Test("a book that has not been read shows the dash, not a confident zero")
    func unreadBookIsStillADash() {
        let shop = Shop()
        #expect(shop.monthNet == nil)
        #expect(shop.monthNetNote != nil, "the dash is unexplained")
    }

    @Test("a month with no row of its own is a dash, not a zero")
    func emptyMonthIsADash() async {
        // A shop that has billed nothing this month has no period row at all.
        // Zero would be a claim; the dash is the truth.
        let shop = await Self.loaded()
        let engine = shop.engine
        let far = Calendar.current.date(byAdding: .year, value: 3, to: Date()) ?? Date()
        let answer = await Shop.thisMonthsNet(
            engine: engine, orders: shop.orderRows, expenses: shop.expenseRows,
            settings: shop.settingsDict, clients: shop.clientRows,
            currencies: Invoice.currencyTable(shop), now: far)
        #expect(answer == nil, "a month the book knows nothing about produced a figure")
    }

    @Test("the period key is built the way the rule builds its own")
    func keyMatchesTheRule() async throws {
        // A key made any other way misses by a day at either end of a month
        // for a shop not on UTC, and the masthead silently shows last month's.
        let shop = await Self.loaded()
        let engine = try #require(shop.engine)
        let rows = try await engine.pnlByPeriod(
            orders: shop.orderRows, expenses: shop.expenseRows,
            settings: shop.settingsDict, clients: shop.clientRows,
            currencies: Invoice.currencyTable(shop), now: Date(), granularity: "month", wasteLog: shop.wasteRows)
        #expect(!rows.isEmpty, "no periods at all, so the lookup proves nothing")
        for row in rows {
            #expect(row.period.count == 7 && row.period.contains("-"),
                    Comment(rawValue: "\(row.period) is not a YYYY-MM key"))
        }
        #expect(rows.contains { $0.period == DateRange.localMonth(Date()) }
                || shop.monthNet == nil,
                "a figure was shown for a month the rule has no row for")
    }
}
