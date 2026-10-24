import SwiftUI
import KhaytWidgetData
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
    /// The tile a drag is over, which takes a picture as that model's photo.
    @State private var tileTarget: LibraryFile.ID?
    /// Which way "next" is. In a mirrored window the next model is to the left,
    /// and a grid whose right arrow walks backwards is worse than one with no
    /// arrow keys at all.
    @Environment(\.layoutDirection) private var layout
    /// The scroll that follows the keyboard used a hand-written 0.12s — the
    /// number `Motion.hover` holds — so it kept moving under Reduce Motion.
    @Environment(\.accessibilityReduceMotion) private var reduced

    /// Tile size and grid-or-list, per Mac (`LibraryDisplay`).
    private var display: LibraryDisplay { LibraryDisplay.shared }
    @Environment(\.displayScale) private var scale

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
            if display.layout == .list {
                LibraryList(shop: shop)
            } else {
                grid
            }
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
            let tile = display.tileSize.points
            let count = Wide.columns(across: geometry.size.width - Metric.screen * 2, tile: tile)
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVGrid(columns: Wide.grid(across: geometry.size.width - Metric.screen * 2, tile: tile),
                              alignment: .leading,
                              spacing: Wide.tileGap) {
                        ForEach(shop.shownEntries) { entry in
                            switch entry {
                            case .folder(let name, let path, let count, let cover):
                                FolderCell(name: name, count: count,
                                           // The shop's chosen picture,
                                           // else the borrowed one.
                                           thumbnail: shop.groupThumbnail(path, automatic: cover),
                                           words: shop.words,
                                           kind: shop.groupKind(path),
                                           parent: FolderCell.parent(of: path, open: shop.shelf),
                                           selected: shop.groupSelection.contains(path),
                                           size: display.tileSize,
                                           pixels: display.tileSize.pixels(scale: scale))
                                    .id(entry.id)
                                    // A folder OPENS. The shelf already filters
                                    // by group, so entering one is setting it —
                                    // the sidebar and the grid stay one idea.
                                    //
                                    // The PATH, not the name: two projects are
                                    // each allowed a folder called `Blue`, and
                                    // opening one of them must not show both.
                                    //
                                    // ⌘- and ⇧-click CHOOSE it instead, for
                                    // "Move into Group…" — a group tile, never
                                    // the models inside it (#1691).
                                    .onTapGesture {
                                        let flags = NSEvent.modifierFlags
                                        if flags.contains(.command) { shop.selectGroup(path, modifiers: .toggle) }
                                        else if flags.contains(.shift) { shop.selectGroup(path, modifiers: .extend) }
                                        else { shop.shelf = .library(path) }
                                    }
                                    // MOVING THE WHOLE FOLDER, because the
                                    // alternative is opening it, selecting all
                                    // of it and typing a path exactly — once
                                    // per folder, and a library imported flat
                                    // is a great many folders.
                                    .contextMenu {
                                        // One print in parts, or separate
                                        // prints: what decides how "All
                                        // models" draws it.
                                        GroupKindMenu(shop: shop, path: path)
                                        // Its own picture, instead of
                                        // the first model's.
                                        GroupPictureItems(shop: shop, path: path)
                                        Divider()
                                        FolderMoveMenu(shop: shop, path: path)
                                        // Every chosen group at once, and a
                                        // new name for this one.
                                        GroupTileActions(shop: shop, path: path)
                                        Divider()
                                        // A project folder is often exactly a
                                        // product: a set, a kit, a figure in parts.
                                        Button(shop.words.callIt("mac.catalogue_add_folder") + "\u{2026}") {
                                            Task { await shop.productFromFolder(path) }
                                        }
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
            // ⌫ — the Finder's Delete key — asks to delete the VISIBLE
            // selection, through the right-click menu's own question. See
            // `Shop.askToDeleteLibrarySelection`: never a model inside a folder tile.
            .onDeleteCommand { shop.askToDeleteLibrarySelection() }
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
                guard !shop.fileSelection.isEmpty || !shop.groupSelection.isEmpty else { return .ignored }
                shop.fileSelection = []
                shop.groupSelection = []
                return .handled
            }
            .onAppear { focused = true }
            // Back from the Finder or another app: a drive may have been
            // mounted, or a picture written, while the answers were kept.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                shop.forgetLibraryDisk()
            }
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
        // ONCE per cell: the tile and its right-click preview drew the same
        // picture from two separate asks.
        let thumbnail = shop.thumbnail(for: file)
        Cell(file: file,
             thumbnail: thumbnail,
             selected: shop.fileSelection.contains(file.id),
             words: shop.words,
             group: Cell.groupShown(for: file, shelf: shop.shelf),
             openGroup: { shop.showGroup($0) },
             storage: shop.storageBadge(for: file),
             kept: shop.isKeptOnThisMac(file),
             facts: shop.libraryFactsLine(file),
             size: display.tileSize,
             pixels: display.tileSize.pixels(scale: scale))
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
            // A PICTURE DROPPED ON A MODEL IS ITS PHOTO. The model's page
            // took one only in its last section, which a shop did not find.
            // Every other drop — a model, a folder, a zip — is passed on to
            // the library's own import (`Shop.dropOnModelTile`): a tile now
            // sits under most of the grid's drop area, and an `.stl` let fall
            // on one must still import as it did.
            .dropDestination(for: URL.self) { urls, _ in
                shop.dropOnModelTile(urls, onto: file.id)
            } isTargeted: { targeted in
                if targeted { tileTarget = file.id }
                else if tileTarget == file.id { tileTarget = nil }
            }
            .overlay { TileDropRing(shown: tileTarget == file.id && shop.canMoveJobs) }
            .contextMenu {
                ModelActions(file: file, shop: shop)
            } preview: {
                // Right-click gives the picture at a size worth looking at. It
                // is the fastest way to tell two versions of a model apart.
                Thumbnail(source: thumbnail, tint: file.firstColour, well: LibraryTile.well)
                    .frame(width: 320, height: 320)
            }
    }
}

