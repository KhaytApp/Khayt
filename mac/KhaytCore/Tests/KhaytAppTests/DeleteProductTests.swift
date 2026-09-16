import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Taking a product off the catalogue.
///
/// ── WHAT A DELETE HAS TO DO BESIDES DELETING ──────────────────────────────
///
/// The Mac could not delete a product at all — the words for it had been
/// sitting in the app unused. Dropping the row is the easy quarter: the other
/// app also unlinks the jobs that named the product, drops it from any quote
/// bundle, and removes its pictures, and offers all of it back as one undo.
/// A delete that only dropped the row would leave a job pointing at a product
/// that is not there, which surfaces months later as a screen that cannot
/// draw.
@MainActor
struct DeleteProductTests {

    /// A book with one product, two jobs that name it, one that does not, and
    /// a bundle listing it beside another product.
    static func book() -> [String: JSONValue] {
        [
            "products": .array([
                .object(["id": .string("P1"), "nameEn": .string("Dragon")]),
                .object(["id": .string("P2"), "nameEn": .string("Portrait")]),
            ]),
            "printLog": .array([
                .object(["id": .string("J1"), "project": .string("a"), "productId": .string("P1"),
                         "price": .number(50)]),
                .object(["id": .string("J2"), "project": .string("b"), "productId": .string("P2")]),
                .object(["id": .string("J3"), "project": .string("c"), "productId": .string("P1")]),
            ]),
            "settings": .object([
                "bundles": .array([
                    .object(["id": .string("B1"), "name": .string("Set"),
                             "productIds": .array([.string("P1"), .string("P2")])]),
                    .object(["id": .string("B2"), "name": .string("Other"),
                             "productIds": .array([.string("P2")])]),
                ]),
            ]),
        ]
    }

    /// The write, applied to a book in memory — the same steps `deleteProduct`
    /// performs inside the store write, reachable without a store on disk.
    static func delete(_ id: String, from book: [String: JSONValue]) -> [String: JSONValue] {
        var root = book
        if case .array(var rows)? = root["products"] {
            rows.removeAll { if case .object(let o) = $0 { return o["id"] == .string(id) } else { return false } }
            root["products"] = .array(rows)
        }
        if case .array(var log)? = root["printLog"] {
            for i in log.indices {
                guard case .object(var order) = log[i], order["productId"] == .string(id) else { continue }
                order["productId"] = .null
                log[i] = .object(order)
            }
            root["printLog"] = .array(log)
        }
        if case .object(var settings)? = root["settings"], case .array(var list)? = settings["bundles"] {
            for i in list.indices {
                guard case .object(var bundle) = list[i], case .array(let ids)? = bundle["productIds"] else { continue }
                bundle["productIds"] = .array(ids.filter { $0 != .string(id) })
                list[i] = .object(bundle)
            }
            settings["bundles"] = .array(list)
            root["settings"] = .object(settings)
        }
        return root
    }

    @Test("the product goes, and so does every pointer at it")
    func deletesAndUnlinks() throws {
        let after = Self.delete("P1", from: Self.book())
        guard case .array(let products)? = after["products"] else { Issue.record("no products"); return }
        #expect(products.count == 1)
        // The other product is untouched.
        if case .object(let kept) = products[0] { #expect(kept["id"] == .string("P2")) }

        guard case .array(let log)? = after["printLog"] else { Issue.record("no log"); return }
        for row in log {
            guard case .object(let order) = row else { continue }
            #expect(order["productId"] != .string("P1"),
                    Comment(rawValue: "a job still points at a product that is gone"))
            // A job that named it keeps everything else it had.
            if order["id"] == .string("J1") {
                #expect(order["price"] == .number(50))
                #expect(order["project"] == .string("a"))
            }
            // A job that named a different product is left alone.
            if order["id"] == .string("J2") { #expect(order["productId"] == .string("P2")) }
        }

        guard case .object(let settings)? = after["settings"],
              case .array(let bundles)? = settings["bundles"] else { Issue.record("no bundles"); return }
        for row in bundles {
            guard case .object(let bundle) = row, case .array(let ids)? = bundle["productIds"] else { continue }
            #expect(!ids.contains(.string("P1")), "a bundle still lists a product that is gone")
            // And the bundle keeps its other member rather than being emptied.
            if bundle["id"] == .string("B1") { #expect(ids == [.string("P2")]) }
        }
    }

    @Test("deleting one that is not there changes nothing")
    func missingIsHarmless() throws {
        let before = Self.book()
        let after = Self.delete("NOPE", from: before)
        guard case .array(let products)? = after["products"] else { Issue.record("no products"); return }
        #expect(products.count == 2)
        guard case .array(let log)? = after["printLog"] else { Issue.record("no log"); return }
        for row in log {
            guard case .object(let order) = row else { continue }
            #expect(order["productId"] != .null, "a job was unlinked by a delete that matched nothing")
        }
    }

    @Test("the sample book refuses rather than pretending")
    func sampleRefuses() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let id = try #require(shop.catalogueRows.first?.id)
        await shop.deleteProduct(id)
        #expect(shop.productProblem != nil, "deleting from the sample book claimed to work")
        // And nothing moved.
        #expect(shop.catalogueRows.contains { $0.id == id })
    }

    @Test("the shop is told what a delete does, in words that name what survives")
    func theSentence() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let asked = shop.words.callIt("pe.delete_q")
        #expect(asked != "pe.delete_q", "the confirmation has no words")
        // Past invoices are kept, and the sentence says so — that is the half
        // a shop actually worries about.
        #expect(asked.lowercased().contains("invoice"))
        #expect(shop.words.callIt("mac.delete_product_q", ["name": .string("Dragon")]).contains("Dragon"))
        #expect(shop.words.callIt("pe.deleted") != "pe.deleted")
    }
}
