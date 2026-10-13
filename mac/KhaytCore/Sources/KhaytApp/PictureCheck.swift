import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import CryptoKit
import KhaytCore

// MARK: - What a picture is sent as

/// A picture as "Check pictures" sends it: DRAWN from its pixels into a new
/// JPEG of at most `maxPixel` on its long side.
///
/// ── NOTHING OF THE FILE BUT ITS PIXELS ─────────────────────────────────────
///
/// A phone photo carries where it was taken (GPS), the camera, the time, and
/// whatever an editor wrote (IPTC, XMP). The image is decoded, drawn upright
/// into a fresh sRGB bitmap and encoded from that bitmap with no properties,
/// so none of it can reach the provider — not by stripping named keys, which
/// would miss the next one, but by never copying anything but pixels.
enum PictureSend {

    /// `lib/ai-library.js LIMITS.picturePixels` — `PictureCheckTests` holds them equal.
    nonisolated static let maxPixel = 512
    /// `LIMITS.pictureSourceBytes`, the same cap a print's picture has (`PrintPhotos.maxBytes`).
    nonisolated static let maxSourceBytes = PrintPhotos.maxBytes
    /// `LIMITS.pictureChecksPerScan` — its OWN budget, apart from the
    /// `PrintPhotos.perPass` picture downloads.
    nonisolated static let checksPerScan = 40

    enum Failure: Error, Equatable { case tooBig, notAnImage, couldNotEncode }

    nonisolated static func jpeg(data: Data, maxPixel: Int = maxPixel) throws -> Data {
        guard data.count <= maxSourceBytes else { throw Failure.tooBig }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw Failure.notAnImage }
        return try jpeg(source, maxPixel: maxPixel)
    }

    nonisolated static func jpeg(url: URL, maxPixel: Int = maxPixel) throws -> Data {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size <= maxSourceBytes else { throw Failure.tooBig }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw Failure.notAnImage }
        return try jpeg(source, maxPixel: maxPixel)
    }

    private nonisolated static func jpeg(_ source: CGImageSource, maxPixel: Int) throws -> Data {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,      // upright
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure.notAnImage
        }
        let w = decoded.width, h = decoded.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw Failure.couldNotEncode
        }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(decoded, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let drawn = ctx.makeImage() else { throw Failure.couldNotEncode }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.couldNotEncode
        }
        CGImageDestinationAddImage(dest, drawn, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure.couldNotEncode }
        return out as Data
    }

    /// A short digest of a picture's bytes — what a verdict is cached by.
    nonisolated static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - What was decided about a picture, remembered

extension LooseSort.Suggestion.Target {
    /// One line for a settings key.
    var id: String {
        switch self {
        case .print(let key): "print:" + key
        case .model(let rel): "model:" + rel
        }
    }
}

/// Pairings the shop (or the assistant's "no") turned down, never offered
/// again: `settings.printLibrary.pictureRejected`, a list of
/// `<linked folder>|<picture>|<print or model>`.
enum PictureRejects {
    nonisolated static let settingsKey = "pictureRejected"

    nonisolated static func id(root: URL, image: String, target: LooseSort.Suggestion.Target) -> String {
        root.standardizedFileURL.path + "|" + image + "|" + target.id
    }

    nonisolated static func read(_ settings: [String: JSONValue]) -> Set<String> {
        guard case .object(let library)? = settings["printLibrary"],
              case .array(let rows)? = library[settingsKey] else { return [] }
        return Set(rows.compactMap { if case .string(let s) = $0 { s } else { nil } })
    }

    nonisolated static func add(_ ids: [String], into root: inout [String: JSONValue]) {
        guard !ids.isEmpty else { return }
        var settings: [String: JSONValue] = [:]
        if case .object(let s)? = root["settings"] { settings = s }
        var library: [String: JSONValue] = [:]
        if case .object(let l)? = settings["printLibrary"] { library = l }
        var have: [JSONValue] = []
        if case .array(let rows)? = library[settingsKey] { have = rows }
        let known = Set(have.compactMap { if case .string(let s) = $0 { s } else { nil } })
        for id in ids where !known.contains(id) { have.append(.string(id)) }
        library[settingsKey] = .array(have)
        settings["printLibrary"] = .object(library)
        root["settings"] = .object(settings)
    }
}

/// The assistant's verdicts, by `<picture hash>|<linked folder>|<print or
/// model>`, so a pair is never sent twice: `settings.printLibrary.pictureChecks`.
enum PictureVerdicts {
    nonisolated static let settingsKey = "pictureChecks"

    struct Verdict: Sendable, Equatable {
        let verdict: String
        let reference: Bool
    }

    nonisolated static func key(hash: String, root: URL, target: LooseSort.Suggestion.Target) -> String {
        hash + "|" + root.standardizedFileURL.path + "|" + target.id
    }

