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
        for left in ["printFiles", "products", "expenses", "auditLog"] {
            #expect(cut.store[left] == nil, "\(left) travelled and no screen shows it")
            #expect(cut.taken.omitted.contains(left),
                    "\(left) was withheld silently — the phone cannot tell that from empty")
        }
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
