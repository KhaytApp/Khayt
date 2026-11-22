import Foundation
import Testing
import SwiftUI
import AppKit
import KhaytCore
@testable import KhaytApp

/// The screens the alpha.56 review found faults on, photographed light and
/// dark in whatever language `KHAYT_LANG` asks for. Writes only when
/// KHAYT_SNAPSHOT_DIR is set, like `SnapshotTests`. Serialized because the
/// machine sheet is opened through `MachineSheet.opensOn`, a static.
@Suite(.serialized) @MainActor
struct ReviewFixSnapshotTests {

    private var lang: String { ProcessInfo.processInfo.environment["KHAYT_LANG"] ?? "en" }

    private func both(_ view: some View, _ name: String, _ size: CGSize) throws {
        let s = SnapshotTests()
        try s.render(view.background(Khayt.surface), "\(name)-\(lang)", size: size)
        try s.renderDark(view.background(Khayt.surface), "\(name)-\(lang)-dark", size: size)
    }

    @Test("a laser cutter's sheet calls it a machine")
    func laserSheet() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let laser = try #require(shop.machines.first { shop.kind(of: $0)?.kind == "laser" },
                                 "the sample shop has no laser cutter to draw")
        try both(MachineSheet(shop: shop, existing: laser), "95-machine-laser",
                 CGSize(width: MachineSheet.width, height: 560))
        MachineSheet.opensOn = "value"
        defer { MachineSheet.opensOn = "printer" }
        try both(MachineSheet(shop: shop, existing: laser), "95-machine-laser-value",
                 CGSize(width: MachineSheet.width, height: 560))
    }

    @Test("the downtime row, its arrow and its dates")
    func downtimeRow() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let blocks = Binding.constant([Shop.DowntimeBlock(from: "2026-10-02T09:00", to: "2026-10-02T13:00",
                                                          reason: "Belt")])
        try both(DowntimeEditor(shop: shop, blocks: blocks).padding(16).frame(width: 640),
                 "95-downtime-row", CGSize(width: 640, height: 110))
    }

    @Test("the consumable and spool sheets, with their units")
    func unitSheets() async throws {
        let shop = Shop()
        await shop.load(.sample)
        try both(ConsumableSheet(shop: shop, existing: shop.consumables.first), "95-consumable",
                 CGSize(width: ConsumableSheet.width, height: 520))
        try both(SpoolSheet(shop: shop, existing: shop.spools.first), "95-spool",
                 CGSize(width: SpoolSheet.width, height: 620))
    }

    @Test("the edit-job sheet stays inside its margins")
    func editJob() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let job = try #require(shop.orders.first)
        try both(EditJobSheet(shop: shop, subject: Shop.PendingHold(id: job.id, project: job.project)),
                 "95-edit-job", CGSize(width: EditJobSheet.width, height: 330))
    }
}

/// The words behind the alpha.56 fixes.
@Suite @MainActor
struct ReviewFixWordsTests {

    @Test("the currency menu is named and sorted in the shop's language")
    func currencies() async throws {
        let table = ["SAR": "Saudi Riyal (SAR)", "USD": "US Dollar (USD)", "EUR": "Euro (EUR)"]
        let ar = Words()
        await ar.load("ar", engine: try KhaytEngine())
        let arabic = ar.currencyChoices(table)
        #expect(arabic.first { $0.code == "SAR" }?.label == "ريال سعودي (SAR)")
        #expect(arabic.allSatisfy { !$0.label.contains("Dollar") && !$0.label.contains("Riyal") },
                "an English name in the Arabic menu: \(arabic)")
        // دولار < ريال < يورو in Arabic order; English would put Euro first.
        #expect(arabic.map(\.code) == ["USD", "SAR", "EUR"])

        let en = Words()
        await en.load("en", engine: try KhaytEngine())
        #expect(en.currencyChoices(table).map(\.code) == ["EUR", "SAR", "USD"])
        // The book's own currency is offered even when the table lacks it.
        #expect(en.currencyChoices(table, current: "XYZ").contains { $0.code == "XYZ" })
    }

    @Test("a setup failure is a sentence, never Swift's description of the error")
    func setupFailure() async throws {
        for lang in ["en", "ar"] {
            let words = Words()
            await words.load(lang, engine: try KhaytEngine())
            let said = [
                words.setupFailure(CocoaError(.fileWriteFileExists), startingBook: true),
                words.setupFailure(CocoaError(.fileWriteNoPermission), startingBook: true),
                words.setupFailure(StoreWriter.Refusal.notOurs("Electron"), startingBook: false),
                words.setupFailure(StoreWriter.Refusal.tooLarge(60_000_000), startingBook: false),
                words.setupFailure(StoreWriter.Refusal.unreadable("gone"), startingBook: false),
                words.setupFailure(KhaytJSError.evaluationFailed("boom"), startingBook: false),
            ]
            #expect(Set(said).count == said.count, "two failures said the same thing in \(lang)")
            for line in said {
                #expect(!line.hasPrefix("mac."), "a missing word: \(line)")
                #expect(!line.contains("Error") && !line.contains("Refusal") && !line.contains("boom"),
                        "Swift's own text reached the sheet: \(line)")
            }
        }
    }

    @Test("only a laser cutter and a CNC router are called machines")
    func machineWording() {
        #expect(["fdm", "resin", "uv"].allSatisfy(MachineSheet.isPrinter))
        #expect(!MachineSheet.isPrinter("laser"))
        #expect(!MachineSheet.isPrinter("cnc"))
    }
}

/// The Edit Job sheet's controls stay inside its 18pt margins.
///
/// Measured in a real `NSHostingView`, because `ImageRenderer` draws the
/// segmented control as a placeholder of whatever width it is offered and so
/// photographs this as fine. At 460 wide the English priority control ran
/// past the right margin.
@Suite @MainActor
struct EditJobMarginTests {

    @Test("no control in the Edit Job sheet reaches into its margins", arguments: ["en", "ar"])
    func margins(lang: String) async throws {
        let shop = Shop()
        await shop.load(.sample)
        await shop.words.load(lang, engine: try KhaytEngine())
        let job = try #require(shop.orders.first)
        let host = NSHostingView(rootView: EditJobSheet(
            shop: shop, subject: Shop.PendingHold(id: job.id, project: job.project)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: EditJobSheet.width, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        var controls: [CGRect] = []
        func walk(_ view: NSView) {
            if view is NSControl { controls.append(view.convert(view.bounds, to: host)) }
            view.subviews.forEach(walk)
        }
        walk(host)
        #expect(!controls.isEmpty, "found nothing to measure")
        for frame in controls {
            #expect(frame.minX >= 17 && frame.maxX <= EditJobSheet.width - 17,
                    "a control at \(frame) is in the margin of a \(EditJobSheet.width)pt sheet (\(lang))")
        }
    }
}
