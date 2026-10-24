import Foundation
import KhaytCore

/// ── ONE QUERY: THE BAR, THE SAVED SEARCHES AND THE COUNTS ─────────────────
///
/// `libraryQuery` is the whole of what the library is narrowed by, as one
/// value (`LibraryQuery`, portable). The filter bar reads and writes it, a
/// saved search stores it and loads it back, and every list or count of
/// models is worked out from a query by `libraryMatcher` — the grid's
/// `buildShownFiles`, the facet pools (`libraryPool`) and each smart folder's
/// count in the sidebar (`libraryCount`). There is no second filter.
///
/// The axes are still kept as the shop's own properties (`libraryTag`,
/// `libraryRanges`, …), because each one's setter is what recounts the chips
/// and prunes the selection, and fifty call sites and tests set them. This
/// getter and setter are the one door between those and the value: reading
/// assembles it, writing sets only the axes that differ, so loading a saved
/// search recounts once per axis it changes and never for one it does not.
extension Shop {

    var libraryQuery: LibraryQuery {
        get {
            var q = LibraryQuery()
            q.text = search
            q.printNext = libraryPrintNextOnly
            q.duplicates = libraryDuplicatesOnly
            q.unfiled = libraryUnfiledOnly
            q.neverPrinted = libraryNeverPrintedOnly
            q.archived = libraryShowArchived
            q.storage = libraryStorage.map { $0 == .onlineOnly ? .onlineOnly : .thisMacOnly }
            q.noFigures = libraryNoFiguresOnly
            q.inCatalogue = libraryInCatalogueOnly
            q.readyOn = libraryReadyOn
            q.readyAnywhere = libraryReadyAnywhere
            q.creator = libraryCreator
            switch libraryCategory {
            case .named(let name)?: q.category = name
            case .unfiled?: q.uncategorised = true
            case nil: break
            }
            q.tag = libraryTag
            q.ranges = libraryRanges
            q.sort = librarySort.rawValue
            return q
        }
        set {
            let q = newValue
            if search != q.text { search = q.text }
            if libraryPrintNextOnly != q.printNext { libraryPrintNextOnly = q.printNext }
            if libraryDuplicatesOnly != q.duplicates { libraryDuplicatesOnly = q.duplicates }
            if libraryUnfiledOnly != q.unfiled { libraryUnfiledOnly = q.unfiled }
            if libraryNeverPrintedOnly != q.neverPrinted { libraryNeverPrintedOnly = q.neverPrinted }
            if libraryShowArchived != q.archived { libraryShowArchived = q.archived }
            let storage: LibraryStorageFilter? = q.storage.map { $0 == .onlineOnly ? .onlineOnly : .thisMacOnly }
            if libraryStorage != storage { libraryStorage = storage }
            if libraryNoFiguresOnly != q.noFigures { libraryNoFiguresOnly = q.noFigures }
            if libraryInCatalogueOnly != q.inCatalogue { libraryInCatalogueOnly = q.inCatalogue }
            if libraryReadyOn != q.readyOn { libraryReadyOn = q.readyOn }
            if libraryReadyAnywhere != q.readyAnywhere { libraryReadyAnywhere = q.readyAnywhere }
            if libraryCreator != q.creator { libraryCreator = q.creator }
            let category: FilterChoice? = q.category.map { .named($0) } ?? (q.uncategorised ? .unfiled : nil)
            if libraryCategory != category { libraryCategory = category }
            if libraryTag != q.tag { libraryTag = q.tag }
            if libraryRanges != q.ranges { libraryRanges = q.ranges }
            // Nil keeps the order on screen; a name this build does not know
            // keeps it too, rather than jumping to some other order.
            if let raw = q.sort, let sort = LibrarySort(rawValue: raw), sort != librarySort { librarySort = sort }
        }
    }

    /// Is anything narrowing the library — what offers "Save Search…".
    var libraryQueryActive: Bool { !libraryQuery.isEmpty }

    // MARK: - The one matcher

