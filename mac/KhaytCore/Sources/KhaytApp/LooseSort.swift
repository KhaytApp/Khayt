import Foundation

/// Models lying LOOSE at the top of a linked folder, sorted into prints by
/// their names.
///
/// ── THE COMPLAINT (alpha.67, Oct 2026) ─────────────────────────────────────
///
/// `PrintSort` files a linked folder by its sub-folders, so a model with no
/// folder of its own stayed ungrouped. On the shop's Google Drive that was
/// about 2,150 models, dropped straight into the top of the folder by an
/// automatic copy job:
///
///     v4-AA - holder.stl, v4-AA - cover.stl, v4-AA - connector.stl, …
///     totoroA.stl, totoroA.3mf, totoroB_smile.stl, totoro-medium.3mf, …
///     Fig_One Piece Luffy_LegRight_03_Skin.stl, …
///     core-one-drybox-clip3-v11.stl, core-one-drybox-v11-c.stl, …
///
/// ── NAMES, AND THE ORDER THE FILES ARRIVED IN ──────────────────────────────
///
/// Only names are read — never a file's bytes, so nothing online is fetched.
/// A copy job drops one kit's files one after the other, so the order the
/// files were CREATED in (their birth time, a listing's metadata) keeps a
/// kit's parts together. That order decides how far a shared name reaches:
/// `v4-AA - …` and `v4-AAA - …` sit side by side and share only `v4`, which
/// names no print, so they stay two prints.
///
/// ── WHAT IS NEVER A PRINT BY ITSELF ────────────────────────────────────────
///
/// A name made only of part, colour, size and format words (`Plate 3 -
/// Yellow`, `Peg`, `Left Arm`, `Fossil Grey 2`) says nothing about which kit
/// it belongs to, and a picture called `189.jpg` says nothing at all. Those
/// stay loose here; the shop's assistant, when the shop turned it on, may
/// place them beside the named file they arrived with (`lib/ai-library.js`).
/// A print of one model is that model, not a group of one.
///
/// Pure: names, an order and a few counts in, clusters out.
enum LooseSort {

    /// A print found among the loose models.
    struct Cluster: Sendable, Equatable {
        /// The print's name, as a group may be called (not yet fitted).
        let name: String
        /// Its models, by path below the linked folder, in copy order.
        let members: [String]
        /// Pictures named for it (`totoro.jpg`), best first.
        var pictures: [String] = []
        /// Placed by the shop's assistant, not by the names here.
        var byAssistant = false
    }

    /// One loose file, as the sort reads it.
    struct Read: Sendable, Equatable {
        /// What its name says, lower-cased, packaging gone.
        let tokens: [String]
        /// The text the tokens were read from, for a print's name.
        let text: String
        /// Where each token sits in `text`.
        let spans: [Range<String.Index>]
    }

    // MARK: - Words

    /// The words of a kit's PARTS (`Plate`, `Peg`, `Torso`, `Drawer`) — a
    /// name of nothing else is a part of SOME kit and never a print by
    /// itself.
    nonisolated static let partWords: Set<String> = [
        "plate", "plates", "part", "parts", "piece", "pieces", "left", "right", "base", "bases", "top",
        "bottom", "middle", "mid", "middel", "center", "centre", "front", "back", "side", "sides", "body",
        "bodies", "head", "heads", "arm", "arms", "leg", "legs", "hand", "hands", "foot", "feet", "ear",
        "ears", "eye", "eyes", "nose", "tail", "peg", "pegs", "pin", "pins", "insert", "inserts", "cover",
        "covers", "lid", "lids", "key", "keys", "cap", "caps", "ring", "rings", "link", "links", "corner",
        "corners", "panel", "panels", "shelf", "wall", "walls", "door", "frame", "handle", "hook",
        "hooks", "bin", "bins", "wing", "wings", "stand", "clip", "clips", "connector", "connectors",
        "spacer", "spacers", "adapter", "bolt", "bolts", "nut", "nuts", "screw", "screws", "washer",
        "hinge", "hinges", "spring", "gear", "gears", "wheel", "wheels", "track", "rail", "plug", "knob",
        "button", "mount", "bracket", "support", "supports", "block", "blocks", "torso", "pelvis",
        "helmet", "neck", "knee", "knees", "belly", "chest", "shoulder", "hip", "hips", "waist", "visor",
        "gun", "muzzle", "armor", "armour", "cape", "staff", "horn", "horns", "hair", "hat", "boot",
        "boots", "shoe", "shoes", "glove", "collar", "jaw", "tooth", "teeth", "tongue", "nail", "nails",
        "claw", "claws", "finger", "fingers", "thumb", "elbow", "wrist", "ankle", "toe", "toes", "spike",
        "chain", "pommel", "grip", "sheath", "hilt", "blade", "blades", "stem", "leaf", "leaves",
        "petal", "petals", "lower", "upper", "inner", "outer", "letter", "letters", "text", "bg",
        "background", "number", "numbers", "poster", "posters", "card", "cards", "concert", "drawer",
        "drawers", "latch", "latches", "led", "castor", "cradle", "divider", "dividers", "nameplate",
        "slot", "slots", "box", "boxes", "tray", "trays", "build", "grid", "tall", "short", "wide",
        "narrow", "deep", "shallow", "low", "high", "locking", "tube", "sheet", "strip", "bar", "rod",
        "axle", "shaft", "bearing", "seal", "lever", "guard", "shell", "dome", "disc", "disk",
    ]

