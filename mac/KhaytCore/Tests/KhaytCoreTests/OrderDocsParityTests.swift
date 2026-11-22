import Foundation
import Testing
@testable import KhaytCore

/// Which papers travel with an order, against the JavaScript it came from.
///
/// The rule the port could get wrong silently is the default: a document with
/// no `packWithOrder` flag SHIPS. Read the other way, a shop that attached
/// safety sheets before the flag existed would stop shipping them and nothing
/// on screen would say so. So every awkward value goes in that field, not just
/// `true` and `false`.
@MainActor
struct OrderDocsParityTests {

    private func js() throws -> JSModule { try JSModule(["product-docs"]) }

    private func theirs(_ js: JSModule, _ fn: String,
                        _ order: JSONValue, _ products: [JSONValue]) throws -> [OrderDocs.Doc] {
        guard case .array(let rows) = try js.value(
            "globalThis.KhaytProductDocs.\(fn)(ARG0, ARG1)", [order, .array(products)])
        else { return [] }
        return rows.compactMap { row in
            guard case .object(let d) = row,
                  case .string(let filename)? = d["filename"],
                  case .string(let name)? = d["name"],
                  case .bool(let packs)? = d["packWithOrder"] else { return nil }
            return OrderDocs.Doc(filename: filename, name: name, packWithOrder: packs)
        }
    }

    private func check(_ order: JSONValue, _ products: [JSONValue],
                       _ what: String) throws {
        let js = try js()
        #expect(OrderDocs.forOrder(order, products: products)
                == (try theirs(js, "docsForOrder", order, products)),
                Comment(rawValue: "docsForOrder: \(what)"))
        #expect(OrderDocs.packableForOrder(order, products: products)
                == (try theirs(js, "packableDocsForOrder", order, products)),
                Comment(rawValue: "packableDocsForOrder: \(what)"))
    }

    /// A product carrying one document whose flag is `value`.
    private func product(flag: JSONValue?) -> [JSONValue] {
        var doc: [String: JSONValue] = ["filename": .string("p1-abc.pdf"),
                                        "originalName": .string("Assembly.pdf")]
        if let flag { doc["packWithOrder"] = flag }
        return [.object(["id": .string("p1"), "docs": .array([.object(doc)])])]
    }

    @Test("absent means yes — and so does every value except a literal false")
    func theDefaultHolds() throws {
        let order = JSONValue.object(["productId": .string("p1")])
        try check(order, product(flag: nil), "no flag at all")
        var values: [JSONValue] = [.bool(true), .bool(false), .null, .number(0), .number(1),
                                   .string(""), .string("false"), .string("no"), .string("0"),
                                   .array([]), .object([:])]
        values += Awkward.notNumbers
        for value in values {
            try check(order, product(flag: value), "flag = \(value)")
        }
        // And the answer had better actually be "ships" for the absent case,
        // not merely "the same wrong answer in both languages".
        #expect(OrderDocs.forOrder(order, products: product(flag: nil)).first?.packWithOrder == true)
        #expect(OrderDocs.forOrder(order, products: product(flag: .bool(false))).first?.packWithOrder == false)
    }

    @Test("a document named only one way round, and one named neither")
    func namingMatches() throws {
        let order = JSONValue.object(["productId": .string("p1")])
        let docs: [JSONValue] = [
            .object(["filename": .string("only-file.pdf")]),
            .object(["originalName": .string("Only original.pdf")]),
            .object(["filename": .string(""), "originalName": .string("")]),
            .object([:]),
            .object(["filename": .null, "originalName": .string("N")]),
            .object(["filename": .number(12), "originalName": .number(0)]),
            .object(["filename": .bool(true)]),
            .object(["filename": .array([.string("a"), .string("b")])]),
            .string("not a doc"), .null, .number(3),
        ]
        try check(order, [.object(["id": .string("p1"), "docs": .array(docs)])], "odd names")
    }

    @Test("an order with no product, and a product that is not there")
    func missingThingsMatch() throws {
        let products = product(flag: nil)
        for order in [JSONValue.object([:]),
                      .object(["productId": .string("")]),
                      .object(["productId": .null]),
                      .object(["productId": .number(0)]),
                      .object(["productId": .string("p2")]),
                      .object(["productId": .bool(true)]),
                      .null, .string("p1"), .number(1), .array([])] {
            try check(order, products, "order \(order)")
        }
    }

    @Test("an id that only matches loosely does not match")
    func strictIdMatching() throws {
        // `p.id === id`. A product filed under the number 7 must not answer an
        // order asking about "7" — loose matching is how one job ends up
        // carrying another product's paperwork.
        let numbered: [JSONValue] = [.object(["id": .number(7),
                                              "docs": .array([.object(["filename": .string("f")])])])]
        try check(.object(["productId": .string("7")]), numbered, "string 7 vs number 7")
        try check(.object(["productId": .number(7)]), numbered, "number 7 vs number 7")
    }

    @Test("a product with no docs, docs that are not a list, and several products")
    func productShapesMatch() throws {
        let order = JSONValue.object(["productId": .string("p1")])
        for products in [[JSONValue.object(["id": .string("p1")])],
                         [.object(["id": .string("p1"), "docs": .null])],
                         [.object(["id": .string("p1"), "docs": .string("x")])],
                         [.object(["id": .string("p1"), "docs": .object([:])])],
                         [],
                         [.null, .string("x"), .object(["id": .string("p1"),
                                                        "docs": .array([.object(["filename": .string("a")])])])],
                         // Two products with the same id: the FIRST answers.
                         [.object(["id": .string("p1"), "docs": .array([.object(["filename": .string("first")])])]),
                          .object(["id": .string("p1"), "docs": .array([.object(["filename": .string("second")])])])]] {
            try check(order, products, "products \(products.count)")
        }
    }

    @Test("a real product's papers, both audiences")
    func realProductMatches() throws {
        let order = JSONValue.object(["productId": .string("prod-lamp"), "project": .string("Lamp ×4")])
        let products: [JSONValue] = [.object([
            "id": .string("prod-lamp"),
            "docs": .array([
                .object(["filename": .string("prod-lamp-m3x9f.pdf"),
                         "originalName": .string("Assembly instructions.pdf")]),
                .object(["filename": .string("prod-lamp-m3xa0.pdf"),
                         "originalName": .string("Safety sheet.pdf"),
                         "packWithOrder": .bool(true)]),
                .object(["filename": .string("prod-lamp-m3xa1.pdf"),
                         "originalName": .string("Machine setup.pdf"),
                         "packWithOrder": .bool(false)]),
            ]),
        ])]
        try check(order, products, "the lamp")
        #expect(OrderDocs.forOrder(order, products: products).count == 3)
        #expect(OrderDocs.packableForOrder(order, products: products).count == 2)
    }
}
