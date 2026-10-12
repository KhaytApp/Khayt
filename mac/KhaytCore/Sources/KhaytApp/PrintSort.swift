import Foundation

/// What each folder of a linked folder IS — a collection, a print, a part of
/// a print, a format, or pictures — and so which group a model belongs in.
///
/// ── THE COMPLAINT (alpha.66, Oct 2026) ─────────────────────────────────────
///
/// After the shop's Google Drive was scanned: "Some folders have multiple
/// prints and I want them as a main group if they are an independent print."
/// The book had 103 models under `Oct26 Giga Tier/Guilmon Card/Mini Poster`
/// and 50 under `Aug26 Giga Tier/Life Size Buzz Lightyear/4 feet Size/Wing`,
/// because `ImportGrouping` keeps every folder that NAMES something and a
/// Patreon tier names something. On disk a print looks like
///
///     Aug26 Giga Tier/Aug26 Super Yosher Tier/Aug26 Yosher Tier/
///         Life Size Buzz Lightyear/{STLs/4 feet Size/Wing/…, Colored 3MFs/…,
///                                   Uncolored 3MFs/…, Renders/front.jpg…}
///
/// and the shop reads it in roles, not names: the tiers are COLLECTIONS (where
/// the file came from), `Life Size Buzz Lightyear` is the PRINT, `STLs` and
/// `Colored 3MFs` are FORMATS of the same parts, `Renders` is its PICTURES,
/// and `4 feet Size` is a PART or SIZE set of that print.
///
/// ── THE GROUP IS THE PRINT ─────────────────────────────────────────────────
///
/// A model's group is its print's name, plus at most ONE part/size level when
/// the print is split that way (`Life Size Gambit/Large Cuts`). Collections
/// and formats never appear in it, so the same print delivered in two tiers
/// is one group. The outermost collection is kept on the record as a TAG —
/// the library's own field for "where it came from, to filter by".
///
/// ── HEURISTIC FIRST, ALWAYS ────────────────────────────────────────────────
///
/// Everything here is pure and offline: it reads a tree of names and counts.
/// The shop's assistant may refine it (`SortAnswers`, from `ai-library`), but
/// nothing waits for that: a scan files by this, and a refinement is a later
/// regroup through the same protections.
enum PrintSort {

    /// What a folder is. The raw values are the wire format the assistant
    /// answers in (`lib/ai-library.js ROLES`) and the cache stores.
    enum Role: String, CaseIterable, Sendable {
        /// Holds prints: a tier, a pack, a month, a bundle, a theme set.
        case collection
        /// One independent thing to print.
        case print
        /// A part or size set inside a print (`4 feet Size`, `Large Cuts`).
        case part
        /// Packaging inside a print: `STLs`, `Colored 3MFs`, `Print Files`.
        case format
        /// Pictures, renders, documents — no models.
        case assets
    }

    // MARK: - The tree

    /// One folder, by its path below the linked folder ("" is the linked
    /// folder itself).
    struct Node: Sendable, Equatable {
        var name: String
        var children: [String] = []
        /// Models directly inside.
        var models = 0
        /// Models at or below.
        var under = 0
        /// Picture files directly inside, by name.
        var images: [String] = []
        /// The first few model files directly inside, by name — what the
        /// assistant reads a folder by (`lib/ai-library.js LIMITS.samples`).
        var samples: [String] = []
    }

    /// A linked folder as names and counts — all the classifier ever sees.
    struct Tree: Sendable {
        var nodes: [String: Node] = ["": Node(name: "")]

        /// Built from the RELATIVE paths of the models and pictures under the
        /// linked folder (`a/b/c.stl`). Folders with neither do not exist here.
        init(models: [String], images: [String] = []) {
            for rel in models { add(rel, model: true) }
            for rel in images { add(rel, model: false) }
            for key in nodes.keys {
                nodes[key]?.children.sort { $0.localizedStandardCompare($1) == .orderedAscending }
                nodes[key]?.images.sort { $0.localizedStandardCompare($1) == .orderedAscending }
            }
        }

