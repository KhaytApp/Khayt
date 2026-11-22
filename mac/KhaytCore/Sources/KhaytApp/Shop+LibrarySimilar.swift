import Foundation
import KhaytCore

/// ── FIND SIMILAR ────────────────────────────────────────────────────────
///
/// The ranking is `LibrarySimilar` (KhaytCore): the same file, then the same
/// `geometryKey`, then near in box, volume and triangles, with the group, the
/// tags and the name. The answer goes on the grid as a FOCUS — the ids Library
/// Health's Show uses (`libraryHealthFocus`), which `libraryMatcher` takes as
/// its `focus:` — so it is the one filter path, in the ranked order, on the
/// Show menu as a chip, and cleared with the other filters. Nothing is written.
///
/// A same-shape match may be the part's MIRRORED twin, so whenever one is in
/// the list the grid says so, in Library Health's own words.
extension Shop {

    /// The models as the ranking reads them.
    func similarModels() -> [LibrarySimilar.Model] {
        files.map { f in
            LibrarySimilar.Model(id: f.id, title: f.title, group: f.groupName, tags: f.tags ?? [],
                                 contentHash: f.contentHash, geometryKey: f.geometryKey, archived: f.isArchived)
        }
    }

    /// The models most like `file`, best first.
    func similar(to file: LibraryFile) -> [LibrarySimilar.Match] {
        let all = similarModels()
        guard let me = all.first(where: { $0.id == file.id }) else { return [] }
        return LibrarySimilar.ranked(me, among: all)
    }

    /// Put `file` and the models most like it on the grid: every other filter
    /// and the search cleared, the whole library, drawn flat, the model
    /// itself first and chosen. Says so when nothing is like it.
    func findSimilar(to file: LibraryFile) {
        let matches = similar(to: file)
        clearLastOutcome()
        guard !matches.isEmpty else {
            // The library's banner: the answer to the last thing asked.
            importNote = words.callIt("mac.sim_none", ["name": .string(file.title)])
            return
        }
        clearLibraryFilter()
        search = ""
        libraryHealthOpen = false
        shelf = .library(nil)
        libraryFlat = true
        // An archived model is not on the grid; its matches are.
        let ids = (file.isArchived ? [] : [file.id]) + matches.map(\.id)
        libraryHealthFocus = LibraryHealthFocus(
            kind: .looksSame, ids: ids,
            label: words.callIt("mac.sim_chip", ["name": .string(file.title)]),
            note: matches.contains(where: \.mirrorCaveat) ? "mac.lh_mirror_note" : nil)
        fileSelection = file.isArchived ? [] : [file.id]
        anchor = file.isArchived ? nil : file.id
        cursor = anchor
        libraryScrollRequest += 1
    }

    /// Model ▸ Find Similar: the one selected model.
    func findSimilarToSelection() {
        guard let one = selectedFile else { return }
        findSimilar(to: one)
    }
}
