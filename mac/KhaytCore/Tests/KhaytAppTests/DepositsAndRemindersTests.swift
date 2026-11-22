import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A portal deposit records itself, and reminders that work.
///
/// The decisions are `lib/portal-owner.js recordPortalPayment` and
/// `lib/payment-reminder.js` (held by Node tests); these pin what the Mac does
/// with them — the write, exactly once, the switches that gate Today, the
/// reminder record, and the milestone due date.
@MainActor
struct DepositsAndRemindersTests {

    static let settings: JSONValue = .object([
        "currency": .string("SAR"),
        "paymentReminder": .object(["enabled": .bool(true)]),
        "quoteFollowUp": .object(["enabled": .bool(true)]),
    ])

    static func quote() -> [String: JSONValue] {
        [
            "id": .string("Q1"), "date": .string("2026-10-01"), "status": .string("quote"),
            "project": .string("Lamp shade"), "client": .string("Sara"),
            "price": .number(1000), "paidAmount": .number(0), "paymentStatus": .string("unpaid"),
            "printTime": .number(1), "priority": .bool(false), "notes": .string(""), "rev": .number(1),
            "trackingToken": .string("tokQ1"), "cloudPublished": .bool(true), "cloudDeposit": .number(300),
        ]
    }

    /// A job a month past due, owing all of it.
    static func overdue() -> [String: JSONValue] {
        let due = Calendar.book.dayString(Date().addingTimeInterval(-30 * 86400))
        return [
            "id": .string("J1"), "date": .string("2026-09-01"), "status": .string("completed"),
            "project": .string("Bracket"), "client": .string("Acme"),
            "price": .number(500), "paidAmount": .number(0), "paymentStatus": .string("unpaid"),
            "printTime": .number(1), "priority": .bool(false), "notes": .string(""), "rev": .number(1),
            "dueDate": .string(due),
        ]
    }

    static func paid(ref: String, amount: String = "300") -> JSONValue {
        .array([.object([
            "token": .string("tokQ1"), "kind": .string("quote"), "action": .null,
            "payment": .object(["status": .string("paid"), "amount": .string(amount), "ref": .string(ref),
                                "at": .number(Date().timeIntervalSince1970 * 1000)]),
        ])])
    }

    static func onDisk(_ url: URL, _ id: String) throws -> [String: JSONValue] {
        let root = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
        guard case .object(let o)? = Shop.rows(root, "printLog").first(where: { Shop.recordId($0) == id })
        else { throw CocoaError(.fileReadCorruptFile) }
        return o
    }

    static func book(_ jobs: [[String: JSONValue]], settings: JSONValue = Self.settings) -> [String: JSONValue] {
        var book = PerfBook.synthesize(models: 1)
        book["printLog"] = .array(jobs.map(JSONValue.object))
        book["settings"] = settings
        return book
    }

    @Test("the portal is watched for published quotes and deposits still to come in")
    func whatIsWatched() {
        var paidIn = Self.quote()
        paidIn["status"] = .string("pending")
        paidIn["portalPayments"] = .array([.object(["key": .string("ref:x")])])
        var depositOpen = paidIn
        depositOpen["id"] = .string("Q2")
        depositOpen["portalPayments"] = nil
        var unpublished = Self.quote()
        unpublished["id"] = .string("Q3")
        unpublished["cloudPublished"] = .bool(false)
        let watched = Shop.portalJobsToWatch([Self.quote(), paidIn, depositOpen, unpublished].map(JSONValue.object))
        #expect(watched.map(\.id) == ["Q1", "Q2"])
    }

