import Testing
import SwiftUI
import KhaytCore
@testable import KhaytApp

/// The machine card in each of its working-life states — in service, under
/// service, retired — in English and Arabic, light and dark. `ImageRenderer`
/// runs no `.task`, so what is drawn is the record and nothing polled.
/// Written only when KHAYT_SNAPSHOT_DIR is set.
@Suite @MainActor struct MachineLifeSnapshotTests {

    @Test("the machine card renders active, under service and retired")
    func card() async throws {
        guard SnapshotTests.outputDir != nil else { return }
        let shop = Shop()
        await shop.load(.sample)
        // Nothing in the background may change what is drawn.
        shop.printers.stop()
        shop.cameras.stop()
        shop.stopWatchingPlugs()
        shop.stopPublishingLeadTime()
        shop.stopPollingWhatsAppReports()
        shop.stopPublishingCustomerRecords()
        let snap = SnapshotTests()

        guard case .object(let base)? = shop.machineRows.first else {
            Issue.record("the sample has no machine"); return
        }
        func variant(_ extra: [String: JSONValue]) throws -> Machine {
            var row = base
            for (k, v) in extra { row[k] = v }
            row["webcam"] = nil
            return try JSONDecoder().decode(Machine.self, from: JSONEncoder().encode(JSONValue.object(row)))
        }
        let states: [(String, Machine)] = [
            ("active", try variant([:])),
            ("service", try variant(["isOffline": .bool(true), "offlineReason": .string("Hotend on order"),
                                     "offlineSince": .string("2026-10-12")])),
            ("retired", try variant(["status": .string("retired"), "retiredAt": .string("2026-09-03"),
                                     "retiredReason": .string("Sold to a school")])),
        ]
        // The verdict a retired card's Delete reads: greyed, with the reason.
        shop.machineDeleteVerdicts[base["id"].flatMap { if case .string(let s) = $0 { s } else { nil } } ?? ""] =
            .init(ok: false, reason: "has_history", total: 15, by: ["printLog": 12, "machMaintLog": 3])

        for language in ["en", "ar"] {
            await shop.words.load(language, engine: shop.engine)
            let direction: LayoutDirection = language == "ar" ? .rightToLeft : .leftToRight
            for (name, machine) in states {
                let size = CGSize(width: 380, height: 760)
                let page = VStack(alignment: .leading, spacing: 8) {
                    MachineCard(machine: machine, wear: nil, shop: shop)
                        .opacity(machine.isRetired ? 0.62 : 1)
                    if machine.isRetired { RetiredActions(machine: machine, shop: shop) }
                }
                .padding(16)
                .frame(width: size.width, height: size.height, alignment: .top)
                .environment(shop.cameras)
                .environment(\.layoutDirection, direction)
                let file = "80-machine-\(name)-\(language)"
                try snap.render(page.background(Khayt.ground), file, size: size)
                try snap.renderDark(page, file + "-dark", size: size)
            }
            // The badge's own words, whatever the picture shows.
            #expect(MachineLifeBadge.sentence(states[1].1, shop.words)
                        .contains(shop.words.callIt("mac.life_badge_service")))
            #expect(MachineLifeBadge.sentence(states[2].1, shop.words).contains("Sold to a school"))
        }
        await shop.words.load("en", engine: shop.engine)
    }
}
