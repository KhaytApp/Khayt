import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The pre-release UI review's fixes that can be held by a test rather than
/// only by a picture: the words, the save line, the machine sheet's rules and
/// the masthead's cost figure.
@MainActor
struct UiReviewFixesTests {

    static func words(_ lang: String) async throws -> Words {
        let w = Words()
        await w.load(lang, engine: try KhaytEngine())
        return w
    }

    // MARK: - The save line

    @Test("never saved is its own words, not 'never printed'")
    func notSavedYet() async throws {
        let ar = try await Self.words("ar")
        #expect(Shop.savedLabel(nil, words: ar) == "لم يُحفظ بعد")
        #expect(Shop.savedLabel(nil, words: ar) != ar.callIt("mac.never"))
        let en = try await Self.words("en")
        #expect(Shop.savedLabel(nil, words: en) == "not saved yet")
    }

    @Test("a backup day is said as a day, never as midnight")
    func savedDayNotTime() async throws {
        let en = try await Self.words("en")
        let today = try #require(Order.day("2026-09-20"))
        #expect(Shop.savedLabel("2026-09-20", words: en, today: today) == "saved today")
        #expect(Shop.savedLabel("2026-09-19", words: en, today: today) == "saved yesterday")
        let older = Shop.savedLabel("2026-09-14", words: en, today: today)
        #expect(older.hasPrefix("saved "))
        #expect(older.contains("14"))
        #expect(!older.contains("12:00"), "a day-only backup was printed with a time: \(older)")
        #expect(!older.contains("AM") && !older.contains("PM"))
    }

    // MARK: - Arabic counts

    @Test("three to ten take the plural where a word has been given one")
    func arabicFew() async throws {
        let ar = try await Self.words("ar")
        #expect(ar.counting(1, "mac.dep_months_left") == "شهر واحد")
        #expect(ar.counting(2, "mac.dep_months_left") == "شهران")
        #expect(ar.counting(5, "mac.dep_months_left") == "5 أشهر")
        #expect(ar.counting(10, "mac.dep_months_left") == "10 أشهر")
        #expect(ar.counting(11, "mac.dep_months_left") == "11 شهرًا")
        #expect(ar.counting(7, "mac.cloudlib_n_days") == "7 أيام")
        #expect(ar.counting(30, "mac.cloudlib_n_days") == "30 يومًا")
        #expect(ar.counting(365, "mac.cloudlib_n_days") == "365 يومًا")
        let en = try await Self.words("en")
        #expect(en.counting(5, "mac.dep_months_left") == "5 months")
        #expect(en.counting(1, "mac.dep_months_left") == "1 month")
        #expect(en.counting(90, "mac.cloudlib_n_days") == "90 days")
    }

    // MARK: - One word for filament

    @Test("filament is one word in Arabic, on every screen")
    func filamentOneWord() async throws {
        let ar = try await Self.words("ar")
        let shared = try await KhaytEngine().translations(language: "ar")
        // The shared catalogue says خيط now (the other app's #1669), so the
        // two keys this app used to re-word read the same as its own.
        #expect(ar.callIt("calc.part.filament") == ar.callIt("mac.filament"))
        #expect(ar.callIt("exp.cat.filament").contains("خيوط"))
        for (key, text) in shared {
            #expect(!text.contains("فلامنت") && !text.contains("فيلامنت"), "\(key) says فلامنت")
        }
    }

    // MARK: - The machine sheet

    @Test("hours a month is asked only where it changes the hourly figure")
    func monthlyHoursMatter() {
        #expect(!MachineSheet.monthlyHoursMatter(method: "perHour", unit: "hours"))
        #expect(MachineSheet.monthlyHoursMatter(method: "perHour", unit: "years"))
        #expect(MachineSheet.monthlyHoursMatter(method: "straightLine", unit: "hours"))
        #expect(MachineSheet.monthlyHoursMatter(method: "straightLine", unit: "years"))
    }

    // MARK: - The masthead

    @Test("the masthead's cost figure is Reports' cost of goods for the month")
    func mastheadCostIsReports() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let rows = try await engine.pnlByPeriod(
            orders: shop.orderRows, expenses: shop.expenseRows,
            settings: shop.settingsDict, clients: shop.clientRows,
            currencies: Invoice.currencyTable(shop), now: Date(),
            granularity: "month", wasteLog: shop.wasteRows,
            inventory: shop.inventoryRows, machines: shop.machineRows,
            recentMonthlyHours: shop.recentMonthlyHours)
        let key = DateRange.localMonth(Date())
        let reports = rows.first { $0.period == key }?.cogsValue
        #expect(shop.monthCostOfGoods == reports)
    }

    // MARK: - The sample book draws the new rows

    @Test("the sample book has a depreciating machine and a job-linked failure")
    func sampleSpansTheCases() async throws {
        let shop = Shop()
        await shop.load(.sample)
        #expect(shop.machines.contains { $0.depreciation != nil })
        let linked = shop.wasteRows.contains { row in
            if case .object(let o) = row, case .string(let id)? = o["orderId"], !id.isEmpty,
               case .number? = o["costFull"] { return true }
            return false
        }
        #expect(linked, "no waste row on a job with its true cost: the Waste true-cost lines are never drawn")
    }
}