/// Which folder the library is showing, and the way out of it.
///
/// Reads as a path rather than a button: "Library / Saudi Kings", with the
/// first half doing the work. A bare back arrow says where it goes and not
/// where you are, and a shop three folders into a hundred and fifty models
/// wants both.
struct GroupCrumb: View {
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
            // What this group is, and the way to change it, beside its name.
            Menu {
                ForEach(GroupKind.allCases, id: \.self) { kind in
                    Button {
                        Task { await shop.setGroupKind(group, kind) }
                    } label: {
                        if kind == shop.groupKind(group) {
                            Label(shop.words.callIt(kind.wordKey), systemImage: "checkmark")
                        } else { Text(shop.words.callIt(kind.wordKey)) }
                    }
                }
                // The group's picture, from the same place its kind is
                // changed: the one menu that is about the group itself.
                Divider()
                GroupPictureItems(shop: shop, path: group)
                // And moving or renaming the group you are IN — the tile's
                // right-click had them, and from inside the group there is no
                // tile to right-click.
                Divider()
                GroupTileActions(shop: shop, path: group)
            } label: {
                // IN THE CRUMB'S OWN INK. As a borderless menu its label was
                // drawn pale grey — the look of a control that is switched
                // off — beside links drawn in the brand colour. A plain
                // button-style menu takes the colour it is given.
                HStack(spacing: 3) {
                    Image(systemName: shop.groupKind(group).symbol)
                    Text(shop.words.callIt(shop.groupKind(group).wordKey)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                }
                .foregroundStyle(shop.canWrite ? AnyShapeStyle(Khayt.brand) : AnyShapeStyle(.secondary))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!shop.canWrite)
            .help(shop.words.callIt("mac.group_kind_menu"))
            // What is in it, so the count a shop tapped is still on screen.
            // In the shop's digits, as every other count in the app.
            Text(verbatim: shop.words.numeral(shop.shownFiles.count))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, Metric.screen)
        .padding(.vertical, 7)
    }
}

