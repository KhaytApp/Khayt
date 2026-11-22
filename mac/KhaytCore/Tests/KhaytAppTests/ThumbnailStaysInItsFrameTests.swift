import Testing
import SwiftUI
import AppKit
@testable import KhaytApp

/// A thumbnail is the size it is offered, whatever the picture's shape.
///
/// It was a ZStack, and a ZStack is as big as its biggest child: a landscape
/// picture filling a square tile reported the size it FILLED, so the library
/// tile came out wider than its column and drew over the next print (reported
/// from the shop's Mac, Oct 13 2026).
@MainActor struct ThumbnailStaysInItsFrameTests {

    /// A picture three times wider than it is tall (or the other way round).
    static func picture(_ name: String, width: Int, height: Int) throws -> URL {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try #require(rep.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appending(path: "thumb-\(name)-\(width)x\(height).png")
        try data.write(to: url)
        return url
    }

    /// What a square tile of `side` points measures with this picture in it.
    static func tile(_ url: URL, side: CGFloat) -> CGSize {
        let view = Thumbnail(source: .file(url))
            .aspectRatio(1, contentMode: .fit)
            .environment(\.photographFlat, true)    // decoded on the spot, not in `.task`
        return NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: side, height: 1_000))
    }

    @Test("a landscape picture does not widen its tile")
    func landscape() throws {
        let size = Self.tile(try Self.picture("wide", width: 600, height: 200), side: 100)
        let width = size.width
        #expect(width <= 100.5, "a 3:1 picture made a 100pt tile \(Int(width))pt wide")
        #expect(abs(size.height - 100) < 0.5)
    }

    @Test("a portrait picture does not stretch its tile")
    func portrait() throws {
        let size = Self.tile(try Self.picture("tall", width: 200, height: 600), side: 100)
        let height = size.height
        #expect(height <= 100.5, "a 1:3 picture made a 100pt tile \(Int(height))pt tall")
        #expect(abs(size.width - 100) < 0.5)
    }
}
