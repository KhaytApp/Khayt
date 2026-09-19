import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// What a supplier delete has to do besides deleting.
///
/// ── THE FAULT THIS SUITE EXISTS FOR ───────────────────────────────────────
///
/// A spool and a purchase order can each carry a `supplierId`. The other app's
/// delete has always nulled those out — and relinked them on undo — while this
/// app's, when it first shipped, dropped the supplier row and nothing else. So
/// a book tidied on the Mac came out different from one tidied in the other
/// window, and the difference was a pointer at a record that is not there:
/// the kind of thing that surfaces months later as a screen that cannot draw.
@MainActor
struct SupplierUnlinkTests {

    static func book() -> [String: JSONValue] {
        [
            "suppliers": .array([
                .object(["id": .string("SUP-1"), "name": .string("Tuwaiq Supply")]),
                .object(["id": .string("SUP-2"), "name": .string("Jeddah Packaging")]),
            ]),
            "inventory": .array([
                .object(["id": .string("sp-1"), "material": .string("PLA+"),
                         "supplierId": .string("SUP-1")]),
                .object(["id": .string("sp-2"), "material": .string("PETG"),
                         "supplierId": .string("SUP-2")]),
                // One that names nobody, which must come through untouched.
                .object(["id": .string("sp-3"), "material": .string("ASA")]),
            ]),
            "purchaseOrders": .array([
                .object(["id": .string("PO-1"), "supplierId": .string("SUP-1"),
                         "supplierName": .string("Tuwaiq Supply"), "qty": .number(2000)]),
                .object(["id": .string("PO-2"), "supplierId": .string("SUP-2"),
                         "supplierName": .string("Jeddah Packaging"), "qty": .number(200)]),
            ]),
        ]
    }

    static func row(_ root: [String: JSONValue], _ collection: String,
                    _ id: String) -> [String: JSONValue]? {
        for value in Shop.rows(root, collection) {
            if case .object(let o) = value, Shop.plainString(o["id"]) == id { return o }
        }
        return nil
    }

    @Test("everything that pointed at the deleted supplier stops pointing at it")
    func bothCollectionsAreUnlinked() throws {
        var book = Self.book()
        let changed = Shop.unpointing(&book, from: "SUP-1")

        let spool = try #require(Self.row(book, "inventory", "sp-1"))
        #expect(spool["supplierId"] == .null,
                "a spool still names a supplier the book no longer has")
        let order = try #require(Self.row(book, "purchaseOrders", "PO-1"))
        #expect(order["supplierId"] == .null,
                "an order still names a supplier the book no longer has")

        // NULL rather than absent, which is what the other app writes. A field
        // two apps spell differently reads differently depending on which one
        // saved last.
        #expect(spool["supplierId"] != nil)

        #expect(changed.count == 2, "the undo was not told about both records")
        #expect(Set(changed.map(\.collection)) == ["inventory", "purchaseOrders"])
    }

    @Test("the name the order was written with is left exactly as it was")
    func theNameSurvives() throws {
        // An order records who the shop actually bought from at the time.
        // Tidying up a contact list is not permission to rewrite that — which
        // is the whole reason `supplierName` sits on the order rather than
        // being looked up through the id.
        var book = Self.book()
        _ = Shop.unpointing(&book, from: "SUP-1")
        let order = try #require(Self.row(book, "purchaseOrders", "PO-1"))
        #expect(order["supplierName"] == .string("Tuwaiq Supply"))
        #expect(order["qty"] == .number(2000), "the rest of the order moved")
    }

    @Test("records naming another supplier, or none, are not touched")
    func othersAreLeftAlone() throws {
        var book = Self.book()
        _ = Shop.unpointing(&book, from: "SUP-1")

        let other = try #require(Self.row(book, "inventory", "sp-2"))
        #expect(other["supplierId"] == .string("SUP-2"),
                "deleting one supplier unlinked another's spools")
        let none = try #require(Self.row(book, "inventory", "sp-3"))
        #expect(none["supplierId"] == nil,
                "a spool that named nobody was given a null it never had")
        let otherOrder = try #require(Self.row(book, "purchaseOrders", "PO-2"))
        #expect(otherOrder["supplierId"] == .string("SUP-2"))
    }

    @Test("a supplier nothing points at changes nothing, and says so")
    func nothingToUnlink() {
        var book = Self.book()
        book["inventory"] = .array([])
        book["purchaseOrders"] = .array([])
        #expect(Shop.unpointing(&book, from: "SUP-1").isEmpty)
    }

    @Test("the two collections are the two the other app walks")
    func sameCollectionsAsTheOtherApp() throws {
        // `renderer/inventory.js` loops `inventory` and `purchaseOrders`. If a
        // third collection ever grows a `supplierId` on either side, this is
        // where the two apps start disagreeing again.
        #expect(Shop.pointAtSuppliers == ["inventory", "purchaseOrders"])

        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let js = try String(contentsOf: repo.appending(path: "renderer/inventory.js"),
                            encoding: .utf8)
        #expect(js.contains("for (const it of inventory) { if (it.supplierId === id)"),
                "the other app's delete has changed shape — check what it unlinks now")
        #expect(js.contains("for (const po of purchaseOrders) { if (po.supplierId === id)"),
                "the other app's delete has changed shape — check what it unlinks now")
    }
}
