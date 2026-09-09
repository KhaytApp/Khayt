import Foundation
import Testing
import CoreImage
import AppKit
import KhaytCore
@testable import KhaytApp

/// A sheet of QR labels for the rack.
///
/// `lib/labels.js` has built this sheet for a long time and the Electron app
/// prints from it; the Mac app could not reach the module. So most of what is
/// worth testing here is the BRIDGE: that the same builder is used, that the
/// code on the label is the one the other app writes, and that the QR is a real
/// QR rather than a plausible-looking square.
@MainActor
struct ShelfLabelTests {

    static func shop() async throws -> Shop {
        let s = Shop()
        await s.load(.sample)
        return s
    }

    /// THE ONE THAT MATTERS MOST. A label a scanner cannot read is a sticker.
    /// This decodes the generated image with Vision's own detector — the same
    /// job a phone does at the shelf — rather than trusting that a QR-shaped
    /// PNG contains what was asked for.
    @Test("the QR on a label decodes back to the code that was encoded")
    func itIsAReadableCode() throws {
        let wanted = ShelfLabels.code(for: "sp-4")
        let url = try #require(ShelfLabels.qr(wanted))
        let base64 = try #require(url.split(separator: ",").last.map(String.init))
        let data = try #require(Data(base64Encoded: base64))
        let image = try #require(CIImage(data: data))

        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                               options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let found = detector.features(in: image)
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        #expect(found.contains(wanted),
                "the label's QR decoded to \(found) rather than \(wanted)")
    }

    /// The code itself is a contract with the other app and with the phone.
    /// `renderer/labels.js` writes `KHAYT-SPOOL:<id>`; a Mac that wrote
    /// anything else would give a shop a rack it can only half scan.
    @Test("the code is the one the other app writes")
    func sameCodeAsElectron() throws {
        #expect(ShelfLabels.code(for: "sp-1") == "KHAYT-SPOOL:sp-1")
        let renderer = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "renderer/labels.js"),
            encoding: .utf8)
        #expect(renderer.contains("KHAYT-SPOOL:"),
                "the renderer no longer writes this code, so the two apps have drifted")
    }

    /// A label carries the item's OWN unit. A bottle of resin labelled "340 g"
    /// sends somebody to the wrong shelf — the mistake the cards made until the
    /// units work, and a sticker is harder to correct than a screen.
    @Test("a label counts a bottle of resin in millilitres")
    func labelsUseTheItemsOwnUnit() async throws {
        let shop = try await Self.shop()
        let resin = try #require(shop.spools.first { shop.unit(of: $0)?.unit == "ml" })
        guard case .object(let entry) = ShelfLabels.entry(for: resin, shop: shop),
              case .array(let lines)? = entry["lines"] else {
            Issue.record("the label has no lines"); return
        }
        let said = lines.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        #expect(said.contains { $0.contains("ml") || $0.contains("مل") },
                "a bottle of resin was labelled \(said)")
        #expect(!said.contains { $0.hasSuffix(" g") }, "labelled in grams")
    }

    /// The sheet comes from the shared builder, and carries every spool asked
    /// for. Built through the engine, so a change to `lib/labels.js` reaches
    /// this app rather than a Swift copy of it.
    @Test("the sheet is the shared builder's, and holds one card per spool")
    func theSheetIsShared() async throws {
        let shop = try await Self.shop()
        let engine = try #require(shop.engine)
        let entries = shop.spools.prefix(3).map { ShelfLabels.entry(for: $0, shop: shop) }
        let html = try await engine.labelSheet(Array(entries), heading: "Shelf labels")
        #expect(html.contains("label-grid"), "not the shared builder's markup")
        let cards = html.components(separatedBy: "lbl-card").count - 1
        #expect(cards == 3, "\(cards) cards for three spools")
        #expect(html.contains("data:image/png;base64,"), "no QR reached the sheet")
        // The id is on the label, because that is what somebody reads when the
        // camera will not focus.
        #expect(html.contains(shop.spools[0].id))
    }

    /// Nothing to label is not an empty sheet of paper.
    @Test("asking about an empty shelf raises no sheet")
    func nothingToLabel() async throws {
        let shop = try await Self.shop()
        await shop.askForShelfLabels(["no-such-spool"])
        #expect(shop.pendingLabels == nil, "a sheet with no labels on it was offered")
    }
}
