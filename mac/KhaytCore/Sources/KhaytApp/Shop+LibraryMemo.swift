import Foundation
import KhaytCore

/// ── THE LIBRARY, WORKED OUT ONCE PER CHANGE ─────────────────────────────
///
/// `shownFiles` filtered, folded and sorted the whole book every time it was
/// read, and `shownEntries`, `visibleFiles`, `selectedFiles`, `selectedFile`
/// and `selectedIds` each read it again. One draw of the library screen — the
/// grid, its empty-state check, the inspector, the toolbar count and the menu
/// bar's items — read it about ten times. Measured on a 5,000-model book in
/// 200 groups (Oct 17 2026, debug build): one pass took 25–60 ms, so a click
/// on a model took 260–300 ms before the window moved, and each key typed in
/// the search box 120–490 ms. Each visible tile also asked the disk twice
/// whether its thumbnail was there, on every draw.
///
/// Now each list is kept with the inputs it was made from (`LibraryMemo`) and
/// made again only when one of them changes. A longer search narrows the last
/// answer instead of starting over, the way ⌘K does (`GoToIndex.search`), and
/// every model's search text is folded once per change to the book rather
/// than once per row per key.
///
/// The selection rule is untouched: `visibleFiles` is still derived from the
/// very entries the grid draws, so a model folded inside a group tile can
/// never be selected (27 Sep 2026).
final class LibraryMemo {
    /// What one pass of `shownFiles` depended on. Anything that can change
    /// which models are shown, or their order, is here.
    struct ShownKey: Equatable {
        var files: Int
        var derived: Int
        var library: Bool
        var group: String?
        var archived: Bool
        var unfiled: Bool
        var neverPrinted: Bool
        var readyOn: String?
        var category: Shop.FilterChoice?
        var tag: String?
        var creator: String?
        var printNext: Bool
        var duplicates: Bool
        /// A Library Health group's models, from its Show button.
        var healthFocus: LibraryHealthFocus?
        var storage: LibraryStorageFilter?
        /// The axes and ranges added with the saved searches.
        var readyAnywhere = false
        var noFigures = false
        var inCatalogue = false
        var fromWeb = false
        var ranges = LibraryQuery.Ranges()
        /// Today, while a "last N days" range is on — tomorrow it finds less.
        var day = ""
        /// `librarySyncRevision`: a model moved out or brought back.
        var sync: Int
        var sort: LibrarySort
        /// What the tile facts were made from — only when the order READS
        /// them (print time, weight, price), so an ordinary sort is not
        /// rebuilt by every change to the catalogue.
        var facts: [Int] = []
        /// Trimmed and folded.
        var query: String

        /// The same view in every respect but the search.
        func sameView(as other: ShownKey) -> Bool {
            var me = self
            me.query = other.query
            return me == other
        }
    }

    struct EntriesKey: Equatable {
        var shown: ShownKey
        var flat: Bool
        var showsFlat: Bool
    }

    /// The work done, counted — so a test can prove a draw that changed
    /// nothing did nothing, without timing anything.
    struct Work: Equatable {
        /// `shownFiles` from the whole book.
        var builds = 0
        /// `shownFiles` narrowed from the last answer, for a longer search.
        var narrowed = 0
        /// Models compared against a search, over every pass.
        var rowsSearched = 0
        /// `shownEntries` built.
        var entryBuilds = 0
        /// Models whose search text was folded.
        var folds = 0
        /// Questions put to the disk about a thumbnail.
        var diskChecks = 0
        /// Searches a recount of the chips ran over the book — one per
        /// recount, however many pools it counts.
        var facetSearches = 0
        /// Models whose tile facts were worked out (`Shop.libraryFacts`).
        var factBuilds = 0
        /// Facet recounts that ran, and those the memo answered.
        var facetRecounts = 0
        var facetMemoHits = 0
        /// Saved-search counts worked out (`Shop.libraryCount`).
        var queryCounts = 0
    }

    var work = Work()

    var shownKey: ShownKey?
    var shown: [LibraryFile] = []

