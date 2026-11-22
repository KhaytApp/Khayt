import Foundation
import Testing
import KhaytCore

/// What a phone carries, and — the harder half — what it is told it does not.
@Suite struct BookScopeTests {

    private func order(_ id: String, _ status: String, _ date: String) -> JSONValue {
        .object(["id": .string(id), "status": .string(status), "date": .string(date)])
    }

    private func shop(orders: [JSONValue]) -> [String: JSONValue] {
        [
            "settings": .object(["shopName": .string("Ward"), "vatRate": .number(15)]),
            "printLog": .array(orders),
            "clients": .array([.object(["id": .string("c1")])]),
            "inventory": .array([.object(["id": .string("s1")])]),
            "machines": .array([.object(["id": .string("m1")])]),
            "waitingList": .array([]),
            // The three quarters of a real book that no companion screen shows.
            "printFiles": .array([.object(["id": .string("f1")])]),
            // The catalogue, which the phone's Catalogue screen shows.
            "products": .array([.object(["id": .string("p1")])]),
            "expenses": .array([.object(["id": .string("e1")])]),
            "auditLog": .array([.object(["id": .string("a1")])]),
        ]
    }

    @Test("settings always travel, because nothing can be priced without them")
    func settingsTravel() {
        let cut = BookScope.take(from: shop(orders: []))
        #expect(cut.store["settings"] != nil)
        // And are not counted as a collection — one object is not a list of
        // records, and counting its keys would inflate what the phone reports.
        #expect(cut.taken.collections["settings"] == nil)
    }

    @Test("history is left on the Mac, and the phone is told which parts")
    func historyStaysBehind() {
        let cut = BookScope.take(from: shop(orders: []))
        for left in ["printFiles", "auditLog"] {
            #expect(cut.store[left] == nil, "\(left) travelled and no screen shows it")
            #expect(cut.taken.omitted.contains(left),
                    "\(left) was withheld silently — the phone cannot tell that from empty")
        }
        #expect(cut.store["products"] != nil, "the phone's Catalogue screen reads it")
    }

    @Test("unfinished work travels whatever its age")
    func openWorkAlwaysTravels() {
        // One ancient job stuck in QC, and 250 finished ones after it. The old
        // job is the one somebody is chasing; dropping it for being old would
        // hide exactly the record that matters.
        var orders = [order("STUCK", "qc", "2023-01-04")]
        for i in 0..<250 { orders.append(order("OLD-\(i)", "delivered", "2026-0\((i % 9) + 1)-01")) }

        let cut = BookScope.take(from: shop(orders: orders))
        guard case .array(let kept)? = cut.store["printLog"] else { Issue.record("no orders"); return }
        let ids = kept.compactMap { row -> String? in
            guard case .object(let o) = row, case .string(let id)? = o["id"] else { return nil }
            return id
        }
        #expect(ids.contains("STUCK"), "a job stuck in QC since 2023 was dropped for being old")
        // Every open order, plus the 200 newest finished ones — not 251.
        #expect(kept.count == 201)
        #expect(cut.taken.collections["printLog"]?.whole == false)
        #expect(cut.taken.collections["printLog"]?.available == 251,
                "the phone cannot say \"200 of 251\" without being told the 251")
    }

    @Test("a small shop gets its whole order history and is told it is whole")
    func smallShopIsComplete() {
        let orders = (0..<12).map { order("O-\($0)", "delivered", "2026-07-0\(($0 % 9) + 1)") }
        let cut = BookScope.take(from: shop(orders: orders))
        // The distinction the screens rest on: this phone may count, total and
        // report on orders, because it has all of them.
        #expect(cut.taken.isWhole("printLog"))
        #expect(cut.taken.collections["printLog"]?.available == nil)
        #expect(cut.taken.isWhole("clients"))
    }

    @Test("newest means newest — the cut keeps the recent history, not an arbitrary 200")
    func newestIsNewest() {
        var orders: [JSONValue] = []
        for year in ["2020", "2021", "2022", "2023", "2024", "2025", "2026"] {
            for i in 1...40 { orders.append(order("\(year)-\(i)", "completed", "\(year)-01-\(String(format: "%02d", (i % 28) + 1))")) }
        }
        let cut = BookScope.take(from: shop(orders: orders))
        guard case .array(let kept)? = cut.store["printLog"] else { Issue.record("no orders"); return }
        let years = Set(kept.compactMap { row -> String? in
            guard case .object(let o) = row, case .string(let date)? = o["date"] else { return nil }
            return String(date.prefix(4))
        })
        #expect(kept.count == 200)
        #expect(!years.contains("2020"), "the oldest year survived a cut that keeps the newest 200")
        #expect(years.contains("2026"), "the newest year did not survive the cut")
    }

    @Test("a collection the shop does not have is whole-and-empty, not withheld")
    func absentIsNotWithheld() {
        var book = shop(orders: [])
        book["inventory"] = nil
        let cut = BookScope.take(from: book)
        // "You have every spool there is, and there are none" — as opposed to
        // "spools were not sent", which would send a screen looking for more.
        #expect(cut.taken.isWhole("inventory"))
        #expect(cut.taken.collections["inventory"]?.sent == 0)
        #expect(!cut.taken.omitted.contains("inventory"))
    }
}

