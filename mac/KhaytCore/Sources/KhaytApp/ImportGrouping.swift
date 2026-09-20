import Foundation

/// Which group an imported file belongs to, decided from where it sat on disk.
///
/// ── THE PROBLEM ───────────────────────────────────────────────────────────
///
/// Importing a folder wrote `folder: ""` on every record. A shop dragging in
/// "Saudi Kings" — seven models, each in its own subfolder — got seven
/// ungrouped files in a flat library and had to regroup them by hand, which is
/// the work the import was supposed to save.
///
/// The folder a model came from is the shop's own grouping. It already exists,
/// it was just being thrown away.
///
/// ── WHY IT IS NOT SIMPLY THE PARENT FOLDER ────────────────────────────────
///
/// Because of how models are actually packaged. A download is rarely
///
///     Saudi Kings/King Abdulaziz/crown.stl
///
/// and very often
///
///     Saudi Kings/King Abdulaziz/STL/presupported/crown.stl
///
/// The parent folder there is `presupported`, which is not a group, it is a
/// statement about the file. Grouping by it gives a library filed under "STL",
/// "files" and "presupported" — worse than no grouping, because it looks
/// deliberate.
///
/// So the rule keeps every folder that is about the MODEL and drops the ones
/// that are about the format or the state of a file. What comes back is a
/// PATH — `Saudi Kings/King Abdulaziz` — because a project with levels in it
/// is a project with levels in it.
///
/// ── IT USED TO RETURN ONLY THE DEEPEST ONE ────────────────────────────────
///
/// That flattened a shop's project the moment it had any shape. Importing
///
///     MyProject/pose 1/Blue/part.stl
///     MyProject/pose 2/Grey/part.stl
///     MyProject/base.stl
///
/// filed those under `Blue`, `Grey` and `MyProject` — three SIBLING folders,
/// with the project holding only whatever sat at its top level and the poses
/// gone altogether. Reported as the library showing "only the files in the
/// first folder, all sub folders skipped", and from the shop's side that is
/// exactly what it looks like: every file was imported, and they landed
/// somewhere other than inside the project.
enum ImportGrouping {

    /// Folder names that describe a format, a state, or a container — never a
    /// model.
    ///
    /// Deliberately a list and not a cleverness. The cost of a wrong entry is a
    /// group that should have been made and was not, so the list holds only
    /// names that are never a model's name in any shop. "Dragon" is a model,
    /// "supported" is not, and nothing in between is guessed at.
    static let notAName: Set<String> = [
        // Formats
        "stl", "stls", "3mf", "3mfs", "obj", "step", "stp", "gcode", "gcodes",
        "bgcode", "ctb", "lys", "amf", "ply", "chitubox", "lychee", "cbddlp",
        // Slicer and printer names a pack is sorted by
        "bambu", "prusa", "cura", "orca", "elegoo", "anycubic", "creality",
        // States
        "supported", "presupported", "pre-supported", "pre supported",
        "unsupported", "supports", "support", "split", "whole", "solid",
        "hollow", "hollowed", "test", "tests", "sample", "samples",
        // Containers
        "files", "file", "models", "model", "parts", "part", "print", "prints",
        "printable", "printables", "printing", "output", "outputs", "export",
        "exports", "source", "sources", "src", "raw", "new", "final", "finals",
        "misc", "other", "others", "extra", "extras", "assets", "downloads",
        // Things that are not the model at all
        "images", "image", "photos", "photo", "renders", "render", "preview",
        "previews", "docs", "doc", "documents", "readme", "license", "licence",
        "textures", "texture", "scenes", "scene", "thumbnails", "thumbs",
    ]

    /// The separator between levels of a group path.
    ///
    /// A forward slash, because that is what the shop's own folders use and
    /// what the other app will show if it never learns to split on it: a
    /// folder called `MyProject/pose 1` reads as a path to anybody, where a
    /// private sentinel would read as a mistake. See `LibraryFile.groupPath`.
    static let separator = "/"

