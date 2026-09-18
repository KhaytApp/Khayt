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
        try book.replace(with: shop())
        XCTAssertTrue(book.exists)

        let back = try book.read()
        XCTAssertEqual(back["settings"], shop()["settings"],
                       "the book did not survive the round trip value for value")
        XCTAssertEqual(back["clients"], shop()["clients"])
    }

    func testAnEditIsStampedSoTheMacCanHearAboutIt() throws {
        try book.replace(with: shop())
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
        try book.replace(with: shop())
        try book.update { root in root["clients"] = .array([]) }

        // `.prev` is what a corrupt primary is recovered from, and it is the
        // writer's doing rather than this file's — which is the point of
        // writing through it instead of `Data.write`.
        let prev = book.url.appendingPathExtension("prev")
        XCTAssertTrue(FileManager.default.fileExists(atPath: prev.path),
                      "no rollback copy was left behind")
    }

    func testForgettingLeavesNoClientListOnThePhone() throws {
        try book.replace(with: shop())
        try book.update { root in root["clients"] = .array([]) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.url.appendingPathExtension("prev").path))

        book.forget()

        // Both copies, not just the live one. An unpaired phone that still had
        // `.prev` would still have the shop's client list on it.
        XCTAssertFalse(book.exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: book.url.appendingPathExtension("prev").path),
                       "unpairing left the rollback copy, which holds the same names")
    }

    func testTheEngineCanWorkFromTheBookWithNoDesktopInReach() async throws {
        // The two halves together, which is the whole thesis: the phone holds
        // the book, the phone holds the engine, so the phone can work out a
        // figure with nothing to ask.
        try book.replace(with: shop())
        let settings = try book.read()["settings"]
        guard case .object(let fields) = settings else { return XCTFail("no settings in the book") }

        let engine = try KhaytEngine()
        let profile = try await engine.taxProfile(settings: fields)
        let split = try await engine.computeTax(1000, profile: profile)

        XCTAssertEqual(split.subtotal, 869.57, accuracy: 0.0001)
        XCTAssertEqual(split.taxTotal, 130.43, accuracy: 0.0001)
    }
}
