import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// What a customer's upload is priced from, on a real shop — and the quote
/// sheet published from the same inputs.
///
/// ── THE BUG THIS FOUND ────────────────────────────────────────────────────
///
/// The LAN estimate handed `publicQuote` the server's book, `Shop.lanBook`:
/// `printLog`, `waitingList`, `settings`, `machines`. `publicQuote` finds the
/// printer preset in `store.printers` and the filament in `store.inventory` —
/// neither in that book — so on a real shop every upload was refused "not
/// configured". `LanServerTests` never saw it, because its bench put
/// `printers` straight into the server's book. These tests build the books
/// with `Shop`'s OWN functions, which is the path the app runs.
@MainActor
struct PricingBookTests {

    static func engine() async throws -> KhaytEngine {
        let shop = Shop()
        await shop.load(.sample)
        return try #require(shop.engine)
    }

    /// A shop's book as it is on disk, set up to price uploads.
    static let root: [String: JSONValue] = [
        "settings": .object([
            "currency": .string("SAR"),
            "lanApi": .object(["intakeQuote": .object([
                "enabled": .bool(true), "presetId": .string("P1"), "filamentId": .string("INV-1"),
                "marginPct": .number(40), "minPrice": .number(25), "wastePct": .number(0.08),
            ])]),
        ]),
        "printers": .array([.object([
            "id": .string("P1"), "name": .string("U1"), "wearRate": .number(0.6), "powerDraw": .number(350),
            "elecRate": .number(0.18), "laborRate": .number(40), "failureRate": .number(5),
            "prepTime": .number(0.1), "postTime": .number(0.25),
        ])]),
        "inventory": .array([.object([
            "id": .string("INV-1"), "material": .string("Sunlu PETG"), "cost": .number(85),
            "weight": .number(700), "spoolWeight": .number(1000),
        ])]),
        "printLog": .array([]), "waitingList": .array([]), "machines": .array([]),
    ]

    static let sliced: JSONValue = .object([
        "exact": .bool(true), "printTimeMins": .number(95), "filamentGrams": .number(41.2),
    ])

    @Test("the book the server used could not price anything; the pricing book can")
    func pricingBookPrices() async throws {
        let engine = try await Self.engine()
        let old = try await engine.publicQuote(intake: Self.sliced, store: .object(Shop.lanBook(from: Self.root)), qty: 1)
        guard case .object(let refused) = old else { Issue.record("no answer"); return }
        #expect(refused["ok"] == .bool(false), "the phone's book priced a part — then this test proves nothing")
        let new = try await engine.publicQuote(intake: Self.sliced, store: .object(Shop.pricingBook(from: Self.root)), qty: 1)
        guard case .object(let priced) = new, case .number(let price)? = priced["price"] else {
            Issue.record("the pricing book did not price the part: \(new)"); return
        }
        #expect(priced["ok"] == .bool(true))
        #expect(price > 25)
    }

    @Test("the phone's book is unchanged — no presets or shelf were added to it")
    func phoneBookUnchanged() {
        #expect(Set(Shop.lanBook(from: Self.root).keys) == ["printLog", "waitingList", "settings", "machines"])
    }

    @Test("the quote sheet is built from the pricing book, with the calibrated estimator")
    func sheet() async throws {
        let engine = try await Self.engine()
        let sheet = try #require(try await engine.quoteSheet(store: .object(Shop.pricingBook(from: Self.root)),
                                                             now: Date(), staleAfterHours: 168))
        guard case .object(let s) = sheet, case .object(let material)? = s["material"],
              case .object(let estimator)? = s["estimator"] else { Issue.record("not a sheet"); return }
        #expect(material["spoolCost"] == .number(85))
        #expect(s["currency"] == .string("SAR"))
        #expect(!estimator.isEmpty, "the estimator was not resolved, so geometry would be priced on defaults")
        // Off is a withdrawal.
        var off = Self.root
        off["settings"] = .object(["lanApi": .object(["intakeQuote": .object(["enabled": .bool(false)])])])
        #expect(try await engine.quoteSheet(store: .object(Shop.pricingBook(from: off)), now: Date(),
                                            staleAfterHours: 168) == nil)
    }

    final class Caught: @unchecked Sendable { var request: URLRequest? }

    @Test("the sheet is PUT to the shop's quote-sheet, a withdrawal is null, and a 404 means not offered yet")
    func publisher() async throws {
        let connection = CloudReader.Connection(url: "https://cloud.khaytapp.com", shopId: "shop-7",
                                                storedToken: "sealed")
        let caught = Caught()
        func stub(_ status: Int) -> (URLRequest) async throws -> (Data, URLResponse) {
            { request in
                caught.request = request
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!)
            }
        }
        try await QuoteSheetPublisher.publish(connection, token: "tok", sheet: .object(["v": .number(1)]), fetch: stub(200))
        let sent = try #require(caught.request)
        #expect(sent.httpMethod == "PUT")
        #expect(sent.url?.path.hasSuffix("/v1/shops/shop-7/quote-sheet") == true)
        #expect(String(decoding: sent.httpBody ?? Data(), as: UTF8.self) == #"{"quoteSheet":{"v":1}}"#)
        try await QuoteSheetPublisher.publish(connection, token: "tok", sheet: nil, fetch: stub(200))
        #expect(String(decoding: caught.request?.httpBody ?? Data(), as: UTF8.self) == #"{"quoteSheet":null}"#)
        await #expect(throws: QuoteSheetPublisher.Failure.notOffered) {
            try await QuoteSheetPublisher.publish(connection, token: "tok", sheet: nil, fetch: stub(404))
        }
    }

    @Test("the app wires both: the server prices from the pricing book, and the sheet is published on the timer")
    func wired() {
        let server = MenuCoverageTests.source("LanServer.swift")
        #expect(server.contains("host.pricing = { [weak self] in self?.pricingBook ?? [:] }"),
                "nothing hands the server the pricing book, so uploads are refused again")
        #expect(server.contains("engine.publicQuote(intake: intake, store: .object(host.pricing()), qty: qty)"))
        let shop = MenuCoverageTests.source("Shop.swift")
        #expect(shop.contains("pricingBook = Self.pricingBook(from: root)"))
        #expect(shop.contains("await self?.publishQuoteSheet()"), "the quote sheet is never published")
    }
}
