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
    @ViewBuilder let content: Content

    init(_ title: String, accent: Color? = nil, symbol: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title; self.accent = accent; self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                }
                Text(title)
                    .textCase(.uppercase)
                    .tracking(0.6)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(accent.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tertiary))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    init(_ label: String, _ value: String, dim: Bool = false, strong: Bool = false, warn: Bool = false) {
        self.label = label; self.value = value
        self.dim = dim; self.strong = strong; self.warn = warn
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
                .foregroundStyle(warn ? AnyShapeStyle(Khayt.attention)
                                 : dim ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
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
