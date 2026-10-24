import SwiftUI
import KhaytCore

// ── SMART FOLDERS: THE BAR'S TWO BUTTONS AND THE SIDEBAR'S ROWS ───────────
//
// Everything here reads and writes `Shop.libraryQuery` — the one value the
// filter bar, the saved searches and the facet counts share. Nothing here
// filters a model itself: a count is `Shop.libraryCount`, which runs the
// grid's own matcher.

// MARK: - Ranges

/// "Ranges" (or "Ranges: 2"), opening the five ranges.
struct LibraryRangesButton: View {
    @Bindable var shop: Shop

    var body: some View {
        let n = shop.libraryRanges.activeCount
        Button {
            shop.libraryRangesShown.toggle()
        } label: {
            Text(n == 0 ? shop.words.callIt("mac.ls_ranges")
                 : shop.words.callIt("mac.ls_ranges_on", ["n": .string(shop.words.numeral(n))]))
                .lineLimit(1)
        }
        .fixedSize()
        .help(shop.words.callIt("mac.ls_ranges_help") + "\n" + shop.words.callIt("mac.ls_unknown_rule"))
        .popover(isPresented: $shop.libraryRangesShown, arrowEdge: .bottom) {
            LibraryRangesPopover(shop: shop)
        }
    }
}

/// Which range a row edits.
enum LibraryRangeKind: CaseIterable, Identifiable {
    case time, grams, price, printed
    var id: Self { self }
}

/// The five ranges, as a small form: a low and a high figure each, and the
/// day a model was added. Under each range that is on, how many models it is
/// leaving out because their figure is not known — a range is never silent
/// about what it cannot see.
struct LibraryRangesPopover: View {
    @Bindable var shop: Shop

    private func label(_ kind: LibraryRangeKind) -> String {
        switch kind {
        case .time: shop.words.callIt("mac.ls_range_time")
        case .grams: shop.words.callIt("mac.ls_range_grams")
        case .price: shop.words.callIt("mac.ls_range_price", ["currency": .string(Money.mark(shop.currency))])
        case .printed: shop.words.callIt("mac.ls_range_printed")
        }
    }

