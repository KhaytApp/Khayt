import Foundation
import QuickLookThumbnailing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import KhaytCore

/// What Finder shows for a `.3mf`.
///
/// ── WHY THIS IS WORTH A WHOLE EXTENSION ───────────────────────────────────
///
/// A shop's library is 3MF files and macOS has never heard of them: no icon, no
/// preview, no type — `mdls` on one of this shop's models reports
/// `dyn.ah62d4rv4ge8xg5pg`, which is macOS's way of saying it has no idea. Ten
/// identical blank document icons in a Finder window, each 46 MB, each a
/// different king.
///
/// The picture is already inside the file. A 3MF is a zip and every one of them
/// carries a plate render the slicer wrote; `ThreeMF.preview` decides which
/// member that is, and this reads it out. Nothing is rendered, nothing is
/// parsed, no mesh is touched — the largest of these files is 436 MB of triangle
/// data and the thumbnail is 160 KB of PNG sitting beside it in the archive.
///
/// This is the sort of thing only a native app can do. A window cannot tell
/// Finder what a file looks like.
@objc(KhaytThumbnailProvider)
final class KhaytThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        do {
            let image = try Self.picture(inside: request.fileURL)
            let reply = ThreeMF.thumbnailSize(
                for: CGSize(width: image.width, height: image.height),
                maximum: request.maximumSize, scale: request.scale)
            handler(QLThumbnailReply(contextSize: reply) { context in
                // DRAW INTO THE CONTEXT'S OWN BOUNDS, NOT INTO `reply`.
                //
                // `contextSize` is documented in points, and the obvious thing —
                // drawing a rect of that size — put the picture in the bottom-left
                // quarter of the reply. The context handed over here is 1024×1024
                // for a 512-point reply at scale 2 and its CTM is the identity, so
                // point units address a quarter of it. Asking the context what it
                // covers is right under either reading, and survives the day macOS
                // starts applying the transform.
                context.interpolationQuality = .high
                context.draw(image, in: context.boundingBoxOfClipPath)
                return true
            }, nil)
        } catch {
            // No reply and no error: a 3MF a CAD program wrote has no preview in
            // it, and that is not a failure. Finder falls back to the generic
            // icon, which is what it would have shown anyway.
            handler(nil, nil)
        }
    }

    enum Failure: Error { case noPreview, notAnImage }

    /// The plate render inside a 3MF, decoded.
    static func picture(inside url: URL) throws -> CGImage {
        let entries = try Zip.entries(of: url)
        guard let name = ThreeMF.preview(among: entries.map(\.name)),
              let entry = entries.first(where: { $0.name == name }) else {
            throw Failure.noPreview
        }
        let data = try Zip.data(of: entry, in: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure.notAnImage
        }
        return image
    }
}
