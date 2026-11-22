import XCTest
import KhaytCore
@testable import KhaytCompanion

/// The phone's WhatsApp update runs `lib/whatsapp-message.js` through KhaytCore
/// on the book's own rows, and logs to the customer the way the Mac does.
final class WhatsAppUpdateTests: XCTestCase {
    private var dir: URL!
    private var book: CompanionBook!
    private var reader: BookReader!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "wa-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        book = CompanionBook(directory: dir)
        reader = BookReader(book: book)
        try book.replace(with: [
            "settings": .object(["bizAr": .string("ورشة طويق"), "bizEn": .string("Tuwaiq Shop")]),
            "printLog": .array([.object(["id": .string("INV-7"), "status": .string("completed"),
                                         "clientId": .string("C-1"), "price": .number(120), "rev": .number(1)])]),
            "clients": .array([.object(["id": .string("C-1"), "nameAr": .string("سارة"),
                                        "phone": .string("055 123 4567"), "rev": .number(1)])]),
        ], scope: nil)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func row(_ c: String, _ id: String) throws -> [String: JSONValue] {
        guard case .array(let rows)? = try book.read()[c] else { return [:] }
        for r in rows { if case .object(let o) = r, o["id"] == .string(id) { return o } }
        return [:]
    }

    func testAFinishedJobIsReadyAndWritesToTheCustomerInHerLanguage() async throws {
        let engine = try await reader.sharedEngine()
        let order = JSONValue.object(try row("printLog", "INV-7"))
        let milestone = try await engine.whatsAppMilestone(order: order)
        XCTAssertEqual(milestone, "ready")
        let update = try await engine.whatsAppUpdate(order: order, client: .object(try row("clients", "C-1")),
                                                     settings: ["bizAr": .string("ورشة طويق")], templates: [],
                                                     milestone: nil, lang: nil, shopLang: "en",
                                                     values: ["price": "120.00", "currency": "SAR", "due": ""])
        XCTAssertTrue(update.ok, update.reason)
        XCTAssertEqual(update.lang, "ar", "a customer written only in Arabic is written to in Arabic")
        XCTAssertEqual(update.e164, "+966551234567", "a local 05… number made international for wa.me")
        XCTAssertTrue(update.text.contains("INV-7") && update.text.contains("سارة"))
        XCTAssertTrue(update.isDefault)
    }

    func testOpeningItLogsToTheCustomerAndTheJobKnowsItWent() async throws {
        let engine = try await reader.sharedEngine()
        let at = Date(timeIntervalSince1970: 1_791_000_000)
        let entry = try await engine.whatsAppCommEntry(id: "CMM-1", at: at, text: "جاهز", orderId: "INV-7",
                                                       milestone: "ready", lang: "ar")
        try BookWriter(book: book).addCommEntry(clientId: "C-1", entry: entry)
        let client = try row("clients", "C-1")
        guard case .array(let log)? = client["commLog"], case .object(let line)? = log.first else { return XCTFail() }
        XCTAssertEqual(line["type"], .string("whatsapp"), "the shape the desktop's customer editor lists")
        XCTAssertEqual(client["rev"], .number(2), "stamped, so the line reaches the Mac")
        let sent = try await engine.whatsAppSentAt(commLog: log, orderId: "INV-7", milestone: "ready")
        XCTAssertEqual(sent, StoreWriter.iso(at))
    }

    func testAnUnusableNumberSaysWhy() async throws {
        let engine = try await reader.sharedEngine()
        // The shared rule decides the reason; the sheet must have a sentence for it.
        for phone in ["800 123 4567", "12", "05", "9200 12345"] {
            let chat = try await engine.whatsAppChat(phone: phone, text: "x")
            XCTAssertFalse(chat.ok, phone)
            XCTAssertEqual(WhatsAppSheet.reason(chat.reason), L10n.tr("wa.reason.\(chat.reason)"),
                           "no sentence for the rule's reason \(chat.reason)")
        }
    }
}