/// What the phone's calculator and receipt scanner need (Oct 2026).
@Suite struct BookScopeCalculatorTests {

    private func expense(_ id: String, _ date: String) -> JSONValue {
        .object(["id": .string(id), "date": .string(date), "amount": .number(10)])
    }

    @Test("presets, consumables and suppliers travel whole")
    func calculatorCollectionsTravel() {
        let store: [String: JSONValue] = [
            "printers": .array([.object(["id": .string("pr1")])]),
            "consumables": .array([.object(["id": .string("c1")])]),
            "suppliers": .array([.object(["id": .string("sup1"), "vat": .string("300000000000003")])]),
        ]
        let cut = BookScope.take(from: store)
        for name in ["printers", "consumables", "suppliers"] {
            #expect(cut.taken.isWhole(name), "\(name) did not travel whole")
            #expect(!cut.taken.omitted.contains(name))
        }
    }

    @Test("expenses: the newest by day, wherever a row sits in the list")
    func newestExpensesByDayNotPosition() {
        // 1,200 expenses newest-first, then a recent one folded in at the END —
        // where a phone's fold or an import can put it. A plain prefix drops it,
        // and the receipt scanner's duplicate check then misses a fresh receipt.
        var rows: [JSONValue] = []
        for i in 0..<1_200 {
            let day = Calendar(identifier: .gregorian).date(byAdding: .day, value: -i - 1,
                                                             to: Date(timeIntervalSince1970: 1_790_000_000))!
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            rows.append(expense("E\(i)", f.string(from: day)))
        }
        rows.append(expense("LATE-FOLD", "2026-09-21"))
        let cut = BookScope.take(from: ["expenses": .array(rows)])
        guard case .array(let kept)? = cut.store["expenses"] else { Issue.record("no expenses"); return }
        let ids = kept.compactMap { row -> String? in
            guard case .object(let o) = row, case .string(let id)? = o["id"] else { return nil }
            return id
        }
        #expect(kept.count == 1_000)
        #expect(ids.contains("LATE-FOLD"))
        #expect(!ids.contains("E1199"))
        #expect(cut.taken.collections["expenses"] == .init(whole: false, sent: 1_000, available: 1_201))
    }

    @Test("a product travels with its small pictures but without the Mac's file paths")
    func productsLeaveTheirPathsBehind() {
        let product: JSONValue = .object([
            "id": .string("PROD-1"), "nameEn": .string("Lamp"), "basePrice": .number(40),
            "thumbnail": .string("data:image/jpeg;base64,AAA"),
            "imagePath": .string("/Users/someone/Library/Khayt/products/PROD-1-a.jpg"),
            "docs": .array([.object(["path": .string("/Users/someone/manual.pdf")])]),
            "images": .array([.object(["id": .string("a"), "path": .string("/Users/someone/x.jpg"),
                                       "thumbnail": .string("data:image/jpeg;base64,BBB")])]),
        ])
        let cut = BookScope.take(from: ["products": .array([product])])
        guard case .array(let rows)? = cut.store["products"], case .object(let o)? = rows.first else {
            Issue.record("no products"); return
        }
        #expect(o["imagePath"] == nil)
        #expect(o["docs"] == nil)
        #expect(o["thumbnail"] == .string("data:image/jpeg;base64,AAA"))
        #expect(o["basePrice"] == .number(40))
        guard case .array(let images)? = o["images"], case .object(let first)? = images.first else {
            Issue.record("no images"); return
        }
        #expect(first["path"] == nil)
        #expect(first["thumbnail"] == .string("data:image/jpeg;base64,BBB"))
        #expect(cut.taken.collections["products"]?.whole == true)
        // The same trim for a record a cloud change folds in.
        #expect(BookScope.trimmed(["products": .array([product])]) == ["products": .array([.object(o)])])
    }
}

