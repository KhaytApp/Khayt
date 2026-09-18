import Foundation
import AppKit
import Testing
import KhaytCore
@testable import KhaytApp

/// The shop's own mark, on the documents it hands a customer.
///
/// This app printed Khayt's mark where the other app printed the shop's, for
/// as long as it could print an invoice — the engine answered `safeBizLogo()`
/// with the empty string always.
@MainActor
struct ShopLogoTests {

    private func written(_ bytes: [UInt8], ext: String = "png") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "khayt-logo-\(UUID().uuidString).\(ext)")
        try Data(bytes).write(to: url)
        return url
    }

    private func png(_ side: Int) throws -> URL {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        NSGraphicsContext.restoreGraphicsState()
        let data = try #require(rep.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory
            .appending(path: "khayt-logo-\(UUID().uuidString).png")
        try data.write(to: url)
        return url
    }

    @Test("the cap is the other app's own cap")
    func capMatches() {
        // `file.size > 1024 * 1024` in `renderer/wire-events.js`. Matched
        // rather than chosen: the bytes live in the book, so they are in every
        // sync, every backup and every export of the settings.
        #expect(ShopLogo.maxBytes == 1024 * 1024)
    }

    @Test("a picture becomes a data URI the document will accept")
    func encodes() throws {
        let uri = try ShopLogo.dataURI(of: try png(200))
        #expect(uri.hasPrefix("data:image/png;base64,"))
        // The same test the document applies, so what Settings shows and what
        // the invoice prints cannot disagree.
        #expect(uri.hasPrefix("data:image/"))
        #expect(ShopLogo.image(from: uri) != nil)
    }

    @Test("the format is read from the bytes, not from the name")
    func sniffsTheBytes() throws {
        #expect(ShopLogo.mediaType(of: Data([0x89, 0x50, 0x4E, 0x47, 0x0D])) == "image/png")
        #expect(ShopLogo.mediaType(of: Data([0xFF, 0xD8, 0xFF, 0xE0])) == "image/jpeg")
        #expect(ShopLogo.mediaType(of: Data("GIF89a".utf8)) == "image/gif")
        var webp = Data("RIFF".utf8); webp.append(Data([0, 0, 0, 0])); webp.append(Data("WEBP".utf8))
        #expect(ShopLogo.mediaType(of: webp) == "image/webp")
        // An SVG is text and could carry a script, on a document handed to a
        // customer. Refused rather than sniffed.
        #expect(ShopLogo.mediaType(of: Data("<svg xmlns=".utf8)) == nil)
        #expect(ShopLogo.mediaType(of: Data()) == nil)
        #expect(ShopLogo.mediaType(of: Data("not a picture at all".utf8)) == nil)
    }

    @Test("a file that is not a picture is refused, whatever it is called")
    func refusesTheWrongThing() throws {
        let fake = try written(Array("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8))
        #expect(throws: ShopLogo.Refused.notAnImage) { _ = try ShopLogo.dataURI(of: fake) }
    }

    @Test("a picture over the cap is refused with its own sentence")
    func refusesTheTooBig() throws {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        bytes += Array(repeating: 0, count: ShopLogo.maxBytes)
        let big = try written(bytes)
        #expect(throws: ShopLogo.Refused.tooBig(bytes.count)) { _ = try ShopLogo.dataURI(of: big) }
    }

    @Test("only a data URI is read back, so a stored URL draws nothing")
    func onlyDataURIs() {
        #expect(ShopLogo.image(from: "https://example.com/logo.png") == nil)
        #expect(ShopLogo.image(from: "") == nil)
        #expect(ShopLogo.image(from: nil) == nil)
        #expect(ShopLogo.image(from: "data:image/png;base64,not base64") == nil)
    }

    @Test("the document is handed the same guarded value")
    func documentUsesTheGuard() throws {
        // The engine used to answer the empty string always, so every invoice
        // carried Khayt's mark. It passes the value now — through the same
        // `data:image/` test, which is the security rule, not the refusal.
        let engine = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytCore/KhaytEngine.swift"), encoding: .utf8)
        guard let at = engine.range(of: "safeBizLogo: function () {") else {
            Issue.record("safeBizLogo has moved"); return
        }
        let body = engine[at.lowerBound...].prefix(260)
        #expect(body.contains("settings.bizLogo"), "the document is still handed nothing")
        #expect(body.contains("data:image/"), "the guard is gone")
    }

    @Test("the control is on the pane that ships")
    func wiredIn() throws {
        let pane = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/SettingsWindow.swift"), encoding: .utf8)
        #expect(pane.contains("shop.pickLogo()"), "nothing in Settings can set a logo")
        #expect(pane.contains("shop.clearLogo()"), "nothing can take it off again")
    }

    @Test("the sample shop is told it cannot")
    func sampleRefuses() async throws {
        let shop = Shop()
        await shop.load(.sample)
        shop.setLogo(from: try png(64))
        #expect(shop.writeProblem == shop.words.callIt("mac.move_sample"))
        #expect(shop.bizLogo.isEmpty)
    }
}
