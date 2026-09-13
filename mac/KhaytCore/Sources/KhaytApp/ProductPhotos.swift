import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import KhaytCore

/// Turning a file the shop picked into the two things a product picture is.
///
/// ── THE HALF THAT CANNOT BE SHARED ────────────────────────────────────────
///
/// `lib/product-images.js` owns everything about what a picture MEANS — the
/// kinds, which one is primary, the migration, when the legacy fields are
/// rewritten. None of that is here. What is here is the part no pure module can
/// do: read an image off disk, scale it, and write bytes.
///
/// ── AND WHY IT COPIES THE CANVAS RATHER THAN DOING BETTER ─────────────────
///
/// Both apps write into the SAME `products` folder beside the same book, and
/// the store holds the thumbnail as a data URI that either app may draw. So the
/// numbers below are not choices — they are `renderer/inventory.js`'s
/// `resizeImage`, matched deliberately:
///
///   - the scale is `min(1, maxDim / max(width, height))`, so nothing is ever
///     enlarged. A 200px photo stays 200px rather than being blown up to 1600
///     and looking worse than the file the shop gave us.
///   - transparency is flattened onto WHITE. JPEG has no alpha, and a PNG with
///     a transparent background encoded straight to JPEG comes out on black —
///     which is what the canvas's `fillRect` is there to prevent.
///   - JPEG, at the same two qualities.
///
/// The FILENAME is matched for a harder reason: `main.js` writes
/// `<productId>-<imageId>.<ext>` with everything outside `[A-Za-z0-9_-]`
/// replaced, and the store records that name. Spell it differently here and the
/// two apps write the same picture twice under two names, or worse, one app
/// records a path the other cannot open.
///
/// Its comment says what the rule is FOR, and it is worth repeating because it
/// is the bug this shape exists to avoid: the name was once built from the
/// product id alone, so every photo of one product wrote to the same file and
/// every image record pointed at it. Three thumbnails, three rows in the store,
/// one picture on disk — and deleting any of them unlinked the file the other
/// two were using.
enum ProductPhotos {

    /// What the shop picked, scaled the two ways a product picture needs.
    struct Prepared {
        /// The data URI that goes in the store and is drawn everywhere.
        let thumbnail: String
        /// The full-size JPEG, for the file beside the book.
        let full: Data
    }

    /// `renderer/inventory.js`: `resizeImage(file, 240, 0.85)`.
    static let thumbMaxDim = 240
    static let thumbQuality = 0.85
    /// `renderer/inventory.js`: `resizeImage(file, 1600, 0.88)`.
    static let fullMaxDim = 1600
    static let fullQuality = 0.88

    /// The biggest file worth reading. The Electron editor refuses past this
    /// and says so, rather than letting a 40 MB phone photo through to be
    /// scaled down to 240px at the cost of holding all of it in memory first.
    static let maxSourceBytes = 8 * 1024 * 1024

    enum Failure: Error, LocalizedError {
        case tooBig(Int)
        case notAnImage
        case couldNotEncode
        var errorDescription: String? {
            switch self {
            case .tooBig(let n): return "The picture is \(n / 1_048_576) MB; the limit is 8 MB."
            case .notAnImage: return "That file is not a picture Khayt can read."
            case .couldNotEncode: return "The picture could not be converted."
            }
        }
    }