    /// The test a model is put to under `q` — every axis and range, NOT the
    /// search box (that is `searchMatcher`, run after, over fewer models).
    ///
    /// `group` is the open folder, or nil for the whole library. `axis` is
    /// left out, for the facet counts: each axis is counted over what the
    /// OTHERS leave, or the shop could never press a second value on it.
    /// Ranges are never left out — they narrow every count.
    ///
    /// Everything that is the same for every model (the ready set, the
    /// catalogue's files, today) is worked out once here, not per model.
    func libraryMatcher(_ q: LibraryQuery, group: String?,
                        skipping axis: LibraryAxis? = nil) -> (LibraryFile) -> Bool {
        let ready: Set<String>? = {
            guard axis != .ready else { return nil }
            if let machine = q.readyOn { return readyByMachine[machine] ?? [] }
            if q.readyAnywhere { return readyByMachine.values.reduce(into: Set<String>()) { $0.formUnion($1) } }
            return nil
        }()
        let dupes = duplicateOf
        let storage: LibraryStorageFilter? = axis == .storage ? nil
            : q.storage.map { $0 == .onlineOnly ? .onlineOnly : .thisMacOnly }
        let index = syncIndex, remote = libraryRemoteId
        let sells: Set<String>? = q.inCatalogue && axis != .inCatalogue ? catalogueFileIds() : nil
        let noFigures = q.noFigures && axis != .noFigures
        let ranges = q.ranges.isActive ? q.ranges : nil
        let today = Calendar.book.dayString(Date())
        let category: FilterChoice? = axis == .category ? nil
            : (q.category.map { .named($0) } ?? (q.uncategorised ? .unfiled : nil))
        let tag = axis == .tag ? nil : q.tag?.lowercased()
        let creator = axis == .creator ? nil : q.creator?.lowercased()
        return { [self] f in
            // A model a conversion has replaced is put aside rather than
            // deleted (`LibraryFile.archivedAt`): it is still in the book and
            // still what a past job was printed from, but not one of the
            // things the shop is choosing between today. The Archived view is
            // ONLY those, so a shop looking for something to restore is not
            // looking through everything else.
            if axis != .archived, f.isArchived != q.archived { return false }
            if let group, !Self.isUnder(f.groupName, group) { return false }
            if axis != .unfiled, q.unfiled, !(f.groupName ?? "").isEmpty { return false }
            if axis != .neverPrinted, q.neverPrinted, f.printCount != 0 { return false }
            if let ready, !ready.contains(f.id) { return false }
            if let category, !category.matches(f.category) { return false }
            if let tag, !(f.tags ?? []).contains(where: { $0.lowercased() == tag }) { return false }
            if let creator, f.creator?.lowercased() != creator { return false }
            if axis != .printNext, q.printNext, !f.isPrintNext { return false }
            if axis != .duplicates, q.duplicates, dupes[f.id] == nil { return false }
            // Where the bytes are, from the index — one lookup a model.
            if let storage, !storage.matches(index?.state(f.id, remote: remote)) { return false }
            if let sells, !sells.contains(f.id) { return false }
            if noFigures, !libraryHasNoFigures(f) { return false }
            if let ranges, !ranges.matches(libraryFigures(f), today: today) { return false }
            return true
        }
    }

    /// One model's figures, as the ranges read them: the tile facts' own
    /// (`libraryFacts`, memoised per change to the book — never worked out
    /// again per frame), its print count, and the book-calendar day it was
    /// added. A figure nobody knows is nil, and nil never matches a range.
    func libraryFigures(_ file: LibraryFile) -> LibraryQuery.Figures {
        let facts = libraryFacts(file)
        return LibraryQuery.Figures(minutes: facts.minutes, grams: facts.grams, price: facts.price,
                                    timesPrinted: file.printCount,
                                    addedDay: file.createdAt?.date.map { Calendar.book.dayString($0) })
    }

    /// Nothing to price a print from: no print time and no weight, measured
    /// or estimated.
    func libraryHasNoFigures(_ file: LibraryFile) -> Bool {
        let facts = libraryFacts(file)
        return facts.minutes == nil && facts.grams == nil
    }

