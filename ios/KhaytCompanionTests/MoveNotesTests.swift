import XCTest
import KhaytCore
@testable import KhaytCompanion

/// What the shop's rule says about a move reaches the person who made it:
/// filament taken, a spool running low, a due date pushed back — the Mac's
/// toast, on the phone.
final class MoveNotesTests: XCTestCase {

    private var dir: URL!
    private var book: CompanionBook!
    private static let sharedEngine = Result { try KhaytEngine() }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "move-notes-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        book = CompanionBook(directory: dir)
        L10n.setLanguage(.en)
    }

    override func tearDownWithError() throws {
        L10n.setLanguage(.system)
        try? FileManager.default.removeItem(at: dir)
    }

    private func notice(_ json: String) throws -> Notice {
        try JSONDecoder().decode(Notice.self, from: Data(json.utf8))
    }

    /// A shop that deducts on completion; J-1 owes 120 g of S-1.
    private func shop(spoolLeft: Double) -> [String: JSONValue] {
        [
            "settings": .object(["autoDeduct": .bool(true)]),
            "printLog": .array([
                .object(["id": .string("J-1"), "status": .string("qc"), "project": .string("Bracket"),
                         "parts": .array([.object(["name": .string("Bracket"), "filamentId": .string("S-1"),
                                                   "printWeight": .number(120), "qty": .number(1)])]),
                         "rev": .number(1)]),
            ]),
            "inventory": .array([
                .object(["id": .string("S-1"), "material": .string("PLA"), "weight": .number(spoolLeft),
                         "spoolWeight": .number(1000), "rev": .number(1)]),
            ]),
            "consumables": .array([]),
            "machines": .array([]),
        ]
    }

    func testFinishingAJobSaysWhatItTookOffTheShelf() async throws {
        try book.replace(with: shop(spoolLeft: 640), scope: nil)
        let notices = try await BookWriter(book: book)
            .setOrderStatus(orderId: "J-1", to: "completed", engine: try Self.sharedEngine.get())
        XCTAssertEqual(notices.map(\.code), ["filament_deducted"])
        XCTAssertEqual(notices.map(BookWriter.sentence(for:)), ["Took 120 g off 1 spool(s)."])
    }

    func testMovingAFinishedJobBackSaysTheFilamentWentBack() async throws {
        try book.replace(with: shop(spoolLeft: 640), scope: nil)
        let writer = BookWriter(book: book)
        let engine = try Self.sharedEngine.get()
        try await writer.setOrderStatus(orderId: "J-1", to: "completed", engine: engine)
        let back = try await writer.setOrderStatus(orderId: "J-1", to: "qc", engine: engine)
        XCTAssertEqual(back.map(\.code), ["filament_returned"])
        XCTAssertTrue(BookWriter.sentence(for: back[0]).hasPrefix("Put 120 g back on the shelf"))
    }

    func testEveryCodeTheRulesSendHasASentenceInBothLanguages() throws {
        let all = try [
            #"{"code":"due_extended","params":{"days":3,"date":"2026-11-04"}}"#,
            #"{"code":"filament_deducted","params":{"weight":120,"spools":1,"low":0}}"#,
            #"{"code":"filament_deducted_low","params":{"weight":120,"spools":2,"low":1}}"#,
            #"{"code":"filament_returned","params":{"weight":120}}"#,
            #"{"code":"packaging_deducted","params":{}}"#,
            #"{"code":"consumable_low","params":{"name":"Boxes"}}"#,
            #"{"code":"packaging_low","params":{"name":"Tape"}}"#,
        ].map { try notice($0) }

        XCTAssertEqual(all.map(BookWriter.sentence(for:)), [
            "Due date pushed back 3 days for the time on hold: now 2026-11-04.",
            "Took 120 g off 1 spool(s).",
            "Took 120 g off 2 spool(s); 1 now low.",
            "Put 120 g back on the shelf — the job is no longer finished, so its filament is not used yet.",
            "Packaging taken off the shelf for the finished job.",
            "Running low: Boxes",
            "Running low: Tape",
        ])

        L10n.setLanguage(.ar)
        for n in all {
            let line = BookWriter.sentence(for: n)
            XCTAssertNotEqual(line, n.code, "\(n.code) has no Arabic sentence")
            XCTAssertFalse(line.contains("move.note"), "\(n.code) shows its key: \(line)")
            XCTAssertNil(line.rangeOfCharacter(from: CharacterSet(charactersIn: "٠١٢٣٤٥٦٧٨٩")),
                         "Western digits: \(line)")
        }
    }

    /// A code nobody wrote a sentence for shows as the code — wrong-looking,
    /// which is the point, rather than nothing.
    func testAnUnknownCodeIsShownNotDropped() throws {
        XCTAssertEqual(BookWriter.sentence(for: try notice(#"{"code":"brand_new","params":{}}"#)), "brand_new")
    }
}