    /// Words that WRAP a print's name without being it: formats, slicers
    /// and printers, colour and print states, sizes, versions. Taken off the
    /// end of a print's name (`ucard_box_window_single` → `ucard box window`).
    nonisolated static let noiseWords: Set<String> = [
        "stl", "stls", "3mf", "3mfs", "obj", "step", "stp", "gcode", "bgcode", "amf", "ply", "f3d",
        "scad", "bambu", "bambulab", "bambustudio", "prusa", "prusaslicer", "orca", "orcaslicer",
        "cura", "creality", "snapmaker", "elegoo", "anycubic", "ams", "noams", "mmu", "u1", "a1",
        "a1m", "a1mini", "p1", "p1s", "p1p", "x1", "x1c", "h2", "h2d", "mk3", "mk3s", "mk4",
        "makerworld", "printables", "thingiverse", "ready", "profile", "project", "studio",
        "printers", "printer", "pla", "petg", "tpu", "abs", "asa", "hd", "highres", "lowres",
        "render", "preview", "sliced", "slice", "supported", "presupported", "unsupported",
        "multicolor", "multicolour", "multicolored", "color", "colour", "colors", "colours",
        "colored", "coloured", "uncolored", "uncoloured", "mono", "solid", "hollow", "plated",
        "assembly", "object", "objects", "mesh", "model", "models", "print", "prints", "file", "files",
        "test", "sample", "half", "full", "whole", "small", "large", "medium", "big", "mini", "tiny",
        "single", "double", "triple", "multi", "multipart", "main", "optional", "alt", "new", "final",
        "fixed", "clean", "damaged", "updated", "copy", "version", "ver", "rev", "option", "style", "set", "kit",
        "combined", "together", "separate", "separated", "cut", "cuts", "split", "with", "without",
        "no", "and", "or", "for", "the", "of", "by", "to", "in", "on", "x", "qty", "pcs", "p", "mm",
        "cm", "inch", "inches", "ft", "size", "sizes", "scale", "scaled", "mirror", "mirrored",
        "xs", "s", "m", "l", "xl", "xxl", "one", "two", "three", "four", "five",
    ]

    nonisolated static let generic: Set<String> = partWords.union(noiseWords).union(colours)

    /// Colour words. A name that STARTS with one is a multi-colour kit's part
    /// (`Black Staff Top`, `Bone White Body`, `Red Horn Left`), never a print.
    nonisolated static let colours: Set<String> = [
        "white", "black", "grey", "gray", "red", "blue", "green", "yellow", "orange", "purple", "pink",
        "brown", "beige", "silver", "gold", "bronze", "copper", "cyan", "magenta", "violet", "indigo",
        "teal", "turquoise", "navy", "maroon", "burgundy", "wine", "cream", "ivory", "tan", "khaki",
        "olive", "lime", "mint", "peach", "coral", "salmon", "lavender", "lilac", "plum", "charcoal",
        "ash", "fossil", "earth", "cotton", "army", "pastel", "muted", "silk", "matte", "glossy", "dark",
        "light", "bright", "deep", "pale", "sky", "sapphire", "forest", "lava", "seafoam", "grass",
        "emerald", "electric", "sunrise", "banana", "terracotta", "periwinkle", "ice", "skin", "peanut",
        "bone", "cobalt", "jade", "sakura", "scarlet", "crimson", "lemon", "mandarin", "latte",
        "caramel", "chocolate", "nardo", "candy", "champagne", "transparent", "clear", "translucent",
        "glow", "neon", "metallic",
    ]

    /// Words that only wrap a name from the front: a format, a printer, a
    /// colour state (`3MF - Titan Fighter`, `Uncolored Concert Poster`).
    nonisolated static let leadingNoise: Set<String> = [
        "3mf", "stl", "obj", "step", "u1", "colored", "coloured", "uncolored", "uncoloured", "multicolor",
        "snapmaker", "bambu",
    ]

