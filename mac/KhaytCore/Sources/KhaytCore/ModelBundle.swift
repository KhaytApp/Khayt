import CryptoKit
import Foundation
import KhaytWebSave

/// A `.khaytbundle`: one library model, packed to hand to someone else — the
/// model file(s), its pictures, its tested print setups and a manifest of what
/// the shop knows about it. A plain zip; Khayt's own writer packs it and its
/// own reader opens it.
///
/// ── WHAT GOES IN THE MANIFEST: AN ALLOWLIST ───────────────────────────────
///
/// A record carries things that must never leave the shop: who a model is on
/// the Print next list FOR (a customer's name), a bought licence's code, the
/// path it sits at on this Mac, its sync and archive bookkeeping, what it cost
/// in consumables. So nothing is copied unless it is named in `exported`; a
/// field added to records tomorrow stays home until somebody decides it may
/// travel. A price goes in only when the shop ticks "include price".
///
/// And the allowlist goes all the way down (beta.8 review): a structured
/// field is shaped on the way OUT by the same per-field rule as on the way in
/// (`checkedFields`), so a print setup's free-text notes and its machine's
/// internal id, a slice's filament cost and anything a record grows inside
/// `parsed` tomorrow stay home too. The group — a folder path, often a
/// customer's name ("Customers/Noura") — travels only when the shop ticks it.
///
/// ── WHAT COMES BACK IN: THE SAME LIST, AND NOTHING ELSE ──────────────────
///
/// A bundle is a file from outside. Its manifest is read through
/// `importable` (the same names, minus the ones the import itself works out,
/// like the hash and the key), each value checked for type and cut to a
/// length, so a crafted manifest cannot set an id, a path or an archive
/// member. Member names are checked before anything is extracted (`verdict`):
/// no absolute path, no `..`, no backslash or control character, no symlink,
/// nothing encrypted, nothing outside the bundle's own folders, and sizes
/// capped by what the zip SAYS before a byte is inflated (the reader enforces
/// the inflated size again as it goes).
public enum ModelBundle {

    public static let format = "khayt-model-bundle"
    public static let version = 1
    public static let fileExtension = "khaytbundle"
    public static let manifestName = "manifest.json"

    /// Where each kind of member lives inside the bundle.
    public enum Folder: String, Sendable, CaseIterable {
        case model, pictures, settings
    }

    // MARK: - Caps

    /// The bundle file itself — the local import budget (`ArchiveImport`).
    public static let maxBundleBytes = 1 << 30
    /// One member, inflated.
    public static let maxMemberBytes = 512 << 20
    /// Every member together, inflated.
    public static let maxTotalBytes = 1 << 30
    public static let maxMembers = 64
    public static let maxManifestBytes = 1 << 20

    // MARK: - Fields

    /// Record fields that travel, as they are.
    public static let exported: [String] = [
        "name", "originalName", "material", "category", "tags", "group", "testedNotes",
        "source", "licence", "licenceUrl", "parsed", "colors", "swapCount",
        "geometryKey", "geometryReader", "contentHash", "setups",
        "sourceUrl", "sourceSite", "sourceLicenceText", "sourceNote",
    ]

    /// What an import takes back: `exported` minus what the import measures
    /// for itself from the bytes (hash, key, reader) — a manifest's word on
    /// those is not evidence.
    public static let importable: Set<String> = Set(exported).subtracting(["contentHash", "geometryKey", "geometryReader"])

    /// Fields that must never be in a bundle — checked by the tests against
    /// `exported`, so adding one there by mistake fails loudly.
    public static let neverExported: Set<String> = [
        "id", "printNextAt", "printNextFor", "licenceCode", "externalPath", "archiveMember", "archiveHash",
        "archiveLocked", "archiveGone", "archiveBytes", "archiveModified", "consumables", "timesPrinted",
        "lastPrinted", "favorite", "rev", "updatedAt", "createdAt", "userPhoto", "thumbFile",
        "stackId", "stackTop", "folder", "activeVersionId", "versions", "slicerProfileId", "printRisk",
        "bundleFigures", "sourceFromBundle",
    ]

    /// The most a manifest may claim: a year of printing, a hundred kilos.
    public static let maxMinutes: Double = 525_600
    public static let maxGrams: Double = 100_000
    /// A group path: this many folders deep, each this long.
    public static let maxGroupDepth = 8
    public static let maxGroupPart = 80

    /// One file in the bundle.
    public struct Member: Sendable, Equatable {
        public var path: String
        public var role: Folder
        public var size: Int
        public init(path: String, role: Folder, size: Int) {
            self.path = path; self.role = role; self.size = size
        }
    }