        private mutating func add(_ rel: String, model: Bool) {
            let parts = rel.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard let file = parts.last else { return }
            var key = ""
            if model { nodes[key]?.under += 1 }
            for folder in parts.dropLast() {
                let child = key.isEmpty ? folder : key + "/" + folder
                if nodes[child] == nil {
                    nodes[child] = Node(name: folder)
                    nodes[key]?.children.append(child)
                }
                if model { nodes[child]?.under += 1 }
                key = child
            }
            if model {
                nodes[key]?.models += 1
                if (nodes[key]?.samples.count ?? 0) < 5 { nodes[key]?.samples.append(file) }
            } else {
                nodes[key]?.images.append(file)
            }
        }

        subscript(_ key: String) -> Node? { nodes[key] }

        /// Folder keys, parents before children.
        var folders: [String] {
            nodes.keys.filter { !$0.isEmpty }.sorted {
                let a = $0.split(separator: "/").count, b = $1.split(separator: "/").count
                return a != b ? a < b : $0.localizedStandardCompare($1) == .orderedAscending
            }
        }
    }

    // MARK: - Words

    /// Folders that are pictures or papers, never models.
    nonisolated static let assetNames: Set<String> = ModelPhoto.galleries.union([
        "media", "documentation", "docs", "doc", "instructions", "instruction", "previews", "preview",
        "thumbnails", "thumbs", "textures", "texture", "guide", "guides",
    ])

    /// Packaging words beyond `ImportGrouping.containerWords` that only ever
    /// mean "the files": `printing_orientation`, `PrintFiles`.
    nonisolated static let formatWords: Set<String> = [
        "orientation", "oriented", "printfiles", "stlfiles", "not", "no", "colors", "colours",
        "multicolored", "multicoloured", "painted", "unpainted", "ams",
    ]

    /// Words that say a folder is a SIZE or PART of something, not a thing.
    nonisolated static let partWords: Set<String> = [
        "poster", "posters", "card", "cards", "mini", "small", "smaller", "large", "larger", "big",
        "bigger", "concert", "size", "sizes", "sized", "inch", "inches", "cm", "mm", "ft", "feet",
        "foot", "scale", "scaled", "cut", "cuts", "uncut", "version", "versions", "variant",
        "variants", "alternate", "alternative", "left", "right", "body", "head", "arm", "arms",
        "leg", "legs", "base", "clean", "damaged", "full", "half", "piece", "pieces", "top",
        "bottom", "front", "back", "side", "waist", "torso", "life", "toy", "standard", "deluxe",
    ]

    /// Words that say a folder is where files CAME FROM.
    nonisolated static let collectionWords: Set<String> = [
        "tier", "tiers", "pack", "packs", "bundle", "bundles", "rewards", "reward", "collection",
        "collections", "release", "releases", "delivery", "giga", "free", "themes",
        "drop", "drops",
    ]

    nonisolated static func isAssetName(_ name: String) -> Bool {
        let w = ImportGrouping.words(name)
        return !w.isEmpty && w.allSatisfy { assetNames.contains($0) || $0 == "and" }
    }

