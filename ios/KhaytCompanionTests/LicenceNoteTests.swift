import XCTest
import KhaytCore
@testable import KhaytCompanion

/// "Not licensed for sale" on a job's page: the Mac's `ModelLicence.saleProblems`,
/// on the job's parts and the phone's library copy.
final class LicenceNoteTests: XCTestCase {

    private var dir: URL!
    private var book: CompanionBook!
    private let now = ISO8601DateFormatter().date(from: "2026-10-30T09:00:00Z")!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "licence-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        book = CompanionBook(directory: dir)
        try book.replace(with: SampleShop.book(now: now), scope: SampleShop.scope(now: now))
        try book.replaceLibrary(SampleShop.library())
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testTheCopyKeepsAModelsLicence() throws {
        let row = JSONValue.object(["id": .string("PF-1"), "name": .string("Dragon"), "licence": .string("cc-by-nc"),
                                    "licenceExpires": .string("2027-01-01"), "thumbnail": .string("x")])
        guard case .object(let o)? = LibraryCopy.slim(row) else { return XCTFail("kept nothing") }
        XCTAssertEqual(o["licence"], .string("cc-by-nc"))
        XCTAssertEqual(o["licenceExpires"], .string("2027-01-01"))
    }

    func testAJobFromModelsThatMayNotBeSoldSaysWhichAndWhy() {
        let problems = LibraryCopy.saleProblems(orderId: "S-1045", book: book, now: now)
        XCTAssertEqual(problems.map(\.id), ["PF-sample-terrain", "PF-sample-tile-base"], "in the job's own order")
        XCTAssertEqual(problems.map(\.reason), ["not-commercial", "expired"])
        XCTAssertEqual(problems.last?.until, "2025-12-31")
        XCTAssertEqual(problems.first?.name, "Dungeon terrain tiles")
    }

    func testUnknownIsNotNo() throws {
        XCTAssertTrue(LibraryCopy.saleProblems(orderId: "S-1044", book: book, now: now).isEmpty,
                      "a job with no model behind it")
        XCTAssertTrue(LibraryCopy.saleProblems(orderId: "nope", book: book, now: now).isEmpty)
        try FileManager.default.removeItem(at: book.libraryURL)
        XCTAssertTrue(LibraryCopy.saleProblems(orderId: "S-1045", book: book, now: now).isEmpty,
                      "no library copy (Wi-Fi only): nothing is known, so nothing is said")
    }

    func testABoughtLicenceIsGoodUntilItsLastDay() {
        let day = ISO8601DateFormatter().date(from: "2025-12-31T09:00:00Z")!
        XCTAssertEqual(LibraryCopy.saleProblems(orderId: "S-1045", book: book, now: day).map(\.reason),
                       ["not-commercial"])
    }

    /// A copy cut before it kept licences would never learn them from changes
    /// alone: under the old name it does not count, so the next pull is whole.
    func testACopyFromBeforeLicencesIsTakenAgain() throws {
        try FileManager.default.removeItem(at: book.libraryURL)
        let old = dir.appending(path: "library.json")
        try Data("[]".utf8).write(to: old)
        XCTAssertFalse(book.hasLibrary, "the old copy does not hold licences")
        try book.replaceLibrary(SampleShop.library())
        XCTAssertTrue(book.hasLibrary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "and is cleared when the new one is written")
    }
}
