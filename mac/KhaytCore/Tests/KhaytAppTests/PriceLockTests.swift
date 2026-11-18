import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A job whose invoice went to ZATCA, or which was voided, credited or
/// cancelled, keeps its price: Edit Job's discount and typed price, and the
/// order editor's discount, shipping and extra charges, are shut (beta.40
/// full review, HIGH). The rule refuses it too (electron's applyJobEdit
/// lock); this is the sheet not offering it.
@MainActor
struct PriceLockTests {

    @Test("the four codes that shut the price, read off the parts rule")
    func codes() async throws {
        let engine = try KhaytEngine()
        func lock(_ extra: [String: JSONValue]) async throws -> KhaytEngine.PartsLock {
            var o: [String: JSONValue] = ["id": .string("J1"), "status": .string("pending"), "price": .number(100),
                                          "parts": .array([])]
            for (k, v) in extra { o[k] = v }
            return try await engine.partsLock(.object(o))
        }
        #expect(Shop.priceShut(try await lock(["zatcaUuid": .string("u")])))
        #expect(Shop.priceShut(try await lock(["voidedAt": .string("2026-11-01")])))
        #expect(Shop.priceShut(try await lock(["creditedAt": .string("2026-11-01")])))
        #expect(Shop.priceShut(try await lock(["status": .string("cancelled")])))
        #expect(!Shop.priceShut(try await lock([:])), "an open job")
        #expect(!Shop.priceShut(try await lock(["status": .string("completed")])), "a finished job keeps its price editable")
        #expect(!Shop.priceShut(nil), "not read yet")
        #expect(Shop.priceLockCodes == ["zatca", "voided", "credited", "cancelled"])
    }

    @Test("both sheets shut their money fields on such a job")
    func wired() {
        let sheet = MenuCoverageTests.source("JobSheet.swift")
        #expect(sheet.contains("private var priceLocked: Bool { Shop.priceShut(lock) }"))
        #expect(sheet.components(separatedBy: ".disabled(priceLocked)").count - 1 == 2, "discount, typed price")
        let editor = MenuCoverageTests.source("OrderDetailsSheet.swift")
        #expect(editor.contains("Task { partsLock = await shop.partsLock(id) }"))
        #expect(editor.contains("Shop.priceLockWords(shop.words)[$0]"), "the price sentence, not the parts one")
        #expect(editor.components(separatedBy: ".disabled(priceLocked)").count - 1 == 7,
                "discount, shipping, presets, add line, a line's label, amount and remove")
    }

    @Test("each price sentence names the price, in English and Arabic")
    func words() {
        let shop = Shop()
        let said = Shop.priceLockWords(shop.words)
        #expect(Set(said.keys) == Shop.priceLockCodes)
        for (code, sentence) in said {
            #expect(sentence.contains("price"), Comment(rawValue: code))
            #expect(!sentence.hasPrefix("mac."), "a key with no words: \(code)")
        }
    }

    @Test("the rule's price refusal (step price) is said with the price sentence")
    func refusalWords() {
        let shop = Shop()
        let all = Shop.jobSaveRefusalWords(shop.words)
        for code in Shop.priceLockCodes {
            #expect(all["price." + code] == Shop.priceLockWords(shop.words)[code], Comment(rawValue: code))
        }
        #expect(MenuCoverageTests.source("Shop+JobSheet.swift").contains(#"r.step == "price" ? "price." : """#))
    }
}