/// What a cut book must keep however old it is, and how "newest" is judged
/// (Nov 2026 review of the phone's money).
@Suite struct BookScopeOwingAndRecencyTests {

    private func job(_ id: String, _ status: String, _ date: String,
                     _ extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "status": .string(status), "date": .string(date)]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    private func ids(_ cut: (store: [String: JSONValue], taken: BookScope.Taken)) -> Set<String> {
        guard case .array(let kept)? = cut.store["printLog"] else { return [] }
        return Set(kept.compactMap { row -> String? in
            guard case .object(let o) = row, case .string(let id)? = o["id"] else { return nil }
            return id
        })
    }

    /// 250 paid finished jobs from 2026, newest of the lot.
    private func recentPaid() -> [JSONValue] {
        (0..<250).map { i in
            job("P-\(i)", "completed", "2026-0\((i % 9) + 1)-15",
                ["price": .number(100), "paidAmount": .number(100), "paymentStatus": .string("paid")])
        }
    }

    @Test("a finished job that still owes money travels whatever its age")
    func owingJobsAlwaysTravel() {
        var orders = recentPaid()
        orders.append(job("OWES", "delivered", "2022-03-01", ["price": .number(500), "paidAmount": .number(200),
                                                                 "paymentStatus": .string("partial")]))
        orders.append(job("UNPAID", "shipped", "2022-03-02", ["price": .number(80)]))
        orders.append(job("SAYS-PAID-BUT-SHORT", "completed", "2022-03-03",
                          ["price": .number(80), "paidAmount": .number(10), "paymentStatus": .string("paid")]))
        // Owe nothing, by the shared rule or by their own figures: left behind.
        orders.append(job("PAID-OLD", "completed", "2022-03-04", ["price": .number(80), "paidAmount": .number(80),
                                                                     "paymentStatus": .string("paid")]))
        orders.append(job("CANCELLED", "cancelled", "2022-03-05", ["price": .number(80)]))
        orders.append(job("VOIDED", "completed", "2022-03-06", ["price": .number(80), "voidedAt": .string("2022-04-01")]))
        orders.append(job("CREDITED", "completed", "2022-03-07", ["price": .number(80), "creditedAt": .string("2022-04-01")]))
        orders.append(job("FREE", "completed", "2022-03-08", ["price": .number(0)]))

        let cut = BookScope.take(from: ["printLog": .array(orders)])
        let kept = ids(cut)
        #expect(kept.contains("OWES"), "an old partly paid job was cut, and its customer's Owed came out short")
        #expect(kept.contains("UNPAID"))
        #expect(kept.contains("SAYS-PAID-BUT-SHORT"), "a stale paid label is not proof of payment")
        for gone in ["PAID-OLD", "CANCELLED", "VOIDED", "CREDITED", "FREE"] {
            #expect(!kept.contains(gone), "\(gone) owes nothing and is older than the 200 newest")
        }
        // The cap is still the newest 200 finished, plus what owes.
        #expect(kept.count == 203)
        #expect(cut.taken.collections["printLog"]?.whole == false)
        #expect(cut.taken.collections["printLog"]?.available == 258)
    }

