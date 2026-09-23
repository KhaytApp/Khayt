import XCTest
import KhaytCore
@testable import KhaytCompanion

/**
 * Working with the Mac switched off.
 *
 * These are about the phone's half: an edit lands in the book, is stamped so it
 * can travel, shows up in the outbox, and stops being pending once the Mac has
 * taken it. What happens on the Mac is `LanServerTests`' job.
 */
final class OfflineWriteTests: XCTestCase {

    private var dir: URL!
    private var book: CompanionBook!
    private var writer: BookWriter!
    private var reader: BookReader!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "offline-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        book = CompanionBook(directory: dir)
        writer = BookWriter(book: book)
        reader = BookReader(book: book)
        try book.replace(with: shop(), scope: nil)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func shop() -> [String: JSONValue] {
        [
            "settings": .object(["shopName": .string("Ward")]),
            "printLog": .array([
                .object(["id": .string("O-1"), "status": .string("printing"),
                         "project": .string("Bracket"), "date": .string("2026-09-19"),
                         "machineId": .string("M-1"), "machine": .string("Bambu X1C"),
                         "rev": .number(3)]),
            ]),
            "inventory": .array([
                .object(["id": .string("S-1"), "material": .string("PLA"),
                         "weight": .number(640), "spoolWeight": .number(1000),
                         "rev": .number(1)]),
            ]),
            "machines": .array([
                .object(["id": .string("M-1"), "name": .string("Bambu X1C")]),
                .object(["id": .string("M-2"), "name": .string("Prusa CORE One")]),
            ]),
            "waitingList": .array([
                .object(["id": .string("W-1"), "status": .string("new"), "rev": .number(1)]),
            ]),
        ]
    }

    private func record(_ collection: String, _ id: String) throws -> [String: JSONValue] {
        guard case .array(let rows)? = try book.read()[collection] else { return [:] }
        for row in rows {
            if case .object(let o) = row, case .string(let rid)? = o["id"], rid == id { return o }
        }
        return [:]
    }

    func testAdvancingAJobLandsInTheBookAndIsStampedToTravel() async throws {
        try writer.setOrderStatus(orderId: "O-1", to: "qc")

        let order = try record("printLog", "O-1")
        XCTAssertEqual(order["status"], .string("qc"))
        // The stamp is what makes it reach the Mac at all: `changesToSend`
        // compares revisions and the fold keeps the higher one.
        XCTAssertEqual(order["rev"], .number(4))
        XCTAssertNotNil(order["updatedAt"])

        let produced = try await reader.pendingChanges()
        let outbox = try XCTUnwrap(produced)
        XCTAssertEqual(outbox.count, 1)
    }

    func testAssigningAPrinterWritesTheNameAsWellAsTheId() async throws {
        // The server looks the machine up and stores both. A record with only
        // the id reads as "Unassigned" on every screen not handed a machine list.
        let machines = try await reader.machines()
        try writer.assignMachine(orderId: "O-1", machineId: "M-2", machines: machines)

        let order = try record("printLog", "O-1")
        XCTAssertEqual(order["machineId"], .string("M-2"))
        XCTAssertEqual(order["machine"], .string("Prusa CORE One"))
    }

    func testTakingAJobOffAPrinterClearsBothFields() async throws {
        let machines = try await reader.machines()
        try writer.assignMachine(orderId: "O-1", machineId: nil, machines: machines)

        let order = try record("printLog", "O-1")
        XCTAssertEqual(order["machineId"], .null)
        XCTAssertEqual(order["machine"], .null, "the old printer's name outlived the assignment")
    }

    func testCorrectingASpoolWritesAllThreeNamesForWhatIsLeft() throws {
        // A record carrying the wire's name as well, stale. One name left
        // unwritten is enough to show the old figure: the model reads
        // `remaining ?? weightRemaining ?? weight`.
        try book.update { root in
            guard case .array(var rows)? = root["inventory"],
                  case .object(var spool) = rows[0] else { return }
            spool["weightRemaining"] = .number(640)
            spool["remaining"] = .number(640)
            rows[0] = .object(spool)
            root["inventory"] = .array(rows)
        }

        try writer.setSpoolRemaining(spoolId: "S-1", grams: 410)

        let spool = try record("inventory", "S-1")
        // The endpoint writes every one of them, and its own comment says why:
        // writing `remaining` alone meant the next print deducted from the
        // figure the shop had just replaced.
        XCTAssertEqual(spool["weight"], .number(410))
        XCTAssertEqual(spool["remaining"], .number(410))
        XCTAssertEqual(spool["weightRemaining"], .number(410),
                       "the wire's name kept the old figure, so the shelf and the deduction disagree")
        // And the full roll is untouched — they are different facts.
        XCTAssertEqual(spool["spoolWeight"], .number(1000))

        // What the model actually shows, which is the thing a shop reads.
        let spools = try JSONDecoder().decode(
            [InventorySpool].self,
            from: try JSONEncoder().encode(JSONValue.array([.object(spool)])))
        XCTAssertEqual(spools[0].remainingGrams, 410)
    }

