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
        //
        // UPRIGHT, NOT AS STORED (`upright`): a phone photo is stored on its
        // side with a tag saying which way up it goes, and the files written
        // below carry no tag — so the turn has to be in the pixels.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = upright(source, maxPixel: maxDecodeDim) else {
            throw Failure.notAnImage
        }
        guard let thumb = jpeg(image, maxDim: thumbMaxDim, quality: thumbQuality),
              let full = jpeg(image, maxDim: fullMaxDim, quality: fullQuality) else {
            throw Failure.couldNotEncode
        }
        return Prepared(thumbnail: "data:image/jpeg;base64,\(thumb.base64EncodedString())",
                        full: full)
    }

    // MARK: - Which way up

    /// The picture the way it is MEANT to be seen.
    ///
    /// ── WHY A SHOP'S PHOTO CAME OUT SIDEWAYS ──────────────────────────────
    ///
    /// A phone does not turn the pixels when it is held upright: it stores
    /// them as the sensor read them and writes an EXIF orientation tag
    /// (6, "turn a quarter clockwise", for a portrait shot). Every viewer
    /// honours the tag. `CGImageSourceCreateImageAtIndex` does NOT — it hands
    /// back the pixels as stored — and `jpeg` then wrote them into a new file
    /// WITHOUT the tag. So the one thing that said which way up the picture
    /// went was dropped, and the photo was sideways for good: in the sheet,
    /// the catalogue, the invoice, the web store and the other app.
    /// Reported: *"I added a photo to a catalogue product and it turned it
    /// sideways with no way to fix it."*
    ///
    /// The other app never had this: its canvas draws an `<img>`, and a
    /// browser applies the tag before `drawImage` sees a pixel. Asking ImageIO
    /// for a full-size "thumbnail" WITH its transform is how this app does
    /// the same: the turn goes into the pixels, and what is written needs no
    /// tag to be right anywhere.
    ///
    /// `maxPixel` nil keeps every pixel (the scaling is `jpeg`'s, which has to
    /// round as the canvas does). Nil when the source holds no image.
    ///
    /// ── NEVER DECODED WHOLE, AND NEVER ABSURD ─────────────────────────────
    ///
    /// The 8 MB file limit is no limit on PIXELS: a PNG of one colour at
    /// 40,000 × 40,000 is a few hundred kilobytes and six gigabytes decoded.
    /// So the size the file DECLARES is read first and anything over
    /// `maxSourcePixels` is refused before a pixel is decoded, and the decode
    /// itself is never larger than `maxPixel` — `maxDecodeDim` when the caller
    /// gives none — on its longest side. ImageIO subsamples as it reads, so a
    /// 48-megapixel photo costs a 4096-pixel image, not the whole sensor.
    /// Oct 2026 review.
    nonisolated static func upright(_ source: CGImageSource, maxPixel: Int? = nil) -> CGImage? {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard Self.sensiblePixels(width: w, height: h) else { return nil }
        let longest = min(maxPixel ?? max(w, h), max(w, h), maxDecodeDim)
        if longest > 0, let turned = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            // From the full image, never the small preview a camera embeds.
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longest,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) {
            return turned
        }
        return nil
    }

    /// The most pixels a picked picture may declare: a 108-megapixel phone
    /// sensor fits, a decompression bomb does not.
    nonisolated static let maxSourcePixels = 120_000_000
    /// The longest side anything is decoded at. Every picture this app writes
    /// is far smaller (1600 for a product's full size, 1000 for the web store).
    nonisolated static let maxDecodeDim = 4096

    /// Does the file declare a size worth decoding at all? Unknown (0) is no.
    nonisolated static func sensiblePixels(width w: Int, height h: Int) -> Bool {
        w > 0 && h > 0 && w <= 100_000 && h <= 100_000 && w * h <= maxSourcePixels
    }

    /// The EXIF orientation a file carries — 1 is upright, and so is no tag.
    nonisolated static func orientation(_ source: CGImageSource) -> Int {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    }

    /// `image` turned by quarter turns: positive is CLOCKWISE (Rotate Right),
    /// negative anticlockwise (Rotate Left). Lossless — whole pixels moved, no
    /// resampling — so the only cost of a turn is the one JPEG encode after.
    nonisolated static func rotated(_ image: CGImage, quarterTurns: Int) -> CGImage? {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }
        let w = image.width, h = image.height
        let (outW, outH) = turns == 2 ? (w, h) : (h, w)
        guard let context = CGContext(
            data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Core Graphics is y-UP, so a positive angle is ANTICLOCKWISE. Each
        // case rotates the image about the origin and slides it back into the
        // bitmap.
        switch turns {
        case 1:  // clockwise
            context.translateBy(x: 0, y: CGFloat(outH))
            context.rotate(by: -.pi / 2)
        case 2:
            context.translateBy(x: CGFloat(outW), y: CGFloat(outH))
            context.rotate(by: .pi)
        default: // 3: anticlockwise
            context.translateBy(x: CGFloat(outW), y: 0)
            context.rotate(by: .pi / 2)
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }

    /// A product picture's file, turned: the full-size JPEG and the store's
    /// thumbnail, both made from the same turned pixels so they cannot
    /// disagree. Read upright first, so a file still carrying a tag is turned
    /// from the way the shop SEES it.
    nonisolated static func turn(_ data: Data, quarterTurns: Int) -> (thumb: String, full: Data)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = upright(source, maxPixel: maxDecodeDim),
              let turned = rotated(image, quarterTurns: quarterTurns),
              let thumb = jpeg(turned, maxDim: thumbMaxDim, quality: thumbQuality),
              let full = jpeg(turned, maxDim: fullMaxDim, quality: fullQuality) else { return nil }
        return ("data:image/jpeg;base64,\(thumb.base64EncodedString())", full)
    }

    /// Run blocking image work on a GCD queue and wait for it without holding
    /// a thread of Swift's cooperative pool — decoding a 12-megapixel photo
    /// inside `Task.detached` parks one of a handful of threads every other
    /// task in the app is waiting on.
    nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: work()) }
        }
    }

    /// Scale to fit `maxDim` on its longest side and encode as JPEG.
    ///
    /// NEVER ENLARGES — `min(1, …)`, as the canvas does. Drawn onto an opaque
    /// white bitmap first, because JPEG carries no alpha and a transparent PNG
    /// encoded directly comes out with a black background.
    nonisolated static func jpeg(_ image: CGImage, maxDim: Int, quality: Double) -> Data? {
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

    /// Write a picture's bytes under a name already decided (`target`).
    @discardableResult
    static func write(_ data: Data, named name: String, in build: StoreReader.Build) throws -> String {
        try write(data, named: name, into: folder(build))
    }

    @discardableResult
    nonisolated static func write(_ data: Data, named name: String, into dir: URL) throws -> String {
        let leaf = (name as NSString).lastPathComponent
        guard !leaf.isEmpty, leaf != ".", leaf != ".." else { throw Failure.couldNotEncode }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appending(path: leaf), options: .atomic)
        return leaf
    }

    /// Unlink a picture nobody references any more.
    ///
    /// `basename` again, because this deletes: the path comes off a store
    /// record, and a record can arrive from a sync with anything in it.
    static func delete(_ name: String, in build: StoreReader.Build) {
        // lock: callers — deleteProduct
        let leaf = (name as NSString).lastPathComponent
        guard !leaf.isEmpty, leaf != ".", leaf != ".." else { return }
        // The Trash, not deleted: Undo on the product brings the record back,
        // and the photo can be put back from the Finder with it.
        try? FileManager.default.trashItem(at: folder(build).appending(path: leaf), resultingItemURL: nil)
    }

    /// Read one back for the screen, where the stored thumbnail is not enough.
    static func load(_ name: String, in build: StoreReader.Build) -> NSImage? {
        guard let data = data(name, in: build) else { return nil }
        return NSImage(data: data)
    }

    /// A picture's bytes as they are on disk, for turning it.
    static func data(_ name: String, in build: StoreReader.Build) -> Data? {
        let leaf = (name as NSString).lastPathComponent
        guard !leaf.isEmpty, leaf != ".", leaf != ".." else { return nil }
        return try? Data(contentsOf: folder(build).appending(path: leaf))
    }

    /// Where a picture's NEW bytes go: a NEW file, always — and the file it
    /// replaces, handed back to be put in the Trash once the record names the
    /// new one.
    ///
    /// ── NEVER OVER ITS OWN FILE ───────────────────────────────────────────
    ///
    /// The first version rewrote a turned picture over its own file, before
    /// the product record was saved. The bytes went down first by design (a
    /// record naming a file never written is a broken picture), so a save
    /// that then FAILED left the original photo turned on disk with nothing
    /// in the book saying so, and Undo on the product put the record back
    /// over bytes that had already changed. A new name means the original is
    /// untouched until the one write that switches the record to the new file
    /// has succeeded; Cancel, a failed save and Undo all leave it as it was.
    ///
    /// The name is `main.js`'s for a picture with no file yet. For one that
    /// has a file it is that name with the moment after it, so two turns in a
    /// day are two names and nothing that drew the old file by its URL shows
    /// it again.
    ///
    /// ── ONLY EVER THIS PRODUCT'S OWN FILE ─────────────────────────────────
    ///
    /// The path comes off the product's record, and a record can arrive from a
    /// sync with anything in it — including the name of ANOTHER product's
    /// picture. So the old file is handed back to be trashed only when its
    /// name is one this product's own pictures are given (`belongs`) and no
    /// other product in the book names it (`othersUse`). Anything else is left
    /// exactly where it is. The new name is always this product's own.
    static func target(existing path: String, productId: String,
                       imageId: String, othersUse: Set<String> = [],
                       at now: Date = Date()) -> (name: String, unlink: String?) {
        let leaf = (path as NSString).lastPathComponent
        let minted = filename(productId: productId, imageId: imageId)
        guard !leaf.isEmpty, leaf != ".", leaf != ".." else { return (minted, nil) }
        let stamp = String(Int(now.timeIntervalSince1970 * 1000), radix: 36)
        var name = (minted as NSString).deletingPathExtension + "-" + stamp + ".jpeg"
        if name == leaf { name = (minted as NSString).deletingPathExtension + "-" + stamp + "b.jpeg" }
        let ours = mayTouch(leaf, productId: productId, othersUse: othersUse)
        return (name, ours ? leaf : nil)
    }

    /// Is `name` a file this product's pictures are named — `<id>.jpeg`, or
    /// `<id>-<image id>.<ext>` — by `main.js`'s rule (`filename`)?
    nonisolated static func belongs(_ name: String, toProduct productId: String) -> Bool {
        let leaf = (name as NSString).lastPathComponent
        let base = (leaf as NSString).deletingPathExtension
        let id = safe(productId)
        guard !id.isEmpty, !base.isEmpty else { return false }
        return base == id || base.hasPrefix(id + "-")
    }

    /// May a save or a delete of THIS product rewrite or unlink `name`? Only
    /// when it is named as this product's own, and no other product names it.
    nonisolated static func mayTouch(_ name: String, productId: String, othersUse: Set<String>) -> Bool {
        let leaf = (name as NSString).lastPathComponent
        return belongs(leaf, toProduct: productId) && !othersUse.contains(leaf)
    }

    /// A picture file sent to the Trash, and where it landed — so an Undo
    /// can bring it back beside the record that names it again.
    struct Trashed: Sendable, Equatable {
        let name: String
        let at: URL
    }

    /// To the Trash, saying where it went. Nil when there was nothing there,
    /// or the Trash would not take it.
    static func trash(_ name: String, in build: StoreReader.Build) -> Trashed? {
        // lock: callers — saveProduct, registerPicturesTrashAgain
        let leaf = (name as NSString).lastPathComponent
        guard !leaf.isEmpty, leaf != ".", leaf != ".." else { return nil }
        var landed: NSURL?
        do {
            try FileManager.default.trashItem(at: folder(build).appending(path: leaf), resultingItemURL: &landed)
        } catch { return nil }
        return (landed as URL?).map { Trashed(name: leaf, at: $0) }
    }

    /// Out of the Trash again, for an Undo — only where nothing has taken
    /// the name since. Returns the names put back.
    static func putBack(_ trashed: [Trashed], in build: StoreReader.Build) -> [String] {
        var back: [String] = []
        for item in trashed {
            let home = folder(build).appending(path: item.name)
            guard !FileManager.default.fileExists(atPath: home.path),
                  (try? FileManager.default.moveItem(at: item.at, to: home)) != nil else { continue }
            back.append(item.name)
        }
        return back
    }

    /// Take away a file THIS save wrote, when the save did not go through —
    /// no record names it, and the original it was to replace is untouched.
    static func discard(_ name: String, in build: StoreReader.Build) {
        // lock: callers — saveProduct
        let leaf = (name as NSString).lastPathComponent
        guard !leaf.isEmpty, leaf != ".", leaf != ".." else { return }
        try? FileManager.default.removeItem(at: folder(build).appending(path: leaf))
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
    /// The full-size JPEG, for a picture picked in this sitting — or one
    /// TURNED in this sitting, whose new bytes replace its file on save.
    var bytes: Data?
    /// How far the shop has turned it in this sitting, in clockwise quarter
    /// turns, and what it is being turned FROM: the bytes and thumbnail it
    /// had when the first turn was asked for. Every turn is made from that
    /// one starting point, so four presses of Rotate Right cost one JPEG
    /// encode, not four stacked on each other.
    var turns: Int = 0
    var turnedFrom: (bytes: Data?, thumbnail: String, original: Data)?

    /// The record shape `lib/product-images.js` reads — the five fields it
    /// keeps, and nothing else. `bytes` is deliberately absent: it is this
    /// app's business on the way to disk and has no place in the book.
    func record() -> JSONValue {
        .object(["id": .string(id), "path": .string(path),
                 "thumbnail": .string(thumbnail), "kind": .string(kind),
                 "caption": .string(caption)])
    }
}