    /// The manifest for `record`. `group` is the record's group as the app
    /// reads it (`folder` before `group`), given only when the shop ticked
    /// it; `price` goes in only when given, and with it the slice's filament
    /// cost. `from` is this shop's mark for the model (`mark`), so an import
    /// back into the same shop can tell its own bundle from a stranger's.
    public static func manifest(record: [String: JSONValue], group: String?, members: [Member],
                                price: (amount: Double, currency: String)?, exportedAt: String,
                                app: String, from: String? = nil) -> JSONValue {
        var out = checkedFields(record, keys: Set(exported).subtracting(["group"]), includeCost: price != nil)
        if let group, let path = groupPath(group) { out["group"] = .string(path) }
        var top: [String: JSONValue] = [
            "format": .string(format), "version": .number(Double(version)),
            "exportedAt": .string(exportedAt), "app": .string(app), "record": .object(out),
            "files": .array(members.map { m in
                .object(["path": .string(m.path), "role": .string(m.role.rawValue), "size": .number(Double(m.size))])
            }),
        ]
        if let from, !from.isEmpty { top["from"] = .string(String(from.prefix(64))) }
        if let price, price.amount.isFinite, price.amount >= 0 {
            top["price"] = .object(["amount": .number(price.amount), "currency": .string(String(price.currency.prefix(8)))])
        }
        return .object(top)
    }

    /// A name for a member: the file's own leaf, made safe, under its folder.
    /// Two files with one name get ` 2`, ` 3` before the extension.
    public static func memberPath(_ leaf: String, in folder: Folder, taken: inout Set<String>) -> String {
        var name = safeLeaf(leaf)
        if name.isEmpty { name = "file" }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var path = folder.rawValue + "/" + name
        var n = 2
        while taken.contains(path.lowercased()) {
            path = folder.rawValue + "/" + base + " \(n)" + (ext.isEmpty ? "" : "." + ext)
            n += 1
        }
        taken.insert(path.lowercased())
        return path
    }

    /// This shop's mark for one model's bytes: a keyed hash of the content
    /// hash under a secret that never leaves the Mac, so a bundle says "this
    /// shop made me" to this shop alone and links nothing for anybody else.
    public static func mark(secret: String, contentHash: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let code = HMAC<SHA256>.authenticationCode(for: Data(contentHash.utf8), using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    /// A member name as APFS compares it: NFC, case folded — so two names a
    /// Mac would file as one are one name here too.
    public static func comparable(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
    }

    /// Text as kept from outside: control (Cc) and format (Cf) characters
    /// out, so a name cannot hide a direction override or a zero-width
    /// letter, then NFC.
    public static func plain(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter {
            let c = $0.properties.generalCategory
            return c != .control && c != .format
        })).precomposedStringWithCanonicalMapping
    }

    /// A group path made tidy: plain parts, no empty, `.` or `..` part, no
    /// leading dot, at most `maxGroupDepth` deep. Nil when nothing is left.
    public static func groupPath(_ raw: String) -> String? {
        let parts = plain(raw).split(whereSeparator: { $0 == "/" || $0 == "\\" }).compactMap { p -> String? in
            var t = String(p).trimmingCharacters(in: .whitespacesAndNewlines)
            while t.hasPrefix(".") { t.removeFirst() }
            t = String(t.prefix(maxGroupPart)).trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let kept = parts.prefix(maxGroupDepth)
        return kept.isEmpty ? nil : kept.joined(separator: "/")
    }

    /// A leaf as kept: the last path part only, control characters, slashes
    /// and backslashes out, leading dots off, cut at 120 characters, NFC.
    public static func safeLeaf(_ raw: String) -> String {
        let last = raw.precomposedStringWithCanonicalMapping
            .split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let clean = String(String.UnicodeScalarView(last.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0 != ":"
        }))
        var t = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix(".") { t.removeFirst() }
        return String(t.prefix(120))
    }

    // MARK: - Opening one

    public enum Refusal: Error, Equatable, Sendable {
        case notABundle
        case tooBig
        case tooMany
        case badName(String)
        case encrypted(String)
        case noManifest
        case badManifest
        case noModel
    }

    /// Is this member name safe to extract? Relative, inside one of the
    /// bundle's folders (or the manifest), no `..` part, no backslash, no
    /// control character, no drive letter.
    public static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 512, !name.hasPrefix("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return false }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty || $0.contains(":") }) else { return false }
        if parts == [manifestName] { return true }
        guard parts.count == 2, Folder(rawValue: parts[0]) != nil else { return false }
        return safeLeaf(parts[1]) == parts[1]
    }

