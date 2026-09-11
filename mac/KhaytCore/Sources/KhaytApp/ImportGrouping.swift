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
/// So the rule walks UP from the file until it finds a folder name that is
/// about the MODEL rather than about the format or the state of the file, and
/// stops at the folder the shop actually chose.
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

        // Folders BELOW what was chosen, deepest last, with the filename dropped.
        var below = Array(fileParts.dropFirst(chosenParts.count).dropLast())

        // Deepest first: the most specific folder that names something wins.
        while let candidate = below.popLast() {
            if let name = meaningful(candidate) { return name }
        }
        // Nothing below was a name — so the chosen folder itself is the group.
        // This is the ordinary case: "Saudi Kings/STL/crown.stl".
        return meaningful(chosen.lastPathComponent)
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