/// A group, as a folder.
///
/// ── IT HAS TO LOOK LIKE MORE THAN ONE THING ───────────────────────────────
///
/// This was "deliberately the same shape as `Cell`" with a 12-point folder
/// glyph in a corner and "1 model" underneath — and a shop read it as a model.
/// Reported: *"one group is now one file"*. A grid of folders and files is
/// still one grid (same width, same two lines, same height), but a folder now
/// wears a STACK: two cards peeking out behind its picture, the shape every
/// photo app uses for "a set", and a badge with the kind's mark (a puzzle
/// piece for one print in parts, a stack for separate prints) and the count
/// where a file draws nothing. Its second line says "Group", not only a count.
///
/// The cards come out of the picture's own square rather than adding height,
/// so a row holding folders and files stays level.
struct FolderCell: View {
    let name: String
    let count: Int
    let thumbnail: ThumbnailSource?
    let words: Words
    /// One print in parts (a puzzle piece) or separate prints (a stack): the
    /// badge and the second line differ, so the two read differently.
    var kind: GroupKind = .assumed
    /// The level this group sits in, when the screen does not already say so
    /// — see `parent(of:open:)`.
    var parent: String? = nil
    /// Chosen with ⌘/⇧-click, drawn the way a chosen model is.
    var selected: Bool = false
    /// The grid's density: Small draws one line of title.
    var size: LibraryTileSize = .medium
    /// What the picture is decoded to (`LibraryTileSize.pixels`).
    var pixels: Int = ThumbnailStore.maxPixels

    /// How far each card behind the picture shows above it.
    static let peek: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { stack }

            VStack(alignment: .leading, spacing: 2) {
                // "Set A · in Collection X": a part's own name is often a
                // word that means nothing alone ("Set A", "left", "pose 2"),
                // and in All models the folder it lives in is nowhere else on
                // screen. On the name's own two lines, so the tile is the
                // height of every other tile.
                title
                    .font(.system(size: size.isCompact ? 11 : 12, weight: .medium))
                    .lineLimit(size.isCompact ? 1 : 2, reservesSpace: true)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .help(parent.map { name + " \u{00B7} " + words.callIt("mac.group_in_parent", ["name": .string($0)]) } ?? name)
                // "One print · 3 parts" or "Collection · 7 models", so the
                // words say it as well as the picture. "1 model", not "1
                // models"; Arabic's one and two are words.
                Text(Self.caption(kind: kind, count: count, words: words))
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
        .tileSelection(selected)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        // One element that says what it is: a group, its name, how many.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText(
            name: parent.map { name + ", " + words.callIt("mac.group_in_parent", ["name": .string($0)]) } ?? name,
            count: count, kind: kind, words: words))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var title: Text {
        guard let parent else { return Text(TitleBreaks.soften(name)) }
        return Text(TitleBreaks.soften(name))
            + Text(verbatim: " \u{00B7} " + words.callIt("mac.group_in_parent", ["name": .string(parent)]))
                .foregroundStyle(.secondary)
    }

    /// The level a group tile names under its own: the folder it sits in, by
    /// its own name — unless that folder is the one open, where the crumb
    /// above the grid already says it. Nil for a group at the top.
    static func parent(of path: String, open shelf: Shop.Shelf) -> String? {
        var levels = path.components(separatedBy: ImportGrouping.separator)
        guard levels.count > 1 else { return nil }
        levels.removeLast()
        let above = levels.joined(separator: ImportGrouping.separator)
        if case .library(let open?) = shelf, open == above { return nil }
        return Shop.groupLeaf(above)
    }

    /// What is in it, counted in the kind's own word: a print has PARTS, a
    /// collection has models.
    static func counted(kind: GroupKind, count: Int, words: Words) -> String {
        words.counting(count, kind == .parts ? "mac.n_parts" : "mac.n_models")
    }

    static func caption(kind: GroupKind, count: Int, words: Words) -> String {
        words.callIt(kind == .parts ? "mac.group_tile_parts" : "mac.group_tile_collection")
            + " \u{00B7} " + counted(kind: kind, count: count, words: words)
    }

    static func accessibilityText(name: String, count: Int, kind: GroupKind, words: Words) -> String {
        words.callIt("mac.group_tile_a11y", ["name": .string(name),
                                             "kind": .string(words.callIt(kind.wordKey)),
                                             "models": .string(counted(kind: kind, count: count, words: words))])
    }

    /// Two cards behind the picture, each narrower and higher than the one in
    /// front of it. Centred, so they read the same way in either direction.
    private var stack: some View {
        ZStack(alignment: .top) {
            card.padding(.horizontal, 14)
                .opacity(0.6)
            card.padding(.horizontal, 7)
                .padding(.top, Self.peek)
            // ── INSIDE THE SAME SQUARE A MODEL'S PICTURE FILLS ─────────────
            //
            // The picture was the full width and pushed down by the cards,
            // and a thumbnail that fills its frame grew past the square: the
            // tile's picture sat about 4pt lower than the models beside it.
            // Now it is a smaller square, inset by the peek at the sides and
            // twice the peek at the top, so the back card's top and the
            // picture's bottom are exactly a model tile's top and bottom.
            // `Color.clear` takes the size it is offered and nothing else, so
            // the picture cannot widen it.
            Color.clear
                .overlay { Thumbnail(source: thumbnail, pixels: pixels, well: LibraryTile.well) }
                // On the window's own ground: the thumbnail's grey is
                // translucent, and without this the cards behind showed
                // through it and the tile came out a different colour from a
                // model's.
                .background(Khayt.ground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, Self.peek)
                .padding(.top, Self.peek * 2)
                // Bottom TRAILING, where a file puts nothing — so it never sits
                // on the palette a file draws bottom-leading — and trailing
                // flips with the window, so in Arabic it is bottom-left.
                .overlay(alignment: .bottomTrailing) { badge }
        }
    }

    /// Ink-relative rather than a palette surface, so the cards read on the
    /// light ground and the dark one alike: `Role.surf3` all but vanished
    /// into the light window.
    private var card: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Khayt.ground)
            .overlay(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.22), lineWidth: 1))
    }

    /// The kind's mark and the count, big enough to be read across the room.
    private var badge: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.symbol)
            Text(Format.count(count)).monospacedDigit()
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(6)
    }
}

