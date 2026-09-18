import XCTest
import KhaytCore
@testable import KhaytCompanion

/**
 * What this phone has changed, and what it must never claim to have changed.
 *
 * The second half is the reason these exist. The phone holds a working set —
 * a couple of hundred orders out of a shop's thousands — and computing "what
 * changed" by diffing that against anything is the shape of a mistake that
 * deletes a business's history. These pin the property that stops it.
 */
final class PendingChangesTests: XCTestCase {

    private var dir: URL!
    private var book: CompanionBook!
    private var reader: BookReader!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "outbox-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        book = CompanionBook(directory: dir)
        reader = BookReader(book: book)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// What the Mac hands over: two clients and one order.
    private func pulled() -> [String: JSONValue] {
        [
            "settings": .object(["shopName": .string("Ward")]),
            "clients": .array([
                .object(["id": .string("C-1"), "name": .string("Sara"), "rev": .number(1)]),
                .object(["id": .string("C-2"), "name": .string("Nora"), "rev": .number(1)]),
            ]),
            "printLog": .array([
                .object(["id": .string("O-1"), "status": .string("printing"),
                         "date": .string("2026-09-10"), "rev": .number(1)]),
            ]),
        ]
    }

    func testAFreshlyPulledBookHasNothingToSend() async throws {
        try book.replace(with: pulled(), scope: nil)
        let outbox = try await reader.pendingChanges()
        XCTAssertNotNil(outbox)
        XCTAssertTrue(outbox!.isEmpty,
                      "a phone that has only received has changes to send — the baseline is wrong")
        let pending = await reader.hasPendingChanges()
        XCTAssertFalse(pending)
    }

    func testAnEditOnThePhoneIsWhatTravels() async throws {
        try book.replace(with: pulled(), scope: nil)
        try book.updateRecord(collection: "clients", id: "C-1") { record in
            record["name"] = .string("Sara Al-Otaibi")
        }

        let produced = try await reader.pendingChanges()
        let outbox = try XCTUnwrap(produced)
        XCTAssertEqual(outbox.count, 1, "exactly one record changed, so exactly one should travel")

        guard case .object(let delta) = outbox.deltas[0],
              case .object(let record)? = delta["record"] else {
            return XCTFail("the delta is not in the shape applyDeltas consumes")
        }
        XCTAssertEqual(delta["collection"], .string("clients"))
        XCTAssertEqual(record["id"], .string("C-1"))
        XCTAssertEqual(record["name"], .string("Sara Al-Otaibi"))
        // The stamp is what makes the Mac accept it: applyDeltas keeps the
        // higher rev, so an unstamped edit would lose to the Mac's own copy.
        XCTAssertEqual(record["rev"], .number(2))
    }

    func testTheUNTOUCHEDRecordsStayHome() async throws {
        try book.replace(with: pulled(), scope: nil)
        try book.updateRecord(collection: "clients", id: "C-1") { $0["name"] = .string("Changed") }

        let produced = try await reader.pendingChanges()
        let outbox = try XCTUnwrap(produced)
        let ids = outbox.deltas.compactMap { d -> String? in
            guard case .object(let o) = d, case .object(let r)? = o["record"],
                  case .string(let id)? = r["id"] else { return nil }
            return id
        }
        XCTAssertEqual(ids, ["C-1"])
        XCTAssertFalse(ids.contains("C-2"), "an untouched record travelled — the whole book would go every time")
    }

    /// THE ONE THAT MATTERS.
    func testAPartialBookNeverAsksTheMacToDeleteWhatItDoesNotHold() async throws {
        // The phone was given a working set: one of the shop's three orders.
        // The Mac still has all three. If "what changed" were computed as a
        // symmetric difference, the two the phone never received would read as
        // deletions — and the shop would lose its history to a phone that was
        // only ever shown part of it.
        let wholeShop: [String: JSONValue] = [
            "clients": .array([.object(["id": .string("C-1"), "rev": .number(1)])]),
            "printLog": .array([
                .object(["id": .string("O-1"), "rev": .number(1)]),
                .object(["id": .string("O-2"), "rev": .number(1)]),
                .object(["id": .string("O-3"), "rev": .number(1)]),
            ]),
        ]
        let workingSet: [String: JSONValue] = [
            "clients": .array([.object(["id": .string("C-1"), "rev": .number(1)])]),
            "printLog": .array([.object(["id": .string("O-1"), "rev": .number(1)])]),
        ]

        // Baseline is the whole shop; the book is the narrower set. This is the
        // worst case the arrangement can produce.
        try book.replace(with: wholeShop, scope: nil)
        try book.replace(with: workingSet, scope: nil)
        // Put the wider store back as the baseline only, leaving the narrow book.
        try JSONEncoder().encode(wholeShop).write(to: book.baselineURL, options: [.atomic])

        let produced = try await reader.pendingChanges()
        let outbox = try XCTUnwrap(produced)
        XCTAssertTrue(outbox.tombstones.isEmpty,
                      "the phone asked the Mac to delete orders it was simply never given")
        XCTAssertTrue(outbox.deltas.isEmpty,
                      "nothing was edited, so nothing should travel")
    }

    func testAPhoneWithNoBookHasNothingToSay() async throws {
        // Not "no changes" — no baseline at all. The distinction matters: one is
        // a phone in step with its Mac, the other has never met one.
        let outbox = try await reader.pendingChanges()
        XCTAssertNil(outbox)
        let pending = await reader.hasPendingChanges()
        XCTAssertFalse(pending)
    }

    func testForgettingTakesTheBaselineToo() throws {
        try book.replace(with: pulled(), scope: nil)
        XCTAssertNotNil(book.baseline())
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.baselineURL.path))

        book.forget()

        // It is a second full copy of the shop's records. Leaving it behind at
        // unpair would keep the client list on the phone after the book is gone.
        XCTAssertNil(book.baseline())
        XCTAssertFalse(FileManager.default.fileExists(atPath: book.baselineURL.path))
    }
}