    var entriesKey: EntriesKey?
    var entries: [LibraryEntry] = []
    var visible: [LibraryFile] = []
    var visiblePosition: [LibraryFile.ID: Int] = [:]

    /// Each model's search text, folded, for the book revision it was made at.
    var foldedRevision = -1
    var folded: [LibraryFile.ID: Folded] = [:]

    /// One model's text, folded once: what the free search reads, and what
    /// each kind of token (`LibrarySearch.Field`) reads.
    ///
    /// Held as UTF-8 bytes, folded and composed, and matched with `memmem`:
    /// a recount runs the search over every model, and the Foundation
    /// comparison of the same folded text took 80 ms per pass at 6,600 models
    /// (Oct 2026 review bench). Both sides are folded by `SearchText` first,
    /// so a byte match is the comparison the folding was for.
    struct Folded {
        var free: [[UInt8]]
        var tags: [[UInt8]]
        var group: [[UInt8]]
        var category: [[UInt8]]
        var materials: [[UInt8]]
        var creators: [[UInt8]]

        init(_ file: LibraryFile) {
            func f(_ list: [String]) -> [[UInt8]] { list.map(Self.bytes).filter { !$0.isEmpty } }
            free = f(file.searchFields)
            tags = f(file.tags ?? [])
            group = f([file.groupName ?? ""])
            category = f([file.category ?? ""])
            materials = f([file.material ?? "", file.parsed?.filamentType ?? ""])
            creators = f([file.creator ?? "", file.source ?? ""])
        }

        /// Text as the matcher compares it.
        static func bytes(_ text: String) -> [UInt8] {
            Array(SearchText.fold(text).precomposedStringWithCanonicalMapping.utf8)
        }

        /// Does any of `fields` hold `needle`?
        static func any(_ fields: [[UInt8]], _ needle: [UInt8]) -> Bool {
            guard !needle.isEmpty else { return true }
            return needle.withUnsafeBytes { n in
                fields.contains { hay in
                    hay.count >= n.count && hay.withUnsafeBytes { h in
                        memmem(h.baseAddress, h.count, n.baseAddress, n.count) != nil
                    }
                }
            }
        }
    }

    /// `files` by id, for the book revision it was made at.
    var byIdRevision = -1
    var byId: [LibraryFile.ID: LibraryFile] = [:]

    /// The thumbnail answer per model, and the record it was worked out for:
    /// a record that changed (a new `thumbFile`) is asked again.
    var thumbRoots: [String]?
    var thumbs: [LibraryFile.ID: (file: LibraryFile, source: ThumbnailSource?)] = [:]

    /// The tile facts (`LibraryDisplay.swift`): the numbers per model, the
    /// line each one is said in, and the catalogue prices they read — all
    /// for the revisions in `factsKey`.
    var factsKey: [Int]?
    var facts: [LibraryFile.ID: LibraryFacts] = [:]
    var prices: [LibraryFile.ID: Double] = [:]
    var factLinesLanguage = ""
    var factLines: [LibraryFile.ID: String] = [:]

    /// The last facet recount's inputs, hashed (`Shop.facetMemoKey`).
    var facetKey: Int?
    /// Each smart folder's count, for the revisions it was counted at.
    var countsRevision: [Int] = []
    var counts: [LibraryQuery: Int] = [:]
    /// The models a catalogue product is made from, per book revision.
    var catalogueKey = -1
    var catalogueIds: Set<String>?

    /// The list view's rows, for the entries and facts they were made from.
    var rowsKey: LibraryRow.Key?
    var rows: [LibraryRow] = []
}

extension Shop.Shelf {
    var isLibrary: Bool {
        if case .library = self { return true }
        return false
    }
}

extension Shop {

