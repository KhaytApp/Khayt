import Foundation
import SwiftUI
import Testing
import KhaytCore
@testable import KhaytApp

/// The kiosk, photographed — and the layout facts that hold without a camera.
///
/// The sample shop's printing jobs have no recorded start and no printer
/// answers in a test, so a kiosk drawn from it alone would be all estimates and
/// no bars. Two of its machines are given readings here so the picture shows
/// the printer's own progress, an overrun, and an idle machine side by side.
@Suite @MainActor struct KioskSnapshotTests {

    @Test("the grid fills a TV and a laptop with every machine on screen")
    func shapes() {
        for count in 1...12 {
            for size in [CGSize(width: 1920, height: 1080), CGSize(width: 1280, height: 760),
                         CGSize(width: 1080, height: 1920)] {
                let shape = KioskGrid.shape(count: count, in: size)
                #expect(shape.columns * shape.rows >= count, "\(count) cards in \(size)")
                #expect(shape.columns * (shape.rows - 1) < count, "an empty row for \(count) in \(size)")
                let rows = KioskGrid.rows((0..<count).map { Self.card("m\($0)") },
                                          columns: shape.columns)
                #expect(rows.flatMap { $0 }.count == count)
            }
        }
        // Bigger type on a bigger screen, within bounds.
        let tv = KioskGrid.scale(for: CGSize(width: 3840, height: 2160), shape: .init(columns: 2, rows: 1))
        let laptop = KioskGrid.scale(for: CGSize(width: 1280, height: 760), shape: .init(columns: 3, rows: 2))
        #expect(tv > laptop)
        #expect(tv <= 3 && laptop >= 0.75)
    }

    static func card(_ id: String) -> KhaytEngine.KioskCard {
        let json = """
        {"machineId":"\(id)","name":"\(id)","model":"","state":"idle","offline":false,
         "orderId":"","project":"","clientId":"","clientLabel":"","dueDate":"",
         "source":"none","pct":null,"remainingMinutes":null,"overrunMinutes":0,"totalHours":null}
        """
        return try! JSONDecoder().decode(KhaytEngine.KioskCard.self, from: Data(json.utf8))
    }

    @Test("the kiosk over the sample shop")
    func picture() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let live: [String: JSONValue] = [
            "MACH-u1": .object(["progress": .number(62), "timeRemaining": .number(5 * 3600 + 40 * 60)]),
            "MACH-x1c": .object(["progress": .number(97), "timeRemaining": .number(9 * 60)]),
            "MACH-LASER": .object(["error": .string("timeout")]),
        ]
        let cards = try await KhaytEngine().kiosk(machines: shop.machineRows, orders: shop.orderRows,
                                                  live: live, mode: shop.mode, now: Date())
        #expect(cards.count == shop.machines.count)
        #expect(cards.contains { $0.source == "printer" })
        let snap = SnapshotTests()
        try snap.render(KioskBoard(cards: cards, shop: shop).background(Role.bg),
                        "kiosk-1920", size: CGSize(width: 1920, height: 1080))
        try snap.render(KioskBoard(cards: cards, shop: shop).background(Role.bg),
                        "kiosk-1280", size: CGSize(width: 1280, height: 760))
        try snap.renderDark(KioskBoard(cards: cards, shop: shop).background(Role.bg),
                            "kiosk-dark", size: CGSize(width: 1920, height: 1080))
    }
}