    nonisolated static func isNumber(_ t: String) -> Bool { !t.isEmpty && t.allSatisfy(\.isNumber) }

    /// `v2`, `v11`, `v13`.
    nonisolated static func isVersion(_ t: String) -> Bool {
        t.range(of: #"^v\d+[a-z]?$"#, options: .regularExpression) != nil
    }

    /// `120mm`, `25cm`, `4ft`, `x4`, `2qty`, `4h41m`.
    nonisolated static func isMeasure(_ t: String) -> Bool {
        t.range(of: #"^(\d+(mm|cm|in|ft|x|qty|h|m|s|l|p|pcs|deg)?|x\d+|\d+h\d+m)$"#, options: .regularExpression) != nil
    }

    /// A site's hash or id: `3441afd1cf7ce332`, `jw6NveuF3aU` — says nothing.
    nonisolated static func isNoise(_ t: String) -> Bool {
        guard t.count >= 8 else { return false }
        let digits = t.filter(\.isNumber).count
        if digits == t.count { return t.count >= 8 }                  // a timestamp
        if t.allSatisfy(\.isHexDigit), digits >= 2 { return true }
        guard digits >= 2, t.count - digits >= 2 else { return false }
        var flips = 0
        var last: Bool?
        for c in t { let d = c.isNumber; if let l = last, l != d { flips += 1 }; last = d }
        return flips >= 3
    }

    /// Says nothing about which print: a part word, colour, size, number,
    /// version, or a hash.
    nonisolated static func isGeneric(_ t: String) -> Bool {
        generic.contains(t) || isNumber(t) || isVersion(t) || isMeasure(t) || isNoise(t)
    }

    /// A word that can name a print by itself: three letters or more and
    /// not generic.
    nonisolated static func isStrong(_ t: String) -> Bool {
        !isGeneric(t) && t.filter(\.isLetter).count >= 3
    }

    /// Whether a run of words names a print: one strong word, or two words or
    /// more with one that is not generic (`v4-AA`, `v4-C`) — never `v4` or
    /// `Al` alone.
    nonisolated static func isDistinctive(_ tokens: [String]) -> Bool {
        if tokens.contains(where: isStrong) { return true }
        // Codes only (`v4` + `AA`): a part or colour word among them makes
        // it a kit's part (`Front Frame Corner TR`, `KA KEY A`).
        return tokens.count >= 2 && tokens.contains { !isGeneric($0) }
            && !tokens.contains { partWords.contains($0) || colours.contains($0) }
    }

    // MARK: - Reading a name

    /// A file's name with its packaging taken off: the extension and any
    /// extension inside it (`.step.stl`, `.stl_3.stl`), a U1 variant
    /// (`.u1`, `.u1-2`, `.u1-CLEAN`), a copy's ` (1)`, Bambu Studio's
    /// `obj_12_` and a figure pack's `Fig_`.
    nonisolated static func stripped(_ fileName: String) -> String {
        var s = (fileName as NSString).deletingPathExtension
        s = s.replacingOccurrences(of: #"(?i)\.u1(?:[-_ ][A-Za-z0-9]+)?$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)\.(stl|step|stp|obj|3mf)(?=$|[^A-Za-z0-9])"#, with: "",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)\.u1(?=$|[^A-Za-z0-9])"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*[(][0-9]+[)]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)^obj_\d+_"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)^fig_"#, with: "", options: .regularExpression)
        // A web address's spaces (`Universal20Filament20Clip`) and a UUID.
        s = s.replacingOccurrences(of: #"(?<=[a-z])20(?=[A-Z])"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#,
                                   with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " -_."))
    }

    /// Words with where they sit. A run of letters and digits is a word,
    /// split where a longer word meets a number (`clip3`, `Pikachu2`, `MARIO1`
    /// — but not `v4`, `a1`, `cr123a`) and where a trailing capital marks a
    /// variant (`totoroA`, `totoroB`, `PikatchuAMS`).
    nonisolated static func tokenize(_ s: String) -> [(String, Range<String.Index>)] {
        var out: [(String, Range<String.Index>)] = []
        var i = s.startIndex
        while i < s.endIndex {
            guard s[i].isLetter || s[i].isNumber else { i = s.index(after: i); continue }
            var j = i
            while j < s.endIndex, s[j].isLetter || s[j].isNumber { j = s.index(after: j) }
            out += splitWord(s, i..<j)
            i = j
        }
        return out
    }

    private nonisolated static func splitWord(_ s: String, _ r: Range<String.Index>) -> [(String, Range<String.Index>)] {
        let chars = Array(s[r].indices)
        var cuts: [String.Index] = []
        var letters = 0
        for (n, idx) in chars.enumerated() {
            let c = s[idx]
            if c.isLetter { letters += 1 }
            else if c.isNumber, n > 0, s[chars[n - 1]].isLetter {
                // Letters (three or more) then digits: `clip3`, `Pikachu2` —
                // and `SnapmakerU1` is `Snapmaker` + `U1`.
                if n >= 2, s[chars[n - 1]].isUppercase, s[chars[n - 2]].isLowercase, letters >= 4 {
                    cuts.append(chars[n - 1])
                } else if letters >= 3 { cuts.append(idx) }
                letters = 0
            } else { letters = 0 }
        }
        // A trailing run of one to three capitals after a lower-case letter.
        var k = chars.count
        while k > 0, s[chars[k - 1]].isUppercase { k -= 1 }
        let caps = chars.count - k
        if caps >= 1, caps <= 3, k > 0, s[chars[k - 1]].isLowercase { cuts.append(chars[k]) }
        cuts = Array(Set(cuts)).sorted()
        var out: [(String, Range<String.Index>)] = []
        var start = r.lowerBound
        for c in cuts where c > start {
            out += camel(s, start..<c)
            start = c
        }
        out += camel(s, start..<r.upperBound)
        return out
    }

    /// `TopPanel`, `LowerArm`, `SideTop`: words run together that are each a
    /// part word are those words. `TwistyBurger` is left whole — one name.
    private nonisolated static func camel(_ s: String, _ r: Range<String.Index>) -> [(String, Range<String.Index>)] {
        var pieces: [Range<String.Index>] = []
        var start = r.lowerBound
        var i = r.lowerBound
        while i < r.upperBound {
            let next = s.index(after: i)
            if next < r.upperBound, s[i].isLowercase, s[next].isUppercase {
                pieces.append(start..<next)
                start = next
            }
            i = next
        }
        pieces.append(start..<r.upperBound)
        let words = pieces.map { String(s[$0]).lowercased() }
        if pieces.count >= 2, words.allSatisfy(isGeneric) {
            return zip(words, pieces).map { ($0, $1) }
        }
        return [(String(s[r]).lowercased(), r)]
    }

    /// What a loose model's name says, or nil when it names no print — only
    /// part, colour and size words, a hash, or a kit part that starts with
    /// its colour (`Charcoal Black 2`, `AMS Eye Left`).
    nonisolated static func read(_ fileName: String) -> Read? {
        let s = stripped(fileName)
        let all = tokenize(s)
        guard let first = all.first?.0, !colours.contains(first), first != "ams" else { return nil }
        // `Kit - Part - Variant`: the kit is the first piece that names
        // something (`3MF - Titan Fighter` is the Titan Fighter). With no
        // ` - `, a name with spaces split by `_` is `Kit_Part_Number`.
        var text = s
        if s.contains(" - ") {
            let pieces = s.components(separatedBy: " - ")
            text = pieces.first { isDistinctive(core(tokenize($0).map(\.0))) } ?? pieces[0]
        }
        if text.contains(" "), text.contains("_") {
            let pieces = text.components(separatedBy: "_").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            text = pieces.first { isDistinctive(core(tokenize($0).map(\.0))) } ?? pieces.first ?? text
        }
        var words = tokenize(text)
        while let w = words.first?.0, leadingNoise.contains(w) || isNoise(w) { words.removeFirst() }
        words.removeAll { isNoise($0.0) }
        guard isDistinctive(core(words.map(\.0))) else { return nil }
        return Read(tokens: words.map(\.0), text: text, spans: words.map(\.1))
    }

    /// Words with the generic ones that TRAIL them gone (numbers kept:
    /// `Halo 3`, `Stacking Coaster Style 6`) — what is judged distinctive.
    nonisolated static func core(_ tokens: [String]) -> [String] {
        var t = tokens
        while let last = t.last, isGeneric(last), !isNumber(last) { t.removeLast() }
        return t
    }

    /// Words with only the WRAPPING that trails them gone — what a print is
    /// called: `guitar stand` keeps its stand, `ucard box window single`
    /// loses its `single`, `Halo 3 Uncolored` its colour state.
    nonisolated static func trimmed(_ tokens: [String]) -> [String] {
        var t = tokens
        while let last = t.last, noiseWords.contains(last) || colours.contains(last) || isVersion(last)
                || isNoise(last) || (isMeasure(last) && !isNumber(last)) { t.removeLast() }
        return t
    }

    /// The print's name: the first `count` words as the file spells them,
    /// a slug's hyphens and underscores read as spaces
    /// (`core-one-drybox` → `core one drybox`, but `v4-AA` stays).
    nonisolated static func name(_ read: Read, words count: Int) -> String {
        let n = min(count, read.spans.count)
        guard n > 0 else { return "" }
        var s = String(read.text[read.spans[0].lowerBound..<read.spans[n - 1].upperBound])
        if !s.contains(" ") {
            if s.contains("_") { s = s.replacingOccurrences(of: "_", with: " ") }
            if s.filter({ $0 == "-" }).count >= 2 { s = s.replacingOccurrences(of: "-", with: " ") }
        }
        return s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -_."))
    }

    /// The canonical form two runs are the same print by.
    nonisolated static func canon(_ tokens: [String]) -> String { tokens.joined(separator: " ") }

    /// A print's name as its group is called: tidied the way a folder's is
    /// (`PrintSort.cleanName`) and at most sixty UTF-16 units.
    nonisolated static func shown(_ raw: String) -> String { PrintSort.fit(PrintSort.cleanName(raw)) }

    /// Two names for one group, as `PrintSort.placements` tells them apart.
    nonisolated static func identity(_ name: String) -> String {
        let c = PrintSort.core(name).sorted().joined(separator: " ")
        return c.isEmpty ? name.lowercased() : c
    }

    // MARK: - Sorting

    /// How far apart (in models, in copy order) two files of one kit may sit:
    /// a few unnamed parts between them (`Plate 3`, `Peg`) do not part them.
    nonisolated static let reach = 8

    /// A picture named only by a number or a camera (`189.jpg`, `IMG_2041`)
    /// is nobody's picture.
    nonisolated static func isAnonymousPicture(_ fileName: String) -> Bool {
        let stem = (fileName as NSString).deletingPathExtension
        return stem.range(of: #"(?i)^((img|dsc|dscn|pxl|photo|image|screenshot)[ _-]?)?[\d _-]+$"#,
                          options: .regularExpression) != nil
    }

    /// The loose models of one linked folder, as prints.
    ///
    /// - Parameters:
    ///   - models: the loose models' paths below the linked folder.
    ///   - images: the loose pictures' paths below the linked folder.
    ///   - births: when each was created (seconds), by path — the copy
    ///     order. A file without one sorts by name after those with one.
    ///   - assistant: what the shop's assistant said, by path: the print a
    ///     model belongs to. A model it placed is not judged again here.
    nonisolated static func clusters(models: [String], images: [String] = [],
                                     births: [String: Double] = [:],
                                     assistant: [String: String] = [:]) -> [Cluster] {
        sort(models: models, images: images, births: births, assistant: assistant).clusters
    }

    /// The prints alone, from the models' names (and the assistant's word).
    private nonisolated static func prints(models: [String], births: [String: Double],
                                           assistant: [String: String]) -> [Cluster] {
        let ordered = order(models, births: births)
        var out: [Cluster] = []
        var taken = Set<String>()

        // 1. The assistant's prints, where two of their models are still here.
        var byName: [String: (name: String, members: [String])] = [:]
        var assistantOrder: [String] = []
        for rel in ordered {
            guard let raw = assistant[rel], let name = PrintSort.assistantName(raw) else { continue }
            let key = name.lowercased()
            if byName[key] == nil { byName[key] = (name, []); assistantOrder.append(key) }
            byName[key]?.members.append(rel)
        }
        for key in assistantOrder {
            guard let c = byName[key], c.members.count >= 2 else { continue }
            out.append(Cluster(name: c.name, members: c.members, byAssistant: true))
            taken.formUnion(c.members)
        }

        // 2. The rest by their names, in copy order.
        let rest = ordered.filter { !taken.contains($0) }
        var reads: [(rel: String, at: Int, read: Read)] = []
        for (at, rel) in rest.enumerated() {
            if let r = read((rel as NSString).lastPathComponent) { reads.append((rel, at, r)) }
        }
        var named: [(canon: String, name: String, members: [String])] = []
        var start = 0
        while start < reads.count {
            var end = start + 1
            var prefix = reads[start].read.tokens
            while end < reads.count, reads[end].at - reads[end - 1].at <= reach {
                let shared = commonPrefix(prefix, reads[end].read.tokens)
                guard isDistinctive(core(shared)) else { break }
                // Down to one word from a name that said more (`Universal
                // Filament Clip` then `Universal Top part`, `Spray Can Holder`
                // then `Spray Bottle Holder`): two prints that begin alike.
                // `totoroA` then `totoroB` drops only a letter.
                if shared.count == 1, end - start >= 2, prefix.count >= 2, isStrong(prefix[1]) { break }
                prefix = shared
                end += 1
            }
            named += Self.named(Array(reads[start..<end]).map { ($0.rel, $0.read) }, prefix: prefix)
            start = end
        }

        // 3. One print per name: two runs that name the same print are it,
        //    by the rule a group's spelling is shared by (`PrintSort.placements`).
        for i in out.indices { out[i] = Cluster(name: shown(out[i].name), members: out[i].members, byAssistant: true) }
        var merged: [String: (name: String, members: [String])] = [:]
        var mergedOrder: [String] = []
        for n in named {
            let name = shown(n.name)
            let key = identity(name)
            if merged[key] == nil { merged[key] = (name, []); mergedOrder.append(key) }
            merged[key]?.members += n.members
        }
        for key in mergedOrder {
            guard let c = merged[key] else { continue }
            // Joins the assistant's print of the same name.
            if let i = out.firstIndex(where: { identity($0.name) == key }) {
                out[i] = Cluster(name: out[i].name, members: out[i].members + c.members, byAssistant: true)
                continue
            }
            guard c.members.count >= 2 else { continue }
            out.append(Cluster(name: c.name, members: c.members))
        }

        return out
    }


    /// Paths in copy order: by birth, then by name.
    nonisolated static func order(_ rels: [String], births: [String: Double]) -> [String] {
        rels.sorted { a, b in
            switch (births[a], births[b]) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.localizedStandardCompare(b) == .orderedAscending
            }
        }
    }

    nonisolated static func commonPrefix(_ a: [String], _ b: [String]) -> [String] {
        var n = 0
        while n < min(a.count, b.count), a[n] == b[n] { n += 1 }
        return Array(a.prefix(n))
    }

    /// One run of neighbours sharing `prefix`, named — split by its next
    /// word when the shared word is one word and what follows it names
    /// several prints (`KING-Saud-…`, `KING-Fahd-…`: one print per king).
    private nonisolated static func named(_ run: [(rel: String, read: Read)], prefix: [String])
        -> [(canon: String, name: String, members: [String])] {
        if run.count == 1 {
            let r = run[0].read
            let words = trimmed(r.tokens)
            return [(canon(words), name(r, words: words.count), [run[0].rel])]
        }
        let shared = core(prefix)
        if shared.count == 1, prefix.count == 1 {
            let next = run.map { $0.read.tokens.count > 1 ? $0.read.tokens[1] : "" }
            var counts: [String: Int] = [:]
            for n in next { counts[n, default: 0] += 1 }
            let paired = next.filter { (counts[$0] ?? 0) >= 2 }.count
            if next.allSatisfy(isStrong), counts.count >= 2, paired * 2 >= run.count {
                var groups: [String: [(rel: String, read: Read)]] = [:]
                var seen: [String] = []
                for (i, n) in next.enumerated() {
                    if groups[n] == nil { seen.append(n) }
                    groups[n, default: []].append(run[i])
                }
                return seen.map { n in
                    let members = groups[n]!
                    var p = members[0].read.tokens
                    for m in members.dropFirst() { p = commonPrefix(p, m.read.tokens) }
                    let words = members.count == 1 ? Array(p.prefix(2)) : trimmed(p)
                    return (canon(words), name(members[0].read, words: words.count), members.map(\.rel))
                }
            }
        }
        let words = trimmed(prefix)
        return [(canon(words), name(run[0].read, words: words.count), run.map(\.rel))]
    }

    // MARK: - Pictures: attached only when CERTAIN, otherwise offered

    /// A picture the sort is not sure of, offered in "Sort linked folders…"
    /// under "Pictures to check" — never put on by itself.
    struct Suggestion: Sendable, Equatable, Hashable {
        enum Target: Sendable, Equatable, Hashable {
            /// A print, by its name (a loose print) or its key.
            case print(String)
            /// One model, by its path below the linked folder.
            case model(String)
        }
        enum Reason: String, Sendable, Equatable, Hashable {
            /// Named exactly for it, but another print could be meant, or a
            /// named model lies between them in the copy order.
            case unsure
            /// Shares the print's name with more after it (`mochi front.jpg`).
            case named
            /// Shares only a word of the print's name.
            case subject
            /// Named by a number, beside the print in the copy order.
            case numbered
            /// The shop's assistant put it with the print.
            case assistant
        }
        let image: String
        let target: Target
        let reason: Reason
        /// Ticked to start with: one strong candidate. Anything ambiguous
        /// waits for the shop.
        let ticked: Bool
    }

    /// The loose files sorted: the prints, and the pictures.
    struct Result: Sendable, Equatable {
        var clusters: [Cluster] = []
        /// A model in no print with a picture CERTAINLY its own (`totoro.stl`
        /// + `totoro.jpg`, nothing else called totoro-anything), by path.
        var singles: [String: [String]] = [:]
        /// A print's member with a picture certainly its own, by model path.
        var own: [String: String] = [:]
        /// Pictures to check.
        var suggestions: [Suggestion] = []
        /// Pictures that went to nobody, not even as a suggestion.
        var unattached: [String] = []
    }

    /// The loose models AND pictures of one linked folder: the prints, then
    /// the pictures (`attach`).
    ///
    /// `assistant` holds what the shop's assistant said for models and
    /// pictures alike; a picture it placed is only ever a suggestion.
    nonisolated static func sort(models: [String], images: [String] = [], births: [String: Double] = [:],
                                 assistant: [String: String] = [:]) -> Result {
        let modelSet = Set(models)
        let forModels = assistant.filter { modelSet.contains($0.key) }
        var result = Result(clusters: prints(models: models, births: births, assistant: forModels))
        attach(&result, models: models, images: images, births: births,
               assistant: assistant.filter { !modelSet.contains($0.key) })
        return result
    }

    /// What a file's name says, for matching a picture to a model: the words
    /// `read` keeps, or — for a name of only part words — all of them.
    nonisolated static func stem(_ fileName: String) -> [String] {
        if let r = read(fileName) { return r.tokens }
        return tokenize(stripped(fileName)).map(\.0).filter { !isNoise($0) }
    }

    /// Whether one name runs on from the other (`totoro` and `totoroA`).
    nonisolated static func related(_ a: [String], _ b: [String]) -> Bool {
        a != b && (a.starts(with: b) || b.starts(with: a))
    }

    /// ── CERTAIN, OR OFFERED (Oct 2026) ────────────────────────────────────
    ///
    /// The shop asked for the RIGHT picture, not a likely one: the Drive
    /// holds several Luffy prints, `totoroA` and `totoroB_smile`, a bust and
    /// a figure of one man. A picture goes on by itself only when ALL hold:
    ///
    ///   (a) its name, read the way a model's is, EQUALS the print's (or the
    ///       one model's) — a shared word is not enough;
    ///   (b) nothing else at the top of the folder could equally be meant: no
    ///       other print or model whose name runs on from it or into it
    ///       (`totoro.jpg` beside `totoroA` and `totoro-medium` is unsure). A
    ///       print's own parts (`Charmander_tooth3`) do not count against it;
    ///   (c) no unrelated named model lies between it and the print in the
    ///       copy order.
    ///
    /// Everything weaker — unsure, a name with more after it, a shared word, a
    /// number beside the print, the assistant's word — is a `Suggestion`.
    private nonisolated static func attach(_ result: inout Result, models: [String], images: [String],
                                           births: [String: Double], assistant: [String: String]) {
        guard !images.isEmpty else { return }
        let clusters = result.clusters
        let names = clusters.map { trimmed(tokenize($0.name).map(\.0)).filter { !isNoise($0) } }
        var clusterOf: [String: Int] = [:]
        for (i, c) in clusters.enumerated() { for m in c.members { clusterOf[m] = i } }
        var stems: [String: [String]] = [:]
        for m in models { stems[m] = stem((m as NSString).lastPathComponent) }
        let named = Set(models.filter { read(($0 as NSString).lastPathComponent) != nil })
        let all = order(models + images, births: births)
        let isModel = Set(models)
        var position: [String: Int] = [:]
        for (i, r) in all.enumerated() { position[r] = i }

        /// A member that is the print's own part: its name is the print's
        /// with only part words and numbers after it.
        func isPart(_ m: String, of words: [String]) -> Bool {
            guard let s = stems[m], s.starts(with: words) else { return false }
            return s.dropFirst(words.count).allSatisfy {
                partWords.contains($0) || isNumber($0) || isMeasure($0) || isVersion($0)
            }
        }
        /// (b): something else the picture could equally mean.
        func competing(_ words: [String], target: Set<String>) -> Bool {
            for m in models where !target.contains(m) || !isPart(m, of: words) {
                guard let s = stems[m], related(s, words) else { continue }
                if target.contains(m), isPart(m, of: words) { continue }
                return true
            }
            for (i, n) in names.enumerated() where related(n, words) {
                // The target print's own name is no rival.
                if target.contains(where: { clusterOf[$0] == i }) { continue }
                return true
            }
            return false
        }
        /// (c): no unrelated named model between the picture and the target.
        func inRun(_ image: String, _ target: Set<String>) -> Bool {
            guard let at = position[image] else { return false }
            let spots = target.compactMap { position[$0] }
            guard let nearest = spots.min(by: { abs($0 - at) < abs($1 - at) }) else { return false }
            let range = nearest < at ? (nearest + 1)..<at : (at + 1)..<nearest
            return !range.contains { i in
                let r = all[i]
                return isModel.contains(r) && named.contains(r) && !target.contains(r)
            }
        }
        func suggest(_ image: String, _ target: Suggestion.Target, _ reason: Suggestion.Reason, ticked: Bool) {
            result.suggestions.append(Suggestion(image: image, target: target, reason: reason, ticked: ticked))
        }

        var placed = Set<String>()
        for image in order(images, births: births) {
            let file = (image as NSString).lastPathComponent
            if isAnonymousPicture(file) {
                // A number, where the copy order ties it to ONE print: inside
                // its run, or at its edge with no model on the far side.
                guard let at = position[image] else { continue }
                var before: String?, after: String?
                var i = at - 1
                while i >= 0 { if isModel.contains(all[i]) { before = all[i]; break }; i -= 1 }
                i = at + 1
                while i < all.count { if isModel.contains(all[i]) { after = all[i]; break }; i += 1 }
                let b = before.flatMap { clusterOf[$0] }, a = after.flatMap { clusterOf[$0] }
                let tied: Int? = {
                    if let b, let a { return a == b ? b : nil }
                    if let b, after == nil { return b }
                    if let a, before == nil { return a }
                    return nil
                }()
                if let c = tied {
                    suggest(image, .print(clusters[c].name), .numbered, ticked: false)
                    placed.insert(image)
                }
                continue
            }
            let words = stem(file)
            guard !words.isEmpty else { continue }
            // (a) Named exactly for a print, or for one model.
            let exactPrints = names.indices.filter { names[$0] == words }
            let exactModels = Set(models.filter { stems[$0] == words })
            var target: (kind: Suggestion.Target, members: Set<String>)?
            if exactPrints.count == 1 {
                let c = exactPrints[0]
                target = (.print(clusters[c].name), Set(clusters[c].members))
            } else if exactPrints.isEmpty, !exactModels.isEmpty {
                let owners = Set(exactModels.map { clusterOf[$0] })
                if owners.count == 1, let c = owners.first! {
                    // All the print's members are this name: the print's.
                    target = exactModels.count == clusters[c].members.count
                        ? (.print(clusters[c].name), Set(clusters[c].members))
                        : (.model(exactModels.sorted().first!), exactModels)
                } else if owners == [nil], exactModels.count == 1 {
                    target = (.model(exactModels.first!), exactModels)
                }
            }
            if let t = target {
                let sure = !competing(words, target: t.members) && inRun(image, t.members)
                if sure {
                    switch t.kind {
                    case .print(let name):
                        if let c = clusters.firstIndex(where: { $0.name == name }) {
                            result.clusters[c].pictures.append(image)
                        }
                    case .model(let m):
                        if clusterOf[m] != nil {
                            for each in t.members where result.own[each] == nil { result.own[each] = image }
                        } else {
                            result.singles[m, default: []].append(image)
                        }
                    }
                } else {
                    suggest(image, t.kind, .unsure, ticked: false)
                }
                placed.insert(image)
                continue
            }
            // Weaker: a print's name with more after it, or one shared word.
            var offers: [(Suggestion.Target, Suggestion.Reason)] = []
            for (c, n) in names.enumerated() where !n.isEmpty {
                if words.starts(with: n), isDistinctive(core(n)) {
                    offers.append((.print(clusters[c].name), .named))
                } else if words.contains(where: { isStrong($0) && n.contains($0) }) {
                    offers.append((.print(clusters[c].name), .subject))
                }
            }
            if offers.isEmpty {
                // One model in no print sharing a strong word.
                let lone = models.filter { clusterOf[$0] == nil && named.contains($0)
                    && (stems[$0] ?? []).contains { w in isStrong(w) && words.contains(w) } }
                if lone.count == 1 { offers.append((.model(lone[0]), .subject)) }
                else { for m in lone.prefix(3) { offers.append((.model(m), .subject)) } }
            }
            let one = offers.count == 1 && offers[0].1 == .named
            for (t, r) in offers.prefix(3) { suggest(image, t, r, ticked: one) }
            if !offers.isEmpty { placed.insert(image) }
        }
        // The shop's assistant: only ever an offer.
        for image in order(images, births: births) where !placed.contains(image) {
            guard let raw = assistant[image], let said = PrintSort.assistantName(raw) else { continue }
            let key = identity(shown(said))
            if let c = clusters.firstIndex(where: { identity($0.name) == key }) {
                suggest(image, .print(clusters[c].name), .assistant, ticked: false)
                placed.insert(image)
            }
        }
        result.unattached = images.filter { !placed.contains($0) }
    }
}
