import Testing
import Foundation
@testable import KhaytApp
@testable import KhaytCore

/// Undo puts back only the FIELDS the action changed (`FieldUndo.swift`).
///
/// It used to put back the whole record as it was before the action and bump
/// `rev`, so anything written to that record in between — a delivery received
/// onto the spool, a phone's edit, another job's deduction — was silently
/// lost, and the stale copy then won on every other machine too.
@MainActor
struct FieldUndoTests {

    static func book() -> [String: JSONValue] {
        [
            "printLog": .array([
                .object([
                    "id": .string("J1"), "project": .string("Bracket"), "status": .string("printing"),
                    "price": .number(400), "rev": .number(3),
                    "parts": .array([.object([
                        "filamentId": .string("S1"), "printWeight": .number(200),
                        "qty": .number(1), "baseCost": .number(20),
                    ])]),
                    "printTime": .number(4),
                ]),
                .object([
                    "id": .string("J2"), "project": .string("Clip"), "status": .string("printing"),
                    "price": .number(100), "rev": .number(1),
                    "parts": .array([.object([
                        "filamentId": .string("S1"), "printWeight": .number(50),
                        "qty": .number(1), "baseCost": .number(5),
                    ])]),
                    "printTime": .number(1),
                ]),
            ]),
            "inventory": .array([
                .object(["id": .string("S1"), "material": .string("PLA"), "weight": .number(1000),
                         "rev": .number(1)]),
            ]),
            "consumables": .array([]), "machines": .array([]), "clients": .array([]),
            "wasteLog": .array([]),
            "purchaseOrders": .array([
                .object(["id": .string("PO1"), "status": .string("ordered"), "rev": .number(1)]),
            ]),
            "settings": .object(["autoDeduct": .bool(true)]),
        ]
    }

    static func weight(_ root: [String: JSONValue]) -> Double? {
        MoveJobTests.number(MoveJobTests.row(root, "inventory", "S1")?["weight"])
    }

    /// Someone else's write: change one record's fields and stamp it, the way
    /// a delivery, a phone fold or a cloud merge reaches the book.
    static func elsewhere(_ root: inout [String: JSONValue], _ collection: String, _ id: String,
                          _ change: (inout [String: JSONValue]) -> Void) {
        var rows = Shop.rows(root, collection)
        guard let at = rows.firstIndex(where: { Shop.recordId($0) == id }),
              case .object(var record) = rows[at] else { Issue.record("no \(id)"); return }
        change(&record)
        StoreWriter.stamp(&record)
        rows[at] = .object(record)
        root[collection] = .array(rows)
    }

    // MARK: - The spool

