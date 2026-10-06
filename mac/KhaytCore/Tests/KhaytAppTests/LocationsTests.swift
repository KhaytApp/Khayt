import Foundation
import SwiftUI
import Testing
import KhaytCore
@testable import KhaytApp

/// The shop's sites on the Mac: the records, the delete, the machine sheet, and
/// the P&L split by site.
@Suite @MainActor struct LocationsTests {

    static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    // ── THE DELETE ──────────────────────────────────────────────────────

    @Test("a delete clears the same collections the shared rule does")
    func pointersAgree() throws {
        let src = try String(contentsOf: Self.repoRoot().appending(path: "lib/location-pl.js"), encoding: .utf8)
        let line = try #require(src.split(separator: "\n").first { $0.contains("const POINTERS = [") })
        let names = line.split(separator: "'").enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
        #expect(names == Shop.pointAtLocations)
    }

    static func book() -> [String: JSONValue] {
        [
            "locations": .array([.object(["id": .string("LOC-a"), "name": .string("Main"), "rev": .number(4)]),
                                 .object(["id": .string("LOC-b"), "name": .string("Site 2")])]),
            "machines": .array([.object(["id": .string("m1"), "locationId": .string("LOC-b")]),
                                .object(["id": .string("m2"), "locationId": .string("LOC-a")])]),
            "inventory": .array([.object(["id": .string("s1"), "locationId": .string("LOC-b")])]),
            "expenses": .array([.object(["id": .string("e1"), "locationId": .string("LOC-b")])]),
            "printLog": .array([.object(["id": .string("o1"), "locationId": .string("LOC-b")]),
                                .object(["id": .string("o2")])]),
        ]
    }

    static func field(_ root: [String: JSONValue], _ collection: String, _ id: String,
                      _ key: String) -> JSONValue? {
        for row in Shop.rows(root, collection) {
            if case .object(let r) = row, r["id"] == .string(id) { return r[key] }
        }
        return nil
    }

    @Test("deleting a location unassigns what stood at it, and undo puts it all back")
    func deleteAndUndo() {
        var root = Self.book()
        let removed: [String: JSONValue] = ["id": .string("LOC-b"), "name": .string("Site 2")]
        root["locations"] = .array(Shop.rows(root, "locations").filter { Shop.recordId($0) != "LOC-b" })
        let unlinked = Shop.unpointingLocation(&root, from: "LOC-b")
        #expect(Set(unlinked.map { $0.collection + ":" + $0.id })
                == ["machines:m1", "inventory:s1", "expenses:e1", "printLog:o1"])
        #expect(Self.field(root, "machines", "m1", "locationId") == .string(""))
        #expect(Self.field(root, "machines", "m2", "locationId") == .string("LOC-a"), "another site untouched")
        #expect(Self.field(root, "printLog", "o2", "locationId") == nil, "a job that named none gets no field")

        // Meanwhile the shop moves the spool to Main. Undo must not take it back.
        var rows = Shop.rows(root, "inventory")
        rows[0] = .object(["id": .string("s1"), "locationId": .string("LOC-a")])
        root["inventory"] = .array(rows)

