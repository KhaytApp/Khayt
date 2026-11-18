import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A payment the shared rule refuses is not recorded (Dev Hub, Nov 18: the
/// engine's payment script dropped `refused`, so a refused payment looked like
/// one recorded on the Mac and on the phone). The rule's coming `plan_recorded`
/// refusal (a total below the plan's base plus its recorded rows) depends on it.
@MainActor
struct PaymentRefusedTests {

    static func recorded(_ json: String) throws -> PaymentRecorded {
        try JSONDecoder().decode(PaymentRecorded.self, from: Data(json.utf8))
    }

    @Test("a refused payment throws the refusal and writes nothing")
    func refusedThrows() async throws {
        let shop = Shop()
        await shop.load(.sample)   // the shared words (`pay.*`) come with a book
        let refused = try Self.recorded(#"{"order":{"id":"J1"},"effects":[],"refused":"plan_recorded","refusedKey":null,"floor":150}"#)
        do {
            try Shop.throwIfRefused(refused, words: shop.words, settings: ["currency": .string("SAR")])
            Issue.record("a refused payment went through")
        } catch let r as Shop.MoveRefused {
            #expect(r.code == "plan_recorded")
            #expect(r.sentence == shop.words.callIt("mac.payment_refused"), "no key from the rule: the plain sentence")
            #expect(!r.sentence.hasPrefix("mac."))
        }
        // With the rule's own words, they are used, the floor filled in.
        let worded = try Self.recorded(#"{"order":{"id":"J1"},"effects":[],"refused":"plan_collected","refusedKey":"pay.clear_plan_first","floor":null}"#)
        do {
            try Shop.throwIfRefused(worded, words: shop.words, settings: [:])
            Issue.record("a refused payment went through")
        } catch let r as Shop.MoveRefused {
            let said = shop.words.callIt("pay.clear_plan_first")
            #expect(said != "pay.clear_plan_first", "the shared words are loaded")
            #expect(r.sentence == said)
        }
        let fine = try Self.recorded(#"{"order":{"id":"J1"},"effects":["save"]}"#)
        #expect(throws: Never.self) { try Shop.throwIfRefused(fine, words: shop.words, settings: [:]) }
    }

    @Test("the engine carries the rule's refusal, and a recorded payment has none")
    func engineCarriesIt() async throws {
        let engine = try KhaytEngine()
        let order: JSONValue = .object(["id": .string("J1"), "status": .string("pending"), "price": .number(100),
                                        "paidAmount": .number(0)])
        let done = try await engine.recordPayment(order: order, amount: 40, method: "cash",
                                                  paidAt: "2026-11-18", today: "2026-11-18")
        #expect(done.refused == nil && done.refusedKey == nil && done.floor == nil)
        let src = (try? String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytCore/KhaytEngine.swift"), encoding: .utf8)) ?? ""
        #expect(src.contains("refused: r.refused || null,\n    refusedKey: said ? said.key : null,"))
    }

    @Test("every Mac caller stops at a refusal")
    func callersStop() {
        #expect(MenuCoverageTests.source("Shop+Money.swift").contains("try Self.throwIfRefused(done, words: self.words, settings: settings)"))
        #expect(MenuCoverageTests.source("Shop+Bnpl.swift").contains("try Self.throwIfRefused(done, words: self.words, settings: settings)"))
        #expect(MenuCoverageTests.source("OnlineOrders.swift").contains("if done.refused == nil { job = done.order }"))
    }
}