    @Test("the reminder asks for what is owed, in the job's words, with the shop's pay link")
    func reminderWords() async throws {
        let engine = try KhaytEngine()
        let settings: [String: JSONValue] = [
            "currency": .string("SAR"),
            "paymentProviders": .object(["moyasar": .object([
                "enabled": .bool(true), "payLink": .string("https://pay.example/{amount}")])]),
        ]
        let client: JSONValue = .object(["id": .string("C1"), "phone": .string("+966500000000")])
        let plan = try await engine.reminderPlan(order: .object(Self.overdue()), owed: 500,
                                                 settings: settings, client: client)
        #expect(plan.channel == "whatsapp")
        #expect(plan.amount == 500)
        #expect(plan.payLink == "https://pay.example/500.00")
        let text = try await engine.reminderText(
            body: "Hi {{client}}, {{price}} {{currency}} for {{id}}.",
            values: ["client": "Acme", "price": "500.00", "currency": "EUR", "id": "J1"],
            payLink: plan.payLink, payLabel: "Pay here:")
        #expect(text == "Hi Acme, 500.00 EUR for J1.\nPay here: https://pay.example/500.00")
        // A job in euros: the link is the shop's, so it charges riyals at the
        // job's saved rate, and with no saved rate there is no link.
        var euro = Self.overdue()
        euro["currency"] = .string("EUR")
        euro["fxRate"] = .number(4)
        let converted = try await engine.reminderPlan(order: .object(euro), owed: 500,
                                                      settings: settings, client: client)
        #expect(converted.payLink == "https://pay.example/2000.00")
        euro["fxRate"] = nil
        let unrated = try await engine.reminderPlan(order: .object(euro), owed: 500,
                                                    settings: settings, client: client)
        #expect(unrated.payLink.isEmpty)
        let marked = try await engine.markReminder(order: .object(Self.overdue()))
        guard case .object(let o) = marked else { Issue.record("not an order"); return }
        #expect(o["payReminderCount"] == .number(1))
    }
}

/// The tests that write a real book: in `LibraryEditPerfTests`, the one serialised
/// suite that owns the temp support folder (`withPerfBook`), so no other test
/// reads the book through that seam meanwhile.
extension LibraryEditPerfTests {

    @Test("a portal deposit is recorded on the job once, and said")
    func deposits_depositRecordsItselfOnce() async throws {
        try await withPerfBook(DepositsAndRemindersTests.book([DepositsAndRemindersTests.quote()])) { shop, url in
            let said = await shop.recordPortalDeposit("Q1", items: DepositsAndRemindersTests.paid(ref: "pay_1"), token: "tokQ1", quiet: false)
            #expect(said != nil, Comment(rawValue: shop.moveProblem ?? "nothing recorded"))
            var disk = try DepositsAndRemindersTests.onDisk(url, "Q1")
            #expect(disk["paidAmount"] == .number(300))
            #expect(disk["paymentStatus"] == .string("partial"))
            guard case .array(let log)? = disk["portalPayments"] else { Issue.record("no note"); return }
            #expect(log.count == 1)
            #expect(shop.moveNotices.contains { $0.contains("300") }, "the shop is told the amount")

            // Again — the button twice, or the timer after the button.
            let again = await shop.recordPortalDeposit("Q1", items: DepositsAndRemindersTests.paid(ref: "pay_1"), token: "tokQ1", quiet: true)
            #expect(again == nil)
            disk = try DepositsAndRemindersTests.onDisk(url, "Q1")
            #expect(disk["paidAmount"] == .number(300), "not doubled")
        }
    }

    @Test("a recorded portal deposit can be undone, and is never recorded again")
    func deposits_undoKeepsTheKey() async throws {
        var job = DepositsAndRemindersTests.quote()
        // Typed in by hand a month ago: outside the matching window.
        job["paidAmount"] = .number(300)
        job["paidAt"] = .string("2026-10-01")
        job["paymentStatus"] = .string("partial")
        try await withPerfBook(DepositsAndRemindersTests.book([job])) { shop, url in
            let items = DepositsAndRemindersTests.paid(ref: "pay_dup")
            #expect(await shop.recordPortalDeposit("Q1", items: items, token: "tokQ1", quiet: false) != nil)
            #expect(try DepositsAndRemindersTests.onDisk(url, "Q1")["paidAmount"] == .number(600))
            guard let undo = shop.portalDepositUndo else { Issue.record("no undo offered"); return }
            #expect(shop.undoablePortalDeposit("Q1") == undo.key)
            await shop.undoPortalDeposit("Q1", key: undo.key)
            let disk = try DepositsAndRemindersTests.onDisk(url, "Q1")
            #expect(disk["paidAmount"] == .number(300))
            guard case .array(let log)? = disk["portalPayments"], case .object(let note)? = log.first else {
                Issue.record("the note went"); return
            }
            #expect(note["outcome"] == .string("undone"))
            #expect(shop.undoablePortalDeposit("Q1") == nil)
            #expect(await shop.recordPortalDeposit("Q1", items: items, token: "tokQ1", quiet: true) == nil)
            #expect(try DepositsAndRemindersTests.onDisk(url, "Q1")["paidAmount"] == .number(300))
        }
    }

