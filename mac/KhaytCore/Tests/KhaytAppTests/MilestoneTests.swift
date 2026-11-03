import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Milestones of a job: "Deposit 50%", then "On delivery 50%".
///
/// Each prints as a PROFORMA asking for that part. The data is the desktop's
/// (`order.milestoneInvoices`), the document is the shared module's
/// `milestone` option, and the job's one tax invoice is not touched.
@MainActor
@Suite(.serialized)
struct MilestoneTests {

    /// A job as the desktop writes one with a milestone on it — including a
    /// key (`paidAt`) and a field of its own (`note`) this app does not know.
    static func job(milestones: [JSONValue] = []) -> [String: JSONValue] {
        [
            "id": .string("J1"), "date": .string("2026-10-01"), "status": .string("pending"),
            "project": .string("Turbine bracket"), "client": .string("Acme"),
            "price": .number(1150), "paidAmount": .number(0), "paymentStatus": .string("unpaid"),
            "printTime": .number(1), "priority": .bool(false), "notes": .string(""),
            "rev": .number(1), "invoiceNote": .string("keep me"),
            "milestoneInvoices": .array(milestones),
        ]
    }

    static let deposit: JSONValue = .object([
        "id": .string("MS-LX1ABC"), "label": .string("Deposit 50%"), "percentage": .number(50),
        "amount": .number(575), "issuedAt": .string("2026-10-02"),
        "paidAt": .string("2026-10-03"), "note": .string("wire"),
    ])
    static let delivery: JSONValue = .object([
        "id": .string("MS-LX1DEF"), "label": .string("On delivery 50%"), "percentage": .number(50),
        "amount": .number(575), "extra": .object(["a": .number(1)]),
    ])

    // MARK: - the shape

    @Test("the shape is the desktop's, and a key this app does not know survives every edit")
    func shapeRoundTrip() throws {
        let order = JSONValue.object(Self.job(milestones: [Self.deposit, Self.delivery]))
        let read = Milestones.read(order)
        #expect(read.map(\.id) == ["MS-LX1ABC", "MS-LX1DEF"])
        #expect(read[0].label == "Deposit 50%")
        #expect(read[0].percentage == 50)
        #expect(read[0].amount == 575)
        #expect(read[0].issuedAt == "2026-10-02")
        #expect(read[1].issuedAt == nil)

        // Stamping sets ONE key on ONE entry.
        let stamped = Milestones.stamping("MS-LX1DEF", on: "2026-11-02", in: order)
        guard case .object(let o) = stamped, case .array(let list)? = o["milestoneInvoices"] else {
            Issue.record("not an order"); return
        }
        #expect(list[0] == Self.deposit, "the other milestone is untouched, paidAt and all")
        guard case .object(let second) = list[1] else { Issue.record("not a milestone"); return }
        #expect(second["issuedAt"] == .string("2026-11-02"))
        #expect(second["extra"] == .object(["a": .number(1)]), "an unknown key stays")
        #expect(o["invoiceNote"] == .string("keep me"), "so does the rest of the job")

        // Adding appends in the same five-key shape.
        let made = Milestone(id: "MS-NEW", label: "Final", percentage: 20, amount: 230)
        let added = Milestones.adding(made, to: stamped)
        #expect(Milestones.read(added).map(\.id) == ["MS-LX1ABC", "MS-LX1DEF", "MS-NEW"])
        guard case .object(let a) = added, case .array(let all)? = a["milestoneInvoices"],
              case .object(let fresh) = all[2] else { Issue.record("not an order"); return }
        #expect(Set(fresh.keys) == ["id", "label", "percentage", "amount"], "issuedAt only once it is produced")

        // Removing takes the one entry and nothing else.
        let removed = Milestones.removing("MS-LX1DEF", from: added)
        #expect(Milestones.read(removed).map(\.id) == ["MS-LX1ABC", "MS-NEW"])
        guard case .object(let r) = removed, case .array(let rest)? = r["milestoneInvoices"] else {
            Issue.record("not an order"); return
        }
        #expect(rest[0] == Self.deposit)
        #expect(r["invoiceNote"] == .string("keep me"))
    }

    @Test("an id looks like the desktop's uid('MS')")
    func ids() {
        let id = Milestones.newId()
        #expect(id.hasPrefix("MS-"))
        #expect(id.count >= 12)
        #expect(Milestones.newId() != id)
    }

    @Test("the amount starts as the percentage of the job's price, to the cent")
    func autoAmount() {
        #expect(Milestones.amount(percent: 50, of: 1150) == 575)
        #expect(Milestones.amount(percent: 33.333, of: 100) == 33.33)
        #expect(Milestones.amount(percent: 0, of: 1150) == 0)
        #expect(Milestones.amount(percent: .nan, of: 1150) == 0)
    }

    // MARK: - the paper

    @Test("a milestone's proforma is one line at its amount, titled a proforma, with no ZATCA QR")
    func thePaper() async throws {
        // `enableVat`/`vatRate` are what the shared tax engine reads the shop's
        // registration from; the document works the tax out on the amount itself.
        var paper = InvoiceTests.paper(settings: ["enableVat": .bool(true), "vatRate": .number(15)],
                                       order: ["invoiceNumber": .string("INV-2026-0042"),
                                               "invoiceNum": .string("INV-2026-0042")])
        paper.proforma = true
        paper.milestone = Milestone(id: "MS-1", label: "Deposit 50%", percentage: 50, amount: 250)
        let doc = try await InvoiceTests.build(paper)
        #expect(doc.html.contains("Deposit 50%"), "the label")
        #expect(doc.html.contains("250.00"), "the amount")
        #expect(doc.html.contains("50% of 575.00"), "and what it is a part of")
        #expect(!doc.html.contains("PETG-CF"), "the job's parts are not listed")
        #expect(!doc.html.contains("alt=\"ZATCA\""), "not a tax invoice")
        #expect(!doc.html.contains("qr-box"))
        #expect(doc.html.contains("proforma-watermark"))
        #expect(!doc.html.contains("INV-2026-0042"), "no invoice number")
        // The tax is on the amount (15% inclusive of 250), not on the job.
        #expect(doc.html.contains("32.61"))

        // And the job's own proforma is what it was.
        paper.milestone = nil
        let whole = try await InvoiceTests.build(paper)
        #expect(whole.html.contains("PETG-CF"))
        #expect(!whole.html.contains("Deposit 50%"))
    }

