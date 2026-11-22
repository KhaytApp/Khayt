import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The desktop's order tools on the Mac: the whole order editor, voiding an
/// invoice, a credit note, an RMA, a manual reprint, the timeline and edit
/// history, and the job intake waiting list.
///
/// Each write is driven against a book in memory through the same static
/// function the app's write runs, with the real shared rules underneath — so
/// what is asserted is the record the other app would read.
@MainActor
struct OrderToolsTests {

    static func book() -> [String: JSONValue] {
        [
            "printLog": .array([.object([
                "id": .string("ORD-1"), "project": .string("Lamp"), "status": .string("completed"),
                "date": .string("2026-11-01"), "price": .number(230), "shippingCost": .number(30),
                "discountPct": .number(0), "paidAmount": .number(0), "paymentStatus": .string("unpaid"),
                "material": .string("PLA"), "machineId": .string("M1"),
                "deliveredAt": .string("2026-11-03T10:00:00.000Z"),
                "parts": .array([.object(["id": .string("P1"), "name": .string("Shade"),
                                          "printWeight": .number(120), "qty": .number(1)])]),
                "statusHistory": .array([
                    .object(["status": .string("pending"), "at": .string("2026-11-01T08:00:00.000Z")]),
                    .object(["status": .string("completed"), "at": .string("2026-11-02T08:00:00.000Z")]),
                ]),
            ])]),
            "wasteLog": .array([]), "inventory": .array([]), "consumables": .array([]),
            "clients": .array([.object(["id": .string("C1"), "nameEn": .string("Sara"), "phone": .string("+9665")])]),
            "waitingList": .array([
                .object(["id": .string("W1"), "project": .string("Vase"), "priority": .string("normal"),
                         "status": .string("active"), "clientName": .string("Noor"),
                         "notes": .string("Tall and blue"), "phone": .string("+9661")]),
                .object(["id": .string("W2"), "project": .string("Bracket"), "priority": .string("urgent"),
                         "status": .string("active"), "estValue": .number(50)]),
            ]),
            "waitingListHistory": .array([]),
            "settings": .object(["currency": .string("SAR")]),
        ]
    }

    static func job(_ root: [String: JSONValue], _ id: String = "ORD-1") -> [String: JSONValue] {
        Shop.rows(root, "printLog").first { Shop.recordId($0) == id }.flatMap(Shop.asObject) ?? [:]
    }

    // MARK: - The order editor

    @Test("the order editor writes notes, tags and the address, and re-prices for a discount")
    func editor() async throws {
        let engine = try KhaytEngine()
        let order = Shop.rows(Self.book(), "printLog")[0]
        let out = try await engine.editOrderDetails(
            order: order,
            fields: ["notes": .string("Gift wrap"), "tags": .string("resin, gift"),
                     "deliveryAddress": .string("Riyadh"), "discountPct": .number(10),
                     "internalNotes": .string("")],
            now: Date(), editId: "edit-1", priceId: "edit-2")
        #expect(out.changed)
        let o = Shop.asObject(out.order) ?? [:]
        #expect(o["notes"] == .string("Gift wrap"))
        #expect(o["tags"] == .array([.string("gift"), .string("resin")]))
        #expect(o["deliveryAddress"] == .string("Riyadh"))
        #expect(o["internalNotes"] == nil, "empty means gone, the shape the desktop writes")
        // 200 of goods at 10% off, plus the 30 shipping.
        #expect(o["price"] == .number(210))
        #expect(o["priceBeforeDiscount"] == .number(200))
        guard case .array(let history)? = o["editHistory"] else { Issue.record("no edit history"); return }
        #expect(history.count == 1)
    }

    @Test("the sheet hands over only what the shop changed")
    func onlyChanged() {
        var opened = OrderDetailsSheet.opening(Self.job(Self.book()))
        opened.lines = []
        var now = opened
        #expect(OrderDetailsSheet.fields(opened: opened, now: now).isEmpty, "opened and closed writes nothing")
        now.trackingNumber = "  TRK1 "
        now.lines = [OrderDetailsSheet.Line(label: "Paint", amount: 25)]
        let fields = OrderDetailsSheet.fields(opened: opened, now: now)
        #expect(Set(fields.keys) == ["trackingNumber", "extraLines"])
        #expect(fields["trackingNumber"] == .string("TRK1"))
        guard case .array(let lines)? = fields["extraLines"], case .object(let line)? = lines.first else {
            Issue.record("no extra line"); return
        }
        #expect(line["amount"] == .number(25))
        #expect(line["id"] != nil, "a new line gets an id, as the desktop's does")
    }

    @Test("an inactive operator still on the job stays offered")
    func operatorKept() {
        let rows: [JSONValue] = [
            .object(["id": .string("OP1"), "name": .string("Ali")]),
            .object(["id": .string("OP2"), "name": .string("Huda"), "active": .bool(false)]),
        ]
        #expect(OrderDetailsSheet.operatorChoices(rows, current: "").map(\.id) == ["OP1"])
        #expect(OrderDetailsSheet.operatorChoices(rows, current: "OP2").map(\.id) == ["OP1", "OP2"])
    }

