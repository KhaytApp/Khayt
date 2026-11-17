import Foundation
import Testing
@testable import KhaytCore

/// Whether a quote is POSITIVELY a draft, so its price may follow a parts
/// change without asking: `lib/order-edit.js quoteIsDraft`, through
/// `KhaytEngine.partsLock(_:client:clients:)`.
///
/// `test/fixtures/quote-draft-vectors.json` is what
/// `test/quote-draft-vectors.test.js` holds lib to under node. The same cases
/// go through the Mac's bridge here (and the phone's, which links this
/// package), `ctx.client` and `ctx.clients` included: a bridge that dropped
/// the customer would still pass every case that does not need one, and
/// re-price a quote the customer had been messaged about.
struct QuoteDraftVectorsTests {

    struct Case: Decodable {
        let why: String
        let order: JSONValue
        let ctx: Ctx?
        let draft: Bool
        struct Ctx: Decodable { let client: JSONValue?; let clients: [JSONValue]? }
    }
    struct Vectors: Decodable { let cases: [Case] }

    static func vectors() throws -> Vectors {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/Tests/KhaytCoreTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // …/KhaytCore
            .deletingLastPathComponent()   // …/mac
            .deletingLastPathComponent()   // the repository root
            .appending(path: "test/fixtures/quote-draft-vectors.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    @Test("every shared case: a draft does not ask, anything else does")
    func vectorsAgree() async throws {
        let engine = try KhaytEngine()
        let cases = try Self.vectors().cases
        #expect(cases.count >= 12)
        #expect(cases.contains { $0.ctx?.client != nil } && cases.contains { $0.ctx?.clients != nil },
                "the fixture exercises both ways of handing over the customer")
        for c in cases {
            let lock = try await engine.partsLock(c.order, client: c.ctx?.client, clients: c.ctx?.clients)
            #expect(lock.askPrice == !c.draft, Comment(rawValue: c.why))
            #expect(lock.code == nil && lock.edit && lock.addRemove, Comment(rawValue: c.why))
        }
    }

    /// What the customer adds, and that leaving it out is the old answer: the
    /// overload is additive, so a caller that passes no customer is judged by
    /// the job alone.
    @Test("a message logged against the quote makes it sent, only when the customer is handed over")
    func theCustomerMatters() async throws {
        let engine = try KhaytEngine()
        let quote: JSONValue = .object(["id": .string("Q-1"), "status": .string("quote"), "clientId": .string("C-1"),
                                        "quoteShareStamped": .bool(true)])
        let messaged: JSONValue = .object(["id": .string("C-1"), "commLog": .array([
            .object(["id": .string("CMM-1"), "orderId": .string("Q-1"), "channel": .string("whatsapp")])])])
        let other: JSONValue = .object(["id": .string("C-1"), "commLog": .array([
            .object(["id": .string("CMM-2"), "orderId": .string("Q-OTHER")])])])
        #expect(try await engine.partsLock(quote).askPrice == false, "no customer handed over: the job alone")
        #expect(try await engine.partsLock(quote, client: messaged).askPrice)
        #expect(try await engine.partsLock(quote, clients: [messaged]).askPrice)
        #expect(try await engine.partsLock(quote, client: other).askPrice == false, "a message about another job")
        #expect(try await engine.partsLock(quote, clients: []).askPrice == false)
        // A save through the same rule reads the customers it is given.
        let part: JSONValue = .object(["id": .string("A"), "name": .string("a"), "qty": .number(1),
                                       "unitCost": .number(80), "baseCost": .number(80)])
        var priced: [String: JSONValue] = ["id": .string("Q-1"), "status": .string("quote"), "clientId": .string("C-1"),
                                           "quoteShareStamped": .bool(true), "price": .number(120),
                                           "paidAmount": .number(0), "parts": .array([part])]
        priced["marginPct"] = .number(50)
        let asked = try await engine.applyJobEdit(order: .object(priced), fields: ["marginPct": .number(60)],
                                                 clients: [messaged], now: Date(timeIntervalSince1970: 1_800_000_000),
                                                 editId: "e1", priceId: "e2")
        #expect(!asked.ok && asked.reason == "ask_price", "a new markup on a messaged quote asks")
        let quiet = try await engine.applyJobEdit(order: .object(priced), fields: ["marginPct": .number(60)],
                                                 clients: [other], now: Date(timeIntervalSince1970: 1_800_000_000),
                                                 editId: "e1", priceId: "e2")
        #expect(quiet.ok && quiet.reason == nil, "a draft takes it")
    }
}