    /// Scale one picked file both ways.
    static func prepare(_ url: URL) throws -> Prepared {
        let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        if let size, size > maxSourceBytes { throw Failure.tooBig(size) }

        // CGImageSource rather than NSImage: an NSImage of a 6000px photo is a
        // representation the size of the file, and this only ever needs pixels.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure.notAnImage
        }
        guard let thumb = jpeg(image, maxDim: thumbMaxDim, quality: thumbQuality),
              let full = jpeg(image, maxDim: fullMaxDim, quality: fullQuality) else {
            throw Failure.couldNotEncode
        }
        return Prepared(thumbnail: "data:image/jpeg;base64,\(thumb.base64EncodedString())",
                        full: full)
    }

    /// Scale to fit `maxDim` on its longest side and encode as JPEG.
    ///
    /// NEVER ENLARGES — `min(1, …)`, as the canvas does. Drawn onto an opaque
    /// white bitmap first, because JPEG carries no alpha and a transparent PNG
    /// encoded directly comes out with a black background.
    static func jpeg(_ image: CGImage, maxDim: Int, quality: Double) -> Data? {
        let longest = max(image.width, image.height)
        let scale = min(1.0, Double(maxDim) / Double(longest))
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))

        guard let context = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        guard let scaled = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, scaled, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: - Where the files live

    /// The folder both apps put product pictures in: `products`, beside the
    /// book. `main.js` calls it `ensureDir('products')` under userData, and
    /// userData is the directory the store itself sits in.
    static func folder(_ build: StoreReader.Build) -> URL {
        build.storeURL.deletingLastPathComponent().appending(path: "products")
    }

    /// `main.js`'s filename, spelled the same way.
    ///
    /// One file per IMAGE, not per product — see the note at the top of this
    /// file for what happened when it was per product. `jpeg`, not `jpg`:
    /// `decodeDataUrl` maps the mime straight through and only rewrites `jpg`,
    /// so a canvas JPEG lands as `.jpeg` and this must agree.
    static func filename(productId: String, imageId: String) -> String {
        let safeId = safe(productId)
        let safeImg = safe(imageId)
        return safeImg.isEmpty ? "\(safeId).jpeg" : "\(safeId)-\(safeImg).jpeg"
    }

    /// Everything outside `[A-Za-z0-9_-]` becomes `_`, after taking the last
    /// path component — the same two steps, in the same order, as
    /// `path.basename(...).replace(/[^a-zA-Z0-9_-]/g, '_')`.
    ///
    /// Both halves matter and the order matters: `basename` first is what stops
    /// a product id of `../../etc/passwd` from being turned into a harmless
    /// underscored string that still escapes the folder on some other path.
    ///
    /// ── ONE UNDERSCORE PER UTF-16 UNIT, NOT PER CHARACTER ─────────────────
    ///
    /// This walked Swift `Character`s first, and that is a DIFFERENT STRING for
    /// anything outside the basic plane. A JavaScript regex replaces per UTF-16
    /// code unit; a Swift `Character` is a grapheme cluster, which can be
    /// several. Measured against `main.js`'s own regex:
    ///
    ///     "Café" (e + U+0301)  →  JS "Cafe_"    Swift-by-character "Caf_"
    ///     "Part 🔥"            →  JS "Part___"  Swift-by-character "Part__"
    ///
    /// Both apps write into ONE folder beside ONE book, so a shop whose product
    /// name carries an emoji or an accent would have had the Mac record a path
    /// Khayt could not open, and Khayt record one the Mac could not. Walking
    /// `utf16` is what makes the two spellings identical.
    static func safe(_ raw: String) -> String {
        let base = (raw as NSString).lastPathComponent
        let units = base.utf16.map { unit -> Character in
            guard let scalar = Unicode.Scalar(unit) else { return "_" }
            let c = Character(scalar)
            return c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "-") ? c : "_"
        }
        return String(units)
    }

    /// Write a picture's bytes and return the name recorded against it.
    @discardableResult
    static func write(_ data: Data, productId: String, imageId: String,
                      in build: StoreReader.Build) throws -> String {
        let dir = folder(build)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = filename(productId: productId, imageId: imageId)
        try data.write(to: dir.appending(path: name))
        return name
    }

    /// Unlink a picture nobody references any more.
    ///
    /// `basename` again, because this deletes: the path comes off a store
    /// record, and a record can arrive from a sync with anything in it.
    static func delete(_ name: String, in build: StoreReader.Build) {
        let leaf = (name as NSString).lastPathComponent
        guard !leaf.isEmpty, leaf != ".", leaf != ".." else { return }
        try? FileManager.default.removeItem(at: folder(build).appending(path: leaf))
    }

    /// Read one back for the screen, where the stored thumbnail is not enough.
    static func load(_ name: String, in build: StoreReader.Build) -> NSImage? {
        let leaf = (name as NSString).lastPathComponent
        guard !leaf.isEmpty else { return nil }
        return NSImage(contentsOf: folder(build).appending(path: leaf))
    }
}

/// A picture in the editor, which may or may not be on disk yet.
///
/// ── WHY THIS IS STAGED AND NOT WRITTEN AS IT IS PICKED ────────────────────
///
/// Cancelling the sheet has to leave the shop's pictures exactly as they were.
/// A picture written to the products folder the moment it is chosen survives a
/// cancel as an orphan file; a picture DELETED the moment it is removed cannot
/// be brought back by one. So nothing touches the folder until save — new bytes
/// are carried here, and removals are carried as a list of paths that is only
/// acted on once the record has been written.
///
/// That ordering is the same one `renderer/inventory.js` follows, and its
/// comment says why in four words: "Cancelling must leave them."
struct StagedPicture: Identifiable, Sendable {
    /// The image id the shared rule minted. The filename is built from it, so
    /// it has to be decided before the bytes are written, not after.
    let id: String
    var kind: String
    var caption: String
    /// The data URI drawn in the strip and stored on the record.
    var thumbnail: String
    /// The file beside the book. Empty for a picture picked in this sitting.
    var path: String
    /// The full-size JPEG, for a picture picked in this sitting only.
    var bytes: Data?

    /// The record shape `lib/product-images.js` reads — the five fields it
    /// keeps, and nothing else. `bytes` is deliberately absent: it is this
    /// app's business on the way to disk and has no place in the book.
    func record() -> JSONValue {
        .object(["id": .string(id), "path": .string(path),
                 "thumbnail": .string(thumbnail), "kind": .string(kind),
                 "caption": .string(caption)])
    }
}