    /// Packaging, judged against the print it sits in: `Gambit 3mf files
    /// (Not Colored)` inside `Life Size Gambit` is {gambit, 3mf, files}, and
    /// once the print's own words are gone only packaging is left.
    nonisolated static func isFormatName(_ name: String, printCore: Set<String> = []) -> Bool {
        if ImportGrouping.meaningful(name) == nil { return true }
        let lowered = name.lowercased()
        if lowered.range(of: #"^(stls?|3mfs?)[a-z]"#, options: .regularExpression) != nil { return true }
        let w = ImportGrouping.words(name).filter { Double($0) == nil && !printCore.contains($0) }
        // Nothing but the print's own words: the print said again
        // (`Gabumon Card` inside `Gabumon Card`) — but `Kang` inside `Kang &
        // Kodos` is one of two things, not the same one.
        guard !w.isEmpty else { return !printCore.isEmpty && core(name) == printCore }
        return w.allSatisfy { ImportGrouping.containerWords.contains($0) || ImportGrouping.notAName.contains($0)
            || formatWords.contains($0) || ImportGrouping.decorationWords.contains($0) }
            && w.contains { ImportGrouping.containerWords.contains($0) || formatWords.contains($0)
                || ImportGrouping.notAName.contains($0) }
    }

    ///
    /// Not `ImportGrouping.isWrapper`: that one also counts "Patreon" and
    /// "Files", and `Headless Horseman - Patreon` is one print, as is
    /// `Gridcube STL Files`.
    nonisolated static func isCollectionName(_ name: String) -> Bool {
        let w = ImportGrouping.words(name)
        if w.contains(where: collectionWords.contains) { return true }
        // A month's release: `Aug26`, `Sept2026`.
        return w.contains {
            $0.range(of: #"^(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\d{2,4}$"#,
                     options: .regularExpression) != nil
        }
    }

    /// A download site's folder for ONE model: `drill-organizer-box-model_files`,
    /// `Cactus-Organizer-2-Handles_stls`.
    nonisolated static func isDownloadSlug(_ name: String) -> Bool {
        name.range(of: #"(?i)[-_](model[-_])?files$|[-_]stls?$"#, options: .regularExpression) != nil
    }

    /// Nothing but packaging words — `STLs`, `Single Part STLs` — as against
    /// a print's name with packaging on it (`Mugs STL bundle`).
    nonisolated static func isPurePackaging(_ name: String) -> Bool {
        isFormatName(name, printCore: [])
    }

    /// A size or part: a part word, a measurement (`30cm`, `4 feet`, `6 INCH`),
    /// or a version (`v2`).
    nonisolated static func isPartName(_ name: String, printCore: Set<String> = []) -> Bool {
        let w = ImportGrouping.words(name).filter { !printCore.contains($0) }
        if w.contains(where: partWords.contains) { return true }
        if w.contains(where: { $0.range(of: #"^(v\d+|\d+(cm|mm|in|ft|x)?|x\d+)$"#, options: .regularExpression) != nil }),
           w.count <= 2 { return true }
        return false
    }

    /// `01 Hooks`, `02_Drawers` — steps of one thing, not things.
    nonisolated static func isNumbered(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespaces).range(of: #"^\d{1,3}\s*[-._) ]"#, options: .regularExpression) != nil
    }

    /// The words that name a folder's subject, packaging and decoration gone.
    nonisolated static func core(_ name: String) -> Set<String> { ImportGrouping.core(name) }

    /// Two names for the same thing: `Mumm-Ra` and `Mumm Ra - Patreon`.
    nonisolated static func sameThing(_ a: String, _ b: String) -> Bool {
        let x = core(a), y = core(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x.isSubset(of: y) || y.isSubset(of: x)
    }

    // MARK: - Classifying

    /// Every folder's role, the linked folder's own ("" — always a collection)
    /// included. `answers` are roles the assistant gave, by folder key; a role
    /// that cannot hold where it was given (a collection inside a print) is
    /// ignored and the heuristic's stands.
    static func classify(_ tree: Tree, answers: [String: Role] = [:]) -> [String: Role] {
        var roles: [String: Role] = ["": .collection]
        var memo: [String: Role] = [:]
        func walkCollection(_ key: String) {
            for child in tree[key]?.children ?? [] {
                let role = answers[child].flatMap { said in
                    // A part needs a print around it; "pictures" for a folder
                    // that holds models would drop them from every group.
                    said == .part || (said == .assets && (tree[child]?.under ?? 0) > 0) ? nil : said
                } ?? topRole(child, tree, &memo)
                roles[child] = role
                switch role {
                case .collection, .format: walkCollection(child)
                case .print:
                    // A print that is only a repeat of its one child
                    // (`Mumm-Ra/Mumm Ra - Patreon`): the child is the print's
                    // packaging, not a part.
                    walkPrint(child, printCore: core(tree[child]?.name ?? ""), tree: tree,
                              answers: answers, roles: &roles)
                case .assets, .part: markAll(child, .assets, tree: tree, roles: &roles)
                }
            }
        }
        walkCollection("")
        return roles
    }

    private static func markAll(_ key: String, _ role: Role, tree: Tree, roles: inout [String: Role]) {
        for child in tree[key]?.children ?? [] {
            roles[child] = role
            markAll(child, role, tree: tree, roles: &roles)
        }
    }

    /// Below a print: pictures, packaging, or its parts — nothing else.
    private static func walkPrint(_ key: String, printCore: Set<String>, tree: Tree,
                                  answers: [String: Role], roles: inout [String: Role]) {
        let node = tree[key]
        let content = (node?.children ?? []).filter { isContent($0, tree, printCore: printCore) }
        for child in node?.children ?? [] {
            guard let c = tree[child] else { continue }
            var role: Role
            if c.under == 0 || isAssetName(c.name) {
                role = .assets
            } else if isFormatName(c.name, printCore: printCore) {
                role = .format
            } else if content.count == 1, node?.models == 0, sameThing(node?.name ?? "", c.name),
                      !isPartName(c.name, printCore: printCore) {
                role = .format                                   // the print said twice
            } else {
                role = .part
            }
            if let said = answers[child], said != .collection, said != .print,
               said != .assets || c.under == 0 { role = said }
            roles[child] = role
            walkPrint(child, printCore: printCore, tree: tree, answers: answers, roles: &roles)
        }
    }

    /// A child folder that holds models of its own subject — not pictures,
    /// not packaging.
    private static func isContent(_ key: String, _ tree: Tree, printCore: Set<String>) -> Bool {
        guard let n = tree[key], n.under > 0, !isAssetName(n.name) else { return false }
        return !isFormatName(n.name, printCore: printCore)
    }

    /// Whether a folder has pictures of its own: a Renders folder, or images
    /// loose beside its models.
    private static func hasPictures(_ key: String, _ tree: Tree) -> Bool {
        guard let n = tree[key] else { return false }
        if !n.images.isEmpty { return true }
        return n.children.contains { c in
            guard let cn = tree[c], isAssetName(cn.name) else { return false }
            return !cn.images.isEmpty || cn.children.contains { !(tree[$0]?.images.isEmpty ?? true) }
        }
    }

    /// The sub-folders that hold models of their own subject, with packaging
    /// looked THROUGH: `Mugs STL Bundle/Mugs STL bundle/{60 mugs}` holds the
    /// sixty mugs, not one folder called "STL bundle".
    private static func content(_ key: String, _ tree: Tree, printCore: Set<String>) -> [String] {
        packedContent(key, tree, printCore: printCore).map(\.key)
    }

    /// `content`, each marked with whether it was reached through a folder of
    /// PURE packaging (`MK World Display Set/Single Part STLs/MK - Logo`): what
    /// sits inside a print's STL folder is that print's parts.
    private static func packedContent(_ key: String, _ tree: Tree, printCore: Set<String>,
                                      packed: Bool = false) -> [(key: String, packed: Bool)] {
        var out: [(key: String, packed: Bool)] = []
        for child in tree[key]?.children ?? [] {
            guard let c = tree[child], c.under > 0, !isAssetName(c.name) else { continue }
            if isFormatName(c.name, printCore: printCore) {
                out += packedContent(child, tree, printCore: printCore,
                                     packed: packed || isPurePackaging(c.name))
            } else {
                out.append((child, packed))
            }
        }
        return out
    }

    /// Models a folder holds itself — loose, or inside its packaging.
    private static func ownModels(_ key: String, _ tree: Tree, printCore: Set<String>) -> Int {
        guard let n = tree[key] else { return 0 }
        var count = n.models
        for child in n.children {
            guard let c = tree[child], c.under > 0, !isAssetName(c.name),
                  isFormatName(c.name, printCore: printCore) else { continue }
            count += ownModels(child, tree, printCore: printCore)
        }
        return count
    }

    /// Has packaging of its own holding models (`Zard Buddy/STLs`).
    private static func hasFormats(_ key: String, _ tree: Tree) -> Bool {
        guard let n = tree[key] else { return false }
        let mine = core(n.name)
        return n.children.contains { c in
            guard let cn = tree[c], cn.under > 0, !isAssetName(cn.name) else { return false }
            return isFormatName(cn.name, printCore: mine)
        }
    }

    /// A folder met among collections: is it a print or another collection?
    private static func topRole(_ key: String, _ tree: Tree, _ memo: inout [String: Role]) -> Role {
        if let hit = memo[key] { return hit }
        let role = decideTop(key, tree, &memo)
        memo[key] = role
        return role
    }

    /// The rules, strongest first. Each names the real folder it was written
    /// for; `PrintSortTests` holds them to those shapes.
    private static func decideTop(_ key: String, _ tree: Tree, _ memo: inout [String: Role]) -> Role {
        guard let node = tree[key] else { return .assets }
        if node.under == 0 || isAssetName(node.name) { return .assets }
        // Packaging met where prints are expected (`Pack/STL/…`): walked
        // through, its contents judged as if they sat in the folder above.
        if isFormatName(node.name) { return .format }
        let mine = core(node.name)
        let packed = packedContent(key, tree, printCore: mine)
        let kids = packed.map(\.key)
        let own = ownModels(key, tree, printCore: mine)
        // Nothing but models, pictures and packaging: a print.
        if kids.isEmpty { return .print }
        let pictures = hasPictures(key, tree)
        let wrapper = isCollectionName(node.name)
        // A download of ONE model, whatever is inside it.
        if isDownloadSlug(node.name), !wrapper { return .print }
        // What sits inside its STL folder is its parts (`MK World Display
        // Set/…/Single Part STLs/{MK - Display Stand, MK - Logo…}`).
        if !wrapper, packed.filter(\.packed).count * 2 > kids.count { return .print }

        // ONE sub-folder and nothing else of its own.
        if kids.count == 1, own == 0 {
            let only = kids[0]
            let child = tree[only]!
            let plain = !hasPictures(only, tree) && !hasFormats(only, tree)
                && content(only, tree, printCore: core(child.name)).isEmpty
            if pictures && !wrapper { return .print }
            if plain {
                // `Storm Breaker/Stomrbreaker new STLs`: a folder of models
                // that says it is files, a size, or the print again is this
                // print's files. `Monsters/Dragon` is a print in a collection.
                let packaging = ImportGrouping.words(child.name).contains {
                    ImportGrouping.containerWords.contains($0) || ImportGrouping.notAName.contains($0)
                }
                return !wrapper && (packaging || sameThing(node.name, child.name)
                                    || isPartName(child.name, printCore: mine)) ? .print : .collection
            }
            // `Mumm-Ra/Mumm Ra - Patreon/{Pictures, Single STLs}` — the same
            // print said twice — and `cute-cat-mug-hugger/KrakDrag/…`, a
            // designer's folder inside a download: one print, and the OUTER
            // folder names it. A pack holding one print is still a pack.
            return topRole(only, tree, &memo) == .print && !wrapper ? .print : .collection
        }

        let kidsPictures = kids.filter { hasPictures($0, tree) }.count
        // Pictures here and not in the sub-folders: the sub-folders are this
        // print's sizes (`Call of Duty 4/{Concert Poster, Mini Poster, RENDERS}`).
        // Not for a pack's own media folder (`GridCube File Delivery/Media`).
        if pictures, kidsPictures * 2 < kids.count, !wrapper { return .print }
        // Sub-folders that are each a print with its own pictures
        // (`Themes/*/Renders`, `Aug26 Collectibles Tier/*/Renders`).
        if kidsPictures >= 2, kidsPictures * 3 >= kids.count { return .collection }
        // Sizes and parts (`Card`, `Mini Poster`, `4 and 6 inches`, `Clean`).
        let parts = kids.filter { isPartName(tree[$0]!.name, printCore: mine) }.count
        if parts * 2 > kids.count, !wrapper { return .print }
        // Steps of one thing (`01_Cubes`, `02_Drawers`).
        if kids.filter({ isNumbered(tree[$0]!.name) }).count * 2 > kids.count, !wrapper { return .print }
        // Sub-folders that each carry their own STL/3MF folders.
        let kidsFormats = kids.filter { hasFormats($0, tree) }.count
        if kidsFormats >= 2, kidsFormats * 3 >= kids.count { return .collection }
        // Its own models beside variants of them (`Gridcube STL Files/Non LED Version`).
        if own > 0, kidsPictures == 0, kidsFormats == 0, !wrapper, own * 2 >= node.under - own { return .print }
        return .collection
    }

    // MARK: - Names

    /// A folder's name as a print's group: a download site's spelling undone
    /// (`ImportGrouping.display`), the packaging and pack wrapping that trail
    /// it gone (`Mumm Ra - Patreon` → `Mumm Ra`, `Gridcube STL Files` →
    /// `Gridcube`), a shop handle and a site's number dropped (`_@stl_zone`,
    /// ` - 1810411`), and a name shouted in capitals spoken normally
    /// (`LARGE CUTS` → `Large Cuts`). Never empty: when nothing would be left,
    /// the name as written. `keepWrapping` is a COLLECTION's name, for a tag:
    /// `Yosh Free Files` stays whole, because "Files" is part of its name.
    nonisolated static func cleanName(_ folder: String, keepWrapping: Bool = false) -> String {
        var s = folder.replacingOccurrences(of: #"\s*_?@[A-Za-z0-9_.]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // Leading or trailing site numbers: `1810109_Desk_Organizer`, `… - 6814716`
        // — but `2026 World Cup` keeps its year.
        if s.range(of: #"^(19|20)\d\d[ _-]"#, options: .regularExpression) == nil {
            s = s.replacingOccurrences(of: #"^\d{4,}[ _-]+"#, with: "", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"[ _-]+\d{5,}$"#, with: "", options: .regularExpression)
        // An ordering: `02_Drawers`, `01 - Base`, `3) Lid`.
        s = s.replacingOccurrences(of: #"^\d{1,3}\s*[-._)]+\s*(?=\S)"#, with: "", options: .regularExpression)
        s = ImportGrouping.display(s)
        s = s.replacingOccurrences(of: "_", with: " ")
        // Trailing wrapping, a word at a time.
        let tailWords = ImportGrouping.containerWords.union(ImportGrouping.decorationWords)
            .subtracting(["part", "parts", "single", "and", "for", "only", "multi", "mono", "color", "colour"])
        var tokens = s.split(separator: " ").map(String.init)
        while !keepWrapping, tokens.count > 1 {
            let last = tokens.last!.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "-_.()[]"))
            if last.isEmpty || last == "-" || last == "–" || tailWords.contains(last) { tokens.removeLast() } else { break }
        }
        s = tokens.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -_–"))
        // Shouted: every letter a capital and more than a short acronym.
        let letters = s.filter(\.isLetter)
        if letters.count > 4, letters.allSatisfy({ $0.isUppercase }) {
            s = s.lowercased().split(separator: " ").map { w -> String in
                ["and", "of", "the", "for", "in", "with"].contains(w) ? String(w) : w.prefix(1).uppercased() + w.dropFirst()
            }.joined(separator: " ")
            if let first = s.first { s = first.uppercased() + s.dropFirst() }
        }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? folder.trimmingCharacters(in: .whitespaces) : s
    }

    /// At most sixty UTF-16 units, cut at a word (`LibraryFile.normalise`
    /// owns the limit and cuts mid-word; a print's own name should not read
    /// as a typo).
    nonisolated static func fit(_ name: String) -> String {
        guard name.utf16.count > 60 else { return name }
        var out = ""
        for word in name.split(separator: " ") {
            let next = out.isEmpty ? String(word) : out + " " + word
            if next.utf16.count > 60 { break }
            out = next
        }
        return out.isEmpty ? String(name.prefix(60)) : out
    }

    // MARK: - A print's picture

    /// Words that name a print's hero shot.
    nonisolated static let heroWords: Set<String> = ["front", "hero", "cover", "main", "thumbnail", "thumb", "preview"]

    /// The pictures of one print, best first, as paths below the linked
    /// folder:
    ///
    ///   1. one named for the print (`Renders/Buzz Lightyear.jpg` for
    ///      `Life Size Buzz Lightyear`);
    ///   2. a hero shot — `front`, `hero`, `cover`, `main`;
    ///   3. the first in its own Renders/Pictures/Images folder;
    ///   4. any picture loose in the print's folder;
    ///   5. any picture deeper inside it.
    ///
    /// Names only: what a picture weighs, and whether it decodes, is the
    /// fetcher's to find out, which is why this is a ranking and not a pick.
    static func pictures(of print: String, in tree: Tree, roles: [String: Role], name: String) -> [String] {
        guard let node = tree[print] else { return [] }
        let printCore = core(name).union(core(node.name))
        // Every picture in the print, with the folder it is in.
        var all: [(rel: String, gallery: Bool, loose: Bool)] = []
        func walk(_ key: String, depth: Int, inGallery: Bool) {
            guard let n = tree[key] else { return }
            let gallery = inGallery || (depth > 0 && isAssetName(n.name))
            for image in n.images {
                all.append((key + "/" + image, gallery, depth == 0))
            }
            for child in n.children { walk(child, depth: depth + 1, inGallery: gallery) }
        }
        walk(print, depth: 0, inGallery: false)
        // 6. A pack's own media folder, sorted by print: `GridCube File
        //    Delivery/Media/Renders/Drawers/…` is the picture of `Drawers`.
        var above = (print as NSString).deletingLastPathComponent
        var hops = 0
        while all.isEmpty, hops < 3 {
            for child in tree[above]?.children ?? [] where isAssetName(tree[child]?.name ?? "") {
                func find(_ key: String) {
                    guard let n = tree[key] else { return }
                    let c = core(n.name)
                    if !c.isEmpty, !printCore.isEmpty, c == printCore || (c.isSuperset(of: printCore) && c.count <= printCore.count + 1) {
                        for image in n.images { all.append((key + "/" + image, true, false)) }
                    }
                    n.children.forEach(find)
                }
                find(child)
            }
            if above.isEmpty { break }
            above = (above as NSString).deletingLastPathComponent
            hops += 1
        }
        func stemCore(_ rel: String) -> Set<String> {
            core((rel as NSString).lastPathComponent.replacingOccurrences(of: #"\.[^.]+$"#, with: "",
                                                                          options: .regularExpression))
        }
        func rank(_ p: (rel: String, gallery: Bool, loose: Bool)) -> Int {
            let words = stemCore(p.rel)
            let named = !words.isEmpty && !printCore.isEmpty
                && (words.isSuperset(of: printCore) || (words.count >= 2 && words.isSubset(of: printCore)))
            if named { return 0 }
            if !words.isDisjoint(with: heroWords) { return 1 }
            if p.gallery { return 2 }
            if p.loose { return 3 }
            return 4
        }
        return all.enumerated()
            .sorted { a, b in
                let ra = rank(a.element), rb = rank(b.element)
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map(\.element.rel)
    }

    /// A picture inside the print named EXACTLY as one model is
    /// (`Body.stl` + `Renders/Body.png`), by model path — the only way a
    /// print's picture becomes one model's own.
    static func modelPictures(of print: String, in tree: Tree, models: [String]) -> [String: String] {
        var byStem: [String: String] = [:]
        func walk(_ key: String) {
            guard let n = tree[key] else { return }
            for image in n.images {
                let stem = (image as NSString).deletingPathExtension.lowercased()
                if byStem[stem] == nil { byStem[stem] = key + "/" + image }
            }
            n.children.forEach(walk)
        }
        walk(print)
        guard !byStem.isEmpty else { return [:] }
        var out: [String: String] = [:]
        for rel in models where rel.hasPrefix(print + "/") {
            let stem = ((rel as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
            if let hit = byStem[stem] { out[rel] = hit }
        }
        return out
    }

    // MARK: - Placing models

    struct Placement: Equatable, Sendable {
        /// `Print` or `Print/Part`, or nil for a model that stands alone.
        let group: String?
        /// The model's name, when the folder named it better than its file.
        let title: String?
        /// The outermost collection it came from, for the record's tags.
        let collection: String?
        /// The print folder's key, when it is in one.
        let print: String?
    }

    /// Where every model goes.
    ///
    /// - Parameters:
    ///   - models: relative paths of the models (`a/b/c.stl`).
    ///   - names: clean names the assistant gave prints, by folder key.
    static func placements(_ tree: Tree, roles: [String: Role], models: [String],
                           names: [String: String] = [:]) -> [String: Placement] {
        struct Spot { let print: String?; let part: String?; let collection: String? }
        var spots: [String: Spot] = [:]
        for rel in models {
            let parts = rel.split(separator: "/").map(String.init).dropLast()
            var key = ""
            var collection: String?
            var print: String?
            var part: String?
            for folder in parts {
                key = key.isEmpty ? folder : key + "/" + folder
                switch roles[key] ?? .assets {
                case .collection where print == nil:
                    if collection == nil { collection = key }
                case .print where print == nil:
                    print = key
                case .part where print != nil && part == nil:
                    part = key
                default: break
                }
            }
            spots[rel] = Spot(print: print, part: part, collection: collection)
        }
        // One spelling per print name: the same print from two collections is
        // one group, spelled as the first path met spells it.
        var spelling: [String: String] = [:]
        func display(_ key: String) -> String {
            let raw = names[key].map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
                ?? cleanName(tree[key]?.name ?? key)
            let shown = fit(raw)
            let canon = core(shown).sorted().joined(separator: " ")
            let id = canon.isEmpty ? shown.lowercased() : canon
            if let had = spelling[id] { return had }
            spelling[id] = shown
            return shown
        }
        let ordered = models.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var perPrint: [String: Int] = [:]
        var perPart: [String: Int] = [:]
        var partsOf: [String: Set<String>] = [:]
        for rel in ordered {
            guard let s = spots[rel], let p = s.print else { continue }
            perPrint[p, default: 0] += 1
            partsOf[p, default: []].insert(s.part ?? "")
            if let part = s.part { perPart[part, default: 0] += 1 }
        }
        var out: [String: Placement] = [:]
        for rel in ordered {
            guard let s = spots[rel] else { continue }
            let tag = s.collection.map { cleanName(tree[$0]?.name ?? $0, keepWrapping: true) }
            guard let p = s.print else {
                out[rel] = Placement(group: nil, title: nil, collection: tag, print: nil)
                continue
            }
            let printName = display(p)
            // A print of ONE model is that model, not a folder of one.
            if perPrint[p] == 1 {
                out[rel] = Placement(group: nil, title: printName, collection: tag, print: p)
                continue
            }
            var group = printName
            var title: String?
            if let part = s.part, (partsOf[p]?.count ?? 0) >= 2 {
                let partName = cleanName(tree[part]?.name ?? part)
                if perPart[part] == 1 {
                    title = partName
                } else if !partName.isEmpty, (printName + ImportGrouping.separator + partName).utf16.count <= 60 {
                    group = printName + ImportGrouping.separator + partName
                }
            }
            out[rel] = Placement(group: group, title: title, collection: tag, print: p)
        }
        return out
    }
}
