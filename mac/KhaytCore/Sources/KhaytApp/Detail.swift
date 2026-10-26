import SwiftUI
import ImageIO

/// The vocabulary an inspector is written in.
///
/// Lifted out of `OrderInspector` when the library grew one too. It was called
/// `Section` there, which shadowed SwiftUI's own `Section` for the whole file —
/// harmless while one file used it, a trap waiting for the second.
struct DetailSection<Content: View>: View {
    let title: String
    /// The colour of what this section is about, or nil for the ordinary case.
    ///
    /// A tinted header and a rail on the card below it are one signal said
    /// twice, which is the point — see the note in `Surface.swift` on why most
    /// sections should leave this nil. A section that is merely a heading over
    /// some facts is not news, and colouring it costs the colour its meaning.
    var accent: Color?
    var symbol: String?
    /// The one section on a screen that is the reason somebody opened it.
    ///
    /// ── FOUR HEADINGS AT ONE VOLUME IS NO HEADING AT ALL ──────────────────
    ///
    /// Every section in this app said its name in the same 10pt uppercase
    /// grey. On the dashboard that is "NEEDS ATTENTION", "THE FLOOR",
    /// "INVOICES TO CHASE" and "MONEY" — four labels of identical weight, so a
    /// screen whose whole job is to answer "what should I look at" answered by
    /// listing four things and standing back.
    ///
    /// A lead section says its name at reading size, in the colour of what is
    /// wrong, with the count in the heading. At most one per screen, and NOT
    /// always the same one: nothing is wrong on most mornings, and on those the
    /// floor leads instead.
    var lead = false
    /// How many, shown in a lead heading — half the news is the number. "Three
    /// things need you" is a different morning from "one thing does".
    var count: Int?
    @ViewBuilder let content: Content

    init(_ title: String, accent: Color? = nil, symbol: String? = nil,
         lead: Bool = false, count: Int? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title; self.accent = accent; self.symbol = symbol
        self.lead = lead; self.count = count
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: lead ? 9 : 8) {
            if lead { leadHeading } else { quietHeading }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The ordinary heading: a label over some facts, deliberately quiet.
    private var quietHeading: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            }
            Text(title).textCase(.uppercase).tracking(0.6)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(accent.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tertiary))
    }

    /// The lead heading: reading size, in the colour of what is wrong, with the
    /// count beside it.
    private var leadHeading: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
            }
            Text(title).font(.system(size: 15, weight: .semibold))
            if let count, count > 0 {
                Text("\(count)")
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background((accent ?? Khayt.attention).opacity(0.15), in: Capsule())
            }
        }
        .foregroundStyle(accent.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
    }
}

/// A labelled figure. The label is secondary and the value is aligned to the
/// right edge, so a column of them reads as a column.
struct DetailLine: View {
    let label: String
    let value: String
    var dim = false
    var strong = false
    var warn = false
    /// An explicit colour for the value, where neither "ordinary" nor `warn`
    /// is the right thing to say. `warn` means amber, which is the palette's
    /// "wants a person" — a quarter that lost money is not that, and passing
    /// `warn` for it would put a third meaning on the one colour this app
    /// already had to rescue from meaning everything.
    var tint: Color?

    init(_ label: String, _ value: String, dim: Bool = false, strong: Bool = false,
         warn: Bool = false, tint: Color? = nil) {
        self.label = label; self.value = value
        self.dim = dim; self.strong = strong; self.warn = warn; self.tint = tint
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.callout)
                .foregroundStyle(dim ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            Spacer(minLength: 12)
            Text(value)
                .font(.callout.weight(strong ? .semibold : .regular))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .foregroundStyle(tint.map(AnyShapeStyle.init)
                                 ?? (warn ? AnyShapeStyle(Khayt.attention)
                                     : dim ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)))
        }
    }
}

