import SwiftUI
import AppKit
import KhaytCore

// MARK: - The trailing half of the filter row

/// How the library is shown: what is left after the filters, the order, grid
/// or list, and the tile size — the trailing side of `LibraryFilterBar`.
struct LibraryViewControls: View {
    @Bindable var shop: Shop
    private var display: LibraryDisplay { LibraryDisplay.shared }

    var body: some View {
        HStack(spacing: 8) {
            // What is left, in the shop's digits: "1,240 models". Models, not
            // tiles — a group folded into one tile still holds what it holds.
            Text(verbatim: shop.words.counting(shop.shownFiles.count, "mac.n_models"))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .accessibilityLabel(shop.words.counting(shop.shownFiles.count, "mac.n_models"))

            sortMenu

            // Grid | List.
            Picker(shop.words.callIt("mac.lg_view"), selection: Binding(
                get: { display.layout }, set: { display.layout = $0 })) {
                ForEach(LibraryLayout.allCases) { layout in
                    Image(systemName: layout.symbol)
                        .help(shop.words.callIt(layout.wordKey))
                        .accessibilityLabel(shop.words.callIt(layout.wordKey))
                        .tag(layout)
                }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help(shop.words.callIt("mac.lg_view"))

            // Small / Medium / Large — only where there are tiles to size.
            if display.layout == .grid {
                Picker(shop.words.callIt("mac.lg_tile_size"), selection: Binding(
                    get: { display.tileSize }, set: { display.tileSize = $0 })) {
                    ForEach(LibraryTileSize.allCases) { size in
                        Image(systemName: size.symbol)
                            .help(shop.words.callIt(size.wordKey))
                            .accessibilityLabel(shop.words.callIt(size.wordKey))
                            .tag(size)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help(shop.words.callIt("mac.lg_tile_size_help"))
            }
        }
    }

    /// The order — the same choice as View ▸ Sort By, where it can be seen.
    private var sortMenu: some View {
        Menu {
            Picker(shop.words.callIt("mac.sort_by"), selection: $shop.librarySort) {
                ForEach(LibrarySort.allCases) { sort in
                    Text(shop.words.callIt(sort.key)).tag(sort)
                }
            }
            .pickerStyle(.inline)
        } label: {
            // ONE Text, for the reason `LibraryFilterBar.menu` gives.
            Text(verbatim: "\u{21C5} " + shop.words.callIt(shop.librarySort.key)).lineLimit(1)
        }
        .menuStyle(.button)
        .fixedSize()
        .id("sort|" + shop.librarySort.rawValue)
        .help(shop.words.callIt("mac.sort_by"))
    }
}

// MARK: - The list

/// One row of the list: a model or a group, with every figure the columns
/// show worked out once (`Shop.libraryListRows`), never per draw.
///
/// The figures are plain numbers with `-1` for "not known", so a column can
/// be declared sortable by key path; the ORDER itself is the library's own
/// (`LibrarySort`, the memo), so the grid and the list never disagree.
struct LibraryRow: Identifiable, Hashable {
    struct Key: Equatable {
        var entries: LibraryMemo.EntriesKey?
        var facts: [Int]
        var sync: Int
        var language: String
        /// What the printer chips were made from (`machineFitsKey`).
        var fits: [Int]
    }

    let id: String
    let entry: LibraryEntry
    let name: String
    let folder: String
    let material: String
    let minutes: Double
    let minutesEstimated: Bool
    let grams: Double
    let gramsEstimated: Bool
    let price: Double
    let size: Double
    let times: Int
    let last: Double
    let storage: LibrarySyncIndex.State?
    let kept: Bool
    /// The tile's printer chips (`Shop.libraryFitChips`); nil for a folder.
    var fits: LibraryFitChips.Row? = nil

    var file: LibraryFile? {
        if case .file(let f) = entry { return f }
        return nil
    }
    var isFolder: Bool { file == nil }
}

extension Shop {
    /// The list's rows, from the memo when the entries, the facts and the
    /// storage index have not moved.
    func libraryListRows() -> [LibraryRow] {
        let entries = memoEntries().entries
        let memo = libraryMemo
        let key = LibraryRow.Key(entries: memo.entriesKey, facts: libraryFactsKey(),
                                 sync: librarySyncRevision, language: words.language,
                                 fits: machineFitsKey())
        if memo.rowsKey == key { return memo.rows }
        let rows: [LibraryRow] = entries.map { entry in
            switch entry {
            case .folder(let name, let path, let count, _):
                let parent = path.components(separatedBy: ImportGrouping.separator).dropLast()
                    .joined(separator: ImportGrouping.separator)
                return LibraryRow(id: entry.id, entry: entry, name: name, folder: parent,
                                  material: "", minutes: -1, minutesEstimated: false, grams: -1,
                                  gramsEstimated: false, price: -1, size: -1, times: count, last: -1,
                                  storage: nil, kept: false)
            case .file(let file):
                let facts = libraryFacts(file)
                let material = [file.material, file.parsed?.filamentType]
                    .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
                return LibraryRow(id: entry.id, entry: entry, name: file.title, folder: file.groupName ?? "",
                                  material: material,
                                  minutes: facts.minutes ?? -1, minutesEstimated: facts.minutesEstimated,
                                  grams: facts.grams ?? -1, gramsEstimated: facts.gramsEstimated,
                                  price: facts.price ?? -1, size: file.size ?? -1, times: file.printCount,
                                  last: file.lastPrintedDate?.timeIntervalSince1970 ?? -1,
                                  storage: storageBadge(for: file), kept: isKeptOnThisMac(file),
                                  fits: modelMachines.isEmpty ? nil : libraryFitChips(file))
            }
        }
        memo.rowsKey = key
        memo.rows = rows
        return rows
    }
}

/// The library as a table — for a shop that knows what it is looking for by
/// name, weight or what it sells for, and wants a hundred rows on screen.
///
/// The SAME selection, keyboard and right-click as the grid: Return opens,
/// Space is Quick Look, ⌫ asks the grid's own delete question, and the menu on
/// a row is `ModelActions`. Numbers are right-aligned in tabular digits, so a
/// column of weights reads as a column; `Table` mirrors itself in Arabic.
struct LibraryList: View {
    @Bindable var shop: Shop
    @State private var order: [KeyPathComparator<LibraryRow>] = []
    @State private var dropping = false
    /// The window's own Hide/Show Details, read here so the table can give
    /// up its least-needed column when the inspector takes 280 pt of it.
    @SceneStorage("inspector.showing") private var inspectorShowing = true

    var body: some View {
        let rows = shown(shop.libraryListRows())
        Table(rows, selection: selection, sortOrder: $order) {
            TableColumn("") { row in
                picture(row)
            }
            .width(30)
            TableColumn(shop.words.callIt("mac.name"), value: \LibraryRow.name) { row in
                HStack(spacing: 4) {
                    if row.isFolder { Image(systemName: "folder.fill").foregroundStyle(Khayt.brand) }
                    if row.file?.isFavourite == true {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(Khayt.marked)
                    }
                    // A stack's cover: the variants it stands for, as the tile's badge.
                    if let file = row.file, let stack = shop.libraryStackTile(file.id), stack.isStack {
                        let said = Cell.stackSaid(stack, words: shop.words)
                        Button { if let id = stack.stackId { shop.toggleStackOpen(id) } } label: {
                            HStack(spacing: 1) {
                                Image(systemName: "square.stack.fill")
                                Text(verbatim: Cell.stackBadge(stack, words: shop.words))
                            }
                            .font(.caption2).monospacedDigit()
                        }
                        .buttonStyle(.plain)
                        .help(said)
                        .accessibilityLabel(said)
                    }
                    if let file = row.file, file.isPrintNext {
                        Image(systemName: "bookmark.fill").font(.caption2).foregroundStyle(Khayt.brand)
                            .help(Cell.printNextSaid(file, words: shop.words))
                    }
                    Text(row.name).lineLimit(1).truncationMode(.middle)
                }
                .help(row.name)
            }
            // THE COLUMNS FIT THE PANE AT 1440 PT WITH THE INSPECTOR OPEN.
            // beta.7: the ideal widths added up to more than the content
            // column, so "Last run" was cut to "Sep"/"O", Storage was never
            // on screen, and names were middle-truncated beside a wide
            // Folder. Folder goes while the inspector is open (the model's
            // page says where it is), Fits is narrower (its chips fold into
            // "+N" on their own), and Name is the one that grows.
            .width(min: 120, ideal: 190)
            if !inspectorShowing {
                TableColumn(shop.words.callIt("mac.lg_col_folder")) { row in
                    Text(row.folder).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                }
                .width(min: 48, ideal: 72)
            }
            TableColumn(shop.words.callIt("mac.lg_col_material")) { row in
                Text(row.material).lineLimit(1)
            }
            .width(min: 44, ideal: 56)
            // WHERE IT PRINTS — the tile's printer chips, the same memo. Beside
            // the name rather than at the far end: the table is wider than
            // the window with the inspector open, and the last column was
            // the one cut off (Oct 2026 capture).
            TableColumn(shop.words.callIt("mac.lg_col_fits")) { row in
                if let fits = row.fits {
                    FitChipRow(row: LibraryFitChips.leading(fits, shop.libraryFitsOn ?? shop.libraryReadyOn),
                               words: shop.words)
                }
            }
            .width(min: 60, ideal: 96)
            Group {
                TableColumn(shop.words.callIt("mac.lg_sort_time"), value: \LibraryRow.minutes) { row in
                    figure(row.minutes < 0 ? ""
                           : LibraryFacts.duration(row.minutes, words: shop.words, approximate: row.minutesEstimated))
                }
                .width(min: 60, ideal: 74)
                TableColumn(shop.words.callIt("mac.lg_col_grams"), value: \LibraryRow.grams) { row in
                    figure(row.grams < 0 ? ""
                           : LibraryFacts.weight(row.grams, words: shop.words, approximate: row.gramsEstimated))
                }
                .width(min: 44, ideal: 56)
                TableColumn(shop.words.callIt("mac.lg_sort_price"), value: \LibraryRow.price) { row in
                    figure(row.price < 0 ? "" : LibraryFacts.price(row.price, currency: shop.currency))
                }
                .width(min: 44, ideal: 58)
                TableColumn(shop.words.callIt("set.store_size"), value: \LibraryRow.size) { row in
                    figure(row.size < 0 ? "" : Format.bytes(row.size))
                }
                .width(min: 44, ideal: 58)
            }
            Group {
                TableColumn(shop.words.callIt("mac.printed"), value: \LibraryRow.times) { row in
                    figure(row.isFolder ? "" : (row.times > 0 ? Format.count(row.times) : "\u{2013}"))
                }
                .width(min: 36, ideal: 40)
                TableColumn(shop.words.callIt("mac.last_run"), value: \LibraryRow.last) { row in
                    figure(row.last < 0 ? "" : Self.day(Date(timeIntervalSince1970: row.last), words: shop.words))
                }
                .width(min: 56, ideal: 68)
                TableColumn(shop.words.callIt("mac.lg_col_storage")) { row in
                    storage(row)
                }
                .width(min: 44, ideal: 60)
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .onAppear { order = Self.comparators(for: shop.librarySort) }
        .onChange(of: shop.librarySort) { _, sort in
            if Self.sort(for: order) != sort { order = Self.comparators(for: sort) }
        }
        .onChange(of: order) { _, now in
            if let sort = Self.sort(for: now), sort != shop.librarySort { shop.librarySort = sort }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            open(ids)
        }
        .onKeyPress(.return) {
            open(selection.wrappedValue)
            return .handled
        }
        .onKeyPress(.space) {
            guard shop.selectionIsOnThisMac else { return .ignored }
            shop.quickLookSelection()
            return .handled
        }
        .onDeleteCommand { shop.askToDeleteLibrarySelection() }
        .dropDestination(for: URL.self) { urls, _ in
            guard shop.canMoveJobs, !shop.importing, !urls.isEmpty else { return false }
            Task { await shop.addModelsToLibrary(urls) }
            return true
        } isTargeted: { dropping = $0 }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .overlay { if shop.shownFiles.isEmpty { LibraryEmptyOverlay(shop: shop) } }
    }

    /// The rows, turned round when a column header asked for the other way.
    private func shown(_ rows: [LibraryRow]) -> [LibraryRow] {
        guard let first = order.first, let sort = Self.sort(for: order),
              first.order != Self.natural(sort) else { return rows }
        return rows.reversed()
    }

    /// A last-printed date as short as it can be read: "Sep 15" this year,
    /// "Sep 15, 2025" before it — the year said only when it is news. In the
    /// book's calendar, like every date a person reads in this app.
    static func day(_ date: Date, now: Date = Date(), words: Words) -> String {
        let sameYear = Calendar.book.component(.year, from: date) == Calendar.book.component(.year, from: now)
        return sameYear ? words.say(date, .dateTime.day().month(.abbreviated))
                        : words.say(date, .dateTime.day().month(.abbreviated).year())
    }

    // MARK: Columns ↔ the library's order

    /// Which way each order runs on its own, as a column header shows it.
    static func natural(_ sort: LibrarySort) -> SortOrder {
        switch sort {
        case .name, .printTime, .grams: .forward
        default: .reverse
        }
    }

    static func comparators(for sort: LibrarySort) -> [KeyPathComparator<LibraryRow>] {
        let o = natural(sort)
        switch sort {
        case .name: return [KeyPathComparator(\LibraryRow.name, order: o)]
        case .printTime: return [KeyPathComparator(\LibraryRow.minutes, order: o)]
        case .grams: return [KeyPathComparator(\LibraryRow.grams, order: o)]
        case .price: return [KeyPathComparator(\LibraryRow.price, order: o)]
        case .size: return [KeyPathComparator(\LibraryRow.size, order: o)]
        case .timesPrinted: return [KeyPathComparator(\LibraryRow.times, order: o)]
        case .lastPrinted: return [KeyPathComparator(\LibraryRow.last, order: o)]
        case .added, .khayt: return []
        }
    }

    static func sort(for order: [KeyPathComparator<LibraryRow>]) -> LibrarySort? {
        guard let path = order.first?.keyPath else { return nil }
        switch path {
        case \LibraryRow.name: return .name
        case \LibraryRow.minutes: return .printTime
        case \LibraryRow.grams: return .grams
        case \LibraryRow.price: return .price
        case \LibraryRow.size: return .size
        case \LibraryRow.times: return .timesPrinted
        case \LibraryRow.last: return .lastPrinted
        default: return nil
        }
    }

    // MARK: Selection — the grid's own two sets

    private var selection: Binding<Set<String>> {
        Binding {
            Set(shop.fileSelection.map { "file:" + $0 } + shop.groupSelection.map { "folder:" + $0 })
        } set: { ids in
            let files = Set(ids.compactMap { $0.hasPrefix("file:") ? String($0.dropFirst(5)) : nil })
            let groups = Set(ids.compactMap { $0.hasPrefix("folder:") ? String($0.dropFirst(7)) : nil })
            // One kind at a time, as in the grid: models win.
            if !files.isEmpty {
                shop.fileSelection = files
                shop.groupSelection = []
            } else {
                shop.fileSelection = []
                shop.groupSelection = groups
            }
        }
    }

    private func open(_ ids: Set<String>) {
        if ids.count == 1, let id = ids.first, id.hasPrefix("folder:") {
            shop.shelf = .library(String(id.dropFirst(7)))
            return
        }
        shop.openSelection()
    }

    @ViewBuilder private func menu(for ids: Set<String>) -> some View {
        let rows = shop.libraryListRows().filter { ids.contains($0.id) }
        if let file = rows.lazy.compactMap(\.file).first {
            ModelActions(file: file, shop: shop)
        } else if let row = rows.first, case .folder(_, let path, _, _) = row.entry {
            GroupKindMenu(shop: shop, path: path)
            GroupPictureItems(shop: shop, path: path)
            Divider()
            GroupTileActions(shop: shop, path: path)
        }
    }

    // MARK: Cells

    @ViewBuilder private func picture(_ row: LibraryRow) -> some View {
        Group {
            switch row.entry {
            case .file(let file):
                Thumbnail(source: shop.thumbnail(for: file), pixels: 64, tint: file.firstColour,
                          well: LibraryTile.well)
            case .folder(_, let path, _, let cover):
                Thumbnail(source: shop.groupThumbnail(path, automatic: cover), pixels: 64, well: LibraryTile.well)
            }
        }
        .frame(width: 26, height: 26)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// A number, at the column's trailing edge, in tabular digits.
    private func figure(_ text: String) -> some View {
        Text(text)
            .monospacedDigit()
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder private func storage(_ row: LibraryRow) -> some View {
        if let state = row.storage {
            let said = shop.words.callIt(Shop.storageWordKey(state))
            HStack(spacing: 4) {
                if row.kept { Image(systemName: "pin.fill").font(.caption2) }
                Image(systemName: Shop.storageSymbol(state))
                    .foregroundStyle(state == .online ? AnyShapeStyle(Khayt.brand) : AnyShapeStyle(.secondary))
                Text(said).lineLimit(1).foregroundStyle(.secondary)
            }
            .help(said)
        }
    }
}

/// The empty states, shared by the grid and the list.
struct LibraryEmptyOverlay: View {
    let shop: Shop
    var body: some View { EmptyShelf(shop: shop) }
}
