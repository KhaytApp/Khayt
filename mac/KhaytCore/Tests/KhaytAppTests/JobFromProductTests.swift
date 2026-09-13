import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Taking a job from something the shop already makes.
///
/// ── WHY THIS IS NOT ABOUT SAVING TYPING ───────────────────────────────────
///
/// A job taken this way carries `productId`, and that field is what the
/// catalogue counts to say a product has been made 14 times and earned 6,300.
/// A hand-typed job that happens to match a product is not counted, so every
/// figure on that screen is quietly short by it — and the shop has no way to
/// tell, because the job it typed looks right on every other screen.
///
/// It also carries the product's COMPONENTS. The magnets, the screws and the
/// box are what turn printed pieces into the thing somebody buys; a job without
/// them is under-priced by exactly their cost, every time it is sold, and the
/// consumable count on the shelf stays wrong.
@MainActor
struct JobFromProductTests {

    static func product(_ rest: [String: JSONValue], margin: Double? = 35) -> Product {
        Product(id: "PROD-1", names: ["en": "Dallah stand"], descriptions: [:],
                margin: margin, group: "", category: "",
                createdAt: "2026-09-01", rest: rest)
    }

    static let parts: JSONValue = .array([
        .object(["name": .string("Base"), "filamentId": .string("S1"),
                 "printWeight": .number(120), "printTime": .number(3.5),
                 "qty": .number(2)]),
        .object(["name": .string("Lid"), "printWeight": .number(40),
                 "printTime": .number(1), "qty": .number(1)]),
    ])

    // MARK: - What the sheet starts with

    @Test("the product's parts arrive as the job's own, ready to be changed")
    func partsArrive() {
        guard case .array(let rows) = Self.parts else { Issue.record("no parts"); return }
        let drafts = rows.compactMap(NewJobSheet.Draft.from)
        #expect(drafts.count == 2)
        #expect(drafts[0].name == "Base")
        #expect(drafts[0].spoolId == "S1")
        #expect(drafts[0].grams == "120")
        #expect(drafts[0].hours == "3.5", Comment(rawValue: "hours read as \(drafts[0].hours)"))
        #expect(drafts[0].qty == 2)
        // A part with no spool still arrives. It costs nothing until one is
        // picked, which the sheet already says out loud — dropping it would
        // silently make the job cheaper than the product.
        #expect(drafts[1].spoolId == nil)
        #expect(drafts[1].qty == 1)
    }

    @Test("a quantity of zero or nonsense is one part, not none")
    func quantityFloor() {
        let row = JSONValue.object(["name": .string("Base"), "qty": .number(0)])
        #expect(NewJobSheet.Draft.from(row)?.qty == 1)
    }

    // MARK: - What the saved job carries

    @Test("the job names the product, and brings its components with it")
    func inputCarriesTheProduct() async {
        let shop = Shop(source: .sample)
        let product = Self.product([
            "parts": Self.parts,
            "components": .array([.object(["consumableId": .string("C2"),
                                           "qtyPerUnit": .number(1)])]),
            "assemblyQty": .number(2),
        ])
        let input = shop.newJobInput(
            parts: [], project: "Dallah stand", clientId: nil, margin: 35,
            discountPct: 0, shippingCost: 0, deposit: 0, rush: false, asQuote: false,
            fromProduct: product)

        #expect(input["productId"] == .string("PROD-1"),
                "the catalogue cannot count a job that does not name its product")
        guard case .array(let components)? = input["components"] else {
            Issue.record("the components did not travel"); return
        }
        #expect(components.count == 1)
        #expect(input["assemblyQty"] == .number(2))
    }

    @Test("a job typed by hand names no product, rather than naming a wrong one")
    func handTypedNamesNothing() async {
        let shop = Shop(source: .sample)
        let input = shop.newJobInput(
            parts: [], project: "One-off bracket", clientId: nil, margin: 40,
            discountPct: 0, shippingCost: 0, deposit: 0, rush: false, asQuote: false)
        #expect(input["productId"] == nil)
        #expect(input["components"] == nil)
    }

    @Test("the shared rule keeps all three, so this is not a field the Mac invents")
    func theRuleKeepsThem() async throws {
        // `lib/order-new.js` is what writes the record, and a key it drops is a
        // key this app is only pretending to set.
        let engine = try KhaytEngine()
        let out = try await engine.newOrder(
            ["project": .string("Dallah stand"), "productId": .string("PROD-1"),
             "assemblyQty": .number(2),
             "components": .array([.object(["consumableId": .string("C2"),
                                            "qtyPerUnit": .number(1)])]),
             "parts": .array([.object(["printWeight": .number(120), "qty": .number(1)])])],
            orders: [], settings: [:], now: Date(),
            tokens: (tracking: Array(repeating: 7, count: 16),
                     quoteApproval: Array(repeating: 9, count: 16)))
        guard case .object(let order) = out.order else { Issue.record("no order"); return }
        #expect(order["productId"] == .string("PROD-1"))
        #expect(order["assemblyQty"] == .number(2))
        guard case .array(let components)? = order["components"] else {
            Issue.record("the rule dropped the components"); return
        }
        #expect(components.count == 1)
    }

    // MARK: - The tiers

    @Test("a product's named margins are read, and the unusable ones are not")
    func tiers() {
        let product = Self.product(["priceTiers": .array([
            .object(["label": .string("Retail"), "margin": .number(45)]),
            .object(["label": .string("Wholesale"), "margin": .number(20)]),
            // No name: a chip nobody can pick on purpose.
            .object(["label": .string("  "), "margin": .number(10)]),
            // No margin: there is nothing for picking it to do.
            .object(["label": .string("Trade")]),
        ])])
        let tiers = Shop.tiers(of: product)
        #expect(tiers.map(\.label) == ["Retail", "Wholesale"],
                Comment(rawValue: "read \(tiers.map(\.label))"))
        #expect(tiers.first?.margin == 45)
    }

    @Test("a product with no tiers offers none, rather than one made up")
    func noTiers() {
        #expect(Shop.tiers(of: Self.product([:])).isEmpty)
        #expect(Shop.tiers(of: nil).isEmpty)
    }

    // MARK: - The wiring

    @Test("the catalogue can actually start one, and the sheet actually fills")
    func wired() throws {
        // The bug this catches is the one that keeps happening: a correct
        // method nothing calls. Delete either line and the app still builds,
        // still shows the menu item, and does nothing.
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        let catalogue = try String(contentsOf: dir.appending(path: "Catalogue.swift"),
                                   encoding: .utf8)
        #expect(catalogue.contains("shop.takeJob(from: product)"),
                "the catalogue offers to take a job and never starts one")
        let sheet = try String(contentsOf: dir.appending(path: "NewJobSheet.swift"),
                               encoding: .utf8)
        #expect(sheet.contains("shop.jobFromProduct"),
                "the sheet never looks at the product it was opened for")
        #expect(sheet.contains("fromProduct: product"),
                "the sheet fills from a product and saves a job that does not name it")
    }
}
