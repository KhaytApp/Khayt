import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A vault over its plan after a move down, as the Mac says it (khayt-cloud
/// #143): the status row's words in both languages, the specific 402 message,
/// and the Upgrade the plan pane offers.
@MainActor
struct VaultLapseUITests {

    static let end = Calendar.instant("2027-01-23T09:00:00Z")!
    static let since = Calendar.instant("2026-10-25T09:00:00Z")!
    static let gig = 5_000_000_000

    @Test("not over says nothing; read-only says by how much and no date; deleting says the date and the days")
    func words() async throws {
        let engine = try KhaytEngine()
        for lang in ["en", "ar"] {
            let w = Words(); await w.load(lang, engine: engine)
            #expect(Shop.lapseHeadline(.notOver, w) == nil && Shop.lapseDeadline(.notOver, w) == nil)

            let fresh = try #require(Shop.lapseHeadline(.readOnly(overBytes: Self.gig, since: nil), w))
            #expect(fresh.contains(Format.fileSize(Int64(Self.gig))))
            #expect(Shop.lapseDeadline(.readOnly(overBytes: Self.gig, since: Self.since), w) == nil,
                    "read-only has no date until the cloud sets one")
            let dated = try #require(Shop.lapseHeadline(.readOnly(overBytes: Self.gig, since: Self.since), w))
            #expect(dated.contains(Shop.day(Self.since, w)) && dated != fresh)

            let d = CloudPlans.Lapse.Display.deleting(overBytes: Self.gig, deleteAfter: Self.end, daysLeft: 90, since: nil)
            let when = try #require(Shop.lapseDeadline(d, w))
            #expect(when.contains(Shop.day(Self.end, w)))
            #expect(when.contains(w.numeral(90)))
            for key in ["mac.lapse_over", "mac.lapse_over_since", "mac.lapse_delete_on", "mac.lapse_what",
                        "mac.lapse_order", "mac.lapse_fix", "mac.vault_over_err", "mac.lapse_today"] {
                #expect(w.callIt(key) != key, "\(key) has no \(lang)")
                #expect(!w.callIt(key).contains("{n}"))
            }
        }
        let ar = Words(); await ar.load("ar", engine: engine)
        #expect(Shop.lapseDeadline(.deleting(overBytes: 1, deleteAfter: Self.end, daysLeft: 0, since: nil), ar)!.contains("اليوم"))
        #expect(Shop.lapseDeadline(.deleting(overBytes: 1, deleteAfter: Self.end, daysLeft: 2, since: nil), ar)!.contains("يومان"))
        #expect(Shop.lapseDeadline(.deleting(overBytes: 1, deleteAfter: Self.end, daysLeft: 5, since: nil), ar)!.contains("أيام"))
        let en = Words(); await en.load("en", engine: engine)
        #expect(Shop.lapseDeadline(.deleting(overBytes: 1, deleteAfter: Self.end, daysLeft: 1, since: nil), en)!.contains("(1 day)"))
    }

    @Test("402 vault-over reads as its own message and marks the vault over; the deletions are not refused")
    func vaultOverMessage() {
        let shop = Shop()
        #expect(shop.vaultLapse == nil)
        let said = shop.linkProblem(VaultClient.Failure.vaultOver(used: 300, limit: 200))
        #expect(said == shop.words.callIt("mac.vault_over_err") && said != shop.words.callIt("mac.vl_err_generic"))
        #expect(shop.vaultLapse?.over == true && shop.vaultLapse?.overBytes == 100)
        #expect(shop.vaultLapse?.deleteAfter == nil, "the app never makes up a date")
        // Products route the same failure through `productProblem`.
        #expect(shop.productProblem(VaultClient.Failure.vaultOver(used: 1, limit: 0)) == said)
    }

    @Test("the move-down note is the terms' sentence with 90 days, in both languages")
    func moveDownNote() async throws {
        let engine = try KhaytEngine()
        let en = Words(); await en.load("en", engine: engine)
        let note = en.callIt("mac.plan_move_down_note", ["days": .number(90)])
        #expect(note.hasPrefix("If the vault holds more than this plan allows, it becomes read-only"))
        #expect(note.contains("a date 90 days ahead") && !note.contains("Nothing is deleted"))
        let ar = Words(); await ar.load("ar", engine: engine)
        #expect(ar.callIt("mac.plan_move_down_note", ["days": .number(90)]).contains("بعد 90 يوماً"))
        let pane = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../Sources/KhaytApp/CloudPlanSettings.swift"), encoding: .utf8)
        #expect(pane.contains(#"callIt("mac.plan_move_down_note", ["days": .number(90)])"#))
    }

    static func plan(_ name: String, sar: Double, vault: Int) throws -> CloudPlans.Plan {
        try JSONDecoder().decode(CloudPlans.Plan.self, from: Data(
            #"{"name":"\#(name)","priceSar":\#(sar),"limits":{"maxVaultBytes":\#(vault)}}"#.utf8))
    }

    @Test("Upgrade offers the cheapest plan that holds the vault, else the biggest; none from the top")
    func upgradeTarget() throws {
        let free = try Self.plan("free", sar: 0, vault: 2), maker = try Self.plan("maker", sar: 25, vault: 150)
        let creator = try Self.plan("creator", sar: 65, vault: 400), studio = try Self.plan("studio", sar: 150, vault: 1000)
        let plans = [free, maker, creator, studio]
        #expect(CloudPlanSettings.upgradeTarget(over: 100, current: free, plans: plans)?.name == "maker")
        #expect(CloudPlanSettings.upgradeTarget(over: 200, current: free, plans: plans)?.name == "creator")
        #expect(CloudPlanSettings.upgradeTarget(over: 5000, current: free, plans: plans)?.name == "studio")
        #expect(CloudPlanSettings.upgradeTarget(over: 10, current: studio, plans: plans) == nil)
    }
}
