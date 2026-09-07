import SwiftUI
import AppKit

/// The shop's models.
///
/// A grid rather than a table, and that is the whole argument for the screen: a
/// print shop recognises a model by looking at it. The list view in the Electron
/// app puts a 40px thumbnail at the head of a text row, which is a filename with
/// a decoration — you read it rather than see it.
struct LibraryGrid: View {
    @Bindable var shop: Shop
    @FocusState private var focused: Bool
    /// Which way "next" is. In a mirrored window the next model is to the left,
    /// and a grid whose right arrow walks backwards is worse than one with no
    /// arrow keys at all.
    @Environment(\.layoutDirection) private var layout

    private static let cellWidth: CGFloat = 176
    private static let spacing: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            // Fixed columns rather than `.adaptive`, because the arrow keys have
            // to know how many there are: moving down is moving forward by one
            // row, and `.adaptive` decides the count privately.
            let count = Self.columns(across: geometry.size.width)
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing),
                                             count: count),
                              spacing: Self.spacing) {
                        ForEach(shop.shownFiles) { file in
                            cell(for: file).id(file.id)
                        }
                    }
                    .padding(Metric.screen)
                }
                .onChange(of: shop.focusedFile) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.12)) { scroller.scrollTo(id, anchor: .center) }
                }
            }
            .focusable()
            .focused($focused)
            // No ring around the whole pane. Finder, Photos and Music all show
            // keyboard focus through the selection rather than by drawing a
            // border round the content, and a blue rectangle enclosing the grid
            // reads as an error state. Focus with nothing selected is not
            // invisible either: the first arrow press picks an end.
            .focusEffectDisabled()
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                let step = Self.step(for: press.key, columns: count, layout: layout)
                // Unhandled at the ends, so the system beep still means "there
                // is nothing that way" rather than the app swallowing it.
                return shop.moveSelection(by: step, extending: press.modifiers.contains(.shift))
                    ? .handled : .ignored
            }
            // ⌘A is the SYSTEM's Select All, and adding a rival item to the
            // Edit menu simply loses: SwiftUI drops the shortcut on the second
            // claimant and the custom item ends up with no key at all. Handled
            // here instead, where the standard command lands when the grid has
            // focus — which is also how a Finder window does it.
            .onKeyPress(.init("a"), phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                shop.selectAllShown()
                return .handled
            }
            .onKeyPress(.return) {
                shop.openSelection()
                return .handled
            }
            // Space, as it does in Finder. Handled by the grid rather than by a
            // menu shortcut: a bare Space in the menu bar would be swallowed
            // before it ever reached a text field.
            .onKeyPress(.space) {
                guard shop.selectionIsOnThisMac else { return .ignored }
                shop.quickLookSelection()
                return .handled
            }
            .onKeyPress(.escape) {
                guard !shop.fileSelection.isEmpty else { return .ignored }
                shop.fileSelection = []
                return .handled
            }
            .onAppear { focused = true }
        }
        .background(Khayt.ground)
        .overlay { if shop.shownFiles.isEmpty { EmptyShelf(shop: shop) } }
    }

    /// How far an arrow key moves, in reading order.
    ///
    /// Written out rather than switched on inside the handler: `case forward:`
    /// with `forward` a local is an expression pattern, and one character's
    /// difference from `case let forward:` turns it into a binding that matches
    /// everything. Out here it can be tested — and the right arrow moving
    /// backwards in a mirrored window is exactly the kind of thing nobody
    /// notices until an Arabic shop does.
    static func step(for key: KeyEquivalent, columns: Int, layout: LayoutDirection) -> Int {
        let mirrored = layout == .rightToLeft
        switch key {
        case .upArrow: return -columns
        case .downArrow: return columns
        case .rightArrow: return mirrored ? -1 : 1
        default: return mirrored ? 1 : -1     // .leftArrow
        }
    }

    /// How many cells fit, never fewer than one.
    static func columns(across width: CGFloat) -> Int {
        let usable = width - 32   // the grid's own padding
        guard usable > 0 else { return 1 }
        return max(1, Int((usable + spacing) / (cellWidth + spacing)))
    }

    /// Broken out of the grid body: the type-checker gave up on the whole
    /// expression once the modifiers went on.
    @ViewBuilder private func cell(for file: LibraryFile) -> some View {
        Cell(file: file,
             thumbnail: shop.thumbnail(for: file),
             selected: shop.fileSelection.contains(file.id),
             words: shop.words)
            .onTapGesture {
                // SwiftUI's tap gesture does not report modifiers, so they are
                // read from the event that is arriving. Without this, ⌘-click
                // does not extend a selection — and a Mac app where it does not
                // reads as a web page however carefully it is drawn.
                let flags = NSEvent.modifierFlags
                let how: Shop.SelectionModifier =
                    flags.contains(.command) ? .toggle : (flags.contains(.shift) ? .extend : .replace)
                shop.select(file, modifiers: how)
            }
            .contextMenu {
                ModelActions(file: file, shop: shop)
            } preview: {
                // Right-click gives the picture at a size worth looking at. It
                // is the fastest way to tell two versions of a model apart.
                Thumbnail(source: shop.thumbnail(for: file))
                    .frame(width: 320, height: 320)
            }
    }
}

