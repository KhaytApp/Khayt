import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The job inspector's "Next: ‹stage›" button and the invoice sheet's Share…
/// and Send with Pay Link.
///
/// The button is the Job menu's Move Along (and Delivered) under another name,
/// so what is pinned here is that it IS: the same target, hidden where the menu
/// greys out, and reached from the inspector rather than written beside it.
@MainActor
struct NextStepButtonTests {

    /// One job of each kind a book holds.
    static func job(_ id: String, _ status: String, extra: [String: JSONValue] = [:],
                    price: Double = 500, paid: Double = 0) -> [String: JSONValue] {
        var row: [String: JSONValue] = [
            "id": .string(id), "date": .string("2026-10-01"), "status": .string(status),
            "project": .string("Job \(id)"), "client": .string("Acme"),
            "price": .number(price), "paidAmount": .number(paid),
            "paymentStatus": .string(paid >= price ? "paid" : "unpaid"),
            "printTime": .number(1), "priority": .bool(false), "notes": .string(""), "rev": .number(1),
        ]
        for (k, v) in extra { row[k] = v }
        return row
    }

    static let jobs: [[String: JSONValue]] = [
        job("Q", "quote"),
        job("P", "pending"),
        job("H", "on_hold"),
        job("R", "printing"),
        job("O", "post"),
        job("I", "qc"),
        job("C", "completed"),
        job("S", "completed", extra: ["shippedAt": .string("2026-10-05")]),
        job("D", "completed", extra: ["shippedAt": .string("2026-10-05"), "deliveredAt": .string("2026-10-06")]),
        job("X", "cancelled"),
        job("PAID", "completed", paid: 500),
    ]

    /// What the button should offer, by job.
    static let expected: [String: NextStep?] = [
        "Q": .accept(.pending),
        "P": .move(.printing),
        "H": nil,                  // on hold: Move Along has no "along" there
        "R": .move(.post),
        "O": .move(.qc),
        "I": .move(.completed),
        "C": .deliver,
        "S": .deliver,
        "D": nil,                  // handed over: nothing left to do
        "X": nil,
        "PAID": .deliver,
    ]

    static func book(settings: JSONValue) -> [String: JSONValue] {
        var book = PerfBook.synthesize(models: 1)
        book["printLog"] = .array(jobs.map(JSONValue.object))
        book["settings"] = settings
        return book
    }

    // MARK: - wiring, read as source

    @Test("the inspector's button is the menu's Move Along, not a second path")
    func buttonIsWired() {
        let inspector = MenuCoverageTests.source("OrderInspector.swift")
        #expect(inspector.contains("shop.nextStep(for: job.id)"))
        #expect(inspector.contains("shop.takeNextStep(job.id)"))
        let menus = MenuCoverageTests.source("Menus.swift")
        #expect(menus.contains("shop.moveAlongTarget(shop.selection, by: delta)"))
        #expect(menus.contains("shop.moveAlong(shop.selection, by: delta)"))
        #expect(!menus.contains("here.stepped(by:"), "the menu no longer keeps its own copy of the rule")
        #expect(menus.contains("job.map(shop.canMarkDelivered)"))
        #expect(MenuCoverageTests.source("OrdersTable.swift").contains("shop.canMarkDelivered(job)"))
    }

    @Test("the invoice sheet offers Share and Send with Pay Link")
    func invoiceSheetIsWired() {
        let sheet = MenuCoverageTests.source("InvoiceSheet.swift")
        #expect(sheet.contains("\"mac.share\""))
        #expect(sheet.contains("Shop.presentSharePicker("))
        #expect(sheet.contains("shop.sharablePdf("))
        #expect(sheet.contains("shop.payLinkPlan(for: subject.id)"))
        #expect(sheet.contains("shop.sendWithPayLink("))
        // File ▸ Share… writes its PDF through the same function.
        #expect(MenuCoverageTests.source("Shop+Conventions.swift").contains("await sharablePdf("))
    }

    // MARK: - the sample book