    /// The bound a row edits, and the factor its field shows it at: print
    /// time is kept in minutes and typed in hours.
    private func bound(_ kind: LibraryRangeKind) -> (Binding<LibraryQuery.Bound>, Double) {
        switch kind {
        case .time: ($shop.libraryRanges.minutes, 60)
        case .grams: ($shop.libraryRanges.grams, 1)
        case .price: ($shop.libraryRanges.price, 1)
        case .printed: ($shop.libraryRanges.timesPrinted, 1)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    Text(shop.words.callIt("mac.ls_min")).font(.caption).foregroundStyle(.secondary)
                    Text(shop.words.callIt("mac.ls_max")).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(LibraryRangeKind.allCases) { kind in
                    let (b, scale) = bound(kind)
                    GridRow {
                        Text(label(kind)).lineLimit(1)
                        RangeNumberField(value: b.min, scale: scale, words: shop.words)
                        RangeNumberField(value: b.max, scale: scale, words: shop.words)
                    }
                    // Only when the range is on AND leaves something out: an
                    // empty row here drew a blank band under the field.
                    if b.wrappedValue.isActive, case let n = shop.libraryUnknownCount(kind), n > 0 {
                        GridRow {
                            Text("")
                            unknownNote(n).gridCellColumns(2)
                        }
                    }
                }
                GridRow {
                    Text(shop.words.callIt("mac.ls_range_added")).lineLimit(1)
                    AddedPicker(shop: shop).gridCellColumns(2)
                }
                if case .between = AddedPicker.choice(shop.libraryRanges.added) {
                    GridRow {
                        Text("")
                        RangeDayField(day: $shop.libraryRanges.added.from, label: shop.words.callIt("mac.ls_from"))
                        RangeDayField(day: $shop.libraryRanges.added.to, label: shop.words.callIt("mac.ls_to"))
                    }
                }
                if shop.libraryRanges.added.isActive, case let n = shop.libraryUnknownAddedCount(), n > 0 {
                    GridRow {
                        Text("")
                        unknownNote(n).gridCellColumns(2)
                    }
                }
            }
            Divider()
            HStack {
                Text(shop.words.callIt("mac.ls_unknown_rule"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(shop.words.callIt("mac.ls_clear_ranges")) { shop.libraryRanges = LibraryQuery.Ranges() }
                    .disabled(!shop.libraryRanges.isActive)
            }
        }
        .controlSize(.small)
        .padding(14)
        .frame(width: 380)
    }

    @ViewBuilder private func unknownNote(_ n: Int) -> some View {
        if n > 0 {
            Label(shop.words.callIt("mac.ls_unknown_n", ["n": .string(shop.words.numeral(n))]),
                  systemImage: "questionmark.circle")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// A figure, typed. Empty is an open end. Arabic-Indic digits and the Arabic
/// decimal separator are read as the figures they are.
private struct RangeNumberField: View {
    @Binding var value: Double?
    /// What the stored figure is divided by to show it (minutes → hours).
    let scale: Double
    let words: Words
    @State private var text = ""

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 84)
            .onAppear { text = Self.show(value, scale: scale) }
            .onChange(of: text) { _, typed in
                let parsed = Self.number(typed).map { $0 * scale }
                if parsed != value { value = parsed }
            }
            .onChange(of: value) { _, now in
                // Cleared from outside (Clear Ranges, a saved search loaded).
                if Self.number(text).map({ $0 * scale }) != now { text = Self.show(now, scale: scale) }
            }
    }

    static func show(_ v: Double?, scale: Double) -> String {
        guard let v else { return "" }
        let shown = v / scale
        return shown.rounded() == shown ? String(Int(shown)) : String(format: "%g", shown)
    }

    /// A typed figure, or nil for empty or not a number.
    static func number(_ typed: String) -> Double? {
        var out = ""
        for ch in typed.trimmingCharacters(in: .whitespaces) {
            if let v = ch.wholeNumberValue { out.append(String(v)) }
            else if ch == "." || ch == "," || ch == "\u{066B}" { out.append(".") }
            else if ch == "-" { out.append("-") }
            else { return nil }
        }
        guard !out.isEmpty, let v = Double(out), v.isFinite, v >= 0 else { return nil }
        return v
    }
}

/// Any time, the last 7/30/90 days, or between two days.
private struct AddedPicker: View {
    @Bindable var shop: Shop

    enum Choice: Hashable { case any, last(Int), between }

    static func choice(_ d: LibraryQuery.Days) -> Choice {
        if let n = d.lastDays, n > 0 { return .last(n) }
        if d.from != nil || d.to != nil { return .between }
        return .any
    }

    var body: some View {
        Picker("", selection: Binding(get: { Self.choice(shop.libraryRanges.added) }, set: { c in
            switch c {
            case .any: shop.libraryRanges.added = .init()
            case .last(let n): shop.libraryRanges.added = .init(lastDays: n)
            case .between:
                let today = Calendar.book.dayString(Date())
                let start = Calendar.book.date(byAdding: .day, value: -29, to: Date()).map { Calendar.book.dayString($0) }
                shop.libraryRanges.added = .init(from: start, to: today)
            }
        })) {
            Text(shop.words.callIt("mac.ls_any_time")).tag(Choice.any)
            Text(shop.words.callIt("mac.ls_last_7")).tag(Choice.last(7))
            Text(shop.words.callIt("mac.ls_last_30")).tag(Choice.last(30))
            Text(shop.words.callIt("mac.ls_last_90")).tag(Choice.last(90))
            Text(shop.words.callIt("mac.ls_between")).tag(Choice.between)
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// One end of "between", as a day in the book's calendar.
private struct RangeDayField: View {
    @Binding var day: String?
    let label: String

    var body: some View {
        DatePicker(label, selection: Binding(get: {
            day.flatMap(Self.date) ?? Date()
        }, set: { day = Calendar.book.dayString($0) }), displayedComponents: .date)
            .labelsHidden()
            .help(label)
    }

    /// Midday on a `YYYY-MM-DD`, in the book's calendar.
    static func date(_ day: String) -> Date? {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return Calendar.book.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))
    }
}

extension Shop {
    /// How many models a range is leaving out because their figure is not
    /// known: those the query finds with this range taken off, that have no
    /// figure for it. Asked only while the popover is open.
    func libraryUnknownCount(_ kind: LibraryRangeKind) -> Int {
        var q = libraryQuery
        switch kind {
        case .time: q.ranges.minutes = .init()
        case .grams: q.ranges.grams = .init()
        case .price: q.ranges.price = .init()
        case .printed: q.ranges.timesPrinted = .init()
        }
        return libraryUnknownCount(q) { f in
            switch kind {
            case .time: f.minutes == nil
            case .grams: f.grams == nil
            case .price: f.price == nil
            case .printed: f.timesPrinted == nil
            }
        }
    }

    func libraryUnknownAddedCount() -> Int {
        var q = libraryQuery
        q.ranges.added = .init()
        return libraryUnknownCount(q) { $0.addedDay == nil }
    }

    private func libraryUnknownCount(_ q: LibraryQuery, _ unknown: (LibraryQuery.Figures) -> Bool) -> Int {
        var group: String?
        if case .library(let g) = shelf { group = g }
        let match = libraryMatcher(q, group: group)
        let text = SearchText.fold(q.text.trimmingCharacters(in: .whitespaces))
        let searching = text.isEmpty ? nil : searchMatcher(LibrarySearch.parse(text))
        return files.count { match($0) && (searching?($0) ?? true) && unknown(libraryFigures($0)) }
    }
}

// MARK: - Save Search…

/// "Save Search…", and "Update Search" while a saved search loaded with
/// Edit Search has been changed. The name is in the tooltip, never on the
/// button: a long name made the row wider than the window and pushed the
/// sidebar off it (Oct 2026 capture). `compact` — the row's narrowest
/// layout — folds the two into one Save menu.
struct LibrarySaveSearchButton: View {
    @Bindable var shop: Shop
    var compact = false

    private var editing: LibrarySavedSearch? {
        guard let id = shop.libraryEditingSearchId else { return nil }
        return shop.librarySavedSearches.first { $0.id == id }
    }

    var body: some View {
        let changed = editing.flatMap { $0.query.unsorted != shop.libraryQuery.unsorted ? $0 : nil }
        Group {
            if compact, let changed {
                Menu {
                    Button(shop.words.callIt("mac.ls_update")) { Task { await shop.replaceLibrarySearch(changed.id) } }
                    Button(shop.words.callIt("mac.ls_save")) { shop.librarySaveSearchShown = true }
                } label: {
                    Text(shop.words.callIt("mac.ls_save_menu")).lineLimit(1)
                }
                .menuStyle(.button)
                .fixedSize()
                .help(shop.words.callIt("mac.ls_update_help", ["name": .string(changed.name)]))
            } else {
                HStack(spacing: 6) {
                    if let changed {
                        Button(shop.words.callIt("mac.ls_update")) {
                            Task { await shop.replaceLibrarySearch(changed.id) }
                        }
                        .fixedSize()
                        .help(shop.words.callIt("mac.ls_update_help", ["name": .string(changed.name)]))
                    }
                    Button(shop.words.callIt("mac.ls_save")) { shop.librarySaveSearchShown = true }
                        .fixedSize()
                        .help(shop.words.callIt("mac.ls_save_help"))
                }
            }
        }
        .popover(isPresented: $shop.librarySaveSearchShown, arrowEdge: .bottom) {
            SearchNamePopover(shop: shop, original: nil, initial: editing?.name ?? "")
        }
    }
}

/// A name for a saved search: Save Search… and Rename… both.
struct SearchNamePopover: View {
    @Bindable var shop: Shop
    /// The search being renamed, or nil when saving the one on screen.
    let original: LibrarySavedSearch?
    let initial: String
    @State private var name = ""
    @FocusState private var focused: Bool

    private var cleaned: String { LibrarySavedSearch.clean(name) }

    /// Saving under a name that is taken replaces that search; renaming onto
    /// one is refused.
    private var clash: Bool {
        shop.librarySavedSearches.contains {
            $0.id != original?.id && $0.name.lowercased() == cleaned.lowercased()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(shop.words.callIt("mac.ls_name")).font(.caption).foregroundStyle(.secondary)
            TextField(shop.words.callIt("mac.ls_name_prompt"), text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(commit)
            if clash, !cleaned.isEmpty {
                Text(shop.words.callIt(original == nil ? "mac.ls_replaces" : "mac.ls_rename_taken"))
                    .font(.caption)
                    .foregroundStyle(original == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Khayt.attention))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(shop.words.callIt("mac.ls_cancel")) { close() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("mac.ls_save_button"), action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(cleaned.isEmpty || (original != nil && clash))
            }
        }
        .controlSize(.small)
        .padding(14)
        .frame(width: 280)
        .onAppear { name = initial; focused = true }
    }

    private func close() {
        shop.librarySaveSearchShown = false
        shop.libraryRenamingSearchId = nil
    }

    private func commit() {
        guard !cleaned.isEmpty, !(original != nil && clash) else { return }
        let typed = cleaned
        let original = self.original
        close()
        Task {
            if let original { await shop.renameLibrarySearch(original.id, to: typed) }
            else { await shop.saveLibrarySearch(named: typed) }
        }
    }
}

// MARK: - The sidebar

/// One smart folder or saved search, as the sidebar lists it.
struct LibrarySmartRowModel: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let query: LibraryQuery
    /// Nil for a built-in one, which cannot be renamed or deleted.
    let saved: LibrarySavedSearch?
}

extension Shop {
    /// The built-in smart folders, then the shop's own saved searches.
    var librarySmartRows: [LibrarySmartRowModel] {
        LibrarySmartFolder.allCases.map {
            LibrarySmartRowModel(id: "builtin:" + $0.rawValue, title: words.callIt($0.key),
                                 symbol: $0.symbol, query: $0.query, saved: nil)
        } + librarySavedSearches.map {
            LibrarySmartRowModel(id: $0.id, title: $0.name, symbol: "line.3.horizontal.decrease.circle",
                                 query: $0.query, saved: $0)
        }
    }

    /// Open a row: its query in the bar. Edit Search also marks it as the one
    /// being changed, so the bar offers Update.
    func openSmartRow(_ row: LibrarySmartRowModel, editing: Bool = false) {
        guard !needsSignIn else { return }
        openLibraryQuery(row.query)
        libraryEditingSearchId = editing ? row.saved?.id : nil
    }
}

/// The right-click menu a saved search has: Rename, Edit, Duplicate, Delete.
private struct SavedSearchMenu: View {
    let shop: Shop
    let row: LibrarySmartRowModel

    var body: some View {
        if let saved = row.saved {
            Button(shop.words.callIt("mac.ls_rename")) { shop.libraryRenamingSearchId = saved.id }
            Button(shop.words.callIt("mac.ls_edit")) { shop.openSmartRow(row, editing: true) }
            Button(shop.words.callIt("mac.ls_duplicate")) { Task { await shop.duplicateLibrarySearch(saved.id) } }
            Divider()
            Button(shop.words.callIt("mac.ls_delete"), role: .destructive) {
                if shop.libraryEditingSearchId == saved.id { shop.libraryEditingSearchId = nil }
                Task { await shop.deleteLibrarySearch(saved.id) }
            }
        }
    }
}

/// The rename popover, on the row it renames.
private struct RenamePopover: ViewModifier {
    @Bindable var shop: Shop
    let row: LibrarySmartRowModel

    func body(content: Content) -> some View {
        if let saved = row.saved {
            content.popover(isPresented: Binding(get: { shop.libraryRenamingSearchId == saved.id },
                                                 set: { if !$0 { shop.libraryRenamingSearchId = nil } }),
                            arrowEdge: .trailing) {
                SearchNamePopover(shop: shop, original: saved, initial: saved.name)
            }
        } else {
            content
        }
    }
}

/// Under Library in the navy sidebar (`ShellSidebar`): the smart folders and
/// saved searches, indented, smaller than the shelves, each with its live
/// count. A built-in one at zero is dimmed, never hidden — a sidebar that
/// changes shape is a sidebar nobody can learn.
struct ShellSmartFolderRows: View {
    @Bindable var shop: Shop

    var body: some View {
        ForEach(shop.librarySmartRows) { row in
            ShellSmartRow(shop: shop, row: row)
        }
    }
}

private struct ShellSmartRow: View {
    @Bindable var shop: Shop
    let row: LibrarySmartRowModel

    var body: some View {
        let selected = shop.libraryShows(row.query)
        let count = shop.needsSignIn ? nil : shop.libraryCount(row.query)
        HStack(spacing: Space.xs) {
            Image(systemName: row.symbol)
                .font(.system(size: 9))
                .foregroundStyle(Role.onNavy3)
                .frame(width: 11)
            // Shrunk a little before it is cut: "Sells in catalogue" is the
            // longest built-in name and the column is 150pt.
            Text(row.title)
                .font(TypeScale.row(10.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(count == 0 && row.saved == nil ? Role.onNavy3 : Role.onNavy2)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .truncationMode(.tail)
            Spacer(minLength: Space.xs)
            if let count {
                Figure(value: Double(count), size: 9.5, tint: Role.onNavy3)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .frame(height: 21)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(Role.onNavy.opacity(0.08))
                    .padding(.horizontal, 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { shop.openSmartRow(row) }
        .contextMenu { SavedSearchMenu(shop: shop, row: row) }
        .modifier(RenamePopover(shop: shop, row: row))
        .help(row.saved == nil ? shop.words.callIt("mac.ls_builtin_help") : row.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The same rows in the classic source list (`Sidebar`). Untagged, so they
/// never become the list's selection: a saved search is a query on the
/// Library shelf, not a shelf of its own.
struct ClassicSmartFolderRows: View {
    @Bindable var shop: Shop

    var body: some View {
        ForEach(shop.librarySmartRows) { row in
            let count = shop.libraryCount(row.query)
            HStack {
                Label(row.title, systemImage: row.symbol)
                    .foregroundStyle(count == 0 && row.saved == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                Spacer(minLength: 8)
                Text(shop.words.numeral(count)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.leading, 14)
            .contentShape(Rectangle())
            .onTapGesture { shop.openSmartRow(row) }
            .contextMenu { SavedSearchMenu(shop: shop, row: row) }
            .modifier(RenamePopover(shop: shop, row: row))
            .help(row.saved == nil ? shop.words.callIt("mac.ls_builtin_help") : row.title)
        }
    }
}
