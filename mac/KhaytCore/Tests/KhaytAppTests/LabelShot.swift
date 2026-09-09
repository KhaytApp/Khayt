import Foundation
import Testing
import WebKit
import AppKit
import KhaytCore
@testable import KhaytApp

/// Not a test — a way to LOOK at the label sheet.
///
/// Runs only when KHAYT_LABEL_SHOT names a file, so an ordinary test run does
/// not open a WebKit process. A sheet nobody has looked at is a sheet that
/// prints wrong at the shop's expense, in stickers.
@MainActor
struct LabelShot {
    @Test("photograph the label sheet")
    func shoot() async throws {
        guard let out = ProcessInfo.processInfo.environment["KHAYT_LABEL_SHOT"] else { return }
        let shop = Shop()
        await shop.load(.sample)
        await shop.askForShelfLabels()
        let req = try #require(shop.pendingLabels)
        let paper = LabelPaper(html: req.html)
        // WebKit lays out asynchronously; the paper says when it is done.
        for _ in 0..<200 where !paper.drawn {
            try await Task.sleep(for: .milliseconds(50))
        }
        paper.webView.frame = NSRect(x: 0, y: 0, width: 794, height: 1123)   // A4 at 96dpi
        try await Task.sleep(for: .milliseconds(600))
        let config = WKSnapshotConfiguration()
        config.rect = paper.webView.bounds
        let image = try await paper.webView.takeSnapshot(configuration: config)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: out))
        print("wrote \(out) — \(req.count) labels")
    }
}
