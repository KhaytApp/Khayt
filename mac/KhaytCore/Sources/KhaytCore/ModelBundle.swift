import Foundation

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
    ]

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
    /// reads it (`folder` before `group`); `price` goes in only when given.
    public static func manifest(record: [String: JSONValue], group: String?, members: [Member],
                                price: (amount: Double, currency: String)?, exportedAt: String,
                                app: String) -> JSONValue {
        var out: [String: JSONValue] = [:]
        for key in exported where key != "group" {
            if let v = record[key], v != .null { out[key] = v }
        }
        if let group, !group.isEmpty { out["group"] = .string(group) }
        var top: [String: JSONValue] = [
            "format": .string(format), "version": .number(Double(version)),
            "exportedAt": .string(exportedAt), "app": .string(app), "record": .object(out),
            "files": .array(members.map { m in
                .object(["path": .string(m.path), "role": .string(m.role.rawValue), "size": .number(Double(m.size))])
            }),
        ]
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

    /// A leaf as kept: the last path part only, control characters, slashes
    /// and backslashes out, leading dots off, cut at 120 characters.
    public static func safeLeaf(_ raw: String) -> String {
        let last = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
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
            guard isSafeName(e.name), !e.isSymlink, seen.insert(e.name.lowercased()).inserted
            else { return .failure(.badName(e.name)) }
            guard !e.isEncrypted else { return .failure(.encrypted(e.name)) }
            guard e.size >= 0, e.size <= (e.name == manifestName ? maxManifestBytes : maxMemberBytes)
            else { return .failure(.tooBig) }
            total += e.size
            guard total <= maxTotalBytes else { return .failure(.tooBig) }
        }
        guard seen.contains(manifestName) else { return .failure(.noManifest) }
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
        return Opened(fields: fields, title: title, tags: tags, group: group, price: price, currency: currency)
    }

    /// The manifest's fields put on a record the import just made: only where
    /// the record has nothing of its own — what the import measured from the
    /// bytes (the slice's figures, the colours) is evidence, the manifest is
    /// a note. The name, tags and group were given to the import itself.
    /// Returns the keys it set.
    @discardableResult
    public static func fill(_ record: inout [String: JSONValue], from fields: [String: JSONValue]) -> [String] {
        var set: [String] = []
        for key in fields.keys.sorted() where !["name", "tags", "group"].contains(key) {
            guard let value = fields[key] else { continue }
            if let have = record[key], !isBlank(have) { continue }
            record[key] = value
            set.append(key)
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

    /// `importable` fields, each of the type a record holds and cut to size:
    /// text to 4,000 characters (a name to 200), lists to 50 items, objects
    /// passed through only for the structured fields (`parsed`, `colors`,
    /// `setups`) and only as JSON values, never as anything that names a path.
    public static func checkedFields(_ record: [String: JSONValue]) -> [String: JSONValue] {
        let texts: Set<String> = ["name", "originalName", "material", "category", "group", "testedNotes", "source",
                                  "licence", "licenceUrl", "sourceUrl", "sourceSite", "sourceLicenceText", "sourceNote"]
        var out: [String: JSONValue] = [:]
        for key in importable {
            guard let v = record[key] else { continue }
            switch (key, v) {
            case (_, .string(let s)) where texts.contains(key):
                let cut = String(s.prefix(key == "name" ? 200 : 4000)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !cut.isEmpty { out[key] = .string(cut) }
            case ("tags", .array(let a)):
                let t = a.compactMap { x -> JSONValue? in
                    guard case .string(let s) = x else { return nil }
                    let c = String(s.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
                    return c.isEmpty ? nil : .string(c)
                }
                if !t.isEmpty { out[key] = .array(Array(t.prefix(50))) }
            case ("swapCount", .number(let n)) where n.isFinite && n >= 0:
                out[key] = .number(min(n, 10_000).rounded())
            case ("parsed", .object(let o)):
                var p: [String: JSONValue] = [:]
                for k in ["printTimeMins", "filamentGrams"] { if case .number(let n)? = o[k], n.isFinite, n >= 0 { p[k] = .number(n) } }
                for k in ["filamentType", "slicer"] { if case .string(let s)? = o[k] { p[k] = .string(String(s.prefix(80))) } }
                if !p.isEmpty { out[key] = .object(p) }
            case ("colors", .array(let a)):
                let c = a.prefix(16).compactMap { x -> JSONValue? in
                    guard case .object(let o) = x else { return nil }
                    var c: [String: JSONValue] = [:]
                    if case .string(let h)? = o["hex"], h.count <= 9 { c["hex"] = .string(h) }
                    if case .number(let g)? = o["grams"], g.isFinite, g >= 0 { c["grams"] = .number(g) }
                    if case .string(let l)? = o["label"] { c["label"] = .string(String(l.prefix(80))) }
                    return c.isEmpty ? nil : .object(c)
                }
                if !c.isEmpty { out[key] = .array(c) }
            case ("setups", .array(let a)):
                let s = a.prefix(20).compactMap { x -> JSONValue? in
                    guard case .object(let o) = x else { return nil }
                    var c: [String: JSONValue] = [:]
                    for k in ["id", "name", "machineName", "material", "colour", "status"] {
                        if case .string(let t)? = o[k] { c[k] = .string(String(t.prefix(120))) }
                    }
                    for k in ["ok", "failed", "layerHeightMm", "nozzleMm"] {
                        if case .number(let n)? = o[k], n.isFinite, n >= 0 { c[k] = .number(n) }
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