    @Test("a deposit the shop typed in by hand is noted, not added again")
    func deposits_handRecordedDepositIsNotDoubled() async throws {
        var job = DepositsAndRemindersTests.quote()
        job["paidAmount"] = .number(300)
        job["paidAt"] = .string(Calendar.book.dayString(Date()))
        job["paymentStatus"] = .string("partial")
        try await withPerfBook(DepositsAndRemindersTests.book([job])) { shop, url in
            let said = await shop.recordPortalDeposit("Q1", items: DepositsAndRemindersTests.paid(ref: "pay_2"), token: "tokQ1", quiet: false)
            #expect(said != nil)
            let disk = try DepositsAndRemindersTests.onDisk(url, "Q1")
            #expect(disk["paidAmount"] == .number(300))
            guard case .array(let log)? = disk["portalPayments"], case .object(let note)? = log.first else {
                Issue.record("not noted"); return
            }
            #expect(note["outcome"] == .string("matched"))
        }
    }

    @Test("the switches control Today's chase lists")
    func deposits_switchesGateToday() async throws {
        try await withPerfBook(DepositsAndRemindersTests.book([DepositsAndRemindersTests.overdue()])) { shop, _ in
            #expect(shop.invoicesToChase.map(\.id) == ["J1"])
        }
        let off: JSONValue = .object(["currency": .string("SAR")])
        try await withPerfBook(DepositsAndRemindersTests.book([DepositsAndRemindersTests.overdue()], settings: off)) { shop, _ in
            #expect(shop.invoicesToChase.isEmpty, "the switch is off")
            #expect(shop.quotesToChase.isEmpty)
        }
    }

    @Test("a sent reminder is recorded, so the cooldown takes it off Today")
    func deposits_reminderIsRecorded() async throws {
        try await withPerfBook(DepositsAndRemindersTests.book([DepositsAndRemindersTests.overdue()])) { shop, url in
            #expect(shop.invoicesToChase.map(\.id) == ["J1"])
            await shop.recordReminderSent("J1")
            let disk = try DepositsAndRemindersTests.onDisk(url, "J1")
            #expect(disk["payReminderCount"] == .number(1))
            #expect(disk["payRemindedAt"] != nil)
            #expect(shop.invoicesToChase.isEmpty, "inside the cooldown")
        }
    }

    @Test("a milestone gets a due date, and a due one is chased")
    func deposits_milestoneDueDate() async throws {
        let past = Calendar.book.dayString(Date().addingTimeInterval(-10 * 86400))
        var job = DepositsAndRemindersTests.overdue()
        job["dueDate"] = .string(Calendar.book.dayString(Date().addingTimeInterval(30 * 86400)))
        job["status"] = .string("printing")
        job["milestoneInvoices"] = .array([.object([
            "id": .string("MS-A"), "label": .string("Deposit"), "percentage": .number(40),
            "amount": .number(200), "note": .string("keep"),
        ])])
        try await withPerfBook(DepositsAndRemindersTests.book([job])) { shop, url in
            #expect(shop.invoicesToChase.isEmpty, "nothing is due yet")
            let day = Calendar.book.date(from: MilestonesSheet.parts(past))
            #expect(await shop.setMilestoneDue(on: "J1", milestone: "MS-A", day: day))
            let disk = try DepositsAndRemindersTests.onDisk(url, "J1")
            guard case .array(let list)? = disk["milestoneInvoices"], case .object(let m)? = list.first else {
                Issue.record("no milestone"); return
            }
            #expect(m["dueDate"] == .string(past))
            #expect(m["note"] == .string("keep"), "the rest of the row stays")
            #expect(shop.milestones(of: "J1").first?.dueDate == past)
            #expect(shop.invoicesToChase.map(\.id) == ["J1"], "the due milestone is chased")
            #expect(shop.invoicesToChase.first?.days == 10)

            #expect(await shop.setMilestoneDue(on: "J1", milestone: "MS-A", day: nil))
            #expect(shop.milestones(of: "J1").first?.dueDate == nil)
        }
    }
}