    @Test("newest is the latest of completed, delivered, updated and the day")
    func recencyReadsTheLatestStamp() {
        var orders = recentPaid()
        // Booked in 2021, finished and delivered last week: recent history.
        orders.append(job("LONG-JOB", "delivered", "2021-01-10",
                          ["completedAt": .string("2026-10-28T09:00:00.000Z"),
                           "deliveredAt": .string("2026-10-30T09:00:00.000Z")]))
        orders.append(job("EDITED", "completed", "2021-01-11", ["updatedAt": .string("2026-10-29T09:00:00.000Z")]))
        orders.append(job("STALE", "completed", "2021-01-12"))
        let kept = ids(BookScope.take(from: ["printLog": .array(orders)]))
        #expect(kept.contains("LONG-JOB"), "a job finished last week was cut because it was booked in 2021")
        #expect(kept.contains("EDITED"))
        #expect(!kept.contains("STALE"))
    }

    @Test("a cut book says where it was cut, and a whole one does not")
    func theCutIsRecorded() {
        var orders: [JSONValue] = []
        for i in 0..<210 {
            orders.append(job("J-\(i)", "completed", String(format: "2026-%02d-%02d", (i / 28) + 1, (i % 28) + 1)))
        }
        let cut = BookScope.take(from: ["printLog": .array(orders)])
        // The ten oldest are left behind; the newest of them was 2026-01-10.
        #expect(cut.taken.collections["printLog"]?.keptAfter == "2026-01-10")
        let small = BookScope.take(from: ["printLog": .array(Array(orders.prefix(5)))])
        #expect(small.taken.collections["printLog"]?.keptAfter == nil)
    }

    @Test("the meters come with the count over the cut, to add the phone's jobs to")
    func metersHeldBesideMeters() {
        var orders: [JSONValue] = []
        for i in 0..<205 {
            orders.append(job("J-\(i)", "completed", String(format: "2026-%02d-%02d", (i / 28) + 1, (i % 28) + 1),
                              ["machineId": .string("m1"), "printTime": .number(1)]))
        }
        let cut = BookScope.take(from: ["printLog": .array(orders)])
        #expect(cut.taken.meters?["m1"] == 205)
        #expect(cut.taken.metersHeld?["m1"] == 200)
    }

    @Test("the owing set has its own ceiling, and says where it was cut")
    func owingIsCapped() {
        // A shop that never records payments: every finished job "may owe".
        var orders: [JSONValue] = []
        for i in 0..<1_100 {
            orders.append(job("U-\(i)", "completed", String(format: "20%02d-%02d-%02d", 20 + i / 336, (i / 28) % 12 + 1, (i % 28) + 1),
                              ["price": .number(50)]))
        }
        let cut = BookScope.take(from: ["printLog": .array(orders)])
        let held = cut.taken.collections["printLog"]
        #expect(held?.sent == BookScope.owingCap, "a book with no payments recorded travelled whole")
        #expect(held?.whole == false)
        #expect(held?.available == 1_100)
        #expect(held?.keptAfter != nil, "the phone was not told the owing set was cut")
        #expect(!ids(cut).contains("U-0"), "the oldest went first")
        #expect(ids(cut).contains("U-1099"))
    }

    @Test("with no stored status, a job paid its bare price may still owe tax on top")
    func noStatusLeavesRoomForTax() {
        #expect(BookScope.mayOwe(job("A", "completed", "2026-01-01", ["price": .number(100), "paidAmount": .number(100)])))
        #expect(!BookScope.mayOwe(job("B", "completed", "2026-01-01", ["price": .number(100), "paidAmount": .number(125)])))
        #expect(!BookScope.mayOwe(job("C", "completed", "2026-01-01", ["price": .number(100), "paidAmount": .number(100),
                                                                       "paymentStatus": .string("paid")])))
    }

    @Test("a scope from an older Mac, without the new fields, still decodes")
    func oldScopeDecodes() throws {
        let old = #"{"collections":{"printLog":{"whole":false,"sent":200,"available":900}},"omitted":[],"takenAt":"2026-10-01T00:00:00.000Z","meters":{"m1":12}}"#
        let taken = try JSONDecoder().decode(BookScope.Taken.self, from: Data(old.utf8))
        #expect(taken.collections["printLog"]?.keptAfter == nil)
        #expect(taken.metersHeld == nil)
        #expect(taken.meters?["m1"] == 12)
    }
}