    func testAnImpossibleCorrectionIsClampedTheWayTheEndpointClampsIt() throws {
        try writer.setSpoolRemaining(spoolId: "S-1", grams: -5)
        XCTAssertEqual(try record("inventory", "S-1")["weight"], .number(0))

        try writer.setSpoolRemaining(spoolId: "S-1", grams: 9_999_999)
        XCTAssertEqual(try record("inventory", "S-1")["weight"], .number(50_000),
                       "a correction of half a tonne is a typo, and the endpoint says so")
    }

    /// The endpoint MOVES a declined request: into `waitingListHistory` with a
    /// `declinedAt`, and out of `waitingList`. The phone makes the same move,
    /// and the removal travels as a tombstone.
    func testDecliningMovesTheRequestAndTheMoveReachesTheMac() async throws {
        let macCopy = try book.read()             // what the Mac holds before
        try writer.setWaitingStatus(id: "W-1", to: "declined")

        // On the phone: gone from the queue, in the history, with a tombstone.
        guard case .array(let queue)? = try book.read()["waitingList"] else { return XCTFail() }
        XCTAssertTrue(queue.isEmpty, "a declined request is not in the queue")
        let declined = try record("waitingListHistory", "W-1")
        XCTAssertEqual(declined["status"], .string("declined"))
        XCTAssertNotNil(declined["declinedAt"])
        guard case .array(let tombs)? = try book.read()["tombstones"], case .object(let t)? = tombs.first else {
            return XCTFail("no tombstone: the removal would never reach the Mac")
        }
        XCTAssertEqual(t["collection"], .string("waitingList"))
        XCTAssertEqual(t["rev"], .number(1), "the rev the phone saw, which the conflict check measures")

        // And through the shop's own fold: the Mac's copy ends up the same shape.
        let produced = try await reader.pendingChanges()
        let outbox = try XCTUnwrap(produced)
        XCTAssertEqual(outbox.tombstones.count, 1)
        let engine = try await reader.sharedEngine()
        let folded = try await engine.foldDeltas(base: macCopy, deltas: [outbox.wire]).store
        guard case .array(let macQueue)? = folded["waitingList"],
              case .array(let macHistory)? = folded["waitingListHistory"] else { return XCTFail("\(folded.keys)") }
        XCTAssertTrue(macQueue.isEmpty, "the Mac would otherwise put the request straight back in the queue")
        XCTAssertEqual(macHistory.count, 1)
    }

    func testDecliningARequestThatIsAlreadyGoneChangesNothing() throws {
        try writer.setWaitingStatus(id: "W-gone", to: "declined")
        XCTAssertNil(try book.read()["tombstones"])
        XCTAssertEqual(try record("waitingList", "W-1")["status"], .string("new"))
    }

    func testTheOtherTriageStatesAreOrdinaryEdits() throws {
        try writer.setWaitingStatus(id: "W-1", to: "reminded")
        XCTAssertEqual(try record("waitingList", "W-1")["status"], .string("reminded"))
        XCTAssertEqual(try record("waitingList", "W-1")["rev"], .number(2))
    }

    func testAPrinterTheShopDoesNotHaveIsRefused() async throws {
        let machines = try await reader.machines()
        // The endpoint answers 404 for this. Writing the id anyway would put a
        // job on a printer that is not there, and the row would read as
        // unassigned for ever after because no name resolves.
        XCTAssertThrowsError(
            try writer.assignMachine(orderId: "O-1", machineId: "M-NOPE", machines: machines)
        ) { error in
            XCTAssertEqual(error as? BookWriter.Refusal, .noSuchMachine)
        }
        // The job is still on the printer it was on.
        XCTAssertEqual(try record("printLog", "O-1")["machineId"], .string("M-1"))
        XCTAssertEqual(try record("printLog", "O-1")["machine"], .string("Bambu X1C"))
    }

