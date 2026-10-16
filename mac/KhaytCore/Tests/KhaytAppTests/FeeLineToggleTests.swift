import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The New Job sheet's "Platform fee" toggle on a percentage extra line.
///
/// ── WHAT THIS SUITE IS GUARDING ───────────────────────────────────────────
///
/// `lib/pricing.js` grosses up only FEE lines — a percentage with a
/// `platformId` or an explicit `fee: true`. A shop selling on a marketplace
/// the picker does not list typed "Noon 10%" and got a surcharge: 10% of the
/// price before extras, which the platform then takes 10% of the FINAL price
/// for, and the shop keeps less than it quoted. The toggle is how a typed line
/// says "this is a platform's cut".
///
/// Off, the record must not change at all: no `fee: false`, so a book written
/// before the toggle existed reads back byte-identical.
@MainActor
struct FeeLineToggleTests {

    static func percent(_ label: String, _ pct: Double, fee: Bool = false) -> Shop.ExtraLine {
        var line = Shop.ExtraLine(); line.label = label; line.pct = pct; line.fee = fee; return line
    }

    static var sheetSource: String {
        get throws {
            try String(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Sources/KhaytApp/NewJobSheet.swift"), encoding: .utf8)
        }
    }

    @Test("on writes fee: true; off writes no fee key at all")
    func writesOrOmits() throws {
        guard case .object(let on) = Self.percent("Noon", 10, fee: true).row,
              case .object(let off) = Self.percent("Noon", 10).row else {
            Issue.record("a line did not encode as an object"); return
        }
        #expect(on["fee"] == .bool(true))
        #expect(off["fee"] == nil, "an ordinary surcharge grew a fee key")
        #expect(Set(off.keys) == ["label", "pct"], "a line without the toggle changed shape")

        // A flat amount cannot be a percentage fee, whatever the flag says.
        var flat = Shop.ExtraLine(); flat.label = "Design"; flat.amount = 50; flat.fee = true
        guard case .object(let flatRow) = flat.row else { Issue.record("not an object"); return }
        #expect(flatRow["fee"] == nil)
        #expect(!flat.isFeeLine)
    }

    @Test("a 10% line on 100: 110 as a surcharge, 111.11 as a platform fee")
    func theTotalMoves() async throws {
        let shop = Shop()
        await shop.load(.sample)
        #expect(shop.engineProblem == nil, "no engine means this proves nothing")
        let plain = try #require(await shop.previewQuote(
            baseCost: 100, margin: 0, discountPct: 0, shippingCost: 0, rush: false))
        #expect(abs(plain.total - 100) < 0.005, "the base is not 100, so the figures below mean nothing")
        let off = try #require(await shop.previewQuote(
            baseCost: 100, margin: 0, discountPct: 0, shippingCost: 0, rush: false,
            extraLines: [Self.percent("Noon", 10)]))
        let on = try #require(await shop.previewQuote(
            baseCost: 100, margin: 0, discountPct: 0, shippingCost: 0, rush: false,
            extraLines: [Self.percent("Noon", 10, fee: true)]))
        #expect(abs(off.total - 110) < 0.005, "surcharge: \(off.total)")
        #expect(abs(on.total - 111.11) < 0.005, "fee: \(on.total)")
        #expect(off.feePct == nil)
        #expect(on.feePct == 10)
    }

    @Test("a marketplace line is a fee by its platformId, and the sheet locks it on")
    func platformLineIsLocked() throws {
        var line = Self.percent("Etsy transaction fee", 6.5)
        line.platformId = "etsy"
        #expect(line.isFeeLine, "a marketplace line did not read as a fee")
        guard case .object(let row) = line.row else { Issue.record("not an object"); return }
        // Its platformId says so already; the picker's lines are unchanged.
        #expect(row["fee"] == nil)
        #expect(row["platformId"] == .string("etsy"))

        let sheet = try Self.sheetSource
        #expect(sheet.contains("mac.extra_fee"), "the sheet has no fee toggle")
        #expect(sheet.contains("get: { line.isFeeLine }"), "the toggle does not show what the rule will do")
        #expect(sheet.contains(".disabled(line.platformId != nil)"), "a marketplace line's toggle is not locked")
        #expect(sheet.contains("mac.extra_fee_from"), "a locked toggle does not say why")
        #expect(sheet.contains("mac.extra_fee_hint"), "the toggle has no caption")
    }

    @Test("a fee line survives a save through lib/order-new.js and reads back on")
    func survivesSaveAndReload() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let input = shop.newJobInput(
            parts: [], project: "Noon order", clientId: nil,
            margin: 40, discountPct: 0, shippingCost: 0, deposit: 0,
            rush: false, asQuote: true,
            extraLines: [Self.percent("Noon", 10, fee: true), Self.percent("Packing", 5)])
        let engine = try KhaytEngine()
        let out = try await engine.newOrder(
            input, orders: [], settings: shop.settingsDict, now: Date(),
            tokens: (tracking: Array(repeating: 7, count: 16),
                     quoteApproval: Array(repeating: 9, count: 16)))
        guard case .object(let order) = out.order,
              case .array(let saved)? = order["extraLines"] else {
            Issue.record("the saved job carries no extra lines"); return
        }
        #expect(saved.count == 2)
        guard case .object(let first)? = saved.first, case .object(let second)? = saved.last else {
            Issue.record("a saved line is not an object"); return
        }
        #expect(first["fee"] == .bool(true), "lib/order-new.js dropped the fee flag")
        #expect(second["fee"] == nil, "a surcharge was saved with a fee key")

        // Read back the way the sheet reads a job it reopens.
        let back = saved.compactMap(Shop.extraLine(from:))
        #expect(back.map(\.fee) == [true, false])
        #expect(back.map(\.isFeeLine) == [true, false])
    }
}
