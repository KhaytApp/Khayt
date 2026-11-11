import XCTest
import KhaytCore
@testable import KhaytCompanion

/// `baseRev` on `POST /api/store/deltas` (Mac review fixes, Nov 10): each
/// delta of a record this phone edited says which `rev` the edit started
/// from, so a Mac whose copy moved on (a payment taken at the desk) keeps its
/// own instead of being replaced by an edit made from a stale copy.
final class DeltaBaseRevTests: XCTestCase {

    private var dir: URL!
    private var book: CompanionBook!
    private var reader: BookReader!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "baserev-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        book = CompanionBook(directory: dir)
        reader = BookReader(book: book)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func job(rev: Double, paid: Double = 0) -> JSONValue {
        .object(["id": .string("J-1"), "status": .string("printing"), "paidAmount": .number(paid), "rev": .number(rev)])
    }

    private func pulled(_ job: JSONValue) -> [String: JSONValue] {
        ["settings": .object(["shopName": .string("Ward")]), "clients": .array([]), "printLog": .array([job])]
    }

    /// The delta for `J-1` as it would go on the wire.
    private func sentDelta(_ id: String = "J-1") async throws -> [String: JSONValue] {
        let snapshot = try await reader.pendingSnapshot()
        let pending = try XCTUnwrap(snapshot)
        let wire = BookReader.wire(pending.outbox, baseRevs: pending.baseRevs)
        guard case .array(let deltas)? = wire["deltas"] else { throw XCTSkip("no deltas") }
        for case .object(let d) in deltas {
            if case .object(let r)? = d["record"], r["id"] == .string(id) { return d }
        }
        XCTFail("no delta for \(id) in \(deltas)")
        return [:]
    }

    func testAnEditSaysTheRevItStartedFrom() async throws {
        try book.replace(with: pulled(job(rev: 7)), scope: nil)
        try book.updateRecord(collection: "printLog", id: "J-1") { $0["status"] = .string("qc") }
        let d = try await sentDelta()
        XCTAssertEqual(d["baseRev"], .number(7))
        guard case .object(let r)? = d["record"] else { return XCTFail() }
        XCTAssertNil(r["baseRev"], "on the delta, not in the record")
    }

    /// The case the field exists for: a pull lands between the phone's edits
    /// and moves the baseline up to the Mac's newer copy. The edit still
    /// started from 7, and says so.
    func testAPullBetweenEditsDoesNotHideTheStaleBase() async throws {
        try book.replace(with: pulled(job(rev: 7)), scope: nil)
        try book.updateRecord(collection: "printLog", id: "J-1") { $0["status"] = .string("qc") }
        try book.updateRecord(collection: "printLog", id: "J-1") { $0["status"] = .string("done") }
        // Measured once (a badge refresh), then the Mac's copy moves to 8 at the desk.
        _ = try await reader.pendingChanges()
        try await reader.adopt(pulled(job(rev: 8, paid: 50)), scope: nil)

        let d = try await sentDelta()
        XCTAssertEqual(d["baseRev"], .number(7), "the baseline's rev is now 8; the edit was made from 7")
    }

    /// Noted at the first measurement whatever triggers it: the pull itself
    /// measures before it moves the baseline.
    func testAPullIsItselfAMeasurement() async throws {
        try book.replace(with: pulled(job(rev: 7)), scope: nil)
        try book.updateRecord(collection: "printLog", id: "J-1") { $0["status"] = .string("qc") }
        try book.updateRecord(collection: "printLog", id: "J-1") { $0["status"] = .string("done") }
        try await reader.adopt(pulled(job(rev: 8, paid: 50)), scope: nil)
        let d = try await sentDelta()
        XCTAssertEqual(d["baseRev"], .number(7))
    }

    func testARecordThisPhoneCreatedCarriesNone() async throws {
        try book.replace(with: pulled(job(rev: 7)), scope: nil)
        try book.appendRecord(collection: "printLog", record: ["id": .string("J-NEW"), "status": .string("quote"),
                                                              "rev": .number(1)])
        let d = try await sentDelta("J-NEW")
        XCTAssertNil(d["baseRev"])
    }

    func testOnceUpstreamTakesItTheNextEditStartsFromTheNewCopy() async throws {
        try book.replace(with: pulled(job(rev: 7)), scope: nil)
        try book.updateRecord(collection: "printLog", id: "J-1") { $0["status"] = .string("qc") }
        let snapshot = try await reader.pendingSnapshot()
        let first = try XCTUnwrap(snapshot)
        XCTAssertEqual(first.baseRevs["printLog/J-1"], 7)
        try book.markSynced(first.book)
        XCTAssertEqual(book.baseRevs(), [:])

        try book.updateRecord(collection: "printLog", id: "J-1") { $0["status"] = .string("done") }
        guard case .number(let sentRev)? = { () -> JSONValue? in
            if case .array(let rows)? = first.book["printLog"], case .object(let o)? = rows.first { return o["rev"] }
            return nil
        }() else { return XCTFail("no rev") }
        let d = try await sentDelta()
        XCTAssertEqual(d["baseRev"], .number(sentRev))
    }

    func testNotesForEditsNoLongerPendingAreDropped() {
        let outbox = KhaytEngine.Outbox(deltas: [], tombstones: [], cursor: .null, settingsDiffer: false)
        XCTAssertEqual(BookReader.baseRevs(of: outbox, baseline: [:], held: ["printLog/J-1": 7]), [:])
    }

    func testUnpairingForgetsTheNotes() async throws {
        try book.replace(with: pulled(job(rev: 7)), scope: nil)
        try book.updateRecord(collection: "printLog", id: "J-1") { $0["status"] = .string("qc") }
        _ = try await reader.pendingChanges()
        XCTAssertFalse(book.baseRevs().isEmpty)
        book.forget()
        XCTAssertFalse(FileManager.default.fileExists(atPath: book.baseRevsURL.path))
    }

    /// The real send puts the noted revs on the wire.
    func testTheSendUsesTheWireWithBaseRevs() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "KhaytCompanion/Services/KhaytAPIClient.swift"), encoding: .utf8)
        let send = try XCTUnwrap(src.range(of: "func sendPendingChanges("))
        let body = String(src[send.lowerBound...].prefix(1500))
        XCTAssertTrue(body.contains("BookReader.wire(outbox, baseRevs: baseRevs)"), body)
    }
}