    func testTwoEditsToOneRecordTravelAsOne() async throws {
        try writer.setOrderStatus(orderId: "O-1", to: "qc")
        try writer.setOrderStatus(orderId: "O-1", to: "completed")

        let produced = try await reader.pendingChanges()
        let outbox = try XCTUnwrap(produced)
        // One record changed, so one delta — carrying the latest state, not a
        // history of keystrokes.
        XCTAssertEqual(outbox.count, 1)
        XCTAssertEqual(try record("printLog", "O-1")["status"], .string("completed"))
        XCTAssertEqual(try record("printLog", "O-1")["rev"], .number(5))
    }

    func testEditsAcrossCollectionsAllTravel() async throws {
        try writer.setOrderStatus(orderId: "O-1", to: "qc")
        try writer.setSpoolRemaining(spoolId: "S-1", grams: 410)
        try writer.setWaitingStatus(id: "W-1", to: "reminded")

        let produced = try await reader.pendingChanges()
        let outbox = try XCTUnwrap(produced)
        XCTAssertEqual(outbox.count, 3)
    }

    func testOnceTheMacHasTakenThemNothingIsPendingAgain() async throws {
        try writer.setOrderStatus(orderId: "O-1", to: "qc")
        let before = try await reader.pendingChanges()
        XCTAssertEqual(try XCTUnwrap(before).count, 1)

        // What a confirmed send does.
        try book.markSynced()

        let after = try await reader.pendingChanges()
        XCTAssertTrue(try XCTUnwrap(after).isEmpty,
                      "the same edit would be sent again on the next connection")
        // And the edit is still in the book — synced, not discarded.
        XCTAssertEqual(try record("printLog", "O-1")["status"], .string("qc"))
    }

    func testAnEditMadeAfterSyncingIsPendingOnItsOwn() async throws {
        try writer.setOrderStatus(orderId: "O-1", to: "qc")
        try book.markSynced()
        try writer.setOrderStatus(orderId: "O-1", to: "completed")

        let produced = try await reader.pendingChanges()
        let outbox = try XCTUnwrap(produced)
        XCTAssertEqual(outbox.count, 1, "the baseline did not move with the sync")
    }

    func testEditsSurviveBeingClosedAndReopened() async throws {
        try writer.setOrderStatus(orderId: "O-1", to: "qc")

        // A different handle on the same directory — the phone was put down and
        // picked up again. An edit held only in memory would vanish here, and
        // the shop would have advanced a job that quietly did not move.
        let reopened = BookReader(book: CompanionBook(directory: dir))
        let produced = try await reopened.pendingChanges()
        XCTAssertEqual(try XCTUnwrap(produced).count, 1)
    }

    /// Edit offline, walk back into range, open a screen: the refresh that
    /// screen triggers used to REPLACE the book and take the edit with it.
    func testAPullFromTheMacKeepsAnEditNotYetSent() async throws {
        try writer.setOrderStatus(orderId: "O-1", to: "qc")         // rev 3 → 4, pending
        var fromMac = shop()
        // The Mac's copy moved on elsewhere too: a spool it corrected at rev 5.
        fromMac["inventory"] = .array([.object(["id": .string("S-1"), "material": .string("PLA"),
                                                "weight": .number(300), "rev": .number(5)])])
        try await reader.adopt(fromMac, scope: nil)

        XCTAssertEqual(try record("printLog", "O-1")["status"], .string("qc"), "the edit survived the pull")
        XCTAssertEqual(try record("inventory", "S-1")["weight"], .number(300), "and the Mac's own change arrived")
        let produced = try await reader.pendingChanges()
        XCTAssertEqual(try XCTUnwrap(produced).count, 1, "still on its way — and only it")
    }

    func testANewerChangeFromTheMacStillWins() async throws {
        try writer.setOrderStatus(orderId: "O-1", to: "qc")         // rev 4 here
        var fromMac = shop()
        fromMac["printLog"] = .array([.object(["id": .string("O-1"), "status": .string("completed"),
                                               "project": .string("Bracket"), "rev": .number(9)])])
        try await reader.adopt(fromMac, scope: nil)
        XCTAssertEqual(try record("printLog", "O-1")["status"], .string("completed"),
                       "the higher revision wins, as it does everywhere else")
    }
}
