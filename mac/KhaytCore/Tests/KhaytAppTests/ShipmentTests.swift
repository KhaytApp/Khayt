import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A job handed to a carrier from this app.
///
/// The fields and how a status moves are `lib/shipment.js`, held to the
/// Electron dialog's own code by `test/shipment.test.js`. This holds the Mac
/// to that module — the engine calls, the order it reads back, the carriers it
/// offers — and to the wiring that puts the sheet in front of a shop.
@MainActor
struct ShipmentTests {

    static func engine() async throws -> KhaytEngine {
        let shop = Shop()
        await shop.load(.sample)
        return try #require(shop.engine)
    }

    static let at = Date(timeIntervalSince1970: 1_800_000_000)

    static func order(_ extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string("J-1"), "date": .string("2027-01-10"), "status": .string("completed"),
            "project": .string("Falcon hood"), "price": .number(120), "paidAmount": .number(120),
            "paymentStatus": .string("paid"), "printTime": .number(2), "priority": .bool(false),
            "notes": .string(""),
        ]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    @Test("shipping writes who took it, the number, and label_created — and the Mac reads it back")
    func create() async throws {
        let engine = try await Self.engine()
        let shipped = try await engine.shipmentCreate(order: Self.order(), carrier: "smsa", service: "dom_exp",
                                                      trackingNumber: "  SM123 ", at: Self.at)
        guard case .object(let o) = shipped else { Issue.record("not an object"); return }
        #expect(o["carrier"] == .string("smsa"))
        #expect(o["trackingNumber"] == .string("SM123"), "the number was not trimmed")
        #expect(o["shippingService"] == .string("dom_exp"))
        #expect(o["shippingStatus"] == .string("label_created"))
        #expect(o["shippedAt"] == .string(StoreWriter.iso(Self.at)))
        #expect(o["courierName"] == .string("SMSA Express"), "the other app's Track button reads courierName")
        #expect(o["status"] == .string("completed"), "shipped is a date stamp, not a status")

        let job = try JSONDecoder().decode(Order.self, from: JSONEncoder().encode(shipped))
        #expect(job.carrier == "smsa")
        #expect(job.trackingNumber == "SM123")
        #expect(job.shippingStatus == "label_created")
        #expect(Stage.of(job) == .shipped)
    }

    @Test("a parcel moves forward by hand, never back, and delivered stamps the date")
    func update() async throws {
        let engine = try await Self.engine()
        var job = try await engine.shipmentCreate(order: Self.order(), carrier: "manual", service: nil,
                                                  trackingNumber: "", at: Self.at)
        let moved = try await engine.shipmentUpdate(order: job, status: "in_transit", trackingNumber: "", at: Self.at)
        #expect(moved.changed)
        job = moved.order
        let back = try await engine.shipmentUpdate(order: job, status: "label_created", trackingNumber: "", at: Self.at)
        #expect(!back.changed, "a parcel in transit was moved back to label created")
        let done = try await engine.shipmentUpdate(order: job, status: "delivered", trackingNumber: "AWB-9", at: Self.at)
        guard case .object(let o) = done.order else { return }
        #expect(o["shippingStatus"] == .string("delivered"))
        #expect(o["trackingNumber"] == .string("AWB-9"))
        #expect(o["deliveredAt"] == .string(StoreWriter.iso(Self.at)))
        guard case .array(let trail)? = o["shippingHistory"] else { Issue.record("no trail"); return }
        #expect(trail.count == 3, "label_created, in_transit, delivered")
    }

    @Test("the sheet offers the carriers the shop set up, and Manual last, always")
    func carriers() async throws {
        let engine = try await Self.engine()
        let none = try await engine.carriersToShipWith(settings: .object([:]))
        #expect(none.map(\.id) == ["manual"])
        let some = try await engine.carriersToShipWith(settings: .object(["shipping": .object([
            "smsa": .object(["enabled": .bool(true), "accountNumber": .string("1")]),
            "aramex": .object(["enabled": .bool(false), "apiKey": .string("x")]),
            "spl": .object(["enabled": .bool(true)]),   // on, but nothing to ship with
        ])]))
        #expect(some.map(\.id) == ["smsa", "manual"])
        #expect(some.first?.services.isEmpty == false)
        #expect(some.first?.name("ar") == "سمسا إكسبريس")
        let all = try await engine.allCarriers()
        #expect(Set(all.map(\.id)) == ["manual", "smsa", "aramex", "spl"])
        #expect(try await engine.shippingStatuses() == ["label_created", "in_transit", "out_for_delivery",
                                                        "delivered", "exception"])
    }

    @Test("a tracking number is read however the book holds it")
    func lenientTracking() throws {
        for (raw, expected) in [(JSONValue.string("SM1"), "SM1"), (.number(123456), "123456"),
                                (.null, nil), (.string(""), nil)] as [(JSONValue, String?)] {
            let data = try JSONEncoder().encode(Self.order(["trackingNumber": raw]))
            let job = try JSONDecoder().decode(Order.self, from: data)
            #expect(job.trackingNumber == expected, Comment(rawValue: "\(raw)"))
        }
    }

    @Test("the sheet is reachable: presented by the window, opened from the menus and the inspector")
    func wired() {
        // A sheet nobody can open is the correct-module-with-no-caller bug.
        let window = MenuCoverageTests.source("ShopWindow.swift")
        #expect(window.contains(".sheet(item: $shop.pendingShipment) { ShipSheet("))
        for file in ["Menus.swift", "OrdersTable.swift", "OrderInspector.swift"] {
            #expect(MenuCoverageTests.source(file).contains("shop.pendingShipment = Shop.PendingHold("),
                    Comment(rawValue: "\(file) no longer opens the Ship sheet"))
        }
        let sheet = MenuCoverageTests.source("ShipSheet.swift")
        #expect(sheet.contains("await shop.ship(id,"))
        #expect(sheet.contains("await shop.updateShipment(id,"))
        let integrations = MenuCoverageTests.source("Integrations.swift")
        #expect(integrations.contains("CarrierSettings(shop: shop)"),
                "the carrier settings are not on any pane, so the sheet can only ever offer Manual")
    }
}