/// A model's thumbnail.
///
/// Loaded off the main thread and cached, because a library is hundreds of
/// JPEGs and a `LazyVGrid` will ask for the same one every time it scrolls back.
/// A model whose file is not on this Mac — an unmounted NAS, or one that only
/// ever reached S3 — draws the placeholder rather than an error: the record is
/// fine, the bytes are simply elsewhere.
struct Thumbnail: View {
    let source: ThumbnailSource?
    /// The longest side to decode to, in pixels. A library tile asks for
    /// twice its own width (`LibraryTileSize.pixels`); everything else keeps
    /// the old 640, which the right-click preview needs.
    var pixels: Int = ThumbnailStore.maxPixels
    /// The model's first filament, for the drawn placeholder.
    var tint: Color? = nil
    /// The surface under the picture. Nil keeps the old translucent grey; the
    /// library passes its own well (`LibraryTile.well`).
    var well: Color? = nil
    @State private var image: NSImage?
    /// A photograph of the screen (`SnapshotTests`) cannot wait for `.task`,
    /// so there the picture is read on the spot. Never in the running app.
    @Environment(\.photographFlat) private var photographing

    var body: some View {
        // THE FRAME DECIDES THE SIZE, NEVER THE PICTURE. This was a ZStack, and
        // a ZStack is as big as its biggest child: a picture filling a square
        // reported the size it FILLED, so a landscape photo made the library
        // tile wider than its column and drew over the next print (Oct 13
        // 2026). The picture is an overlay on a shape that takes the size it is
        // offered, and is clipped to it — the rule ProductCell already keeps.
        Rectangle().fill(well.map(AnyShapeStyle.init) ?? AnyShapeStyle(.quaternary))
            .overlay {
                if let image = image
                    ?? (photographing ? source.flatMap { ThumbnailStore.decode($0, maxPixels: ThumbnailStore.bucket(pixels)) } : nil) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    // A build plate with a print on it, not the system's
                    // generic cube — see `ModelPlaceholder`.
                    ModelPlaceholder(tint: tint)
                }
            }
            .clipped()
        .task(id: TaskKey(source: source, pixels: ThumbnailStore.bucket(pixels))) {
            guard let source else { image = nil; return }
            image = await ThumbnailStore.shared.image(for: source, maxPixels: pixels)
        }
    }

    private struct TaskKey: Hashable {
        let source: ThumbnailSource?
        let pixels: Int
    }
}

/// Where a thumbnail's bytes come from. Two shapes, because the store uses two:
/// a generated thumbnail sits in the record's folder, while a photograph the
/// shop took is inline in `khayt-store.json` as a data URI.
enum ThumbnailSource: Hashable, Sendable {
    case file(URL)
    case inlineData(String)
}

