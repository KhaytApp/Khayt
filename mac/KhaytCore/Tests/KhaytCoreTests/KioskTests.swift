import Foundation
import Testing
@testable import KhaytCore

/// The kiosk's cards crossing into the engine and back.
///
/// The rule is `lib/kiosk.js`, and `test/kiosk.test.js` pins it against the
/// desktop's original. These are about the CROSSING — that the shape decodes,
/// that a nil stays nil rather than becoming 0, and that the rules that matter
/// most on a screen nobody can touch still hold on this side.
struct KioskTests {

    static let now = Date(timeIntervalSince1970: 1_788_000_000)

    static func sampleBook() throws -> (machines: [JSONValue], orders: [JSONValue]) {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Resources/sample-shop.json")
        let root = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        guard case .object(let book) = root,
              case .array(let orders)? = book["printLog"],
              case .array(let machines)? = book["machines"] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (machines, orders)
    }

    @Test("every machine in the sample shop gets one card, and none shows a cancelled job")
    func theSampleShop() async throws {
        let book = try Self.sampleBook()
        let cards = try await KhaytEngine().kiosk(machines: book.machines, orders: book.orders,
                                                  live: [:], mode: "professional", now: Self.now)
        #expect(cards.count == book.machines.count)
        #expect(Set(cards.map(\.machineId)).count == cards.count)
        let cancelled = Set(book.orders.compactMap { o -> String? in
            guard case .object(let row) = o, case .string("cancelled")? = row["status"],
                  case .string(let id)? = row["id"] else { return nil }
            return id
        })
        #expect(!cancelled.isEmpty, "the sample shop must reach the cancelled case")
        for card in cards { #expect(!cancelled.contains(card.orderId)) }
        // The sample's printing jobs have no recorded start, so without a
        // printer the honest answer is the estimate's length and no bar.
        let printing = cards.filter { $0.state == "printing" }
        #expect(!printing.isEmpty)
        for card in printing {
            #expect(card.pct == nil)
            #expect(card.totalHours != nil)
        }
    }

    @Test("a printer's own reading is used, and says so")
    func thePrinterWins() async throws {
        let cards = try await KhaytEngine().kiosk(
            machines: [.object(["id": .string("M1"), "name": .string("U1")])],
            orders: [.object([
                "id": .string("O1"), "status": .string("printing"), "machineId": .string("M1"),
                "printTime": .number(4), "project": .string("Vase"),
                "printingStartedAt": .string("2026-08-29T08:00:00Z"),
            ])],
            live: ["M1": .object(["progress": .number(80), "timeRemaining": .number(1800)])],
            mode: "professional", now: Self.now)
        let card = try #require(cards.first)
        #expect(card.source == "printer")
        #expect(card.pct == 80)
        #expect(card.remainingMinutes == 30)
        #expect(card.project == "Vase")
    }

    @Test("an idle machine is idle, with nothing invented")
    func idle() async throws {
        let cards = try await KhaytEngine().kiosk(
            machines: [.object(["id": .string("M1"), "name": .string(""), "model": .string("Ender 3")])],
            orders: [], live: [:], mode: "enthusiast", now: Self.now)
        let card = try #require(cards.first)
        #expect(card.state == "idle")
        #expect(card.name == "Ender 3")
        #expect(card.model == "")
        #expect(card.pct == nil)
        #expect(card.remainingMinutes == nil)
        #expect(card.totalHours == nil)
    }
}
