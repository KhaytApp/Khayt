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
        Rectangle().fill(.quaternary)
            .overlay {
                if let image = image ?? (photographing ? source.flatMap(ThumbnailStore.decode) : nil) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                }
            }
            .clipped()
        .task(id: source) {
            guard let source else { image = nil; return }
            image = await ThumbnailStore.shared.image(for: source)
        }
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

    /// How many pictures are kept. A tile draws at most ~330 px and the
    /// right-click preview 640, so each is decoded to fit 640 — about 1.6 MB
    /// as a bitmap — and 400 of them cover several screens of scrolling back
    /// without a 5,000-model library holding every picture it ever showed.
    static let limit = 400
    /// The longest side a picture is decoded to.
    static let maxPixels = 640

    private var cache: [ThumbnailSource: (image: NSImage, used: Int)] = [:]
    private var clock = 0
    /// Decodes, counted — for the test that proves a second ask is a hit.
    private(set) var decodes = 0

    func image(for source: ThumbnailSource) async -> NSImage? {
        clock &+= 1
        if let hit = cache[source] {
            cache[source] = (hit.image, clock)
            return hit.image
        }
        decodes += 1
        // Decoded on a global queue, never on the actor's thread or the
        // main one: a JPEG is real work, and blocking work inside a Swift
        // task starves the cooperative pool (memory: swift-pool-starvation).
        let made = await withCheckedContinuation { (done: CheckedContinuation<NSImage?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: Self.decode(source)) }
        }
        if let made {
            clock &+= 1
            cache[source] = (made, clock)
            if cache.count > Self.limit { evict() }
        }
        return made
    }

    /// Drop the least recently used quarter, so eviction is not paid on
    /// every picture once the cache is full.
    private func evict() {
        let keep = Self.limit * 3 / 4
        let order = cache.sorted { $0.value.used > $1.value.used }
        cache = Dictionary(uniqueKeysWithValues: order.prefix(keep).map { ($0.key, $0.value) })
    }

    var count: Int { cache.count }

    /// Read and decode, scaled to fit `maxPixels`. ImageIO decodes at that
    /// size directly, rather than holding a full-size camera photo for a
    /// 150-point tile.
    nonisolated static func decode(_ source: ThumbnailSource) -> NSImage? {
        let image: CGImageSource?
        switch source {
        case .file(let url):
            image = CGImageSourceCreateWithURL(url as CFURL, nil)
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
        guard let cg = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
