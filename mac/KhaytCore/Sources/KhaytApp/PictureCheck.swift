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

    /// "Show" in the sheet: bring ONE picture kept online down, because the
    /// shop asked to see it, within the same 8 MB cap. Reading is what makes
    /// the drive download it; a picture over the cap is never read.
    nonisolated static func bringDown(_ url: URL, size: (URL) -> Int = LinkedCloud.listedSize,
                                      read: (URL) -> Data? = { try? Data(contentsOf: $0) }) -> Bool {
        let listed = size(url)
        guard listed > 0, listed <= maxSourceBytes else { return false }
        return read(url) != nil
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

    nonisolated static func write(_ new: [String: Verdict], hashes: [String: String],
                                  into root: inout [String: JSONValue]) {
        write(new, seen: hashes.mapValues { Seen(hash: $0, size: -1, modified: -1) }, into: &root)
    }

    /// Verdicts and what each checked picture looked like, stamped `at` so
    /// the maps can be kept to `PictureMaps.cap`, oldest dropped first.
    nonisolated static func write(_ new: [String: Verdict], seen hashes: [String: Seen], at: Date = Date(),
                                  into root: inout [String: JSONValue]) {
        guard !new.isEmpty || !hashes.isEmpty else { return }
        let stamp = JSONValue.string(StoreWriter.iso(at))
        var settings: [String: JSONValue] = [:]
        if case .object(let s)? = root["settings"] { settings = s }
        var library: [String: JSONValue] = [:]
        if case .object(let l)? = settings["printLibrary"] { library = l }
        var map: [String: JSONValue] = [:]
        if case .object(let m)? = library[settingsKey] { map = m }
        for (k, v) in new { map[k] = .object(["v": .string(v.verdict), "ref": .bool(v.reference), "at": stamp]) }
        library[settingsKey] = .object(map)
        var known: [String: JSONValue] = [:]
        if case .object(let m)? = library[hashesKey] { known = m }
        for (k, v) in hashes {
            known[k] = .object(["h": .string(v.hash), "size": .number(Double(v.size)),
                                "mtime": .number(v.modified), "at": stamp])
        }
        library[hashesKey] = .object(known)
        settings["printLibrary"] = .object(library)
        root["settings"] = .object(settings)
    }

    /// The hash each checked picture had, by `<linked folder>|<picture>`.
    nonisolated static let hashesKey = "pictureHashes"

    nonisolated static func hashes(_ settings: [String: JSONValue]) -> [String: String] {
        seen(settings).mapValues(\.hash)
    }

    /// What a checked picture looked like: its bytes' hash, and the size and
    /// modification time its listing gave then.
    struct Seen: Sendable, Equatable {
        let hash: String
        let size: Int
        let modified: Double
    }

    /// Every checked picture, by `<linked folder>|<picture>`. An entry written
    /// before sizes were kept (a bare hash) has none, so it is read again.
    nonisolated static func seen(_ settings: [String: JSONValue]) -> [String: Seen] {
        guard case .object(let library)? = settings["printLibrary"],
              case .object(let map)? = library[hashesKey] else { return [:] }
        var out: [String: Seen] = [:]
        for (k, v) in map {
            switch v {
            case .string(let h): out[k] = Seen(hash: h, size: -1, modified: -1)
            case .object(let o):
                guard case .string(let h)? = o["h"] else { continue }
                let size: Int = { if case .number(let n)? = o["size"] { Int(saturating: n) } else { -1 } }()
                let mod: Double = { if case .number(let n)? = o["mtime"] { n } else { -1 } }()
                out[k] = Seen(hash: h, size: size, modified: mod)
            default: continue
            }
        }
        return out
    }

    /// -- DECIDED BEFORE THE PICTURE IS READ (review of #1844) --
    ///
    /// Reading a picture kept online downloads it, and each read spends one of
    /// a scan's 40 checks. So when the picture's listing is what it was when
    /// its hash was taken (same size, same modification time), the pair is
    /// judged by that hash WITHOUT reading: already answered, or held because
    /// its check failed today or three times (`SortFailures`), is skipped.
    /// Only a picture never read, or one whose listing changed, is read.
    nonisolated static func skipWithoutReading(_ known: Seen?, size: Int, modified: Double,
                                               verdicts: [String: Verdict], marks: [String: SortFailures.Mark],
                                               today: String, byHand: Bool, root: URL,
                                               target: LooseSort.Suggestion.Target) -> Bool {
        guard let known, known.size >= 0, known.size == size, known.modified == modified else { return false }
        let key = key(hash: known.hash, root: root, target: target)
        if verdicts[key] != nil { return true }
        return !byHand && SortFailures.held("picture:" + key, in: marks, today: today)
    }

    /// A listing's modification time, in seconds: metadata, never the bytes.
    nonisolated static func modified(_ url: URL) -> Double {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? -1
    }
}

// MARK: - Keeping the remembered pictures bounded

/// `pictureRejected`, `pictureChecks`, `pictureHashes` and `folderSort` grow
/// with every picture and folder ever seen, in settings that sync to every
/// device. On each scan, entries for a picture, print, model or folder no
/// longer in a scanned linked folder go; then each map keeps at most `cap`,
/// the oldest dropped first. A linked folder not scanned this time (a drive
/// not plugged in) keeps its entries, within the cap.
enum PictureMaps {
    nonisolated static let cap = 5000

    struct Present: Sendable {
        let root: String
        let images: Set<String>
        let prints: Set<String>
        let models: Set<String>
        let units: Set<String>