    /// Every input of `shownFiles`, read here — which is also what tells
    /// SwiftUI the view depends on them.
    func libraryShownKey() -> LibraryMemo.ShownKey {
        _ = files.count
        _ = readyByMachine.count
        _ = duplicateOf.count
        var group: String?
        var library = false
        if case .library(let g) = shelf { library = true; group = g }
        return .init(files: filesRevision, derived: libraryDerivedRevision,
                     library: library, group: group,
                     archived: libraryShowArchived, unfiled: libraryUnfiledOnly,
                     neverPrinted: libraryNeverPrintedOnly, readyOn: libraryReadyOn,
                     category: libraryCategory, tag: libraryTag, creator: libraryCreator,
                     printNext: libraryPrintNextOnly, duplicates: libraryDuplicatesOnly,
                     healthFocus: libraryHealthFocus,
                     storage: libraryStorage,
                     readyAnywhere: libraryReadyAnywhere, noFigures: libraryNoFiguresOnly,
                     inCatalogue: libraryInCatalogueOnly, fromWeb: libraryFromWebOnly, ranges: libraryRanges,
                     day: libraryRanges.added.lastDays == nil ? "" : Calendar.book.dayString(Date()),
                     sync: libraryStorage == nil ? 0 : librarySyncRevision,
                     sort: librarySort,
                     // The facts too when a filter READS them (a range, No
                     // print figures, the catalogue's files), not only the order.
                     facts: librarySort.readsFacts || libraryRanges.isActive || libraryNoFiguresOnly
                        || libraryInCatalogueOnly ? libraryFactsKey() : [],
                     query: SearchText.fold(search.trimmingCharacters(in: .whitespaces)))
    }

    /// `shownFiles`, from the memo when nothing it depends on has moved.
    func memoShownFiles() -> [LibraryFile] {
        let key = libraryShownKey()
        let memo = libraryMemo
        if memo.shownKey == key { return memo.shown }
        let rows: [LibraryFile]
        if let old = memo.shownKey, old.sameView(as: key), !old.query.isEmpty,
           LibrarySearch.parse(key.query).narrows(from: LibrarySearch.parse(old.query)) {
            // Typed one more letter: everything the longer search finds, the
            // shorter one found too, already filtered and in order. Asked of
            // the PARSED search, not the string: `tag` → `tag:` is longer and
            // not narrower (`LibrarySearch.narrows`).
            memo.work.narrowed += 1
            memo.work.rowsSearched += memo.shown.count
            let matches = searchMatcher(LibrarySearch.parse(key.query))
            rows = memo.shown.filter(matches)
        } else {
            memo.work.builds += 1
            rows = buildShownFiles(query: key.query)
        }
        memo.shownKey = key
        memo.shown = rows
        return rows
    }

    /// Does this model's search text hold `q` (already folded)? The same
    /// answer as `LibraryFile.matches(folded:)`, from text folded once.
    func matchesSearch(_ file: LibraryFile, _ q: String) -> Bool {
        searchMatcher(LibrarySearch.parse(q))(file)
    }

    /// One model's folded text, from the memo.
    func foldedText(_ file: LibraryFile) -> LibraryMemo.Folded {
        let memo = libraryMemo
        if memo.foldedRevision != filesRevision {
            memo.foldedRevision = filesRevision
            memo.folded = [:]
        }
        if let known = memo.folded[file.id] { return known }
        let made = LibraryMemo.Folded(file)
        memo.folded[file.id] = made
        memo.work.folds += 1
        return made
    }

    /// The test a search puts each model to, made once per pass: what
    /// `printer:` asks is worked out here for the whole book (which models are
    /// ready on a machine of that name), not once per model.
    ///
    /// `printer:` is the Ready on menu typed: a model every colour of which is
    /// loaded on a machine whose name holds the value, in a material that
    /// fits — so, like that menu, it finds nothing on a machine that does not
    /// say what it has loaded.
    func searchMatcher(_ query: LibrarySearch) -> (LibraryFile) -> Bool {
        let readyFor: [[String: Bool]] = query.tokens.filter { $0.field == .printer }.map { token in
            var ids: [String: Bool] = [:]
            for machine in machines where SearchText.fold(machine.name).localizedStandardContains(token.folded) {
                for id in readyByMachine[machine.id] ?? [] { ids[id] = true }
            }
            return ids
        }
        let text = LibraryMemo.Folded.bytes(query.text)
        let tokens = query.tokens.map { ($0.field, LibraryMemo.Folded.bytes($0.folded)) }
        let any = LibraryMemo.Folded.any
        return { [self] file in
            let f = foldedText(file)
            if !text.isEmpty, !any(f.free, text) { return false }
            var printer = 0
            for (field, v) in tokens {
                let ok: Bool
                switch field {
                case .tag: ok = any(f.tags, v)
                case .group: ok = any(f.group, v)
                case .category: ok = any(f.category, v)
                case .material: ok = any(f.materials, v)
                case .creator: ok = any(f.creators, v)
                case .printer:
                    ok = readyFor[printer][file.id] == true
                    printer += 1
                }
                if !ok { return false }
            }
            return true
        }
    }