    /// Judge a bundle's listing before anything is read out of it. Directory
    /// entries are skipped; everything else must pass.
    public static func verdict(_ entries: [Zip.Entry], bundleBytes: Int) -> Result<[Zip.Entry], Refusal> {
        guard bundleBytes <= maxBundleBytes else { return .failure(.tooBig) }
        let files = entries.filter { !$0.isDirectory }
        guard files.count <= maxMembers else { return .failure(.tooMany) }
        var total = 0
        var seen: Set<String> = []
        for e in files {
            guard isSafeName(e.name), !e.isSymlink, seen.insert(comparable(e.name)).inserted
            else { return .failure(.badName(e.name)) }
            guard !e.isEncrypted else { return .failure(.encrypted(e.name)) }
            guard e.size >= 0, e.size <= (e.name == manifestName ? maxManifestBytes : maxMemberBytes)
            else { return .failure(.tooBig) }
            total += e.size
            guard total <= maxTotalBytes else { return .failure(.tooBig) }
        }
        guard seen.contains(comparable(manifestName)) else { return .failure(.noManifest) }
        guard files.contains(where: { $0.name.hasPrefix(Folder.model.rawValue + "/") }) else { return .failure(.noModel) }
        return .success(files)
    }

    /// What an import reads from a manifest.
    public struct Opened: Sendable, Equatable {
        /// `importable` fields only, each checked (`checkedFields`).
        public var fields: [String: JSONValue]
        public var title: String?
        public var tags: [String]
        public var group: String?
        public var price: Double?
        public var currency: String?
        /// The exporting shop's mark (`mark`), when the bundle carried one.
        public var from: String? = nil
    }

