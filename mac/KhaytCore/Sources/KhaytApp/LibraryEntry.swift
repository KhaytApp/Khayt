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
    /// A project, or a level inside one.
    ///
    /// `name` is the LEVEL, as it is drawn — `pose 1`. `path` is the whole way
    /// there — `MyProject/pose 1` — which is what opening it sets, because two
    /// projects are each allowed a folder called `Blue`.
    case folder(name: String, path: String, count: Int, cover: LibraryFile?)
    /// A file that belongs to no project.
    case file(LibraryFile)

    var id: String {
        switch self {
        case .folder(_, let path, _, _): return "folder:" + path
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
    /// What to draw at one level of the library.
    ///
    /// `under` is the folder being looked inside, or nil at the top. A file
    /// belongs HERE when its group is exactly `under`; anything deeper becomes
    /// a sub-folder named by its next level, so `MyProject/pose 1/Blue` seen
    /// from `MyProject` is a folder called `pose 1`.
    ///
    /// ── IT USED TO GROUP BY THE WHOLE NAME ────────────────────────────────
    ///
    /// Which was right while a group was one word and wrong the moment it
    /// became a path: `MyProject`, `MyProject/pose 1` and `MyProject/pose 2`
    /// would have been three unrelated folders sitting beside each other, which
    /// is the flattening this change exists to undo, in a new place.
    static func top(of files: [LibraryFile], under: String? = nil,
                    order: (LibraryFile, LibraryFile) -> Bool) -> [LibraryEntry] {
        let prefix = (under.map { $0 + ImportGrouping.separator }) ?? ""
        var byLevel: [String: [LibraryFile]] = [:]
        var here: [LibraryFile] = []
        for file in files {
            let group = file.groupName ?? ""
            if group == (under ?? "") {
                here.append(file)                       // sits at this level
                continue
            }
            guard under == nil || group.hasPrefix(prefix) else { continue }
            // The next level down, and everything below it counts towards it.
            let rest = String(group.dropFirst(prefix.count))
            let level = rest.components(separatedBy: ImportGrouping.separator).first ?? rest
            guard !level.isEmpty else { continue }
            byLevel[level, default: []].append(file)
        }

        let folders = byLevel
            .map { level, held in
                LibraryEntry.folder(name: level, path: prefix + level, count: held.count,
                                    cover: Self.cover(of: held, order: order))
            }
            // By name, because a folder is a place and places do not reorder
            // themselves when a file inside one changes.
            .sorted { lhs, rhs in
                guard case .folder(let a, _, _, _) = lhs,
                      case .folder(let b, _, _, _) = rhs else { return false }
                return a.localizedStandardCompare(b) == .orderedAscending
            }

        return folders + here.sorted(by: order).map { LibraryEntry.file($0) }
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