    /// `shownEntries` and the model tiles in it, from the memo when nothing
    /// they depend on has moved.
    func memoEntries() -> (entries: [LibraryEntry], visible: [LibraryFile], position: [LibraryFile.ID: Int]) {
        let shown = memoShownFiles()
        let memo = libraryMemo
        guard let shownKey = memo.shownKey else { return ([], [], [:]) }
        let key = LibraryMemo.EntriesKey(shown: shownKey, flat: libraryFlat, showsFlat: libraryShowsFlat)
        _ = libraryGroupKinds.count
        if memo.entriesKey == key { return (memo.entries, memo.visible, memo.visiblePosition) }
        memo.work.entryBuilds += 1
        let entries: [LibraryEntry]
        if key.showsFlat || !shownKey.library {
            entries = shown.map { LibraryEntry.file($0) }
        } else {
            entries = Self.libraryEntries(shown, under: shownKey.group, flat: libraryFlat,
                                          showingMatches: libraryShowsMatches, kinds: libraryGroupKinds,
                                          order: librarySort.ordering(libraryFacts))
        }
        let visible = Self.modelTiles(entries)
        var position: [LibraryFile.ID: Int] = [:]
        position.reserveCapacity(visible.count)
        for (i, f) in visible.enumerated() where position[f.id] == nil { position[f.id] = i }
        memo.entriesKey = key
        memo.entries = entries
        memo.visible = visible
        memo.visiblePosition = position
        return (entries, visible, position)
    }

    /// `files` by id.
    func libraryFile(id: LibraryFile.ID) -> LibraryFile? {
        let memo = libraryMemo
        if memo.byIdRevision != filesRevision {
            memo.byIdRevision = filesRevision
            memo.byId = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
        return memo.byId[id]
    }

    // ── THUMBNAILS ON DISK ──────────────────────────────────────────────

    /// The disk is asked once per model per record, not once per tile per
    /// draw: a library kept on a network drive made each of those a round
    /// trip, on the main thread, for every visible tile on every redraw.
    func cachedThumbnail(for file: LibraryFile) -> ThumbnailSource? {
        _ = libraryDiskEpoch
        let roots = libraryRoots?.roots
        let memo = libraryMemo
        if memo.thumbRoots != roots {
            memo.thumbRoots = roots
            memo.thumbs = [:]
        }
        if let known = memo.thumbs[file.id], known.file == file { return known.source }
        memo.work.diskChecks += 1
        let found = Self.thumbnailOnDisk(file, roots: roots)
        memo.thumbs[file.id] = (file, found)
        return found
    }

    nonisolated static func thumbnailOnDisk(_ file: LibraryFile, roots: [String]?) -> ThumbnailSource? {
        guard let roots, let dir = LibraryLocation.directory(for: file.id, roots: roots) else { return nil }
        // A name in the model's own folder, never a path: `thumbFile` arrives
        // by sync, and the phone's thumbnail route serves what this finds.
        let name = file.thumbFile ?? "thumb.jpg"
        guard !name.isEmpty, !name.contains("/"), name != "..", name != "." else { return nil }
        let url = dir.appending(path: name)
        return FileManager.default.fileExists(atPath: url.path) ? .file(url) : nil
    }

    /// Look at the disk again: the library was opened, or the app came back
    /// to the front, and a drive may have been mounted or a picture written.
    func forgetLibraryDisk() {
        libraryMemo.thumbs = [:]
        libraryDiskEpoch &+= 1
    }
}