        init(_ plan: PrintSort.Plan) {
            root = plan.root.standardizedFileURL.path
            images = Set(plan.images.compactMap(plan.rel))
            prints = Set(plan.prints).union(plan.loose.keys)
            models = Set(plan.models.compactMap(plan.rel))
            units = Set(SortCache.units(plan).map(\.key))
        }

        func has(target id: String) -> Bool {
            if id.hasPrefix("print:") { return prints.contains(String(id.dropFirst(6))) }
            if id.hasPrefix("model:") { return models.contains(String(id.dropFirst(6))) }
            return false
        }
    }

    /// `<image>|print:...` / `<image>|model:...` split at the target.
    nonisolated static func split(_ rest: String) -> (image: String, target: String)? {
        let cuts = ["|print:", "|model:"].compactMap { rest.range(of: $0, options: .backwards) }
        guard let cut = cuts.max(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        return (String(rest[..<cut.lowerBound]), String(rest[rest.index(after: cut.lowerBound)...]))
    }

    /// Prune and cap, in a book's root. Returns whether anything changed.
    @discardableResult
    nonisolated static func prune(_ root: inout [String: JSONValue], plans: [PrintSort.Plan], cap: Int = cap) -> Bool {
        guard case .object(var settings)? = root["settings"],
              case .object(var library)? = settings["printLibrary"] else { return false }
        let before = library
        let present = plans.map(Present.init).sorted { $0.root.count > $1.root.count }
        func owner(_ s: String) -> (Present, String)? {
            for p in present where s.hasPrefix(p.root + "|") { return (p, String(s.dropFirst(p.root.count + 1))) }
            return nil
        }
        func at(_ v: JSONValue) -> String { if case .object(let o) = v, case .string(let s)? = o["at"] { s } else { "" } }
        func capped(_ map: [String: JSONValue]) -> [String: JSONValue] {
            guard map.count > cap else { return map }
            let keep = map.sorted { (at($0.value), $0.key) > (at($1.value), $1.key) }.prefix(cap)
            return Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }

        // Turned-down pairings: a list, oldest first.
        if case .array(let rows)? = library[PictureRejects.settingsKey] {
            var kept = rows.filter { row in
                guard case .string(let id) = row, let (p, rest) = owner(id) else { return true }
                guard let (image, target) = split(rest) else { return false }
                return p.images.contains(image) && p.has(target: target)
            }
            if kept.count > cap { kept = Array(kept.suffix(cap)) }
            library[PictureRejects.settingsKey] = .array(kept)
        }
        // What each picture looked like.
        var liveHashes = Set<String>()
        if case .object(let map)? = library[PictureVerdicts.hashesKey] {
            var kept = map.filter { k, _ in
                guard let (p, image) = owner(k) else { return true }
                return p.images.contains(image)
            }
            kept = capped(kept)
            for (k, v) in kept {
                guard let (p, _) = owner(k) else { continue }
                switch v {
                case .string(let h): liveHashes.insert(p.root + "|" + h)
                case .object(let o): if case .string(let h)? = o["h"] { liveHashes.insert(p.root + "|" + h) }
                default: break
                }
            }
            library[PictureVerdicts.hashesKey] = .object(kept)
        }
        // Verdicts: `<hash>|<linked folder>|<target>`.
        if case .object(let map)? = library[PictureVerdicts.settingsKey] {
            let kept = map.filter { k, _ in
                guard let bar = k.firstIndex(of: "|") else { return false }
                let hash = String(k[..<bar])
                guard let (p, target) = owner(String(k[k.index(after: bar)...])) else { return true }
                return p.has(target: target) && liveHashes.contains(p.root + "|" + hash)
            }
            library[PictureVerdicts.settingsKey] = .object(capped(kept))
        }
        // The folder sort's answers, by top-level folder path.
        if case .object(let map)? = library[SortCache.settingsKey] {
            let kept = map.filter { k, _ in
                guard let p = present.first(where: { k.hasPrefix($0.root + "/") }) else { return true }
                return p.units.contains(k)
            }
            library[SortCache.settingsKey] = .object(capped(kept))
        }
        guard library != before else { return false }
        settings["printLibrary"] = .object(library)
        root["settings"] = .object(settings)
        return true
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
    /// Drawn only for the first few, and only from a file ON THIS MAC.
    let picture: URL?
    /// Kept only in the cloud: shown as a placeholder until the shop asks
    /// for it ("Show"), never downloaded to draw a thumbnail.
    var online = false
}

extension PictureRow {

    /// The pictures to check across sorted linked folders: what the sort
    /// offered, less what was turned down, less a print or model that wears a
    /// picture the shop chose (never put over), ticked as the assistant's
    /// verdict says when it gave one.
    @MainActor static func rows(_ plans: [PrintSort.Plan], settings: [String: JSONValue],
                                hasPicture: (PrintSort.Plan, LooseSort.Suggestion.Target) -> Bool,
                                outcome: (PictureVerdicts.Verdict) -> String?,
                                isOnline: (URL) -> Bool = LinkedCloud.isOnlineOnly) -> [PictureRow] {
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
                let online = isOnline(url)
                let size = LinkedCloud.listedSize(url)
                if !online, shown < PrintPhotos.perPass, size > 0, size <= PrintPhotos.maxBytes { picture = url; shown += 1 }
                let name: String = {
                    switch s.target {
                    case .print(let key): plan.group(ofPrint: key) ?? plan.name(ofPrint: key)
                    case .model(let rel): LinkedRegroup.stem(plan.root.appending(path: rel))
                    }
                }()
                out.append(PictureRow(id: id, root: plan.root, suggestion: s, name: name, image: url,
                                      ticked: ticked, picture: picture, online: online))
            }
        }
        return out
    }
}