actor ThumbnailStore {
    static let shared = ThumbnailStore()

    /// How many pictures are kept, at most.
    static let limit = 400
    /// And how many BYTES of decoded bitmap. Counting pictures alone treated a
    /// 104-pixel small tile and a 640-pixel preview as the same weight; a
    /// budget in bytes keeps several screens of a dense grid while a few
    /// large previews cannot crowd it out.
    static let byteLimit = 128 * 1024 * 1024
    /// The longest side a picture is decoded to, at most.
    static let maxPixels = 640

    private struct Key: Hashable {
        let source: ThumbnailSource
        let pixels: Int
    }

    private var cache: [Key: (image: NSImage, used: Int, bytes: Int)] = [:]
    private var bytes = 0
    private var clock = 0
    /// Decodes, counted — for the test that proves a second ask is a hit.
    private(set) var decodes = 0

    /// Sizes round UP to a step of 64 pixels (and never past `maxPixels`), so
    /// a window being resized does not decode a picture per point.
    nonisolated static func bucket(_ pixels: Int) -> Int {
        min(maxPixels, max(64, ((pixels + 63) / 64) * 64))
    }

    func image(for source: ThumbnailSource, maxPixels wanted: Int = ThumbnailStore.maxPixels) async -> NSImage? {
        let size = Self.bucket(wanted)
        let key = Key(source: source, pixels: size)
        clock &+= 1
        if let hit = cache[key] {
            cache[key] = (hit.image, clock, hit.bytes)
            return hit.image
        }
        // A bigger copy already decoded serves a smaller tile as it is.
        if let bigger = cache.first(where: { $0.key.source == source && $0.key.pixels > size }) {
            cache[bigger.key] = (bigger.value.image, clock, bigger.value.bytes)
            return bigger.value.image
        }
        decodes += 1
        // Decoded on a global queue, never on the actor's thread or the
        // main one: a JPEG is real work, and blocking work inside a Swift
        // task starves the cooperative pool (memory: swift-pool-starvation).
        let made = await withCheckedContinuation { (done: CheckedContinuation<NSImage?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: Self.decode(source, maxPixels: size)) }
        }
        if let made {
            clock &+= 1
            let cost = Self.cost(made)
            cache[key] = (made, clock, cost)
            bytes += cost
            if cache.count > Self.limit || bytes > Self.byteLimit { evict() }
        }
        return made
    }

    /// Drop the least recently used quarter, so eviction is not paid on
    /// every picture once the cache is full.
    private func evict() {
        let keepCount = Self.limit * 3 / 4, keepBytes = Self.byteLimit * 3 / 4
        var kept: [Key: (image: NSImage, used: Int, bytes: Int)] = [:]
        var total = 0
        for (key, value) in cache.sorted(by: { $0.value.used > $1.value.used }) {
            guard kept.count < keepCount, total + value.bytes <= keepBytes else { break }
            kept[key] = value
            total += value.bytes
        }
        cache = kept
        bytes = total
    }

    var count: Int { cache.count }
    var byteCount: Int { bytes }

    private static func cost(_ image: NSImage) -> Int {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0 }
        return cg.bytesPerRow * cg.height
    }

    nonisolated static func decode(_ source: ThumbnailSource) -> NSImage? {
        decode(source, maxPixels: maxPixels)
    }

    /// Read and decode, scaled to fit `maxPixels`. ImageIO decodes at that
    /// size directly, rather than holding a full-size camera photo for a
    /// 150-point tile.
    nonisolated static func decode(_ source: ThumbnailSource, maxPixels: Int) -> NSImage? {
        let image: CGImageSource?
        switch source {
        case .file(let url):
            // By path: a redrawn picture's URL carries a fragment that only
            // keeps it apart in the cache (`Shop.redrawnSource`).
            image = CGImageSourceCreateWithURL(URL(fileURLWithPath: url.path) as CFURL, nil)
        case .inlineData(let uri):
            // `data:[<mediatype>][;base64],<data>` — anything else is not ours.
            guard let comma = uri.firstIndex(of: ","),
                  uri[uri.startIndex..<comma].contains("base64"),
                  let data = Data(base64Encoded: String(uri[uri.index(after: comma)...])) else {
                return nil
            }
            image = CGImageSourceCreateWithData(data as CFData, nil)
        }
        guard let image else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary) else { return nil }
        let cg = matte(decoded) ?? decoded
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: - The white square

    /// ── A RENDER ON WHITE, MADE INTO A RENDER ON NOTHING ──────────────────
    ///
    /// A slicer's or a website's preview is often an opaque picture of the
    /// model on a white-to-grey studio backdrop. On the light window that is
    /// a slightly brighter square; in dark mode it was a wall of white tiles
    /// glaring out of a dark grid (Oct 2026 audit). `MeshPreview` already
    /// draws on transparent for exactly this reason — this does the same for
    /// pictures that arrive already flattened.
    ///
    /// Only a picture with no transparency of its own whose EDGE is almost
    /// all near-white and colourless: that is a backdrop, not a photograph of
    /// a desk. From the edge inwards, the backdrop is followed while it stays
    /// colourless and changes smoothly from one pixel to the next — never
    /// brighter by more than a few levels, so a white model on a white
    /// backdrop keeps its own faces, and darker only in a shadow's bands. What
    /// was followed becomes black at the opacity of its darkness against the
    /// backdrop at that height: white goes, a shadow stays a shadow, and both
    /// sit on whatever the tile's own surface is in either appearance.
    ///
    /// Nil when the picture is not one of these, so the caller keeps it.
    nonisolated static func matte(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard w >= 16, h >= 16, w * h <= 1_200_000 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        @inline(__always) func at(_ x: Int, _ y: Int) -> Int { (y * w + x) * 4 }
        @inline(__always) func light(_ i: Int) -> Int { (Int(px[i]) * 3 + Int(px[i + 1]) * 6 + Int(px[i + 2])) / 10 }
        @inline(__always) func chroma(_ i: Int) -> Int {
            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
            return max(r, g, b) - min(r, g, b)
        }
        @inline(__always) func backdrop(_ i: Int) -> Bool { px[i + 3] == 255 && chroma(i) <= 10 }

        // The edge: opaque, and nine in ten of its pixels near-white.
        var edge: [Int] = []
        edge.reserveCapacity(2 * (w + h))
        for x in 0..<w { edge.append(at(x, 0)); edge.append(at(x, h - 1)) }
        for y in 1..<(h - 1) { edge.append(at(0, y)); edge.append(at(w - 1, y)) }
        if edge.contains(where: { px[$0 + 3] < 250 }) { return nil }
        let white = edge.filter { backdrop($0) && light($0) >= 222 }.count
        guard white * 10 >= edge.count * 9 else { return nil }

        // The backdrop's own brightness at each row: the brighter of the two
        // side edges, which is what a vertical studio gradient varies by.
        var rowLight = [Int](repeating: 255, count: h)
        for y in 0..<h { rowLight[y] = max(light(at(0, y)), light(at(w - 1, y)), 1) }

        // Flood in from the edge.
        var seen = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        stack.reserveCapacity(w * 4)
        for i in edge where backdrop(i) && light(i) >= 200 {
            let p = i / 4
            if !seen[p] { seen[p] = true; stack.append(p) }
        }
        while let p = stack.popLast() {
            let x = p % w, y = p / w
            let l = light(p * 4)
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                let q = ny * w + nx
                guard !seen[q] else { continue }
                let j = q * 4
                // Up by a few levels at most (a white model's face is
                // BRIGHTER than the backdrop and is never entered); down by
                // more, because a rendered shadow is drawn in bands.
                let step = light(j) - l
                guard backdrop(j), step <= 3, step >= -12, light(j) >= 180 else { continue }
                seen[q] = true
                stack.append(q)
            }
        }

        // The anti-aliased rim the flood stops at — a pixel or two of light
        // grey round the model, and the bright sliver a renderer draws where
        // the model meets its floor — read as a white outline on a dark tile.
        // Two pixels' grace for anything colourless and light beside the
        // backdrop.
        for _ in 0..<2 {
            var rim: [Int] = []
            for p in 0..<(w * h) where !seen[p] {
                let i = p * 4
                guard backdrop(i), light(i) >= 200 else { continue }
                let x = p % w, y = p / w
                if (x > 0 && seen[p - 1]) || (x < w - 1 && seen[p + 1])
                    || (y > 0 && seen[p - w]) || (y < h - 1 && seen[p + w]) { rim.append(p) }
            }
            for p in rim { seen[p] = true }
        }

        // Followed pixels become black at the opacity of their shade.
        for p in 0..<(w * h) where seen[p] {
            let i = p * 4
            let ref = Double(rowLight[p / w])
            let dark = max(0, ref - Double(light(i))) / ref
            let alpha = UInt8(min(255, (dark * 2.2 * 255).rounded()))
            px[i] = 0; px[i + 1] = 0; px[i + 2] = 0; px[i + 3] = alpha
        }
        return px.withUnsafeMutableBytes { buf -> CGImage? in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                      bytesPerRow: w * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }
}