/// The ring round a tile that a dragged picture would land on.
struct TileDropRing: View {
    let shown: Bool
    var body: some View {
        if shown {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Khayt.brand, lineWidth: 2)
                .allowsHitTesting(false)
        }
    }
}

struct Cell: View {
    let file: LibraryFile
    let thumbnail: ThumbnailSource?
    let selected: Bool
    /// The words rather than the whole shop: a cell needs to say four things
    /// and has no business being able to change the book to say them.
    let words: Words
    /// The group to name on the tile, as a path — nil when there is nothing to
    /// say. See `groupShown`.
    var group: String? = nil
    /// Opening that group. A closure rather than the shop, for the same reason
    /// as `words`.
    var openGroup: (String) -> Void = { _ in }
    /// Where its bytes are, from the index (`Shop.storageBadge`) — nil draws
    /// nothing. Handed in, never looked up: a tile asks no disk anything.
    var storage: LibrarySyncIndex.State? = nil
    /// Set to Keep on this Mac: a pin beside the storage badge.
    var kept = false
    /// "4h 32m · 57 g · 85 ⃁" — `Shop.libraryFactsLine`, from the memo. Empty
    /// when the app knows none of them, and then the old line is drawn.
    var facts: String = ""
    /// The grid's density.
    var size: LibraryTileSize = .medium
    /// What the picture is decoded to (`LibraryTileSize.pixels`).
    var pixels: Int = ThumbnailStore.maxPixels

    /// The extensions a shop prints from every day. Their badge said
    /// nothing a shop did not already assume, on every tile, so only the
    /// others — the `.step` a customer sent, an `.obj`, a `.gcode` — wear one.
    static let everydayFormats: Set<String> = ["stl", "3mf"]

    /// The badge a tile wears for its format, or nil.
    static func formatBadge(_ ext: String?, size: LibraryTileSize) -> String? {
        guard !size.isCompact, let ext = ext?.lowercased(), !ext.isEmpty,
              !everydayFormats.contains(ext) else { return nil }
        return ext.uppercased()
    }

