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
        #expect(editor.components(separatedBy: ".disabled(priceLocked)").count - 1 == 7,
                "discount, shipping, presets, add line, a line's label, amount and remove")
    }
}