    // MARK: - Void and credit

    @Test("a void stamps the job, keeps its status, and books the waste row")
    func void() async throws {
        let engine = try KhaytEngine()
        var root = Self.book()
        let undo = try await Shop.applyVoid(&root, id: "ORD-1", reason: "duplicate", logWaste: true,
                                            engine: engine, now: Date(), wasteId: "W-9", today: "2026-11-05",
                                            wasteNote: "voided", refused: "no", gone: "gone")
        let o = Self.job(root)
        #expect(o["voidedAt"] != nil)
        #expect(o["voidedReason"] == .string("duplicate"))
        #expect(o["status"] == .string("completed"))
        #expect(o["paymentStatus"] == .string("voided"))
        let waste = Shop.rows(root, "wasteLog")
        #expect(waste.count == 1)
        #expect(Shop.asObject(waste[0])?["weight"] == .number(120))
        #expect(undo.contains { $0.collection == "wasteLog" && $0.kind == .created })
        #expect(undo.contains { $0.collection == "printLog" && $0.kind == .edited })
        var refusedAgain = false
        do {
            _ = try await Shop.applyVoid(&root, id: "ORD-1", reason: "", logWaste: false, engine: engine,
                                         now: Date(), wasteId: "x", today: "2026-11-05", wasteNote: "",
                                         refused: "no", gone: "gone")
        } catch is Shop.MoveRefused { refusedAgain = true }
        #expect(refusedAgain, "a voided invoice cannot be voided twice")
    }

    @Test("a credit note is capped at what is left, and in full the job reads credited")
    func credit() async throws {
        let engine = try KhaytEngine()
        var root = Self.book()
        let first = try await Shop.applyCredit(&root, id: "ORD-1", amount: 200, reason: "defect", engine: engine,
                                               now: Date(), noteId: "CN-a", nothing: "none", gone: "gone")
        #expect(Shop.asObject(first.note ?? .null)?["amount"] == .number(200))
        #expect(Self.job(root)["creditedAt"] == nil)
        #expect(Self.job(root)["paidAmount"] == .number(0), "a credit never touches what was paid")
        let second = try await Shop.applyCredit(&root, id: "ORD-1", amount: 500, reason: "", engine: engine,
                                                now: Date(), noteId: "CN-b", nothing: "none", gone: "gone")
        #expect(Shop.asObject(second.note ?? .null)?["amount"] == .number(30))
        #expect(Self.job(root)["creditedAt"] != nil)
        var refused = false
        do {
            _ = try await Shop.applyCredit(&root, id: "ORD-1", amount: 1, reason: "", engine: engine,
                                           now: Date(), noteId: "CN-c", nothing: "none", gone: "gone")
        } catch is Shop.MoveRefused { refused = true }
        #expect(refused, "nothing is left to credit")
    }

    @Test("the credit note document names the invoice it reverses")
    func creditDocument() async throws {
        let engine = try KhaytEngine()
        var root = Self.book()
        let out = try await Shop.applyCredit(&root, id: "ORD-1", amount: 60, reason: "defect", engine: engine,
                                             now: Date(), noteId: "CN-a", nothing: "none", gone: "gone")
        let doc = try await engine.creditNoteHtml(
            order: .object(Self.job(root)), note: out.note ?? .null, settings: [:], language: "en",
            shopName: "Athar", currencySymbol: "SAR", invoiceNumber: "INV-2026-0001", jobRef: "ORD-1",
            clientName: "Sara", clientSub: "", today: "2026-11-05")
        #expect(doc.html.contains("CN-ORD-1"))
        #expect(doc.html.contains("INV-2026-0001"))
        #expect(doc.html.contains("Credit Note"))
        #expect(doc.html.contains("60.00"))
    }

    // MARK: - RMA and reprint

    @Test("an RMA reprint within warranty makes a free linked job and links it back")
    func rmaReprint() async throws {
        let engine = try KhaytEngine()
        var root = Self.book()
        let made = try await Shop.applyRma(&root, id: "ORD-1", reason: "split", resolution: "reprint",
                                           within: true, reportedBy: nil, engine: engine, now: Date(), gone: "gone")
        let newId = try #require(made)
        let original = Self.job(root)
        guard case .object(let rma)? = original["rma"] else { Issue.record("no rma"); return }
        #expect(rma["resolution"] == .string("reprint"))
        #expect(rma["reprintId"] == .string(newId))
        let reprint = Self.job(root, newId)
        #expect(reprint["reprintOf"] == .string("ORD-1"))
        #expect(reprint["reprintReason"] == .string("rma"))
        #expect(reprint["price"] == .number(0), "within warranty the shop pays")
    }

    @Test("an RMA refund only records the RMA")
    func rmaRefund() async throws {
        let engine = try KhaytEngine()
        var root = Self.book()
        let made = try await Shop.applyRma(&root, id: "ORD-1", reason: "", resolution: "refund",
                                           within: false, reportedBy: "OP1", engine: engine, now: Date(), gone: "gone")
        #expect(made == nil)
        #expect(Shop.rows(root, "printLog").count == 1)
        guard case .object(let rma)? = Self.job(root)["rma"] else { Issue.record("no rma"); return }
        #expect(rma["reportedBy"] == .string("OP1"))
        #expect(rma["reason"] == .null)
    }