    /// Read a manifest. Nil when it is not one of ours.
    public static func open(manifest data: Data) -> Opened? {
        guard data.count <= maxManifestBytes,
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let top) = value,
              case .string(let f)? = top["format"], f == format,
              case .object(let record)? = top["record"] else { return nil }
        let fields = checkedFields(record)
        var tags: [String] = []
        if case .array(let t)? = fields["tags"] { tags = t.compactMap { if case .string(let s) = $0 { s } else { nil } } }
        var title: String?
        if case .string(let s)? = fields["name"] { title = s }
        var group: String?
        if case .string(let s)? = fields["group"] { group = s }
        var price: Double?, currency: String?
        if case .object(let p)? = top["price"], case .number(let n)? = p["amount"], n.isFinite, n >= 0 {
            price = n
            if case .string(let c)? = p["currency"] { currency = String(c.prefix(8)) }
        }
        var from: String?
        if case .string(let f)? = top["from"], f.count <= 64 { from = f }
        return Opened(fields: fields, title: title, tags: tags, group: group, price: price, currency: currency,
                      from: from)
    }

    /// The manifest's fields put on a record the import just made: only where
    /// the record has nothing of its own — what the import measured from the
    /// bytes (the slice's figures, the colours) is evidence, the manifest is
    /// a note. The name, tags and group were given to the import itself.
    /// Returns the keys it set.
    ///
    /// A manifest's print time and grams are ANOTHER shop's slice, on its
    /// printer and profile, and a crafted bundle can say anything: they are
    /// never `parsed` (which the price paths read as measured). They go in as
    /// `bundleFigures`, capped and marked `estimate: "bundle"`.
    ///
    /// `ours`: the bundle carries this shop's own mark. A stranger's source
    /// and address are kept as notes, but marked `sourceFromBundle`, so the
    /// shop's own later save of that page from the browser is not filed into
    /// the bundle's record on the bundle's word (`WebSaveRecord.existing`).
    @discardableResult
    public static func fill(_ record: inout [String: JSONValue], from fields: [String: JSONValue],
                            ours: Bool = false) -> [String] {
        var set: [String] = []
        for key in fields.keys.sorted() where !["name", "tags", "group"].contains(key) {
            guard let value = fields[key] else { continue }
            if key == "parsed" {
                guard case .object(var figures) = value else { continue }
                if let have = record["bundleFigures"], !isBlank(have) { continue }
                figures["estimate"] = .string("bundle")
                record["bundleFigures"] = .object(figures)
                set.append("bundleFigures")
                continue
            }
            if let have = record[key], !isBlank(have) { continue }
            record[key] = value
            set.append(key)
        }
        if !ours, set.contains(where: { $0 == "source" || $0 == "sourceUrl" }) {
            record["sourceFromBundle"] = .bool(true)
            set.append("sourceFromBundle")
        }
        return set
    }

    /// Nothing of substance: null, an empty string, list or object, or a
    /// `parsed` whose figures are all null.
    static func isBlank(_ v: JSONValue) -> Bool {
        switch v {
        case .null: return true
        case .string(let s): return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .array(let a): return a.isEmpty
        case .object(let o): return o.values.allSatisfy(isBlank)
        default: return false
        }
    }

    /// `importable` fields (or `keys`), each of the type a record holds and
    /// cut to size: text to 4,000 characters (a name to 200) with control and
    /// format characters out, links only as https, tags and the group made
    /// tidy, lists to 50 items, objects passed through only for the
    /// structured fields (`parsed`, `colors`, `setups`) and only their named
    /// sub-keys, never as anything that names a path. The SAME shaping runs
    /// on the way out (`manifest`), so what a bundle can carry is what an
    /// import can take — a setup's notes and machine id never travel, and a
    /// slice's filament cost only when `includeCost` (the price is going too).
    public static func checkedFields(_ record: [String: JSONValue], keys: Set<String> = importable,
                                     includeCost: Bool = false) -> [String: JSONValue] {
        let texts: Set<String> = ["name", "originalName", "material", "category", "testedNotes", "source",
                                  "licence", "sourceSite", "sourceLicenceText", "sourceNote",
                                  "contentHash", "geometryKey", "geometryReader"]
        let links: Set<String> = ["licenceUrl", "sourceUrl"]
        func capped(_ v: JSONValue?, _ max: Double) -> JSONValue? {
            if case .number(let n)? = v, n.isFinite, n >= 0 { return .number(min(n, max)) }
            return nil
        }
        var out: [String: JSONValue] = [:]
        for key in keys {
            guard let v = record[key] else { continue }
            switch (key, v) {
            case (_, .string(let s)) where texts.contains(key):
                let cut = String(plain(s).prefix(key == "name" ? 200 : 4000)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !cut.isEmpty { out[key] = .string(cut) }
            case (_, .string(let s)) where links.contains(key):
                if let link = WebSave.https(s) { out[key] = .string(link) }
            case ("group", .string(let s)):
                if let path = groupPath(s) { out[key] = .string(path) }
            case ("tags", .array(let a)):
                let typed = a.compactMap { x -> JSONValue? in
                    guard case .string(let s) = x else { return nil }
                    return .string(String(plain(s).prefix(60)))
                }
                let t = Tags.normalise(.array(typed)).prefix(50).map(JSONValue.string)
                if !t.isEmpty { out[key] = .array(Array(t)) }
            case ("swapCount", .number(let n)) where n.isFinite && n >= 0:
                out[key] = .number(min(n, 10_000).rounded())
            case ("parsed", .object(let o)):
                var p: [String: JSONValue] = [:]
                if let m = capped(o["printTimeMins"], maxMinutes) { p["printTimeMins"] = m }
                if let g = capped(o["filamentGrams"], maxGrams) { p["filamentGrams"] = g }
                if includeCost, let c = capped(o["filamentCost"], 1_000_000) { p["filamentCost"] = c }
                for k in ["filamentType", "slicer"] { if case .string(let s)? = o[k] { p[k] = .string(String(plain(s).prefix(80))) } }
                if !p.isEmpty { out[key] = .object(p) }
            case ("colors", .array(let a)):
                let c = a.prefix(16).compactMap { x -> JSONValue? in
                    guard case .object(let o) = x else { return nil }
                    var c: [String: JSONValue] = [:]
                    if case .string(let h)? = o["hex"], h.count <= 9 { c["hex"] = .string(plain(h)) }
                    if let g = capped(o["grams"], maxGrams) { c["grams"] = g }
                    if case .string(let l)? = o["label"] { c["label"] = .string(String(plain(l).prefix(80))) }
                    return c.isEmpty ? nil : .object(c)
                }
                if !c.isEmpty { out[key] = .array(c) }
            case ("setups", .array(let a)):
                let s = a.prefix(20).compactMap { x -> JSONValue? in
                    guard case .object(let o) = x else { return nil }
                    var c: [String: JSONValue] = [:]
                    for k in ["id", "name", "machineName", "material", "colour", "status"] {
                        if case .string(let t)? = o[k] { c[k] = .string(String(plain(t).prefix(120))) }
                    }
                    for k in ["ok", "failed", "layerHeightMm", "nozzleMm"] {
                        if case .number(let n)? = o[k], n.isFinite, n >= 0 { c[k] = .number(min(n, 1_000_000)) }
                    }
                    return c.isEmpty ? nil : .object(c)
                }
                if !s.isEmpty { out[key] = .array(s) }
            default:
                continue
            }
        }
        return out
    }
}
