import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A marketplace's cut, put on a quote without anybody typing it.
///
/// ── THE ASSERTION THAT MATTERS ────────────────────────────────────────────
///
/// Picking a marketplace twice must REPLACE its charges, not stack a second
/// copy of them. The other app says so in its own comment — a shop "only
/// notices on the finished invoice" — and an invisible extra 9.5% on a
/// customer's quote is the worst thing this screen can do.
///
/// The second is that the shop's own typed lines are never touched. Somebody
/// wrote them; a picker that quietly rewrote or reordered them would be a
/// picker nobody could use twice.
@MainActor
struct PlatformFeesTests {

    static func shop() async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        return shop
    }

    static func typed(_ label: String, amount: Double) -> Shop.ExtraLine {
        var line = Shop.ExtraLine()
        line.label = label
        line.amount = amount
        return line
    }

    @Test("the marketplaces and their rates are the shared rule's, not a copy")
    func theListIsTheRules() async throws {
        let engine = try KhaytEngine()
        let ids = try await engine.platformIds()
        #expect(ids.contains("etsy"), Comment(rawValue: "the list is \(ids)"))
        #expect(ids.count >= 5, "a list this short is a list that was copied and went stale")

        // Etsy's three, the case the request was actually about: "two
        // percentage based fees and a relisting fee of .20 for each item sold".
        let etsy = try #require(try await engine.platform("etsy", settings: [:]))
        #expect(etsy.name == "Etsy")
        #expect(etsy.lines.count == 3)
        #expect(etsy.lines.compactMap(\.pct) == [6.5, 3])
        #expect(etsy.lines.compactMap(\.amount) == [0.20])

        // And a platform nobody sells through is nothing, not an empty
        // schedule that would add no charges and say so.
        #expect(try await engine.platform("not-a-marketplace", settings: [:]) == nil)
    }

    @Test("picking a marketplace twice replaces its charges rather than stacking them")
    func pickingTwiceReplaces() async throws {
        let shop = await Self.shop()
        let mine = [Self.typed("Design fee", amount: 150),
                    Self.typed("Painting", amount: 40)]

        let once = await shop.applyingPlatform("etsy", to: mine)
        #expect(once.count == 5, Comment(rawValue: "\(once.count) lines after one pick"))
        let twice = await shop.applyingPlatform("etsy", to: once)
        #expect(twice.count == 5, Comment(rawValue:
            "picking Etsy again left \(twice.count) lines — a second copy of its charges "
            + "is an invisible extra 9.5% on a customer's quote"))

        // And the shop's own lines are the same lines, in the same order.
        #expect(twice.prefix(2).map(\.label) == ["Design fee", "Painting"])
        #expect(twice.prefix(2).allSatisfy { $0.platformId == nil })
    }

    @Test("switching marketplaces swaps the charges, and clearing removes only those")
    func switchingAndClearing() async throws {
        let shop = await Self.shop()
        let mine = [Self.typed("Design fee", amount: 150)]

        let etsy = await shop.applyingPlatform("etsy", to: mine)
        #expect(Shop.platformOn(etsy) == "etsy")
        let ebay = await shop.applyingPlatform("ebay", to: etsy)
        #expect(Shop.platformOn(ebay) == "ebay", "Etsy's lines survived the switch")
        #expect(ebay.allSatisfy { $0.platformId == nil || $0.platformId == "ebay" })

        let cleared = await shop.applyingPlatform("", to: ebay)
        #expect(cleared.map(\.label) == ["Design fee"],
                "clearing the picker took the shop's own line with it")
        #expect(Shop.platformOn(cleared) == nil)
    }

    @Test("a percentage line is handed over as a percentage, never as an amount")
    func percentagesStayPercentages() async throws {
        let shop = await Self.shop()
        let lines = await shop.feeLines(for: "etsy")
        let transaction = try #require(lines.first)
        #expect(transaction.isPercent, "the 6.5% became a flat charge")
        // `lib/pricing.js` works the percentage out against the price BEFORE
        // extras, after the margin, the discount and the rounding. Resolving it
        // here would be a second answer free to disagree with the rule's.
        guard case .object(let row) = transaction.row else {
            Issue.record("the line does not encode as an object"); return
        }
        #expect(row["pct"] == .number(6.5))
        #expect(row["amount"] == nil, "a percentage line carried a resolved amount")
        #expect(row["platformId"] == .string("etsy"),
                "the line does not say where it came from, so picking twice would stack")
    }

    @Test("a shop's own saved schedule wins, and a deleted line stays deleted")
    func theShopsOwnRatesWin() async throws {
        let engine = try KhaytEngine()
        // A shop on a legacy plan, paying less, having deleted the listing fee.
        let settings: [String: JSONValue] = ["platformFees": .object([
            "etsy": .object([
                "name": .string("Etsy (legacy)"),
                "lines": .array([.object(["key": .string("transaction"),
                                          "label": .string("Etsy transaction fee"),
                                          "pct": .number(5)])]),
            ]),
        ])]
        let etsy = try #require(try await engine.platform("etsy", settings: settings))
        #expect(etsy.name == "Etsy (legacy)")
        #expect(etsy.lines.count == 1, Comment(rawValue:
            "the shipped defaults were merged back in, so a line this shop deleted "
            + "reappears as an invisible charge: \(etsy.lines.map(\.label))"))
        #expect(etsy.lines.first?.pct == 5)
    }

    @Test("the sheet presents the picker, and the picker replaces rather than appends")
    func wired() throws {
        let sheet = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/NewJobSheet.swift"), encoding: .utf8)
        #expect(sheet.contains("calc.platform_fees"), "the picker is never drawn")
        #expect(sheet.contains("calc.platform_none"), "there is no way back to no marketplace")
        #expect(sheet.contains("applyingPlatform"),
                "the sheet builds the lines itself instead of asking the rule")
        #expect(!sheet.contains("extraLines.append(contentsOf:"),
                "appending is what stacks a second copy of the same charges")
        // And the module is bundled, or every one of the above is a call into
        // nothing that fails silently.
        let engine = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytCore/KhaytEngine.swift"), encoding: .utf8)
        #expect(engine.contains("\"platform-fees\","), "the module is not in the bundled list")
    }
}