    @Test("the sample book offers no move, as the menu greys every one")
    func sampleOffersNothing() async {
        let shop = Shop(source: .sample)
        await shop.load(.sample)
        #expect(!shop.canMoveJobs)
        #expect(!shop.orders.isEmpty)
        for job in shop.orders {
            #expect(shop.nextStep(for: job.id) == nil, Comment(rawValue: job.id))
            #expect(shop.moveAlongTarget(job.id, by: 1) == nil)
        }
    }

    // MARK: - pure rules

    @Test("Send with Pay Link needs an amount and a link")
    func payLinkNeedsBoth() throws {
        func plan(_ amount: Double, _ link: String) throws -> KhaytEngine.ReminderPlan {
            let json = #"{"channel":"whatsapp","amount":\#(amount),"milestones":[],"payLink":"\#(link)"}"#
            return try JSONDecoder().decode(KhaytEngine.ReminderPlan.self, from: Data(json.utf8))
        }
        #expect(Shop.offersPayLink(try plan(500, "https://pay.example/500.00")))
        #expect(!Shop.offersPayLink(try plan(500, "")))
        #expect(!Shop.offersPayLink(try plan(0, "https://pay.example/0.00")))
        #expect(!Shop.offersPayLink(nil))
    }
}

/// The cases on a real book — in `LibraryEditPerfTests`, the serialised suite
/// that owns the temp support folder (`withPerfBook`).
extension LibraryEditPerfTests {

    @Test("the button offers exactly what Move Along and Delivered would do, per stage")
    func nextStep_matchesTheMenu() async throws {
        let settings: JSONValue = .object(["currency": .string("SAR")])
        try await withPerfBook(NextStepButtonTests.book(settings: settings)) { shop, _ in
            #expect(shop.canMoveJobs, "a real book is ours to move")
            for (id, want) in NextStepButtonTests.expected {
                let got = shop.nextStep(for: id)
                #expect(got == want, Comment(rawValue: "\(id): \(String(describing: got))"))
                let job = try #require(shop.orders.first { $0.id == id })
                switch got {
                case .move(let stage)?, .accept(let stage)?:
                    // Exactly the menu's Move Along target.
                    #expect(shop.moveAlongTarget(id, by: 1) == stage)
                    #expect(!shop.canMarkDelivered(job))
                case .deliver?:
                    // Exactly where Job ▸ Delivered is enabled.
                    #expect(shop.canMarkDelivered(job))
                case nil:
                    #expect(!shop.canMarkDelivered(job))
                    #expect(shop.moveAlongTarget(id, by: 1) == nil)
                }
            }
            // Its words: the shared stage word, with nothing left to fill.
            let title = shop.nextStepTitle(.move(.printing))
            #expect(title.contains(shop.words.callIt("queue.printing")))
            #expect(!title.contains("{"))
            #expect(shop.nextStepTitle(.accept(.pending)) == shop.words.callIt("mac.accept_quote"))
            #expect(shop.nextStepTitle(.deliver) == shop.words.callIt("mac.mark_delivered"))
        }
    }

    @Test("Send with Pay Link is offered only when the job owes and the shop has a link")
    func nextStep_payLinkOffer() async throws {
        let settings: JSONValue = .object([
            "currency": .string("SAR"),
            "paymentProviders": .object(["moyasar": .object([
                "enabled": .bool(true), "payLink": .string("https://pay.example/{amount}")])]),
        ])
        try await withPerfBook(NextStepButtonTests.book(settings: settings)) { shop, _ in
            let owing = await shop.payLinkPlan(for: "C")
            #expect(owing?.payLink.hasPrefix("https://pay.example/") == true)
            #expect((owing?.amount ?? 0) > 0)
            #expect(await shop.payLinkPlan(for: "PAID") == nil, "nothing owed")
            #expect(await shop.payLinkPlan(for: "Q") == nil, "a quote is not chased for payment")
            #expect(await shop.payLinkPlan(for: "X") == nil, "nor cancelled work")
        }
        try await withPerfBook(NextStepButtonTests.book(settings: .object(["currency": .string("SAR")]))) { shop, _ in
            #expect(await shop.payLinkPlan(for: "C") == nil, "no pay link, no button")
        }
    }
}