    /// The models a catalogue product is made from — any part of any
    /// product, not only a product of one file (that narrower rule is the
    /// tile's PRICE, `pricesByFile`). Once per change to the book.
    func catalogueFileIds() -> Set<String> {
        let memo = libraryMemo
        _ = catalogueRows.count
        if memo.catalogueKey == bookRevision, let known = memo.catalogueIds { return known }
        var out: Set<String> = []
        for case .object(let product) in productRows {
            guard case .array(let parts)? = product["parts"] else { continue }
            for case .object(let part) in parts {
                if case .string(let id)? = part["printFileId"], !id.isEmpty { out.insert(id) }
            }
        }
        memo.catalogueKey = bookRevision
        memo.catalogueIds = out
        return out
    }

    // MARK: - Counting a query

    /// What a count depends on besides the query itself. Anything that can
    /// change which models a query finds is here.
    private func libraryCountRevision() -> [Int] {
        _ = files.count
        _ = readyByMachine.count
        _ = librarySyncRevision
        var h = Hasher()
        h.combine(Calendar.book.dayString(Date()))
        return libraryFactsKey() + [librarySyncRevision, syncIndex == nil ? 0 : 1, h.finalize()]
    }

    /// How many models `q` finds across the whole library — a smart folder's
    /// count in the sidebar. Through `libraryMatcher` and `searchMatcher`,
    /// the grid's own two, so the number beside a saved search is the number
    /// of tiles opening it draws. Kept per query until the library moves.
    func libraryCount(_ q: LibraryQuery) -> Int {
        let memo = libraryMemo
        let revision = libraryCountRevision()
        if memo.countsRevision != revision {
            memo.countsRevision = revision
            memo.counts = [:]
        }
        let key = q.unsorted
        if let known = memo.counts[key] { return known }
        memo.work.queryCounts += 1
        let match = libraryMatcher(key, group: nil)
        let text = SearchText.fold(key.text.trimmingCharacters(in: .whitespaces))
        let searching = text.isEmpty ? nil : searchMatcher(LibrarySearch.parse(text))
        let n = files.count { match($0) && (searching?($0) ?? true) }
        memo.counts[key] = n
        return n
    }

    /// Every input of a facet recount, hashed — `readLibraryFacets` does
    /// nothing when it has not moved since the last one finished.
    func facetMemoKey() -> Int {
        var h = Hasher()
        h.combine(libraryQuery.unsorted)
        if case .library(let g) = shelf { h.combine(1); h.combine(g) } else { h.combine(0) }
        h.combine(libraryRowsRevision)
        h.combine(libraryDerivedRevision)
        h.combine(libraryCountRevision())
        h.combine(libraryHasRemote)
        h.combine(libraryRemoteId)
        for machine in machinesInUse {
            h.combine(machine.id)
            h.combine(loadedSlots(for: machine.id))
            h.combine(machine.name)
        }
        return h.finalize()
    }

    /// The last recount's key (`facetMemoKey`).
    var facetMemo: Int? {
        get { libraryMemo.facetKey }
        set { libraryMemo.facetKey = newValue }
    }

    // MARK: - Opening one

    /// Show the library under a saved search or a smart folder: the whole
    /// library, the query in the bar. A query that names no order keeps the
    /// one on screen.
    func openLibraryQuery(_ q: LibraryQuery) {
        if shelf != .library(nil) { shelf = .library(nil) }
        libraryQuery = q
    }

    /// Is this the query on screen? The order aside: a shop that re-sorts a
    /// smart folder is still in it.
    func libraryShows(_ q: LibraryQuery) -> Bool {
        shelf == .library(nil) && libraryQuery.unsorted == q.unsorted
    }
}

/// ── THE SMART FOLDERS EVERY LIBRARY HAS ──────────────────────────────────
///
/// Worked out, never stored: they are questions every shop asks, so a shop
/// cannot delete or rename them and the book does not carry them. Each one
/// is a plain `LibraryQuery`, so opening it fills the bar like any saved
/// search and Save Search… can keep a narrower copy of it.
enum LibrarySmartFolder: String, CaseIterable, Identifiable, Sendable {
    /// Fits a bed AND has every colour loaded, on some machine
    /// (`ModelReadiness`, through `readyByMachine`).
    case ready
    case neverPrinted
    case onlineOnly
    /// Neither a print time nor a weight: nothing to quote from.
    case noFigures
    /// A catalogue product is made from it.
    case inCatalogue

    var id: String { rawValue }

