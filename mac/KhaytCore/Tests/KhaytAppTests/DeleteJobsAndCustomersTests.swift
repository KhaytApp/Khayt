import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Deleting a job or a customer on the Mac (`Shop+Delete.swift`).
///
/// The RULE is tested in Node (`test/record-delete.test.js`), where it lives.
/// What is tested here: that this app greys Delete where the rule refuses and
/// says why, that the write — through `StoreWriter`, on a book on disk — takes
/// out only what the rule allows and tidies what pointed at it, that Undo puts
/// it back, that several chosen at once skip the refused ones and count them,
/// and that a customer with jobs is refused with the number.
@MainActor
struct DeleteJobsAndCustomersTests {

    // MARK: - a book on disk

    /// A quote with everything that can point at a job, an invoiced job, a
    /// paid job, and customers with and without work.
    static func book() -> [String: JSONValue] {
        func o(_ pairs: [String: JSONValue]) -> JSONValue { .object(pairs) }
        return [
            "printLog": .array([
                o(["id": .string("INV-2026-0001"), "status": .string("pending"),
                   "invoiceNum": .string("INV-2026-0001"), "project": .string("Bracket"),
                   "clientId": .string("C1")]),
                o(["id": .string("QUO-2026-0001"), "status": .string("quote"), "project": .string("Vase"),
                   "photos": .array([.string("QUO-2026-0001-0.jpg")]), "clientId": .string("C1")]),
                o(["id": .string("J-PAID"), "status": .string("completed"), "paidAmount": .number(40),
                   "project": .string("Lamp")]),
            ]),
            "inventory": .array([
                o(["id": .string("S1"), "material": .string("PLA"), "weight": .number(500),
                   "usageHistory": .array([
                    o(["orderId": .string("QUO-2026-0001"), "weightUsed": .number(12)]),
                    o(["orderId": .string("INV-2026-0001"), "weightUsed": .number(30)]),
                   ])]),
            ]),
            "expenses": .array([
                o(["id": .string("E1"), "orderId": .string("QUO-2026-0001"), "amount": .number(25)]),
                o(["id": .string("E2"), "orderId": .string("INV-2026-0001"), "amount": .number(9)]),
            ]),
            "wasteLog": .array([o(["id": .string("W1"), "orderId": .string("QUO-2026-0001"), "weight": .number(40)])]),
            "timeEntries": .array([o(["id": .string("T1"), "orderId": .string("QUO-2026-0001"), "hours": .number(2)])]),
            "clients": .array([
                o(["id": .string("C1"), "nameEn": .string("Nouf")]),
                o(["id": .string("C2"), "nameEn": .string("Hind")]),
                o(["id": .string("C3"), "nameEn": .string("Reem")]),
            ]),
            "giftCards": .array([o(["id": .string("G1"), "issuedTo": .string("C3"), "balance": .number(50)])]),
            "settings": .object([:]),
        ]
    }