private struct Cell: View {
    let file: LibraryFile
    let thumbnail: ThumbnailSource?
    let selected: Bool
    /// The words rather than the whole shop: a cell needs to say four things
    /// and has no business being able to change the book to say them.
    let words: Words

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Thumbnail(source: thumbnail)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topTrailing) {
                    if file.isFavourite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Khayt.marked)
                            .shadow(radius: 2)
                            .padding(6)
                            .help(words.callIt("mac.is_favourite"))
                    }
                }
                // The palette, on the image where the eye already is. Four
                // filaments and three swaps is the difference between a print
                // that runs unattended and one someone has to stand over.
                .overlay(alignment: .bottomLeading) { Palette(file: file, words: words) }

            VStack(alignment: .leading, spacing: 2) {
                Text(file.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                Text(subtitle)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.top, 6)
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(6)
        .background(selected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private var subtitle: String {
        var bits: [String] = []
        if let size = file.size { bits.append(Format.bytes(size)) }
        // Khayt's own words for this, not ours: the catalogue has said
        // "printed {n}×" in nine languages since long before this app, and a
        // shop running in Arabic was reading an English sentence on every card
        // in its library.
        if file.printCount > 0 {
            bits.append(words.callIt("cat.printed_n", ["n": .number(Double(file.printCount))]))
        }
        return bits.joined(separator: " · ")
    }
}

/// The filament colours, and how many swaps the print needs.
private struct Palette: View {
    let file: LibraryFile
    let words: Words

    var body: some View {
        let swatches = file.palette.prefix(6)
        if !swatches.isEmpty {
            HStack(spacing: 3) {
                ForEach(Array(swatches.enumerated()), id: \.offset) { _, colour in
                    if colour.rgb != nil {
                        Swatch(rgb: colour.rgb, size: 9, round: true)
                    }
                }
                if file.swaps > 0 {
                    Text("\(file.swaps)")
                        .font(.system(size: 9, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .help(words.callIt("mac.n_swaps", ["n": .number(Double(file.swaps))]))
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(.black.opacity(0.42), in: Capsule())
            .padding(6)
        }
    }
}

private struct EmptyShelf: View {
    let shop: Shop

    var body: some View {
        if let problem = shop.problem {
            ContentUnavailableView {
                Label(shop.words.callIt("mac.library_wont_open"), systemImage: "exclamationmark.octagon")
            } description: { Text(problem) }
        } else if !shop.search.isEmpty {
            ContentUnavailableView.search(text: shop.search)
        } else {
            ContentUnavailableView(shop.words.callIt("mac.no_models"), systemImage: "cube",
                                   description: Text(shop.words.callIt("mac.no_models_hint")))
        }
    }
}

enum Format {
    /// Sizes a shop reads. Models here run to 80 MB and libraries to hundreds of
    /// gigabytes, so this is base-1000 like the Finder's, not base-1024.
    static func bytes(_ n: Double) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f.string(fromByteCount: Int64(n))
    }

    /// Millimetres with no more precision than a shop can hold a caliper to.
    static func mm(_ v: Double) -> String { String(format: "%.0f", v) }

    static func count(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: n as NSNumber) ?? "\(n)"
    }
}
