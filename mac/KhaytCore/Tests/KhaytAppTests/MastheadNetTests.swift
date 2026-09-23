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
            granularity: "month")
        let key = DateRange.localMonth(Date())
        let reports = rows.first { $0.period == key }?.revenue
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

    @Test("gross is the same jobs as net, before the tax came out")
    func grossIsTheSameJobs() async throws {
        // Gross used to be every PAID job this month, of any status, while net
        // was the FINISHED ones — two sets of jobs under two labels side by
        // side. On 23 Sep 2026 the sample book printed a net of 1,671.90 beside
        // a gross of 1,243.09, and `netIsNotGross` above was the first thing
        // to notice.
        let shop = await Self.loaded()
        let engine = try #require(shop.engine)
        let rows = try await engine.pnlByPeriod(
            orders: shop.orderRows, expenses: shop.expenseRows,
            settings: shop.settingsDict, clients: shop.clientRows,
            currencies: Invoice.currencyTable(shop), now: Date(), granularity: "month")
        let row = rows.first { $0.period == DateRange.localMonth(Date()) }
        let expected = row.map { $0.revenue + $0.vatCollected }
        #expect(shop.monthGross == expected,
                Comment(rawValue: "masthead gross \(shop.monthGross.map { "\($0)" } ?? "nil") vs Reports \(expected.map { "\($0)" } ?? "nil")"))
    }

    @Test("a finished job not yet paid for is in gross, and a paid one still printing is not")
    func grossDoesNotDependOnPayment() async throws {
        // The shape that broke it, built on purpose rather than waiting for
        // the calendar to walk the sample book into it.
        let shop = await Self.loaded()
        let engine = try #require(shop.engine)
        let today = DateFormatter.shopDay.string(from: Date())
        let finishedUnpaid: JSONValue = .object([
            "id": .string("gross-a"), "project": .string("Finished, unpaid"),
            "status": .string("completed"), "date": .string(today),
            "price": .number(200), "paidAmount": .number(0),
        ])
        let paidPrinting: JSONValue = .object([
            "id": .string("gross-b"), "project": .string("Paid, printing"),
            "status": .string("printing"), "date": .string(today),
            "price": .number(900), "paidAmount": .number(900),
        ])
        let row = try #require(await Shop.thisMonthsRow(
            engine: engine, orders: [finishedUnpaid, paidPrinting], expenses: [],
            settings: shop.settingsDict, clients: [],
            currencies: Invoice.currencyTable(shop)))
        #expect(row.orders == 1, "the rule counted a job that is still printing")
        let gross = row.revenue + row.vatCollected
        // 200 if the shop prices tax-inclusive, 200 plus the tax if not —
        // either way the finished job's price and nothing of the 900.
        #expect(gross >= 199.99 && gross < 900,
                Comment(rawValue: "gross \(gross) is not the finished job's 200"))
        #expect(row.revenue <= gross + 0.005)
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
            currencies: Invoice.currencyTable(shop), now: Date(), granularity: "month")
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