    /// The group for one file, or nil when it should stay ungrouped.
    ///
    /// - Parameters:
    ///   - file: the model being imported.
    ///   - chosen: what the shop picked in the panel — a folder, or the file
    ///     itself. A file picked DIRECTLY is never grouped: the shop chose one
    ///     thing, and inventing a group from whatever folder it happened to be
    ///     sitting in would file a model under "Downloads".
    /// - Returns: a folder name, or nil.
    static func group(for file: URL, chosen: URL) -> String? {
        let chosenPath = chosen.standardizedFileURL.resolvingSymlinksInPath().path
        let filePath = file.standardizedFileURL.resolvingSymlinksInPath().path
        // Picked directly, not found inside a folder.
        guard filePath != chosenPath else { return nil }

        let chosenParts = chosenPath.split(separator: "/").map(String.init)
        let fileParts = filePath.split(separator: "/").map(String.init)
        guard fileParts.count > chosenParts.count,
              Array(fileParts.prefix(chosenParts.count)) == chosenParts else { return nil }

        // Folders BELOW what was chosen, with the filename dropped.
        let below = Array(fileParts.dropFirst(chosenParts.count).dropLast())

        // The chosen folder is the root of the path, then every folder under it
        // that names something. `STL` and `presupported` fall out here, so
        // `Kings/King Abdulaziz/STL/head.stl` is `Kings/King Abdulaziz` and not
        // `Kings/King Abdulaziz/STL`.
        var levels: [String] = []
        if let root = meaningful(chosen.lastPathComponent) { levels.append(root) }
        levels += below.compactMap(meaningful)
        return levels.isEmpty ? nil : fitting(levels)
    }

    /// A path short enough to survive being written down.
    ///
    /// ── SIXTY CHARACTERS IS NOT THIS APP'S RULE TO CHANGE ─────────────────
    ///
    /// `LibraryFile.normalise` slices a group name at 60 UTF-16 units, exactly
    /// as `KhaytOrganise.groupOf` does, and `OrganiseParityTests` holds the two
    /// together. A longer path would be cut MID-SEGMENT — `MyProject/pose 1/Ve`
    /// — which is worse than a shorter path, because it reads as a folder the
    /// shop never made.
    ///
    /// So the levels that survive are the ones that say the most: the project
    /// it belongs to, and the folder it actually sat in. The levels between
    /// them go first, then the root, and a single level too long to fit is
    /// handed over anyway to be cut by the rule that owns the limit.
    static func fitting(_ levels: [String]) -> String {
        var kept = levels
        while kept.count > 2, tooLong(kept) {
            kept.remove(at: kept.count - 2)          // the level just above the leaf
        }
        if kept.count == 2, tooLong(kept) { kept.removeFirst() }
        return kept.joined(separator: separator)
    }

    private static func tooLong(_ levels: [String]) -> Bool {
        levels.joined(separator: separator).utf16.count > 60
    }

    /// The folder name as a group, or nil when it says nothing about a model.
    ///
    /// Compared with the decoration stripped, so `01 - Dragon`, `[FDM] Dragon`
    /// and `Dragon_v2` are not each their own group — but RETURNED as the shop
    /// wrote it, because it is the shop's name and this is not the place to
    /// tidy somebody's folders.
    static func meaningful(_ folder: String) -> String? {
        let trimmed = folder.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let bare = strip(trimmed)
        guard !bare.isEmpty, !notAName.contains(bare) else { return nil }
        // A folder called "1" or "01" is an ordering, not a name.
        guard Double(bare) == nil else { return nil }
        return trimmed
    }

    /// Lowercased, with leading numbering and bracketed tags removed.
    static func strip(_ folder: String) -> String {
        var text = folder.lowercased()
        // `[FDM]`, `(v2)` — anywhere, because packs put them at either end.
        text = text.replacingOccurrences(of: #"[\[\(][^\]\)]*[\]\)]"#,
                                          with: " ", options: .regularExpression)
        // A leading `01 - `, `1.`, `02_` — a NUMBER AND THEN A SEPARATOR.
        //
        // The separator is required. Without it this matched the digits in
        // `3mf`, left `mf`, and `mf` is not in the list above — so a folder
        // called `3mf` became a group, which is the exact thing the list exists
        // to prevent. Caught by the test, and worth keeping the shape of: a
        // pattern meant to strip decoration ate a name.
        text = text.replacingOccurrences(of: #"^\s*\d+(?:\s+|\s*[-._)]+\s*)"#,
                                          with: "", options: .regularExpression)
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " -_."))
    }
}