    // MARK: - the book

    /// The book's order `J1` as on disk now.
    static func onDisk(_ url: URL) throws -> [String: JSONValue] {
        let root = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
        let row = Shop.rows(root, "printLog").first { Shop.recordId($0) == "J1" }
        guard case .object(let o)? = row else { throw CocoaError(.fileReadCorruptFile) }
        return o
    }

    static func list(_ job: [String: JSONValue]) -> [JSONValue] {
        if case .array(let l)? = job["milestoneInvoices"] { return l }
        return []
    }

    @Test("adding, stamping and deleting write the book and keep what the desktop put there")
    func writesTheBook() async throws {
        var book = PerfBook.synthesize(models: 3)
        book["printLog"] = .array([.object(Self.job(milestones: [Self.deposit]))])
        try await withPerfBook(book) { shop, url in
            #expect(shop.milestones(of: "J1").map(\.id) == ["MS-LX1ABC"])

            // ADD.
            let added = await shop.addMilestone(to: "J1", label: "On delivery 50%", percentage: 50, amount: 575)
            #expect(added, Comment(rawValue: shop.moveProblem ?? "refused"))
            var disk = try Self.onDisk(url)
            #expect(Self.list(disk).count == 2)
            #expect(Self.list(disk)[0] == Self.deposit, "the desktop's milestone, paidAt and all")
            guard case .object(let fresh) = Self.list(disk)[1] else { Issue.record("not a milestone"); return }
            #expect(fresh["label"] == .string("On delivery 50%"))
            #expect(fresh["percentage"] == .number(50))
            #expect(fresh["amount"] == .number(575))
            guard case .string(let newId)? = fresh["id"] else { Issue.record("no id"); return }
            #expect(newId.hasPrefix("MS-"))
            #expect(disk["invoiceNote"] == .string("keep me"))
            #expect(shop.milestones(of: "J1").count == 2, "the window reads it back")

            // An empty label, or no money, writes nothing.
            #expect(await shop.addMilestone(to: "J1", label: "  ", percentage: 10, amount: 100) == false)
            #expect(await shop.addMilestone(to: "J1", label: "X", percentage: 10, amount: 0) == false)
            #expect(Self.list(try Self.onDisk(url)).count == 2)

            // PROFORMA: stamps the book's day on that one milestone, then shows it.
            shop.pendingMilestones = Shop.PendingHold(id: "J1", project: "Turbine bracket")
            await shop.showMilestoneProforma("J1", milestone: "MS-LX1ABC")
            disk = try Self.onDisk(url)
            guard case .object(let stamped) = Self.list(disk)[0] else { Issue.record("not a milestone"); return }
            #expect(stamped["issuedAt"] == .string(Calendar.book.dayString(Date())))
            #expect(stamped["paidAt"] == .string("2026-10-03"), "beside it, untouched")
            #expect(stamped["note"] == .string("wire"))
            #expect(shop.pendingMilestones == nil)
            #expect(shop.pendingInvoice?.proforma == true)
            #expect(shop.pendingInvoice?.milestone == "MS-LX1ABC")
            // It numbered nothing: the job has no invoice number now either.
            #expect(disk["invoiceNumber"] == nil)

            // DELETE.
            let deleted = await shop.deleteMilestone(from: "J1", milestone: newId)
            #expect(deleted)
            disk = try Self.onDisk(url)
            #expect(Self.list(disk).count == 1)
            guard case .object(let kept) = Self.list(disk)[0] else { Issue.record("not a milestone"); return }
            #expect(kept["id"] == .string("MS-LX1ABC"))
            #expect(kept["paidAt"] == .string("2026-10-03"))
        }
    }

    @Test("it is offered on the work a proforma is for, and a milestone writes through the one-order chain")
    func wired() throws {
        func job(_ status: String, price: Double = 100) throws -> Order {
            var j = Self.job()
            j["status"] = .string(status); j["price"] = .number(price)
            return try JSONDecoder().decode(Order.self, from: JSONEncoder().encode(j))
        }
        for s in ["pending", "printing", "on_hold"] { #expect(Shop.offersMilestones(try job(s)), "\(s)") }
        for s in ["quote", "completed", "cancelled"] { #expect(!Shop.offersMilestones(try job(s)), "\(s)") }
        #expect(!Shop.offersMilestones(try job("pending", price: 0)))

        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        let writes = try String(contentsOf: app.appending(path: "Shop+Milestones.swift"), encoding: .utf8)
        #expect(writes.components(separatedBy: "writeToOneOrder(").count - 1 == 3,
                "add, delete and stamp each go through the store chain")
        #expect(writes.contains("Calendar.book.dayString"))
        #expect(!writes.contains("Calendar.current"))
        for menu in ["OrdersTable.swift", "OrderInspector.swift"] {
            let text = try String(contentsOf: app.appending(path: menu), encoding: .utf8)
            #expect(text.contains("shop.showMilestones(job.id)"), "\(menu) does not offer Milestones")
        }
    }
}