extension ProductPhotos {

    /// A job's photo, as a `print`-kind picture on its product.
    ///
    /// Everything about what the picture MEANS is `product-images.addImage`'s:
    /// appended rather than made primary, an id nobody else on the product
    /// has, and the same picture twice is one picture. What is here is the
    /// order of the two writes: the id is minted first, because the filename
    /// is built from it, then `writeFile` puts the bytes down, and only then
    /// are the record's fields returned for the caller to write.
    ///
    /// Nil when that exact picture is already on the product — nothing was
    /// written and there is nothing to write.
    @MainActor
    static func addPrintPhoto(_ made: (thumb: String, full: Data), to product: JSONValue,
                              productId: String, engine: KhaytEngine,
                              writeFile: (_ imageId: String) throws -> String) async throws -> [String: JSONValue]? {
        let out = try await engine.addProductImage(product, image: .object([
            "thumbnail": .string(made.thumb), "path": .string(""),
            "kind": .string("print"), "caption": .string(""),
        ]))
        guard out.added else { return nil }
        let path = try writeFile(out.image.id)
        guard case .object(var record) = out.product, case .array(var images)? = record["images"] else {
            throw Failure.couldNotEncode
        }
        for i in images.indices {
            guard case .object(var image) = images[i], image["id"] == .string(out.image.id) else { continue }
            image["path"] = .string(path)
            images[i] = .object(image)
        }
        record["images"] = .array(images)
        // The legacy view (`imagePath`, `thumbnail`) is the rule's to mirror,
        // not a Swift copy's — the storefront, portal and labels still read it.
        guard case .object(let applied) = try await engine.applyProductPictures(.object(record)) else {
            throw Failure.couldNotEncode
        }
        var fields: [String: JSONValue] = [:]
        for key in ["images", "imagePath", "thumbnail"] { fields[key] = applied[key] ?? .string("") }
        return fields
    }
}

extension Shop {
    /// Undo on a product save brings back the picture files the save put in
    /// the Trash — registered right after the record's own undo, so the two
    /// are one Undo. Redo sends them back to the Trash.
    func registerPicturesPutBack(_ trashed: [ProductPhotos.Trashed], in build: StoreReader.Build) {
        guard let undoManager, !trashed.isEmpty else { return }
        undoManager.registerUndo(withTarget: self) { shop in
            // A product edit's undo, asked as one (the staff lock).
            guard shop.permitted("inventory", "edit") else { return }
            let back = ProductPhotos.putBack(trashed, in: build)
            shop.registerPicturesTrashAgain(back, in: build)
        }
    }

    private func registerPicturesTrashAgain(_ names: [String], in build: StoreReader.Build) {
        guard let undoManager, !names.isEmpty else { return }
        undoManager.registerUndo(withTarget: self) { shop in
            guard shop.permitted("inventory", "edit") else { return }
            let again = names.compactMap { ProductPhotos.trash($0, in: build) }
            shop.registerPicturesPutBack(again, in: build)
        }
    }
}
