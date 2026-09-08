import SwiftUI

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

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
            }
        }
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
    private var cache: [ThumbnailSource: NSImage] = [:]

    func image(for source: ThumbnailSource) -> NSImage? {
        if let hit = cache[source] { return hit }
        let made: NSImage?
        switch source {
        case .file(let url):
            made = NSImage(contentsOf: url)
        case .inlineData(let uri):
            // `data:[<mediatype>][;base64],<data>` — anything else is not ours.
            guard let comma = uri.firstIndex(of: ","),
                  uri[uri.startIndex..<comma].contains("base64"),
                  let data = Data(base64Encoded: String(uri[uri.index(after: comma)...])) else {
                return nil
            }
            made = NSImage(data: data)
        }
        if let made { cache[source] = made }
        return made
    }
}