    /// Which group a tile names: the model's own, unless the grid is already
    /// INSIDE it.
    ///
    /// "All models" draws every model flat, so a model filed in a group looked
    /// exactly like one filed nowhere — reported as *"the group I created still
    /// appears as single models in All models"*. Inside the group the name
    /// would only repeat the crumb above, so it is left off there.
    static func groupShown(for file: LibraryFile, shelf: Shop.Shelf) -> String? {
        guard let group = file.groupName else { return nil }
        if case .library(let open?) = shelf, open == group { return nil }
        return group
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Thumbnail(source: thumbnail, pixels: pixels, tint: file.firstColour, well: LibraryTile.well)
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
                // WHERE IT IS: on this Mac only, backed up, or online only. The
                // corner the palette leaves; read aloud, never only seen.
                .overlay(alignment: .bottomTrailing) {
                    if let storage {
                        let said = words.callIt(Shop.storageWordKey(storage))
                            + (kept ? " · " + words.callIt("mac.storage_keep") : "")
                        HStack(spacing: 3) {
                            if kept { Image(systemName: "pin.fill") }
                            Image(systemName: Shop.storageSymbol(storage))
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(storage == .online ? AnyShapeStyle(Khayt.brand) : AnyShapeStyle(.primary))
                        .padding(.horizontal, 5).padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                        .padding(6)
                        .help(said)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(said)
                    }
                }
                // WHAT KIND OF FILE THIS IS. Khayt indexes twenty-two
                // extensions and the tile never said which one it was looking
                // at — a `.step` a customer sent and a `.3mf` ready for the
                // bed are the same card. Top-leading, because the favourite
                // star has the other corner and the palette has the floor.
                //
                // QUIETER NOW: only for a format other than STL and 3MF, and
                // never on a Small tile (`formatBadge`).
                .overlay(alignment: .topLeading) {
                    if let badge = Self.formatBadge(file.sourceFile?.ext, size: size) {
                        Text(badge)
                            .font(.system(size: 8, weight: .semibold))
                            .tracking(0.4)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.secondary)
                            .padding(5)
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(TitleBreaks.soften(file.title))
                    .font(.system(size: size.isCompact ? 11 : 12, weight: .medium))
                    .lineLimit(size.isCompact ? 1 : 2, reservesSpace: true)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .help(file.title)
                    .accessibilityLabel(file.title)
                // ONE line either way, so a row of grouped and ungrouped
                // models stays level: the group goes at the head of the line
                // the tile already had, and the rest of it gives way first.
                //
                // THE FACTS FIRST (`LibraryFacts`): how long, how much
                // plastic, what it sells for — the three a shop decides by.
                // They hold their width and the group's name gives way;
                // a Small tile has no room for the group at all.
                HStack(spacing: 4) {
                    if let group, !size.isCompact { groupLabel(group, named: facts.isEmpty).layoutPriority(facts.isEmpty ? 1 : 0) }
                    // Small has room for one figure: the print time, which
                    // is the one a shop plans the day around.
                    let shown = size.isCompact
                        ? (facts.components(separatedBy: " \u{00B7} ").first ?? facts) : facts
                    let line = facts.isEmpty ? subtitle : shown
                    if group == nil || size.isCompact || !line.isEmpty {
                        Text(((group == nil || size.isCompact || !facts.isEmpty) ? "" : "\u{00B7} ") + line)
                            .foregroundStyle(facts.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary.opacity(0.78)))
                            .layoutPriority(facts.isEmpty ? 0 : 1)
                            .help(facts.isEmpty ? line : facts)
                    }
                }
                .font(.caption2)
                .monospacedDigit()
                .lineLimit(1)
            }
            .padding(.top, 6)
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(6)
        .tileSelection(selected)
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    /// The group, as a link to it: the folder mark and the group's own name
    /// (its last level), with the whole path on hover.
    ///
    /// Beside the facts it is the folder mark alone — the name truncated to
    /// "…" said nothing, and the whole path is on hover either way.
    private func groupLabel(_ path: String, named: Bool = true) -> some View {
        let leaf = Shop.groupLeaf(path)
        return Button { openGroup(path) } label: {
            HStack(spacing: 2) {
                Image(systemName: "folder.fill")
                if named { Text(leaf).truncationMode(.tail) }
            }
            .foregroundStyle(Khayt.brand)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(words.callIt("mac.open_group", ["name": .string(path)]))
        .accessibilityLabel(words.callIt("mac.open_group", ["name": .string(leaf)]))
    }

    /// ── WHAT A TILE'S SECOND LINE IS FOR ─────────────────────────────────
    ///
    /// It led with the file's SIZE IN MEGABYTES, which is the least useful
    /// fact this app holds about a model. Nobody has ever chosen what to print
    /// by how many megabytes it is. Behind it sat "printed 12×", which is the
    /// most useful — how often this shop has actually made the thing.
    ///
    /// And the creator was nowhere. Every library tool in this category puts
    /// "By <designer>" under the name; Khayt had the field and never drew it,
    /// which matters more here than it does for them, because a shop that
    /// SELLS a print of somebody's model may owe them attribution — see
    /// `ModelLicence.needsAttribution`.
    ///
    /// So: who made it and how often it has been printed. The size stays in
    /// the inspector, where a shop that wants it is already looking.
    private var subtitle: String {
        var bits: [String] = []
        if let who = file.source, !who.isEmpty { bits.append(who) }
        // Khayt's own words for this, not ours: the catalogue has said
        // "printed {n}×" in nine languages since long before this app, and a
        // shop running in Arabic was reading an English sentence on every card
        // in its library.
        if file.printCount > 0 {
            bits.append(words.counting(file.printCount, "mac.printed_n"))
        }
        // A model that is neither printed nor attributed still says something
        // rather than nothing — and for those the size IS the only fact there
        // is, which is how it came to be first in the first place.
        if bits.isEmpty, let size = file.size { bits.append(Format.bytes(size)) }
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

struct EmptyShelf: View {
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
        } else if shop.libraryFilterOn {
            // Filters narrowed it to nothing: the way back is clearing them,
            // not importing more.
            EmptyHere(title: shop.words.callIt("mac.lg_none_filtered"),
                      message: shop.words.callIt("mac.lg_none_filtered_hint"), mark: .library) {
                Button(shop.words.callIt("log.clear_filters")) { shop.clearLibraryFilter() }
            }
        } else {
            // THE BUTTON THE SENTENCE NAMES, right under it. The hint said
            // "use the Import button" while the only one was an unlabelled
            // arrow in the title strip.
            EmptyHere(title: shop.words.callIt("mac.no_models"),
                      message: shop.words.callIt("mac.lg_empty_hint"), mark: .library) {
                Button {
                    Task { await shop.addModelToLibrary() }
                } label: {
                    Label(shop.words.callIt("mac.import_models") + "\u{2026}", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!shop.canMoveJobs || shop.importing)
            }
        }
    }
}

enum Format {
    /// Sizes a shop reads. Models here run to 80 MB and libraries to hundreds of
    /// gigabytes, so this is base-1000 like the Finder's, not base-1024.
    ///
    /// Through a format style rather than `ByteCountFormatter`, which has no
    /// locale to give and wrote "١٢٫٣ MB" in the English app on an Arabic-Indic
    /// Mac. `Money.digits` keeps the units as they were ("MB") and the digits
    /// this Mac asked for (`Digits`).
    static func bytes(_ n: Double) -> String {
        Int64(n).formatted(.byteCount(style: .file, allowedUnits: [.kb, .mb, .gb]).locale(Money.digits))
    }

    /// Any size, in whichever unit fits — `ByteCountFormatter`'s default units.
    static func fileSize(_ n: Int64) -> String {
        n.formatted(.byteCount(style: .file).locale(Money.digits))
    }

    /// Millimetres with no more precision than a shop can hold a caliper to.
    static func mm(_ v: Double) -> String { String(format: "%.0f", v) }

    static func count(_ n: Int) -> String {
        n.formatted(.number.locale(Money.digits))
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

/// Where a file name may wrap.
///
/// A shop's files are named by slicers and download sites, not by people:
/// `Kimba_gleam_stardemy`, `Modular+Filament+Storage+Organizer`. There is no
/// space in either, so the text system had no word to wrap at and broke the
/// tile's title wherever the line ran out — "Kimba_gleam_stardem / y",
/// "Modular+Filament+Sto / rage". A zero-width space after each separator
/// gives it the boundaries a person would have typed, and a name still too
/// long for two lines ends in an ellipsis with the whole of it on hover.
///
/// Display only. The name the book holds, searches and exports is untouched.
enum TitleBreaks {
    static let separators: Set<Character> = ["_", "+", "-", ".", "/"]

    static func soften(_ name: String) -> String {
        guard name.contains(where: separators.contains) else { return name }
        var out = ""
        out.reserveCapacity(name.count + 8)
        for (i, ch) in zip(name.indices, name) {
            out.append(ch)
            // Not after the last character, and not inside a run of separators
            // ("a__b" breaks once, after the run).
            let next = name.index(after: i)
            if separators.contains(ch), next < name.endIndex, !separators.contains(name[next]) {
                out.append("\u{200B}")
            }
        }
        return out
    }
}

extension View {
    /// A chosen tile — ONE look for a model and a group.
    ///
    /// Both drew `.selection` behind the tile, and on a group it was a faint
    /// wash: its picture and the cards behind it are opaque on the window's
    /// ground, so the fill showed only in the margin around them, while a
    /// model's thumbnail let it through. The border is what makes a chosen
    /// group read as chosen; a model wears the same, so the two cannot be
    /// told apart by how they are selected.
    func tileSelection(_ selected: Bool) -> some View {
        background(selected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                   in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
    }
}
