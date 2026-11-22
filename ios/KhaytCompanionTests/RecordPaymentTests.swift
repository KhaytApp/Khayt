import XCTest
import KhaytCore
@testable import KhaytCompanion

/// Recording a payment on the phone runs the shop's own rule
/// (`KhaytOrderPayment.recordPayment`) — never arithmetic of its own.
final class RecordPaymentTests: XCTestCase {
    private var dir: URL!
    private var book: CompanionBook!
    private var reader: BookReader!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "pay-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        book = CompanionBook(directory: dir)
        reader = BookReader(book: book)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func open(settings: [String: JSONValue] = [:], paid: Double = 0, extra: [String: JSONValue] = [:]) throws {
        var order: [String: JSONValue] = ["id": .string("O-1"), "status": .string("completed"), "price": .number(100),
                                          "paidAmount": .number(paid), "paymentStatus": .string("unpaid"),
                                          "clientId": .string("C-1"), "rev": .number(2)]
        for (k, v) in extra { order[k] = v }
        try book.replace(with: ["settings": .object(settings), "printLog": .array([.object(order)]),
                                "clients": .array([.object(["id": .string("C-1"), "name": .string("Maya")])])],
                         scope: nil)
    }

    private func order() throws -> [String: JSONValue] {
        guard case .array(let rows)? = try book.read()["printLog"], case .object(let o)? = rows.first else { return [:] }
        return o
    }

    private func record(_ total: Double, method: String = "cash") async throws {
        try await BookWriter(book: book).recordPayment(orderId: "O-1", totalPaid: total, method: method,
                                                       engine: try await reader.sharedEngine())
    }

    func testPaidInFullIsTheRulesAnswerAndTravels() async throws {
        try open()
        try await record(100, method: "mada")
        let o = try order()
        XCTAssertEqual(o["paidAmount"], .number(100))
        XCTAssertEqual(o["paymentStatus"], .string("paid"))
        XCTAssertEqual(o["paymentMethod"], .string("mada"))
        XCTAssertEqual(o["paidGross"], .bool(true), "stamped as judged against the gross, as the rule does")
        XCTAssertEqual(o["rev"], .number(3), "stamped, so it reaches the Mac")
        let pending = try await reader.pendingChanges()
        XCTAssertEqual(try XCTUnwrap(pending).count, 1)
    }

    func testTheFigureIsTheTotalNotAnInstalment() async throws {
        try open(paid: 30)
        try await record(60)
        XCTAssertEqual(try order()["paidAmount"], .number(60), "the rule sets the total; it does not add")
        XCTAssertEqual(try order()["paymentStatus"], .string("partial"))
    }

    func testAnOverpaymentIsCappedAtTheBill() async throws {
        try open()
        try await record(150)
        XCTAssertEqual(try order()["paidAmount"], .number(100))
    }

    /// A shop that adds 15% on top bills 115 for a 100 job: 100 is a part payment.
    func testTaxOnTopIsBilledAndJudgedGross() async throws {
        let tax: [String: JSONValue] = ["tax": .object(["mode": .string("exclusive"),
                                                        "rates": .array([.object(["id": .string("vat"), "label": .string("VAT"),
                                                                                  "percent": .number(15), "compound": .bool(false)])])])]
        try open(settings: tax)
        let engine = try await reader.sharedEngine()
        let due = try await engine.cashDue(order: .object(try order()), settings: tax)
        XCTAssertEqual(due.gross, 115)
        XCTAssertEqual(BookWriter.paymentState(order: try order(), gross: due.gross, cash: due.cash)?.owed, 115)
        try await record(100)
        XCTAssertEqual(try order()["paymentStatus"], .string("partial"))
        try await record(115)
        XCTAssertEqual(try order()["paymentStatus"], .string("paid"))
    }

    /// The phone sends no webhook and no email, and neither does the Mac's fold
    /// of its change — so a payment that would owe one is refused, not silently
    /// recorded.
    func testAPaymentThatWouldSendAWebhookIsRefusedAndNothingIsWritten() async throws {
        try open(settings: ["webhooks": .object(["enabled": .bool(true)])])
        do {
            try await record(100)
            XCTFail("recorded a payment whose webhook nobody will send")
        } catch let refusal as BookWriter.Refusal {
            XCTAssertEqual(refusal, .paymentWouldReach(["webhooks"]))
        }
        XCTAssertEqual(try order()["paidAmount"], .number(0))
        XCTAssertEqual(try order()["rev"], .number(2))
    }

    func testAVoidedOrFreeJobHasNoPaymentCard() async throws {
        XCTAssertNil(BookWriter.paymentState(order: ["voidedAt": .string("2026-10-01")], gross: 100, cash: 100))
        XCTAssertNil(BookWriter.paymentState(order: [:], gross: 0, cash: 0))
        let state = try XCTUnwrap(BookWriter.paymentState(order: ["paidAmount": .number(40)], gross: 100, cash: 100))
        XCTAssertEqual(state.status, "partial"); XCTAssertEqual(state.owed, 60)
    }
}
