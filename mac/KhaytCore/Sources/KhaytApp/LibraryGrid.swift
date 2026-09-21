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
    /// True while a drag is over the library, so the drop target is visible
    /// BEFORE the mouse is released rather than after.
    @State private var dropping = false
    /// Which way "next" is. In a mirrored window the next model is to the left,
    /// and a grid whose right arrow walks backwards is worse than one with no
    /// arrow keys at all.
    @Environment(\.layoutDirection) private var layout
    /// The scroll that follows the keyboard used a hand-written 0.12s — the
    /// number `Motion.hover` holds — so it kept moving under Reduce Motion.
    @Environment(\.accessibilityReduceMotion) private var reduced

    private static let cellWidth: CGFloat = 176
    private static let spacing: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            // THE WAY BACK OUT OF A GROUP.
            //
            // Tapping a folder put the whole grid inside it and left nothing on
            // screen to get out again: the only routes were the sidebar's
            // Library row and the Go menu, neither of which is where somebody
            // who has just tapped into a folder is looking.
            //
            // It cannot live in the filter bar below, which draws NOTHING when
            // there are no chips — and a group with one category and no tags has
            // none, so exactly the plainest folder would have had no way back.
            if case .library(let group?) = shop.shelf {
                GroupCrumb(shop: shop, group: group)
            }
            // Above the grid rather than in the sidebar, where the group filter
            // used to live: the chips describe what is on screen and change it,
            // and a control that narrows a grid from another column is a
            // control a shop has to remember it set.
            LibraryFilterBar(shop: shop)
            grid
        }
    }

    private var grid: some View {
        GeometryReader { geometry in
            // Fixed columns rather than `.adaptive`, because the arrow keys have
            // to know how many there are: moving down is moving forward by one
            // row, and `.adaptive` decides the count privately.
            // §10: columns = floor(available ÷ 165). Tiles multiply; a tile
            // never inflates, because a 300-point thumbnail is not a better
            // thumbnail — it is the same picture with the row half as useful.
            let count = Wide.columns(across: geometry.size.width - Metric.screen * 2)
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVGrid(columns: Wide.grid(across: geometry.size.width - Metric.screen * 2),
                              alignment: .leading,
                              spacing: Wide.tileGap) {
                        ForEach(shop.shownEntries) { entry in
                            switch entry {
                            case .folder(let name, let path, let count, let cover):
                                FolderCell(name: name, count: count,
                                           thumbnail: cover.flatMap { shop.thumbnail(for: $0) },
                                           words: shop.words)
                                    .id(entry.id)
                                    // A folder OPENS. The shelf already filters
                                    // by group, so entering one is setting it —
                                    // the sidebar and the grid stay one idea.
                                    //
                                    // The PATH, not the name: two projects are
                                    // each allowed a folder called `Blue`, and
                                    // opening one of them must not show both.
                                    .onTapGesture { shop.shelf = .library(path) }
                                    // MOVING THE WHOLE FOLDER, because the
                                    // alternative is opening it, selecting all
                                    // of it and typing a path exactly — once
                                    // per folder, and a library imported flat
                                    // is a great many folders.
                                    .contextMenu {
                                        FolderMoveMenu(shop: shop, path: path)
                                    }
                            case .file(let file):
                                cell(for: file).id(file.id)
                            }
                        }
                    }
                    .padding(Metric.screen)
                }
                .onChange(of: shop.focusedFile) { _, id in
                    guard let id else { return }
                    withAnimation(Motion.of(Motion.hover, unless: reduced)) { scroller.scrollTo(id, anchor: .center) }
                }
            }
            // DRAGGING A MODEL ONTO THE LIBRARY IMPORTS IT.
            //
            // The only way in was a menu item called "Add model" in the Book
            // menu — not "Import", and not in File, where somebody looking for
            // an import goes. The screen itself had nothing: dropping a folder
            // of models on the library did nothing at all, which reads as the
            // app refusing rather than as the app not offering.
            //
            // The same entry point, so a drop and the menu cannot diverge:
            // folders are walked, the group comes from the folder, duplicates
            // are refused by hash.
            .dropDestination(for: URL.self) { urls, _ in
                guard shop.canMoveJobs, !shop.importing, !urls.isEmpty else { return false }
                Task { await shop.addModelsToLibrary(urls) }
                return true
            } isTargeted: { targeted in
                dropping = targeted
            }
            .overlay {
                if dropping {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .padding(6)
                        .allowsHitTesting(false)
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

/// A project, as a folder.
///
/// Deliberately the same shape as `Cell` — same square picture, same two lines
/// of text — so a library of folders and files reads as one grid rather than
/// two. What differs is what it says: a folder has no size and no print count,
/// it has how many things are in it.
/// Which folder the library is showing, and the way out of it.
///
/// Reads as a path rather than a button: "Library / Saudi Kings", with the
/// first half doing the work. A bare back arrow says where it goes and not
/// where you are, and a shop three folders into a hundred and fifty models
/// wants both.
private struct GroupCrumb: View {
    @Bindable var shop: Shop
    let group: String

    /// Every level above this one, outermost first, with the path to each.
    ///
    /// A trail rather than one Back button, because a project three deep needs
    /// a way to the middle of it and not only to the top: `MyProject/pose 1`
    /// offers "All models" and "MyProject", which is how a folder window has
    /// worked since before this app existed.
    private var above: [(name: String, path: String)] {
        let parts = group.components(separatedBy: ImportGrouping.separator)
        guard parts.count > 1 else { return [] }
        var out: [(String, String)] = []
        for (i, part) in parts.dropLast().enumerated() {
            out.append((part, parts.prefix(i + 1).joined(separator: ImportGrouping.separator)))
        }
        return out
    }

    /// The level being looked at — the last part, not the whole path.
    private var here: String {
        group.components(separatedBy: ImportGrouping.separator).last ?? group
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                // UP ONE, not all the way out. ⌘[ means back in every Mac app,
                // and from three levels deep "back" is the level above — going
                // to the top from there is a jump nobody asked for.
                shop.shelf = .library(above.last?.path)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.backward").font(.caption2.weight(.semibold))
                    Text(above.last?.name ?? shop.words.callIt("mac.all_models"))
                }
            }
            .buttonStyle(.link)
            // ⌘[ is what every other Mac app uses to go back, and the bracket
            // keys were free. Not Escape: this screen's search field takes that,
            // and a key that sometimes clears a search and sometimes leaves the
            // folder is worse than no key at all.
            .keyboardShortcut("[", modifiers: .command)
            .help(shop.words.callIt("mac.leave_group"))

            // The levels between the top and here, each one a way back to it.
            ForEach(above.dropLast(), id: \.path) { step in
                Text(verbatim: "/").foregroundStyle(.quaternary)
                Button(step.name) { shop.shelf = .library(step.path) }
                    .buttonStyle(.link).lineLimit(1)
            }

            Text(verbatim: "/").foregroundStyle(.quaternary)
            Text(here).fontWeight(.medium).lineLimit(1)
            // What is in it, so the count a shop tapped is still on screen.
            Text(verbatim: "\(shop.shownFiles.count)")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, Metric.screen)
        .padding(.vertical, 7)
    }
}