    var key: String {
        switch self {
        case .ready: "mac.ls_ready"
        case .neverPrinted: "mac.never_printed"
        case .onlineOnly: "mac.lib_online_only"
        case .noFigures: "mac.ls_no_figures"
        case .inCatalogue: "mac.ls_in_catalogue"
        }
    }

    var symbol: String {
        switch self {
        case .ready: "checkmark.circle"
        case .neverPrinted: "sparkles"
        case .onlineOnly: "icloud"
        case .noFigures: "questionmark.circle"
        case .inCatalogue: "tag"
        }
    }

    var query: LibraryQuery {
        var q = LibraryQuery()
        switch self {
        case .ready: q.readyAnywhere = true
        case .neverPrinted: q.neverPrinted = true
        case .onlineOnly: q.storage = .onlineOnly
        case .noFigures: q.noFigures = true
        case .inCatalogue: q.inCatalogue = true
        }
        return q
    }
}

// MARK: - Saved searches, in the book

extension Shop {

    /// The shop's saved searches, as the book's settings hold them.
    var librarySavedSearches: [LibrarySavedSearch] { LibrarySavedSearch.all(settings: settingsDict) }

    /// Keep the query on screen under a name. The same name replaces that
    /// search (`LibrarySavedSearch.saving`).
    @discardableResult
    func saveLibrarySearch(named name: String) async -> Bool {
        let query = libraryQuery
        let id = "LSS-" + UUID().uuidString.prefix(8).lowercased()
        let at = StoreWriter.iso(Date())
        return await writeSavedSearches { LibrarySavedSearch.saving(name, query, into: $0, id: id, at: at) }
    }

    @discardableResult
    func renameLibrarySearch(_ id: String, to name: String) async -> Bool {
        await writeSavedSearches { LibrarySavedSearch.renaming(id, to: name, in: $0) }
    }

    /// Put the query on screen into a saved search, keeping its name.
    @discardableResult
    func replaceLibrarySearch(_ id: String) async -> Bool {
        let query = libraryQuery
        return await writeSavedSearches { LibrarySavedSearch.replacing(id, with: query, in: $0) }
    }

    @discardableResult
    func duplicateLibrarySearch(_ id: String) async -> Bool {
        let newId = "LSS-" + UUID().uuidString.prefix(8).lowercased()
        let at = StoreWriter.iso(Date())
        // Said here, on the main actor: the list itself is changed on the
        // write chain, which cannot reach the shop's words.
        let pattern = words.callIt("mac.ls_copy_name")
        let numerals = (0...1000).map { words.numeral($0) }
        return await writeSavedSearches {
            LibrarySavedSearch.duplicating(id, in: $0, newId: newId, at: at) { name, n in
                pattern.replacingOccurrences(of: "{name}", with: name)
                    .replacingOccurrences(of: "{n}", with: numerals[min(n, 1000)])
            }
        }
    }

    @discardableResult
    func deleteLibrarySearch(_ id: String) async -> Bool {
        await writeSavedSearches { LibrarySavedSearch.deleting(id, from: $0) }
    }

    /// The one write behind all five: gated like every other change to the
    /// library's settings, then ON THE WRITE CHAIN — the list is read from the
    /// book as it is at that moment, inside `updateOffMain`, never from the
    /// copy on screen, which lags every write still in flight. Two saves a
    /// moment apart both land. `change` returns nil for "nothing to do".
    private func writeSavedSearches(
        _ change: @escaping @Sendable ([LibrarySavedSearch]) -> [LibrarySavedSearch]?
    ) async -> Bool {
        guard permitted("inventory", "edit") else { return false }
        guard let build = source.build else {
            moveProblem = words.callIt("mac.ls_sample")
            return false
        }
        do {
            let wrote = try await StoreWriter.updateOffMain(build) { root -> Bool in
                let settings = Self.settings(root)
                guard let next = change(LibrarySavedSearch.all(settings: settings)) else { return false }
                var out = settings
                out[LibrarySavedSearch.settingsKey] = LibrarySavedSearch.encode(next)
                root["settings"] = .object(out)
                return true
            }
            writeProblem = nil
            if wrote { await load(source) }
            return wrote
        } catch {
            writeProblem = self.said(error)
            return false
        }
    }
}