        Shop.relinkingLocation(&root, record: removed, id: "LOC-b", unlinked: unlinked)
        #expect(Shop.rows(root, "locations").contains { Shop.recordId($0) == "LOC-b" })
        #expect(Self.field(root, "machines", "m1", "locationId") == .string("LOC-b"))
        #expect(Self.field(root, "expenses", "e1", "locationId") == .string("LOC-b"))
        #expect(Self.field(root, "printLog", "o1", "locationId") == .string("LOC-b"))
        #expect(Self.field(root, "inventory", "s1", "locationId") == .string("LOC-a"),
                "a move made since the delete is the shop's newer word")
    }

    @Test("an edit changes the name and address and keeps everything else")
    func editKeepsFields() {
        var root = Self.book()
        var undo: [Shop.ChangedRecord] = []
        Shop.writeLocation(into: &root, id: "LOC-a", name: "Riyadh", address: "Olaya",
                           newId: "unused", undo: &undo)
        #expect(Self.field(root, "locations", "LOC-a", "name") == .string("Riyadh"))
        #expect(Self.field(root, "locations", "LOC-a", "address") == .string("Olaya"))
        if case .number(let rev)? = Self.field(root, "locations", "LOC-a", "rev") {
            #expect(rev > 4, "stamped, so the other app's merge sees the change")
        } else { Issue.record("rev lost") }
        #expect(undo.count == 1)

        Shop.writeLocation(into: &root, id: nil, name: "Jeddah", address: "",
                           newId: "LOC-new", undo: &undo)
        #expect(Self.field(root, "locations", "LOC-new", "name") == .string("Jeddah"))
        #expect(Shop.rows(root, "locations").count == 3)
    }

    @Test("ids are the other app's shape")
    func idShape() {
        let id = Shop.uid("LOC")
        #expect(id.hasPrefix("LOC-"))
        #expect(id.dropFirst(4).allSatisfy { $0.isNumber || $0.isLetter })
    }

    // ── THE MACHINE SHEET ───────────────────────────────────────────────

    @Test("the machine sheet carries a machine's location through a save")
    func sheetRoundTrip() throws {
        let placed = try JSONDecoder().decode(Machine.self, from: Data(#"{"id":"M1","name":"U1","locationId":"LOC-a"}"#.utf8))
        let form = MachineSheet.Form.opening(placed, kind: "fdm")
        #expect(form.locationId == "LOC-a")
        #expect(form.input()["locationId"] == .string("LOC-a"))
        let bare = try JSONDecoder().decode(Machine.self, from: Data(#"{"id":"M2","name":"CORE One"}"#.utf8))
        #expect(MachineSheet.Form.opening(bare, kind: "fdm").input()["locationId"] == .string(""),
                "none is '' — what lib/machine-edit.js writes, so an unchanged save leaves it alone")
    }

    // ── THE P&L BY SITE ─────────────────────────────────────────────────

    @Test("the sample shop reaches the location P&L, and its sites add up to the shop")
    func sampleReachesIt() async throws {
        let shop = Shop()
        await shop.load(.sample)
        #expect(shop.locations.map(\.name) == ["Riyadh workshop", "Jeddah studio"])
        let engine = try KhaytEngine()
        let report = try await engine.locationPl(
            orders: shop.orderRows, expenses: shop.expenseRows, wasteLog: shop.wasteRows,
            machines: shop.machineRows, locations: shop.locationRows, settings: shop.settingsDict,
            clients: shop.clientRows, currencies: Invoice.currencyTable(shop),
            inventory: shop.inventoryRows, now: Date())
        #expect(report.located)
        let ids = report.rows.map(\.locationId)
        #expect(Array(ids.prefix(2)).sorted() == ["LOC-sample-jed", "LOC-sample-ryd"])
        #expect(ids.last == "", "the laser's work is unassigned, and drawn last")
        let riyadh = try #require(report.rows.first { $0.locationId == "LOC-sample-ryd" })
        #expect(riyadh.revenue > 0 && riyadh.orders > 0)
        #expect(riyadh.expenses > 0, "an expense booked to the site")

        let shopWide = try await engine.pnlByPeriod(
            orders: shop.orderRows, expenses: shop.expenseRows, settings: shop.settingsDict,
            clients: shop.clientRows, currencies: Invoice.currencyTable(shop), now: Date(),
            granularity: "month", wasteLog: shop.wasteRows, inventory: shop.inventoryRows)
        func cents(_ x: Double) -> Int { Int((x * 100).rounded()) }
        #expect(abs(cents(report.rows.reduce(0) { $0 + $1.revenue }) - cents(shopWide.reduce(0) { $0 + $1.revenue })) <= report.rows.count)
        #expect(report.rows.reduce(0) { $0 + $1.orders } == shopWide.reduce(0) { $0 + $1.orders })
    }

    @Test("a book with no locations draws nothing")
    func noLocations() async throws {
        let report = try await KhaytEngine().locationPl(
            orders: [], expenses: [], wasteLog: [], machines: [], locations: [], settings: [:],
            clients: [], currencies: [:], inventory: [], now: Date())
        #expect(!report.located && report.rows.isEmpty)
    }

    @Test("the location P&L, photographed")
    func picture() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let report = try await KhaytEngine().locationPl(
            orders: shop.orderRows, expenses: shop.expenseRows, wasteLog: shop.wasteRows,
            machines: shop.machineRows, locations: shop.locationRows, settings: shop.settingsDict,
            clients: shop.clientRows, currencies: Invoice.currencyTable(shop),
            inventory: shop.inventoryRows, now: Date())
        let snap = SnapshotTests()
        let card = LocationPlCard(shop: shop, report: report)
            .card(rail: Khayt.brand, padding: 14).padding(16).background(Role.bg)
        try snap.render(card, "location-pl", size: CGSize(width: 820, height: 260))
        try snap.renderDark(card, "location-pl-dark", size: CGSize(width: 820, height: 260))
        // Bare, not in its Form: ImageRenderer draws nothing inside a scroller.
        let section = LocationsSection(shop: shop).padding(20).background(Role.bg)
        try snap.render(section, "locations-settings", size: CGSize(width: 600, height: 300))
    }
}