private struct FolderCell: View {
    let name: String
    let count: Int
    let thumbnail: ThumbnailSource?
    let words: Words

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Thumbnail(source: thumbnail)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                // The mark that says this is a place and not a thing. Bottom
                // trailing, where a file puts nothing, so it never sits on top
                // of the palette a file draws bottom-leading.
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(6)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                Text(words.callIt("mac.n_models", ["n": .number(Double(count))]))
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
        .contentShape(RoundedRectangle(cornerRadius: 8))
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
            // DELIBERATELY the system's component and its warning octagon. A
            // book that would not open is a FAILURE, not an empty screen, and
            // the drawn nozzle that says "nothing here yet" would say the
            // wrong thing about it cheerfully.
            ContentUnavailableView {
                Label(shop.words.callIt("mac.library_wont_open"), systemImage: "exclamationmark.octagon")
            } description: { Text(problem) }
        } else if !shop.search.isEmpty {
            NothingMatched(shop: shop, mark: .library)
        } else {
            EmptyHere(title: shop.words.callIt("mac.no_models"), message: shop.words.callIt("mac.no_models_hint"), mark: .library)
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


/// Where a folder can be moved to: any other folder, or out to the top.
///
/// Its own descendants are left out — a folder moved inside itself would write
/// a path containing its own prefix, and it would vanish from the level it was
/// on. `moveFolder` refuses that too; this simply does not offer it.
private struct FolderMoveMenu: View {
    @Bindable var shop: Shop
    let path: String

    private var destinations: [String] {
        shop.folderPaths.filter { $0 != path && !Shop.isUnder($0, path) }
    }

    var body: some View {
        Menu(shop.words.callIt("mac.move_folder")) {
            if path.contains(ImportGrouping.separator) {
                Button(shop.words.callIt("mac.move_to_top")) {
                    Task { await shop.moveFolder(path, under: nil) }
                }
                Divider()
            }
            ForEach(destinations, id: \.self) { target in
                Button(target) { Task { await shop.moveFolder(path, under: target) } }
            }
        }
        .disabled(!shop.canMoveJobs)
    }
}
