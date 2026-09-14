import Foundation

/// What the library shows at the top level: projects as FOLDERS, then whatever
/// is loose.
///
/// ── WHY THIS EXISTS ───────────────────────────────────────────────────────
///
/// A group was only ever a filter in the sidebar. The grid itself was flat, so
/// a project had no presence on screen at all: a hundred and fifty files in one
/// list, some of them carrying a group name nothing drew. Reported as *"the
/// grouping for models is very weak, it's completely not right for a single
/// project"*, and that is exactly it — the shop's own idea of a project existed
/// in the data and nowhere in the picture.
///
/// A project is a folder. It shows as one tile with a picture and a count, and
/// opening it shows what is inside. That is the whole model.
///
/// ── THE COVER IS THE FOLDER'S OWN, THEN THE BEST OF ITS CONTENTS ──────────
///
/// A folder with no picture is a grey square with a name, and a library of grey
/// squares is the flat list again with extra clicks. So a folder borrows a
/// picture from what it holds — see `cover` — and a shop that wants a
/// particular one can say so later without this changing.
enum LibraryEntry: Identifiable, Hashable {
    /// A project. `count` is how many files are inside it.
    case folder(name: String, count: Int, cover: LibraryFile?)
    /// A file that belongs to no project.
    case file(LibraryFile)

    var id: String {
        switch self {
        case .folder(let name, _, _): return "folder:" + name
        case .file(let f): return "file:" + f.id
        }
    }

    /// Folders first, then loose files. Within each, the caller's sort order is
    /// preserved — a folder is not a different kind of thing to sort, it is a
    /// heading, and a shop looking for a project should not have to hunt for it
    /// among a hundred files.
    ///
    /// `order` compares two files, and is the library's own sort so that the
    /// loose half of the screen matches the inside of a folder.
    static func top(of files: [LibraryFile], order: (LibraryFile, LibraryFile) -> Bool)
    -> [LibraryEntry] {
        var byGroup: [String: [LibraryFile]] = [:]
        var loose: [LibraryFile] = []
        for file in files {
            if let group = file.groupName, !group.isEmpty {
                byGroup[group, default: []].append(file)
            } else {
                loose.append(file)
            }
        }

        let folders = byGroup
            .map { name, held in
                LibraryEntry.folder(name: name, count: held.count,
                                    cover: Self.cover(of: held, order: order))
            }
            // By name, because a folder is a place and places do not reorder
            // themselves when a file inside one changes.
            .sorted { lhs, rhs in
                guard case .folder(let a, _, _) = lhs, case .folder(let b, _, _) = rhs else {
                    return false
                }
                return a.localizedStandardCompare(b) == .orderedAscending
            }

        return folders + loose.map { LibraryEntry.file($0) }
    }

    /// The picture a folder wears.
    ///
    /// The first file that HAS a thumbnail, in the shop's own sort order —
    /// not simply the first file, because the first file is often a README or
    /// a part with nothing rendered, and a folder showing an empty square
    /// while holding forty models is worse than one showing any of them.
    static func cover(of held: [LibraryFile], order: (LibraryFile, LibraryFile) -> Bool)
    -> LibraryFile? {
        let sorted = held.sorted(by: order)
        return sorted.first { $0.thumbFile?.isEmpty == false } ?? sorted.first
    }
}
