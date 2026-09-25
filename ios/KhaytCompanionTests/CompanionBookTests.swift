import XCTest
import KhaytCore
@testable import KhaytCompanion

/**
 * The phone's copy of the shop's book.
 *
 * Every test here runs against a real file in a temp directory, because the
 * thing being tested IS the file handling — a write path proved only against a
 * mock has not been proved.
 */
final class CompanionBookTests: XCTestCase {

    private var dir: URL!
    private var book: CompanionBook!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "book-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        book = CompanionBook(directory: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func shop() -> [String: JSONValue] {
        [
            "settings": .object(["shopName": .string("Ward"), "enableVat": .bool(true),
                                 "vatRate": .number(15)]),
            "clients": .array([.object(["id": .string("C-1"), "name": .string("Sara"),
                                        "rev": .number(3)])]),
            "inventory": .array([]),
        ]
    }

    func testAPhoneWithNoBookSaysSoRatherThanPretendingItIsEmpty() {
        // The distinction that matters at pairing: a shop with no clients and a
        // phone that has never been given the book look identical if this
        // returns [:]. One is a shop; the other is a setup step nobody did.
        XCTAssertFalse(book.exists)
        XCTAssertThrowsError(try book.read()) { error in
            XCTAssertEqual((error as? CompanionBook.Failure)?.description,
                           CompanionBook.Failure.notYetPulled.description)
        }
    }

    func testTheFirstPullLandsAndComesBackWhole() throws {
        try book.replace(with: shop(), scope: nil)
        XCTAssertTrue(book.exists)

        let back = try book.read()
        XCTAssertEqual(back["settings"], shop()["settings"],
                       "the book did not survive the round trip value for value")
        XCTAssertEqual(back["clients"], shop()["clients"])
    }

    func testAnEditIsStampedSoTheMacCanHearAboutIt() throws {
        try book.replace(with: shop(), scope: nil)
        try book.updateRecord(collection: "clients", id: "C-1") { record in
            record["name"] = .string("Sara Al-Otaibi")
        }

        let clients = try book.read()["clients"]
        guard case .array(let rows) = clients, case .object(let sara) = rows[0] else {
            return XCTFail("the client went missing in the edit")
        }
        XCTAssertEqual(sara["name"], .string("Sara Al-Otaibi"))
        // The whole reason an edit on the phone is syncable at all: `lib/sync.js`
        // decides what to send by comparing revisions, so an edit that left `rev`
        // at 3 is an edit the Mac would never ask for.
        XCTAssertEqual(sara["rev"], .number(4), "the edit was not stamped, so it will never sync")
        XCTAssertNotNil(sara["updatedAt"], "a stamped record carries when it changed")
    }

    func testTheBookKeepsOneGenerationOfRollback() throws {
        try book.replace(with: shop(), scope: nil)
        try book.update { root in root["clients"] = .array([]) }

        // `.prev` is what a corrupt primary is recovered from, and it is the
        // writer's doing rather than this file's — which is the point of
        // writing through it instead of `Data.write`.
        let prev = book.url.appendingPathExtension("prev")
        XCTAssertTrue(FileManager.default.fileExists(atPath: prev.path),
                      "no rollback copy was left behind")
    }

    func testForgettingLeavesNoClientListOnThePhone() throws {
        try book.replace(with: shop(), scope: nil)
        try book.update { root in root["clients"] = .array([]) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.url.appendingPathExtension("prev").path))

        book.forget()

        // Both copies, not just the live one. An unpaired phone that still had
        // `.prev` would still have the shop's client list on it.
        XCTAssertFalse(book.exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: book.url.appendingPathExtension("prev").path),
                       "unpairing left the rollback copy, which holds the same names")
    }

    func testAPartialBookNeverReadsAsACompleteOne() throws {
        // The failure this guards against: the phone holds 200 of a shop's 3,140
        // orders, a screen totals what it has, and a three-year-old shop is
        // reported as having done 200 jobs.
        let scope = BookScope.Taken(
            collections: [
                "printLog": .init(whole: false, sent: 200, available: 3_140),
                "clients": .init(whole: true, sent: 31, available: nil),
            ],
            omitted: ["printFiles", "auditLog"],
            takenAt: "2026-09-18T09:00:00.000Z")
        try book.replace(with: shop(), scope: scope)

        XCTAssertFalse(book.holdsAll("printLog"), "a windowed collection must never claim to be whole")
        XCTAssertTrue(book.holdsAll("clients"), "a complete collection should be usable for totals")
        XCTAssertEqual(book.scope()?.collections["printLog"]?.available, 3_140,
                       "the phone cannot say \"200 of 3,140\" without being told the 3,140")
    }

    func testNotKnowingWhatIsMissingIsNotTheSameAsHavingEverything() throws {
        // A book written with no scope beside it — an older build, an
        // interrupted pull. The safe answer to "may I total this?" is no.
        try book.replace(with: shop(), scope: nil)
        XCTAssertNil(book.scope())
        XCTAssertFalse(book.holdsAll("clients"),
                       "a phone with no idea what it is missing claimed to hold everything")
    }

    func testForgettingTakesTheScopeWithTheBook() throws {
        let scope = BookScope.Taken(collections: ["clients": .init(whole: true, sent: 31, available: nil)],
                                    omitted: [], takenAt: "2026-09-18T09:00:00.000Z")
        try book.replace(with: shop(), scope: scope)
        XCTAssertNotNil(book.scope())

        book.forget()

        // It names the shop's collections and how many records of each this
        // phone was carrying. Leaving it behind at unpair leaks the shape of a
        // business even once the records are gone.
        XCTAssertNil(book.scope())
        XCTAssertFalse(FileManager.default.fileExists(atPath: book.scopeURL.path))
    }

    func testTheCountShownAtPairingCountsRecordsAndNotSettings() {
        // What the pairing screen says arrived. `settings` is one object, not a
        // list of records, and counting its keys would inflate the number —
        // a shop with three clients would be told it received a dozen things.
        let store: [String: JSONValue] = [
            "settings": .object(["shopName": .string("Ward"), "vatRate": .number(15),
                                 "currency": .string("SAR")]),
            "clients": .array([.object(["id": .string("c1")]), .object(["id": .string("c2")])]),
            "printLog": .array([.object(["id": .string("o1")])]),
            "inventory": .array([]),
        ]
        XCTAssertEqual(KhaytAPIClient.recordCount(in: store), 3)
        XCTAssertEqual(KhaytAPIClient.recordCount(in: [:]), 0)
    }

    func testTheEngineCanWorkFromTheBookWithNoDesktopInReach() async throws {
        // The two halves together, which is the whole thesis: the phone holds
        // the book, the phone holds the engine, so the phone can work out a
        // figure with nothing to ask.
        try book.replace(with: shop(), scope: nil)
        let settings = try book.read()["settings"]
        guard case .object(let fields) = settings else { return XCTFail("no settings in the book") }

        let engine = try KhaytEngine()
        let profile = try await engine.taxProfile(settings: fields)
        let split = try await engine.computeTax(1000, profile: profile)

        XCTAssertEqual(split.subtotal, 869.57, accuracy: 0.0001)
        XCTAssertEqual(split.taxTotal, 130.43, accuracy: 0.0001)
    }

    // MARK: - Folding in, without losing what was written meanwhile

    private func shopWith(_ ids: [String]) -> [String: JSONValue] {
        ["settings": .object([:]),
         "printLog": .array(ids.map { .object(["id": .string($0), "status": .string("pending"), "rev": .number(1)]) })]
    }

    /// A fold that finishes after something was written here must not land:
    /// the record added meanwhile is not in what it folded, and landing it
    /// would delete that record.
    func testAFoldDoesNotLandOverAWriteMadeWhileItWasFolding() throws {
        try book.replace(with: shopWith(["A"]), scope: nil)
        let snapshot = try book.read()
        // Written on the phone during the fold's await:
        try book.update { root in root = self.shopWith(["A", "NEW"]) }
        let foldedFromTheOldBook = shopWith(["A", "FROM-CLOUD"])

        XCTAssertFalse(try book.swap(from: snapshot, to: foldedFromTheOldBook))
        guard case .array(let rows)? = try book.read()["printLog"] else { return XCTFail() }
        let ids = rows.compactMap { row -> String? in
            if case .object(let o) = row, case .string(let id)? = o["id"] { return id }
            return nil
        }
        XCTAssertTrue(ids.contains("NEW"), "the record written meanwhile survives")
        XCTAssertNil(try book.read()["tombstones"], "and nothing was tombstoned")
    }

    /// What a fold removes, it removes because of a tombstone it already
    /// carries. Recording another would be the fold inventing a delete.
    func testAFoldThatRemovesARecordRecordsNoTombstoneOfItsOwn() throws {
        try book.replace(with: shopWith(["A", "B"]), scope: nil)
        let snapshot = try book.read()
        XCTAssertTrue(try book.swap(from: snapshot, to: shopWith(["A"])))
        XCTAssertNil(try book.read()["tombstones"])
    }

    /// An EDIT that removes a record is a delete, and says so — #1609's rule,
    /// which the fold above opts out of and nothing else does.
    func testAnEditThatRemovesARecordLeavesATombstone() throws {
        try book.replace(with: shopWith(["A", "B"]), scope: nil)
        try book.update { root in root["printLog"] = self.shopWith(["A"])["printLog"] }
        guard case .array(let tombs)? = try book.read()["tombstones"] else { return XCTFail("no tombstone") }
        XCTAssertEqual(tombs.count, 1)
    }
}