    nonisolated static func read(_ settings: [String: JSONValue]) -> [String: Verdict] {
        guard case .object(let library)? = settings["printLibrary"],
              case .object(let map)? = library[settingsKey] else { return [:] }
        var out: [String: Verdict] = [:]
        for (k, v) in map {
            guard case .object(let o) = v, case .string(let verdict)? = o["v"] else { continue }
            let ref: Bool = { if case .bool(true)? = o["ref"] { true } else { false } }()
            out[k] = Verdict(verdict: verdict, reference: ref)
        }
        return out
    }

    /// The verdict for a pairing, whatever picture bytes it was given for —
    /// the preview has no bytes to hash, only the pairing.
    nonisolated static func latest(_ verdicts: [String: Verdict], root: URL,
                                   target: LooseSort.Suggestion.Target, image: String,
                                   hashes: [String: String]) -> Verdict? {
        guard let h = hashes[root.standardizedFileURL.path + "|" + image] else { return nil }
        return verdicts[key(hash: h, root: root, target: target)]
    }

    /// Whether this pairing already has a verdict, by the hash its picture
    /// had when it was checked — answered WITHOUT reading the picture, so a
    /// judged pair is neither downloaded again nor counted against a scan's
    /// checks. (A picture whose bytes changed keeps its verdict.)
    nonisolated static func judged(_ verdicts: [String: Verdict], hashes: [String: String], root: URL,
                                   image: String, target: LooseSort.Suggestion.Target) -> Bool {
        latest(verdicts, root: root, target: target, image: image, hashes: hashes) != nil
    }

    nonisolated static func write(_ new: [String: Verdict], hashes: [String: String],
                                  into root: inout [String: JSONValue]) {
        guard !new.isEmpty || !hashes.isEmpty else { return }
        var settings: [String: JSONValue] = [:]
        if case .object(let s)? = root["settings"] { settings = s }
        var library: [String: JSONValue] = [:]
        if case .object(let l)? = settings["printLibrary"] { library = l }
        var map: [String: JSONValue] = [:]
        if case .object(let m)? = library[settingsKey] { map = m }
        for (k, v) in new { map[k] = .object(["v": .string(v.verdict), "ref": .bool(v.reference)]) }
        library[settingsKey] = .object(map)
        var known: [String: JSONValue] = [:]
        if case .object(let m)? = library[hashesKey] { known = m }
        for (k, v) in hashes { known[k] = .string(v) }
        library[hashesKey] = .object(known)
        settings["printLibrary"] = .object(library)
        root["settings"] = .object(settings)
    }

    /// The hash each checked picture had, by `<linked folder>|<picture>`.
    nonisolated static let hashesKey = "pictureHashes"

    nonisolated static func hashes(_ settings: [String: JSONValue]) -> [String: String] {
        guard case .object(let library)? = settings["printLibrary"],
              case .object(let map)? = library[hashesKey] else { return [:] }
        return map.compactMapValues { if case .string(let s) = $0 { s } else { nil } }
    }
}

// MARK: - A picture to check, as the sheet shows it

struct PictureRow: Identifiable, Sendable {
    let id: String
    let root: URL
    let suggestion: LooseSort.Suggestion
    /// The print's (or model's) name, as the shop sees it.
    let name: String
    let image: URL
    let ticked: Bool
    /// Drawn only for the first few small enough to fetch.
    let picture: URL?
}

extension PictureRow {

    /// The pictures to check across sorted linked folders: what the sort
    /// offered, less what was turned down, less a print or model that wears a
    /// picture the shop chose (never put over), ticked as the assistant's
    /// verdict says when it gave one.
    @MainActor static func rows(_ plans: [PrintSort.Plan], settings: [String: JSONValue],
                                hasPicture: (PrintSort.Plan, LooseSort.Suggestion.Target) -> Bool,
                                outcome: (PictureVerdicts.Verdict) -> String?) -> [PictureRow] {
        let rejected = PictureRejects.read(settings)
        let verdicts = PictureVerdicts.read(settings)
        let hashes = PictureVerdicts.hashes(settings)
        var out: [PictureRow] = []
        var shown = 0
        for plan in plans {
            for s in plan.suggestions {
                let id = PictureRejects.id(root: plan.root, image: s.image, target: s.target)
                guard !rejected.contains(id), !hasPicture(plan, s.target) else { continue }
                var ticked = s.ticked
                if let v = PictureVerdicts.latest(verdicts, root: plan.root, target: s.target, image: s.image,
                                                  hashes: hashes), let o = outcome(v) {
                    if o == "rejected" { continue }
                    ticked = o == "ticked" || o == "attach"
                }
                let url = plan.root.appending(path: s.image)
                var picture: URL?
                let size = LinkedCloud.listedSize(url)
                if shown < PrintPhotos.perPass, size > 0, size <= PrintPhotos.maxBytes { picture = url; shown += 1 }
                let name: String = {
                    switch s.target {
                    case .print(let key): plan.group(ofPrint: key) ?? plan.name(ofPrint: key)
                    case .model(let rel): LinkedRegroup.stem(plan.root.appending(path: rel))
                    }
                }()
                out.append(PictureRow(id: id, root: plan.root, suggestion: s, name: name, image: url,
                                      ticked: ticked, picture: picture))
            }
        }
        return out
    }
}