    @Test("a manual reprint is a billable linked job")
    func manualReprint() async throws {
        let engine = try KhaytEngine()
        var root = Self.book()
        let made = try await Shop.linkReprint(&root, of: "ORD-1", orders: Shop.rows(root, "printLog"),
                                              reason: "manual", cost: "billable", engine: engine, now: Date())
        let newId = try #require(made)
        let reprint = Self.job(root, newId)
        #expect(reprint["reprintReason"] == .string("manual"))
        #expect(reprint["reprintCost"] == .string("billable"))
        #expect(reprint["reprintNoCharge"] == nil)
        #expect(Self.job(root)["reprintedInto"] == .array([.string(newId)]))
    }

    // MARK: - History

    @Test("the timeline and edit history read the job's own records")
    func history() async throws {
        let engine = try KhaytEngine()
        var order = Self.job(Self.book())
        order["editHistory"] = .array([.object([
            "id": .string("e1"), "at": .string("2026-11-02T09:00:00.000Z"),
            "fields": .object(["dueDate": .object(["from": .null, "to": .string("2026-11-09")])]),
        ])])
        let log = try await engine.editLog(.object(order))
        #expect(log.count == 1)
        #expect(log[0].fields.map(\.field) == ["dueDate"])
        #expect(log[0].fields.first?.from == "")
        #expect(log[0].fields.first?.to == "2026-11-09")
        #expect(Shop.historyFieldKey("dueDate") == "doc.due")
        let line = try await engine.orderTimeline(.object(order), now: Date())
        #expect(line.steps.map(\.status) == ["pending", "completed"])
        #expect(line.steps[0].ms == 86_400_000)
        #expect(line.steps[1].current)
        #expect(line.totalMs == 86_400_000)
        #expect(OrderHistorySheet.span(86_400_000 + 3_600_000 * 4, locale: Locale(identifier: "en")).contains("4"))
    }

    // MARK: - The waiting list

    @Test("the waiting list shows the most urgent first and counts the funnel")
    func intakeList() async throws {
        let engine = try KhaytEngine()
        let root = Self.book()
        let shown = try await engine.intakeVisible(Shop.rows(root, "waitingList"))
        #expect(shown.compactMap(Shop.recordId) == ["W2", "W1"])
        let funnel = try await engine.intakeFunnel(list: Shop.rows(root, "waitingList"), history: [])
        #expect(funnel.total == 2)
        #expect(funnel.pipeline == 50)
    }

    @Test("saving, declining and deleting enquiries write the list and an undo for each")
    func intakeWrites() async throws {
        let engine = try KhaytEngine()
        var root = Self.book()
        let saved = try await engine.intakeSave(list: Shop.rows(root, "waitingList"),
                                                fields: ["project": .string("Sign"), "priority": .string("high")],
                                                id: nil, newId: "W3", now: Date())
        var undo = Shop.writeIntakeLists(&root, list: saved.list ?? [], history: nil)
        #expect(undo.map(\.kind) == [.created])
        #expect(Shop.recordId(Shop.rows(root, "waitingList")[0]) == "W3")

        let declined = try await engine.intakeDeclined(list: Shop.rows(root, "waitingList"), id: "W1")
        undo = Shop.writeIntakeLists(&root, list: declined, history: nil)
        #expect(undo.map(\.kind) == [.edited])
        #expect(undo.first?.id == "W1")

        let removed = Shop.rows(root, "waitingList").filter { Shop.recordId($0) != "W2" }
        undo = Shop.writeIntakeLists(&root, list: removed, history: nil)
        #expect(undo.map(\.kind) == [.deleted])
        #expect(undo.first?.at == 2)

        let refused = try await engine.intakeSave(list: [], fields: ["project": .string("  ")],
                                                  id: nil, newId: "x", now: Date())
        #expect(refused.ok == false && refused.error == "project_required")
    }

    @Test("promoting an enquiry moves it to the history and finds or makes its customer")
    func intakePromote() async throws {
        let engine = try KhaytEngine()
        var root = Self.book()
        let out = try #require(try await engine.intakePromote(
            list: Shop.rows(root, "waitingList"), history: [], clients: Shop.rows(root, "clients"),
            id: "W1", newClientId: "CLI-new", now: Date()))
        #expect(out.clientId == "CLI-new")
        #expect(Shop.asObject(out.createdClient ?? .null)?["nameEn"] == .string("Noor"))
        #expect(out.note == "Tall and blue\nPhone: +9661")
        let undo = Shop.writeIntakeLists(&root, list: out.list, history: out.history)
        #expect(Shop.rows(root, "waitingList").compactMap(Shop.recordId) == ["W2"])
        let moved = Shop.rows(root, "waitingListHistory")
        #expect(Shop.asObject(moved[0])?["status"] == .string("converted"))
        #expect(undo.contains { $0.collection == "waitingList" && $0.kind == .deleted })
        #expect(undo.contains { $0.collection == "waitingListHistory" && $0.kind == .created })
    }
}