    @Test("a delivery received after a completion survives undoing the completion")
    func receiptSurvivesUndo() async throws {
        var root = Self.book()
        let (undo, _) = try await MoveJobTests.move(&root, "J1", .completed)
        #expect(Self.weight(root) == 800, "the completion took 200 g")

        // Receive 1000 g onto the same spool, and mark the order received.
        Self.elsewhere(&root, "inventory", "S1") { $0["weight"] = .number(1800) }
        Self.elsewhere(&root, "purchaseOrders", "PO1") { $0["status"] = .string("received") }

        let outcome = Shop.undoing(undo, in: &root)
        #expect(Self.weight(root) == 2000,
                "the 200 g the job took comes back ON TOP of the delivery — not 1000")
        #expect(MoveJobTests.string(MoveJobTests.row(root, "printLog", "J1")?["status"]) == "printing")
        #expect(MoveJobTests.string(MoveJobTests.row(root, "purchaseOrders", "PO1")?["status"]) == "received")
        #expect(outcome.notUndone.isEmpty, "\(outcome.notUndone)")
        // The usage line the completion added is gone; nothing else was there.
        if case .array(let history)? = MoveJobTests.row(root, "inventory", "S1")?["usageHistory"] {
            #expect(!history.contains { MoveJobTests.string(Shop.asObject($0)?["orderId"]) == "J1" })
        }
    }

    @Test("another job's deduction from the same spool survives undoing the first")
    func otherDeductionSurvives() async throws {
        var root = Self.book()
        let (first, _) = try await MoveJobTests.move(&root, "J1", .completed)
        _ = try await MoveJobTests.move(&root, "J2", .completed)
        #expect(Self.weight(root) == 750)

        let outcome = Shop.undoing(first, in: &root)
        #expect(Self.weight(root) == 950, "only J1's 200 g come back; J2's 50 g stay spent")
        #expect(outcome.notUndone.isEmpty, "\(outcome.notUndone)")
        // J2's usage line is still on the spool, J1's is not.
        guard case .array(let history)? = MoveJobTests.row(root, "inventory", "S1")?["usageHistory"] else {
            Issue.record("the usage history went"); return
        }
        let orders = history.compactMap { MoveJobTests.string(Shop.asObject($0)?["orderId"]) }
        #expect(orders == ["J2"])
    }

    @Test("redo of an undone completion takes the grams again, by the same delta")
    func redoIsFieldLevelToo() async throws {
        var root = Self.book()
        let (undo, _) = try await MoveJobTests.move(&root, "J1", .completed)
        let outcome = Shop.undoing(undo, in: &root)
        #expect(Self.weight(root) == 1000)
        Self.elsewhere(&root, "inventory", "S1") { $0["weight"] = .number(1500) }
        _ = Shop.undoing(outcome.redo, in: &root)
        #expect(Self.weight(root) == 1300)
        #expect(MoveJobTests.string(MoveJobTests.row(root, "printLog", "J1")?["status"]) == "completed")
    }

    @Test("a phone that re-opened the job and gave the grams back: undo does not give them back twice")
    func returnedElsewhereIsNotReturnedTwice() async throws {
        var root = Self.book()
        let (undo, _) = try await MoveJobTests.move(&root, "J1", .completed)
        #expect(Self.weight(root) == 800)
        // The phone re-opens the job through the shared returnForOrder: the
        // grams go back, the usage line goes, the job's deduction marks go.
        Self.elsewhere(&root, "printLog", "J1") {
            $0["status"] = .string("printing")
            $0["materialDeducted"] = nil
            $0["materialDrawn"] = nil
        }
        Self.elsewhere(&root, "inventory", "S1") {
            $0["weight"] = .number(1000)
            $0["usageHistory"] = .array([])
        }
        let outcome = Shop.undoing(undo, in: &root)
        #expect(Self.weight(root) == 1000, "the phone already put the 200 g back — not 1200")
        #expect(outcome.notUndone.contains("weight (S1)"), "\(outcome.notUndone)")
    }

    @Test("a sync tie that took the other copy of the spool: undo adds nothing it never took")
    func remoteSpoolWithoutTheDrawIsLeft() async throws {
        var root = Self.book()
        let (undo, _) = try await MoveJobTests.move(&root, "J1", .completed)
        // The job kept this Mac's copy, the spool took the other machine's:
        // 1000 g and no line for J1 — that copy never had the draw.
        Self.elsewhere(&root, "inventory", "S1") {
            $0["weight"] = .number(1000)
            $0["usageHistory"] = nil
        }
        let outcome = Shop.undoing(undo, in: &root)
        #expect(Self.weight(root) == 1000, "nothing was taken off this copy, so nothing comes back")
        #expect(MoveJobTests.string(MoveJobTests.row(root, "printLog", "J1")?["status"]) == "printing")
        #expect(outcome.notUndone.contains("weight (S1)"), "\(outcome.notUndone)")
    }

    // MARK: - The job

    @Test("a phone's edit to an unrelated field of the job survives undo")
    func phoneEditSurvives() async throws {
        var root = Self.book()
        let (undo, _) = try await MoveJobTests.move(&root, "J1", .completed)
        Self.elsewhere(&root, "printLog", "J1") {
            $0["notes"] = .string("customer called from the phone")
            $0["paidAmount"] = .number(150)
        }
        let outcome = Shop.undoing(undo, in: &root)
        let job = try #require(MoveJobTests.row(root, "printLog", "J1"))
        #expect(MoveJobTests.string(job["status"]) == "printing")
        #expect(MoveJobTests.string(job["notes"]) == "customer called from the phone")
        #expect(MoveJobTests.number(job["paidAmount"]) == 150, "a LAN payment is not undone with the move")
        #expect(job["completedAt"] == nil, "a field the move added is taken away again")
        #expect(outcome.notUndone.isEmpty)
        // The revision still goes forward, past the phone's write.
        #expect((MoveJobTests.number(job["rev"]) ?? 0) > 5)
    }

    @Test("a field someone else wrote since is left, and named")
    func conflictIsReported() async throws {
        var root = Self.book()
        let (undo, _) = try await MoveJobTests.move(&root, "J1", .completed)
        Self.elsewhere(&root, "printLog", "J1") { $0["status"] = .string("delivered") }
        let outcome = Shop.undoing(undo, in: &root)
        let job = try #require(MoveJobTests.row(root, "printLog", "J1"))
        #expect(MoveJobTests.string(job["status"]) == "delivered", "theirs stands")
        #expect(outcome.notUndone.contains("status (J1)"))
        #expect(Self.weight(root) == 1000, "while the rest of the undo still happens")

        let words = Words()
        let sentence = try #require(Shop.partialUndoSentence(outcome.notUndone, words: words))
        #expect(sentence.contains("status (J1)"))
        #expect(!sentence.contains("{fields}"))
    }

    @Test("undoing a completion takes its actual figures off the job")
    func actualsGoWithTheCompletion() async throws {
        var root = Self.book()
        let actuals = Shop.Actuals(hours: 4.5, grams: 230, timeSource: "printer", weightSource: "manual")
        let (undo, _) = try await MoveJobTests.move(&root, "J1", .completed, actuals: actuals)
        #expect(MoveJobTests.number(MoveJobTests.row(root, "printLog", "J1")?["actualWeight"]) == 230)

        _ = Shop.undoing(undo, in: &root)
        let job = try #require(MoveJobTests.row(root, "printLog", "J1"))
        #expect(job["actualWeight"] == nil)
        #expect(job["actualPrintTime"] == nil)
        #expect(job["actualsSource"] == nil)
    }

    // MARK: - QC failure

    static func failQc(_ root: inout [String: JSONValue]) async throws -> [Shop.ChangedRecord] {
        let engine = try KhaytEngine()
        let orders = Shop.rows(root, "printLog")
        let shelf = Shop.rows(root, "inventory")
        let out = try await engine.recordQcFailure(
            order: orders[0], failureType: "warping", severity: "major",
            reason: "Lifted", weight: 80, inspector: nil,
            inventory: shelf, now: Date(), wasteId: "W-1", defaultReason: "QC fail",
            settings: Shop.settings(root), machines: [], today: Shop.today())
        return Shop.writeQcFailure(&root, order: out.order, waste: out.waste,
                                   inventory: out.inventory, ordersBefore: orders, shelfBefore: shelf)
    }

    @Test("undoing a QC failure removes its waste row and puts the grams back")
    func qcUndoRemovesWaste() async throws {
        var root = Self.book()
        let undo = try await Self.failQc(&root)
        #expect(Shop.rows(root, "wasteLog").count == 1)
        #expect(Self.weight(root) == 920)

        let outcome = Shop.undoing(undo, in: &root)
        #expect(Shop.rows(root, "wasteLog").isEmpty, "the scrap the failure logged goes with it")
        #expect(Self.weight(root) == 1000)
        #expect(outcome.notUndone.isEmpty, "\(outcome.notUndone)")

        // And redo puts the row back.
        _ = Shop.undoing(outcome.redo, in: &root)
        #expect(Shop.rows(root, "wasteLog").map { Shop.recordId($0) } == ["W-1"])
        #expect(Self.weight(root) == 920)
    }

    @Test("a waste row edited since the failure is kept, and named")
    func qcEditedWasteStays() async throws {
        var root = Self.book()
        let undo = try await Self.failQc(&root)
        Self.elsewhere(&root, "wasteLog", "W-1") { $0["reason"] = .string("corrected on the phone") }
        let outcome = Shop.undoing(undo, in: &root)
        #expect(Shop.rows(root, "wasteLog").count == 1)
        #expect(outcome.notUndone.contains("W-1"))
    }

    // MARK: - Records the action deleted

    @Test("a record the action deleted comes back where it was, if still absent")
    func deletedComesBack() {
        var root: [String: JSONValue] = ["consumables": .array([
            .object(["id": .string("A")]), .object(["id": .string("C")]),
        ])]
        let gone = Shop.ChangedRecord(collection: "consumables", id: "B",
                                      was: ["id": .string("B"), "stock": .number(4)],
                                      kind: .deleted, at: 1)
        _ = Shop.undoing([gone], in: &root)
        #expect(Shop.rows(root, "consumables").map { Shop.recordId($0) } == ["A", "B", "C"])
        // Twice is still once.
        _ = Shop.undoing([gone], in: &root)
        #expect(Shop.rows(root, "consumables").count == 3)
    }

    @Test("an edit with no after-copy puts nothing back rather than a stale record")
    func unsealedIsNotRestoredWhole() {
        var root: [String: JSONValue] = ["clients": .array([
            .object(["id": .string("C1"), "name": .string("New"), "phone": .string("055")]),
        ])]
        let outcome = Shop.undoing([Shop.ChangedRecord(collection: "clients", id: "C1",
                                                       was: ["id": .string("C1"), "name": .string("Old")])],
                                   in: &root)
        #expect(MoveJobTests.string(MoveJobTests.row(root, "clients", "C1")?["phone"]) == "055")
        #expect(outcome.notUndone == ["C1"])
    }

    @Test("sealUndo reads each record's after-copy off the book")
    func sealing() {
        var root: [String: JSONValue] = ["clients": .array([
            .object(["id": .string("C1"), "name": .string("Old"), "rev": .number(1)]),
        ])]
        var undo = [Shop.ChangedRecord(collection: "clients", id: "C1",
                                       was: MoveJobTests.row(root, "clients", "C1")!)]
        Self.elsewhere(&root, "clients", "C1") { $0["name"] = .string("New") }
        Shop.sealUndo(&undo, in: root)
        #expect(MoveJobTests.string(undo[0].now?["name"]) == "New")
        // A phone adds a phone number; undo restores the name and keeps it.
        Self.elsewhere(&root, "clients", "C1") { $0["phone"] = .string("055") }
        _ = Shop.undoing(undo, in: &root)
        let c = MoveJobTests.row(root, "clients", "C1")
        #expect(MoveJobTests.string(c?["name"]) == "Old")
        #expect(MoveJobTests.string(c?["phone"]) == "055")
    }

    // MARK: - The library

    @Test("undoing a library edit keeps a field written since, and leaves a field changed since")
    func libraryUndoIsFieldLevel() {
        var root: [String: JSONValue] = [
            "printFiles": .array([.object(["id": .string("f1"), "name": .string("Bracket"),
                                           "group": .string("A"), "rev": .number(2)])]),
            "settings": .object([:]),
        ]
        let undo = Shop.applyFileEdit(&root, ids: ["f1"], alsoRoot: nil) {
            $0["favorite"] = .bool(true)
            $0["group"] = .string("B")
            $0["folder"] = .string("B")
        }
        // A remeasure writes dimensions; a phone moves it to C.
        Self.elsewhere(&root, "printFiles", "f1") {
            $0["dims"] = .string("10x20x30")
            $0["group"] = .string("C")
        }
        let redo = Shop.applyRestore(&root, undo)
        let f = MoveJobTests.row(root, "printFiles", "f1")
        #expect(f?["favorite"] == nil, "what the edit changed and nobody touched goes back")
        #expect(f?["folder"] == nil)
        #expect(MoveJobTests.string(f?["dims"]) == "10x20x30", "the remeasure survives")
        #expect(MoveJobTests.string(f?["group"]) == "C", "the phone's move stands")
        #expect(redo.notUndone == ["group (f1)"])
    }
}