    static func scratch(_ root: [String: JSONValue]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-delete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "khayt-store.json")
        try JSONValue.encode(.object(root)).write(to: url)
        return url
    }

    static func onDisk(_ url: URL) throws -> [String: JSONValue] {
        guard case .object(let root) = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        else { return [:] }
        return root
    }

    static func ids(_ root: [String: JSONValue], _ c: String) -> [String] {
        MoveJobTests.rows(root, c).compactMap { MoveJobTests.string($0["id"]) }
    }

    static func deleteJobs(_ ids: [String], at url: URL) async throws -> KhaytEngine.Deleted {
        let engine = try KhaytEngine()
        var out: KhaytEngine.Deleted?
        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            out = try await Shop.applyJobDeletes(to: &root, ids: ids, engine: engine)
        }
        return try #require(out)
    }

    // MARK: - the tidy-up, on a book on disk

    @Test("only the quote goes: its expense, usage, waste and time rows stay, unlinked")
    func onlyTheJobGoes() async throws {
        let url = try Self.scratch(Self.book())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let out = try await Self.deleteJobs(["QUO-2026-0001"], at: url)
        #expect(out.deletedIds == ["QUO-2026-0001"])
        #expect(out.skipped.isEmpty)

        let after = try Self.onDisk(url)
        #expect(Self.ids(after, "printLog") == ["INV-2026-0001", "J-PAID"])
        let spool = try #require(MoveJobTests.row(after, "inventory", "S1"))
        guard case .array(let usage)? = spool["usageHistory"] else { Issue.record("no usage"); return }
        #expect(usage.count == 2, "a usage row was removed")
        let mine = try #require(usage.compactMap(Shop.asObject).first { MoveJobTests.number($0["weightUsed"]) == 12 })
        #expect(mine["orderId"] == .null)
        #expect(Self.ids(after, "expenses") == ["E1", "E2"], "an expense was removed")
        let expense = try #require(MoveJobTests.row(after, "expenses", "E1"))
        #expect(expense["orderId"] == .null)
        #expect(expense["amount"] == .number(25))
        // The invoiced job's own links are untouched.
        #expect(MoveJobTests.string(try #require(MoveJobTests.row(after, "expenses", "E2"))["orderId"]) == "INV-2026-0001")
        let waste = try #require(MoveJobTests.row(after, "wasteLog", "W1"))
        #expect(waste["orderId"] == .null)
        #expect(waste["weight"] == .number(40), "the waste entry lost its figure")
        let time = try #require(MoveJobTests.row(after, "timeEntries", "T1"))
        #expect(time["orderId"] == .null)
        #expect(time["hours"] == .number(2))
        // The delete is recorded, so another device drops the job too.
        let tombs = MoveJobTests.rows(after, "tombstones")
        #expect(tombs.contains { MoveJobTests.string($0["id"]) == "QUO-2026-0001"
                                 && MoveJobTests.string($0["collection"]) == "printLog" })
        #expect(!tombs.contains { MoveJobTests.string($0["collection"]) != "printLog" },
                "a row other than the job was deleted")
        #expect(Self.ids(after, "clients") == ["C1", "C2", "C3"])
    }

    @Test("deleting a quote leaves the expenses total and the spool's remaining unchanged")
    func moneyAndFilamentUnchanged() async throws {
        let url = try Self.scratch(Self.book())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        func totals(_ root: [String: JSONValue]) -> (spent: Double, remaining: Double?, used: Double) {
            let spent = Shop.decode(root, "expenses", as: Expense.self).reduce(0) { $0 + $1.amount }
            let spool = MoveJobTests.row(root, "inventory", "S1")
            var history: [JSONValue] = []
            if case .array(let h)? = spool?["usageHistory"] { history = h }
            let used = history.compactMap(Shop.asObject)
                .reduce(0) { $0 + (MoveJobTests.number($1["weightUsed"]) ?? 0) }
            return (spent, MoveJobTests.number(spool?["weight"]), used)
        }
        let before = totals(try Self.onDisk(url))
        _ = try await Self.deleteJobs(["QUO-2026-0001"], at: url)
        let after = totals(try Self.onDisk(url))
        #expect(before.spent == 34)
        #expect(after.spent == before.spent, "the P&L's expenses moved")
        #expect(after.remaining == before.remaining, "the spool's remaining moved")
        #expect(after.remaining == 500)
        #expect(after.used == before.used, "the spool's record of use moved")
    }

    @Test("Undo puts the job back and relinks every row, re-pointed at it")
    func undoRestores() async throws {
        let url = try Self.scratch(Self.book())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let out = try await Self.deleteJobs(["QUO-2026-0001"], at: url)

        let engine = try KhaytEngine()
        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            try await Shop.applyJobRestore(to: &root, deleted: out.deleted, engine: engine)
        }
        let after = try Self.onDisk(url)
        let log = MoveJobTests.rows(after, "printLog")
        #expect(log.count == 3)
        // Back where it was, under a fresh id (the delete has already been
        // synced as final), with its photos — and its rows point at the new id.
        let back = try #require(log.first { MoveJobTests.string($0["project"]) == "Vase" })
        let newId = try #require(MoveJobTests.string(back["id"]))
        #expect(MoveJobTests.string(log[1]["project"]) == "Vase")
        #expect(back["photos"] == .array([.string("QUO-2026-0001-0.jpg")]))
        let spool = try #require(MoveJobTests.row(after, "inventory", "S1"))
        guard case .array(let usage)? = spool["usageHistory"] else { Issue.record("no usage"); return }
        #expect(usage.count == 2)
        let mine = try #require(usage.compactMap(Shop.asObject).first { MoveJobTests.number($0["weightUsed"]) == 12 })
        #expect(MoveJobTests.string(mine["orderId"]) == newId)
        #expect(MoveJobTests.rows(after, "expenses").count == 2)
        let expense = try #require(MoveJobTests.row(after, "expenses", "E1"))
        #expect(MoveJobTests.string(expense["orderId"]) == newId)
        let waste = try #require(MoveJobTests.row(after, "wasteLog", "W1"))
        #expect(MoveJobTests.string(waste["orderId"]) == newId)
        let time = try #require(MoveJobTests.row(after, "timeEntries", "T1"))
        #expect(MoveJobTests.string(time["orderId"]) == newId)
    }

    // MARK: - several at once

    @Test("several chosen: only the deletable go, and the refused are counted")
    func multiSelectSkips() async throws {
        let url = try Self.scratch(Self.book())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let out = try await Self.deleteJobs(["INV-2026-0001", "QUO-2026-0001", "J-PAID"], at: url)
        #expect(out.deletedIds == ["QUO-2026-0001"])
        #expect(out.skipped.map(\.id) == ["INV-2026-0001", "J-PAID"])
        #expect(out.skipped.map(\.reason) == ["invoiced", "paid"])
        let after = try Self.onDisk(url)
        #expect(Self.ids(after, "printLog") == ["INV-2026-0001", "J-PAID"])
        // The refused jobs keep their links.
        #expect(MoveJobTests.string(try #require(MoveJobTests.row(after, "expenses", "E2"))["orderId"]) == "INV-2026-0001")
    }

    @Test("nothing deletable: nothing is taken out, nothing is tombstoned")
    func noneDeletableChangesNothing() async throws {
        let url = try Self.scratch(Self.book())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let out = try await Self.deleteJobs(["INV-2026-0001", "J-PAID"], at: url)
        #expect(out.deleted.isEmpty)
        #expect(out.skipped.count == 2)
        let after = try Self.onDisk(url)
        #expect(Self.ids(after, "printLog") == ["INV-2026-0001", "QUO-2026-0001", "J-PAID"])
        #expect(Self.ids(after, "expenses") == ["E1", "E2"])
        #expect(MoveJobTests.rows(after, "tombstones").isEmpty)
    }

    @Test("the question names the jobs, what goes, what stays and what was left out")
    func theQuestion() {
        let book = Self.book()
        let words = Words()
        let lines = Shop.jobDeleteLines(
            ids: ["QUO-2026-0001"], names: ["Vase", "Bowl"], skipped: 2,
            inventory: MoveJobTests.rowValues(book, "inventory"),
            expenses: MoveJobTests.rowValues(book, "expenses"),
            unlinked: [MoveJobTests.rowValues(book, "wasteLog"), MoveJobTests.rowValues(book, "timeEntries")],
            words: words)
        let text = lines.joined(separator: "\n")
        #expect(text.contains("\u{2022} Vase") && text.contains("\u{2022} Bowl"))
        #expect(text.contains("Nothing goes but the job itself"), "\(text)")
        // One usage row, one expense, one waste and one time entry.
        #expect(text.contains("stay in the books, unlinked (4)"), "\(text)")
        #expect(text.contains("invoiced or paid: 2"), "\(text)")
        #expect(text.contains(words.callIt("mac.undo_after")))
    }

    @Test("the jobs list's chosen rows keep the job in front among them")
    func selectionFollows() async {
        let shop = await MacConventionsTests.sample()
        let ids = Array(shop.orders.prefix(3).map(\.id))
        shop.selectJobs(Set(ids))
        #expect(shop.jobSelection == Set(ids))
        #expect(shop.selection.map(ids.contains) == true)
        // A job selected elsewhere (the board, a link) is the whole selection.
        let other = try? #require(shop.orders.dropFirst(5).first?.id)
        shop.selection = other
        #expect(shop.jobSelection == Set([other].compactMap { $0 }))
        shop.selection = nil
        #expect(shop.jobSelection.isEmpty)
    }

    // MARK: - gating

    @Test("Delete is greyed with the reason where the rule refuses, and off on a read-only book")
    func gating() async throws {
        let shop = await MacConventionsTests.sample()
        let verdicts = try #require(shop.deleteVerdicts, "the rule was not read with the book")
        let paid = try #require(shop.orders.first { verdicts.orders[$0.id] == "paid" })
        let quote = try #require(shop.orders.first { $0.status == "quote" && verdicts.orders[$0.id] == nil })
        #expect(shop.jobDeleteRefusal(paid.id) == shop.words.callIt("mac.delete_job_paid"))
        #expect(shop.jobDeleteRefusal(quote.id) == nil)

        // The sample book is read-only: nothing is offered, and asking says so.
        #expect(!shop.mayDeleteJobs)
        shop.shelf = .jobs(nil)
        shop.selection = quote.id
        #expect(shop.frontJobIds == [quote.id])
        #expect(shop.deleteTarget == nil, "a read-only book offers Delete")
        shop.askToDeleteJobs([quote.id])
        #expect(shop.pendingJobDelete == nil)
        #expect(shop.moveProblem != nil)
        // And the write itself refuses.
        shop.moveProblem = nil
        await shop.deleteJobs([quote.id])
        #expect(shop.orders.contains { $0.id == quote.id })
    }

    @Test("the refusal sentences have English and Arabic")
    func translated() {
        for key in ["mac.delete_job_invoiced", "mac.delete_job_paid", "mac.cancel_job", "mac.delete_refused",
                    "mac.delete_jobs_title", "mac.delete_jobs_goes",
                    "mac.delete_jobs_unlinked", "mac.delete_jobs_skipped", "mac.delete_jobs_none",
                    "mac.deleted_jobs", "mac.customer_has_jobs", "mac.customer_has_cards",
                    "mac.delete_customers_title", "mac.delete_customers_goes", "mac.delete_customers_skipped",
                    "mac.delete_customers_none", "mac.deleted_customers", "mac.delete_portal_kept"] {
            let entry = Words.own[key]
            #expect(entry?["en"]?.isEmpty == false, "\(key) en")
            #expect(entry?["ar"]?.isEmpty == false, "\(key) ar")
            #expect(entry?["ar"] != entry?["en"], "\(key) ar is English")
        }
    }

    // MARK: - customers

    @Test("a customer with jobs or a gift card is refused; one with nothing goes")
    func customerRefusal() async throws {
        let url = try Self.scratch(Self.book())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = try KhaytEngine()
        var out: KhaytEngine.Deleted?
        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            out = try await Shop.applyCustomerDeletes(to: &root, ids: ["C1", "C2", "C3"], engine: engine)
        }
        let done = try #require(out)
        #expect(done.deletedIds == ["C2"])
        let nouf = try #require(done.skipped.first { $0.id == "C1" })
        #expect(nouf.reason == "has_jobs")
        #expect(nouf.jobs == 2, "the refusal does not count the customer's jobs")
        #expect(done.skipped.first { $0.id == "C3" }?.reason == "has_gift_cards")
        let after = try Self.onDisk(url)
        #expect(Self.ids(after, "clients") == ["C1", "C3"])
        // Their jobs and cards are untouched.
        #expect(Self.ids(after, "printLog").count == 3)
        #expect(Self.ids(after, "giftCards") == ["G1"])
    }

    @Test("the customers screen says how many jobs a refused customer has")
    func customerSentence() async throws {
        let shop = await MacConventionsTests.sample()
        let busy = try #require(shop.shownCustomers.first { $0.jobCount >= 3 })
        let why = try #require(shop.customerDeleteRefusal(busy))
        #expect(why.contains("\(busy.jobCount)"), "\(why)")
        shop.shelf = .customers
        shop.customerSelection = busy.id
        #expect(shop.frontCustomerIds == [busy.id])
        #expect(shop.deleteTarget == nil)
        shop.askToDeleteCustomers([busy.id])
        #expect(shop.pendingCustomerDelete == nil)
        #expect(shop.moveProblem != nil)
    }

    // MARK: - wiring

    @Test("⌫, ⌘⌫ and the context menus reach the same doors, behind the question")
    func wired() throws {
        let menus = try QuoteSheetStatusTests.source("Menus.swift")
        #expect(menus.contains("shop.askToDeleteFrontmost()"))
        #expect(menus.contains(".disabled(shop.deleteTarget == nil)"))
        for file in ["OrdersTable.swift", "CustomersTable.swift", "Kanban.swift"] {
            #expect(try QuoteSheetStatusTests.source(file).contains(".onDeleteCommand { shop.askToDeleteFrontmost() }"),
                    "\(file)")
        }
        let jobs = try QuoteSheetStatusTests.source("OrdersTable.swift")
        #expect(jobs.contains("JobDeleteItems(shop: shop, ids: [job.id])"), "the job menu has no Delete")
        #expect(jobs.contains("shop.cancelInstead(id)"), "a refused job is not offered Cancel")
        let window = try QuoteSheetStatusTests.source("ShopWindow.swift")
        #expect(window.contains(".askFirst($shop.pendingJobDelete"))
        #expect(window.contains(".askFirst($shop.pendingCustomerDelete"))
    }
}
