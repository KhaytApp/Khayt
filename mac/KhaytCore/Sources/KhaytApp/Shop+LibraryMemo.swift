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
        var sort: LibrarySort
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
    var folded: [LibraryFile.ID: [String]] = [:]

    /// `files` by id, for the book revision it was made at.
    var byIdRevision = -1
    var byId: [LibraryFile.ID: LibraryFile] = [:]

    /// The thumbnail answer per model, and the record it was worked out for:
    /// a record that changed (a new `thumbFile`) is asked again.
    var thumbRoots: [String]?
    var thumbs: [LibraryFile.ID: (file: LibraryFile, source: ThumbnailSource?)] = [:]
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
                     sort: librarySort,
                     query: SearchText.fold(search.trimmingCharacters(in: .whitespaces)))
    }

    /// `shownFiles`, from the memo when nothing it depends on has moved.
    func memoShownFiles() -> [LibraryFile] {
        let key = libraryShownKey()
        let memo = libraryMemo
        if memo.shownKey == key { return memo.shown }
        let rows: [LibraryFile]
        if let old = memo.shownKey, old.sameView(as: key), !old.query.isEmpty, key.query.contains(old.query) {
            // Typed one more letter: everything the longer search finds, the
            // shorter one found too, already filtered and in order.
            memo.work.narrowed += 1
            memo.work.rowsSearched += memo.shown.count
            rows = memo.shown.filter { matchesSearch($0, key.query) }
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
        let memo = libraryMemo
        if memo.foldedRevision != filesRevision {
            memo.foldedRevision = filesRevision
            memo.folded = [:]
        }
        let fields: [String]
        if let known = memo.folded[file.id] {
            fields = known
        } else {
            fields = file.searchFields.map(SearchText.fold)
            memo.folded[file.id] = fields
            memo.work.folds += 1
        }
        return fields.contains { !$0.isEmpty && $0.localizedStandardContains(q) }
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
                                          order: librarySort.order)
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
        let url = dir.appending(path: file.thumbFile ?? "thumb.jpg")
        return FileManager.default.fileExists(atPath: url.path) ? .file(url) : nil
    }

    /// Look at the disk again: the library was opened, or the app came back
    /// to the front, and a drive may have been mounted or a picture written.
    func forgetLibraryDisk() {
        libraryMemo.thumbs = [:]
        libraryDiskEpoch &+= 1
    }
}
