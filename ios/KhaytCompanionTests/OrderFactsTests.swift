import XCTest
import KhaytCore
@testable import KhaytCompanion

/// The order page's filament and quantity come from the book, in the shape
/// `lib/order-new.js` actually writes — not a tidier one invented here.
final class OrderFactsTests: XCTestCase {

    private var dir: URL!
    private var book: CompanionBook!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "facts-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        book = CompanionBook(directory: dir)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testACartsPartsAreSummedAndItsDanglingCommaIsNotShown() async throws {
        // A two-part cart where one part had no filament: the desktop writes
        // "PLA, " and keeps each part's own qty.
        try book.replace(with: ["printLog": .array([
            .object(["id": .string("INV-1"), "status": .string("pending"), "material": .string("PLA, "),
                     "parts": .array([.object(["qty": .number(3)]), .object(["qty": .number(2)])])]),
        ])], scope: nil)
        let facts = try await BookReader(book: book).orderFacts()
        XCTAssertEqual(facts["INV-1"], OrderFacts(material: "PLA", quantity: 5))
    }

    func testAnOlderRecordKeepsItsOwnQuantityAndSeveralMaterialsReadAsOne() async throws {
        try book.replace(with: ["printLog": .array([
            .object(["id": .string("INV-2"), "status": .string("printing"), "material": .string("PLA, PETG"),
                     "qty": .number(4)]),
            .object(["id": .string("INV-3"), "status": .string("pending")]),
        ])], scope: nil)
        let facts = try await BookReader(book: book).orderFacts()
        XCTAssertEqual(facts["INV-2"], OrderFacts(material: "PLA · PETG", quantity: 4))
        XCTAssertEqual(facts["INV-3"], OrderFacts(material: nil, quantity: nil),
                       "nothing known is nothing drawn — not a dash, not a zero")
    }
}
