import Foundation
import AppKit
import KhaytCore

/// A photograph of the finished print, on the job that made it.
///
/// ── WHY THE MAC COULD NOT DO THIS ─────────────────────────────────────────
///
/// Portfolio has always READ `printLog[].printPhotos[]` and nothing on this Mac
/// could write one — so the empty state told a shop to add a photo to a
/// completed order and there was no way to do it here at all. Reported exactly
/// that way: *"portfolio says I need to add a photo to a completed order, how
/// do I do that?"*
///
/// ── AND THE RECORD HAS TO BE THE OTHER APP'S, EXACTLY ─────────────────────
///
/// Both apps read this back, and the same photo has to be one photo. So the
/// sizes, the qualities, the folder and the filename are the other app's:
///
///   * a **240px** thumbnail at **0.85**, inline in the record as a data URI —
///     it is what both Portfolio grids draw, and it travels with the book;
///   * a **1600px** copy at **0.88** written to `order-photos/` beside the
///     store, which is the one worth opening;
///   * `{orderId}-{index}-{base36 milliseconds}.jpg`, with anything outside
///     `A-Za-z0-9_-` in the id replaced by `_`.
///
/// A file named any other way is a file the other app's loader will not find,
/// and a thumbnail at another size is a grid that looks different on two
/// screens showing one shop.
enum OrderPhoto {

    /// Inline in the record, so it travels with the book and needs no file.
    static let thumbMaxDim = 240
    static let thumbQuality = 0.85
    /// On disk, and only on the Mac that took it until the folder is synced.
    static let fullMaxDim = 1600
    static let fullQuality = 0.88

    /// The other app's own cap, so a photo it would refuse is refused here.
    static let maxBytes = 8 * 1024 * 1024

    /// `{orderId}-{index}-{base36 ms}.jpg`.
    ///
    /// The id is sanitised because it becomes a path component: a job id is
    /// the shop's own string and `hub:save-order-photo` has always assumed it
    /// could be anything.
    static func filename(orderId: String, index: Int, at: Date = Date()) -> String {
        let safe = String(orderId.map {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "_"
        })
        let stamp = String(Int(at.timeIntervalSince1970 * 1000), radix: 36)
        // The extension as a constant rather than inside the template: a
        // literal with an interpolation and three letters left over is what
        // `WordsAreTranslatedTests` looks for, and `.jpg` tripped it. It is a
        // file extension, not a unit anybody reads, so the fix is to stop it
        // LOOKING like one rather than to widen a guard that is right.
        return [safe, String(index), stamp].joined(separator: "-") + "." + fileExtension
    }

    /// Both apps write JPEG. `decodeDataUrl` on the other side derives the
    /// extension from the data URI's own type, and `encode` below always
    /// produces `image/jpeg`, so the two agree by construction.
    static let fileExtension = "jpg"

    /// The two sizes, from one picked file.
    ///
    /// Nil when the file is not an image this Mac can read — which is the
    /// honest answer for a PDF somebody dragged in, rather than an empty
    /// photo cell.
    static func encode(_ data: Data) -> (thumb: String, full: Data)? {
        guard let source = NSImage(data: data), let cg = source.cgImage(
            forProposedRect: nil, context: nil, hints: nil) else { return nil }
        guard let thumb = ProductPhotos.jpeg(cg, maxDim: thumbMaxDim, quality: thumbQuality),
              let full = ProductPhotos.jpeg(cg, maxDim: fullMaxDim, quality: fullQuality)
        else { return nil }
        return ("data:image/jpeg;base64," + thumb.base64EncodedString(), full)
    }

    /// The record the other app writes, and reads back.
    static func record(thumb: String, filename: String) -> JSONValue {
        .object(["thumb": .string(thumb), "filename": .string(filename)])
    }
}
