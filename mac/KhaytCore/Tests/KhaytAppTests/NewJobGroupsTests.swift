import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// New Job in three groups, with "More pricing" folded away (S1).
///
/// ── WHAT THIS SUITE IS GUARDING ───────────────────────────────────────────
///
/// Folding rush, rounding, fees, shipping and the deposit out of sight is only
/// safe if the group can never be shut over a figure that moves the total. The
/// rule is one function, and these are its cases. And a priority chosen while
/// taking a job has to reach the record, in the shape Edit Job writes.
@MainActor
struct NewJobGroupsTests {

    @Test("More pricing is in use the moment any figure inside it moves the total")
    func moreInUse() {
        func inUse(rush: Bool = false, step: Double = 0, lines: Int = 0, platform: String = "",
                   shipping: Double = 0, deposit: Double = 0) -> Bool {
            NewJobSheet.moreInUse(rush: rush, roundStep: step, extraLines: lines,
                                  platform: platform, shipping: shipping, deposit: deposit)
        }
        #expect(!inUse(), "a plain job opened with the group in use")
        #expect(inUse(rush: true))
        #expect(inUse(step: 5))
        #expect(inUse(lines: 1))
        #expect(inUse(platform: "etsy"))
        #expect(inUse(shipping: 25))
        #expect(inUse(deposit: 100))
    }

    @Test("a priority chosen while taking the job is handed to the rule; normal says nothing")
    func priorityIsHandedOver() async {
        let shop = Shop()
        await shop.load(.sample)
        func input(_ level: String) -> [String: JSONValue] {
            shop.newJobInput(parts: [], project: "Bracket", clientId: nil,
                             margin: 40, discountPct: 0, shippingCost: 0, deposit: 0,
                             rush: false, asQuote: false, priorityLevel: level)
        }
        #expect(input("urgent")["priorityLevel"] == .string("urgent"))
        #expect(input("high")["priorityLevel"] == .string("high"))
        #expect(input("normal")["priorityLevel"] == nil)
        #expect(input("whenever")["priorityLevel"] == nil)
    }

    @Test("the sheet folds the rest under More pricing, and the group cannot hide a figure in use")
    func theSheetIsWired() throws {
        let sheet = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/NewJobSheet.swift"), encoding: .utf8)
        #expect(sheet.contains("get: { showMore || moreInUse }"))
        #expect(sheet.contains("priorityLevel: priority"))
        for key in ["mac.job", "mac.parts", "mac.price", "mac.more_pricing"] {
            #expect(sheet.contains("\"\(key)\""), "\(key) is not on the sheet")
        }
    }
}
