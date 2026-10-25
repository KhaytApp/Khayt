import CryptoKit
import Foundation

/// A compressed file (ZIP, RAR, 7-Zip, tar) in a linked folder, shown in the
/// library AS A FOLDER — the models inside it as tiles, without the shop
/// unpacking anything. Meshory does this; a model site hands a pack over as a
/// zip, and a shop that keeps its downloads as they came had a library with a
/// hole wherever a pack sat.
///
/// ── WHAT IS DECIDED HERE, AND WHAT IS NOT ────────────────────────────────
///
/// The RULES, which the phone and the tests need without a disk: which names
/// are archives, which member paths are safe, which members are models, when
/// an archive is a bomb or locked, how a member is keyed in the book and in
/// the extraction cache, and what the cache lets go of first. The Mac lists
/// and extracts (`ArchiveMembers` in the app); nothing here reads a byte.
///
/// ── A STRANGER'S ARCHIVE ─────────────────────────────────────────────────
///
/// A pack is a stranger's bytes even when the shop downloaded it, so a member
/// name is never a place to write: `../../Library/LaunchAgents/x.plist`, an
/// absolute `/etc/…`, a `C:\…` and a symlink are refused (`safePath`), and the
/// app extracts only to a cache path it computes from `cacheKey` — never to
/// the member's own path. One unsafe name refuses the WHOLE archive, as
/// `lib/upload-scan.js` refuses a traversal upload: an archive that tries it
/// once is not trusted with the rest.
public enum ArchiveFolder {

    /// The archive kinds, by the ending of a file's name. `.tar.gz` and its
    /// cousins before `.gz`-less endings, so a `pack.tar.gz` is a tar.
    static let endings: [(suffix: String, kind: String)] = [
        (".tar.gz", "tgz"), (".tar.bz2", "tbz"), (".tar.xz", "txz"),
        (".tgz", "tgz"), (".tbz2", "tbz"), (".tbz", "tbz"), (".txz", "txz"),
        (".zip", "zip"), (".rar", "rar"), (".7z", "7z"), (".tar", "tar"),
    ]

    /// The archive kind a file's name says, or nil when it is not one.
    /// A name that is only the ending (`.zip`) is a hidden file, not a pack.
    public static func kind(of name: String) -> String? {
        let lower = name.lowercased()
        for e in endings where lower.hasSuffix(e.suffix) && lower.count > e.suffix.count { return e.kind }
        return nil
    }

    /// The archive's name without its ending — `Dragon Pack.tar.gz` is
    /// `Dragon Pack` — which is what its folder is called.
    public static func baseName(of name: String) -> String {
        let lower = name.lowercased()
        for e in endings where lower.hasSuffix(e.suffix) && lower.count > e.suffix.count {
            return String(name.dropLast(e.suffix.count))
        }
        return name
    }

    // MARK: - Members

    public enum EntryType: String, Sendable, Equatable {
        case file, directory, link, other
    }

    /// One member, as the archive's own listing describes it.
    public struct Member: Sendable, Equatable {
        /// The name EXACTLY as the archive lists it — what extraction asks
        /// for. Never used as a place to write.
        public var path: String
        /// Uncompressed size, when the listing says (a zip and a tar always
        /// do; a member that will not say is capped as it extracts).
        public var size: Int?
        public var type: EntryType
        public var encrypted: Bool

        public init(path: String, size: Int?, type: EntryType = .file, encrypted: Bool = false) {
            self.path = path; self.size = size; self.type = type; self.encrypted = encrypted
        }

        /// The path, made safe — nil when it is not (see `safePath`).
        public var safe: String? { ArchiveFolder.safePath(path) }
        /// The member's own file name.
        public var leaf: String { (safe ?? path).split(separator: "/").last.map(String.init) ?? path }
        /// The member's extension, lowercased.
        public var ext: String { (leaf as NSString).pathExtension.lowercased() }
        /// The folders inside the archive the member sits in.
        public var folders: [String] { (safe ?? "").split(separator: "/").dropLast().map(String.init) }
    }

    /// A member path with its harmless spellings undone — `./`, a doubled
    /// `/`, a Windows `\` — or nil when it is not safe to treat as a path
    /// inside the archive at all: absolute, a drive letter, any `..`, a
    /// control character, or nothing left.
    public static func safePath(_ raw: String) -> String? {
        guard !raw.isEmpty, !raw.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            return nil
        }
        let slashed = raw.replacingOccurrences(of: "\\", with: "/")
        if slashed.hasPrefix("/") || slashed.hasPrefix("~") { return nil }
        // `C:` at the start, or anywhere a Windows tool put one.
        if slashed.split(separator: "/").contains(where: { $0.count == 2 && $0.hasSuffix(":") }) { return nil }
        var parts: [Substring] = []
        for part in slashed.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { return nil }
            parts.append(part)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// The archive's own top folder — `./`, `.` — which names nothing.
    public static func isRoot(_ raw: String) -> Bool {
        !raw.isEmpty && raw.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true).allSatisfy { $0 == "." }
    }

    /// Packaging, not models: a Finder resource fork, the `__MACOSX` folder
    /// a Mac zip carries, a hidden file.
    public static func isJunk(_ safe: String) -> Bool {
        let parts = safe.split(separator: "/")
        if parts.contains(where: { $0 == "__MACOSX" }) { return true }
        return parts.last.map { $0.hasPrefix(".") } ?? true
    }

    // MARK: - The verdict

    /// What an archive may be before it is not opened.
    public struct Limits: Sendable, Equatable {
        /// Entries listed at all, models or not.
        public var maxEntries = 20_000
        /// Model members — each one becomes a record.
        public var maxModels = 2_000
        /// One member: the library's read budget, as for any model file.
        public var memberBytes = 1 << 30
        /// Every model member together, as the listing declares it.
        public var totalBytes = 8 << 30
        /// How far an archive may expand: DEFLATE cannot do better than about
        /// 1,032 to 1, so past this the listing is lying.
        public var maxRatio = 1_100

        public init() {}
    }

    public enum Verdict: Sendable, Equatable {
        /// The model members to show, in the archive's order.
        case open([Member])
        /// The model members are encrypted: shown as locked, never extracted
        /// and never asked for a password.
        case locked([Member])
        /// Not opened, with the shared rule's word for why
        /// (`unsafe-path`, `too-many-parts`, `expands-too-far`, `too-large`).
        case refused(String)
        /// Nothing in it is a model.
        case noModels
    }

    /// Judge an archive from its listing.
    ///
    /// - Parameters:
    ///   - members: every entry the listing gave.
    ///   - archiveBytes: the archive's size on disk, for the expansion ratio.
    ///   - modelKinds: the extensions the library files (`LibraryImport.kinds`).
    public static func judge(_ members: [Member], archiveBytes: Int, modelKinds: Set<String>,
                             limits: Limits = Limits()) -> Verdict {
        guard members.count <= limits.maxEntries else { return .refused("too-many-parts") }
        // The archive's own top (`./`, which bsdtar writes first) is no member.
        let members = members.filter { !isRoot($0.path) }
        // ONE unsafe name refuses the archive, whatever the member is.
        if members.contains(where: { $0.safe == nil }) { return .refused("unsafe-path") }
        let models = members.filter { m in
            guard m.type == .file, let safe = m.safe, !isJunk(safe) else { return false }
            return modelKinds.contains(m.ext)
        }
        guard !models.isEmpty else { return .noModels }
        guard models.count <= limits.maxModels else { return .refused("too-many-parts") }
        // A member past the read budget is left out — too big to read is not
        // a bomb, and the rest of the pack is still the shop's.
        let readable = models.filter { ($0.size ?? 0) <= limits.memberBytes }
        guard !readable.isEmpty else { return .refused("too-large") }
        let total = readable.reduce(0) { $0 &+ max(0, $1.size ?? 0) }
        guard total <= limits.totalBytes else { return .refused("too-large") }
        if archiveBytes > 0, total > archiveBytes &* limits.maxRatio &+ (1 << 20) {
            return .refused("expands-too-far")
        }
        if readable.contains(where: \.encrypted) { return .locked(readable) }
        return .open(readable)
    }

    // MARK: - Keys

    /// How a member is named in the book — beside paths, in the linked scan's
    /// "already indexed" and "deleted, do not take again" lists. `!/` as a
    /// jar URL writes it: no file path the scan meets ends in an archive's
    /// name followed by `!/`.
    public static func memberKey(archive: String, member: String) -> String {
        archive + "!/" + member
    }

    /// The extraction cache's key for one member: the ARCHIVE's bytes (its
    /// SHA-256) and the member's path. A changed archive is a new key, so a
    /// stale extraction is never handed out as the new member.
    public static func cacheKey(archiveHash: String, member: String) -> String {
        let digest = SHA256.hash(data: Data((archiveHash + "\n" + member).utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The file name a member is extracted under, inside its key's folder:
    /// its own leaf, made a plain name. Never a path.
    public static func cacheLeaf(_ member: Member) -> String {
        var leaf = member.leaf.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        while leaf.hasPrefix(".") { leaf.removeFirst() }
        if leaf.isEmpty { leaf = "model" }
        if leaf.utf8.count > 160 {
            let ext = (leaf as NSString).pathExtension
            leaf = String(leaf.prefix(100)) + (ext.isEmpty ? "" : "." + ext)
        }
        return leaf
    }

    // MARK: - The cache

    /// One extracted member, as the cache folder holds it.
    public struct CacheEntry: Sendable, Equatable {
        public var key: String
        public var bytes: Int
        /// When it was last handed out — seconds, any epoch.
        public var usedAt: Double
        public init(key: String, bytes: Int, usedAt: Double) {
            self.key = key; self.bytes = bytes; self.usedAt = usedAt
        }
    }

    /// What the cache lets go of to come back under `cap`: the least recently
    /// used first, never anything in `keep` (what is being extracted or read
    /// right now). The cache is a copy of bytes the archive still holds, so
    /// letting go loses nothing.
    public static func evictions(_ entries: [CacheEntry], cap: Int, keep: Set<String> = []) -> [String] {
        var total = entries.reduce(0) { $0 &+ max(0, $1.bytes) }
        guard total > cap else { return [] }
        var out: [String] = []
        for e in entries.sorted(by: { $0.usedAt < $1.usedAt || ($0.usedAt == $1.usedAt && $0.key < $1.key) }) {
            guard total > cap else { break }
            if keep.contains(e.key) { continue }
            out.append(e.key)
            total -= max(0, e.bytes)
        }
        return out
    }

    // MARK: - bsdtar's listing

    /// A name as `bsdtar -t` prints it, back to the bytes it stands for:
    /// libarchive escapes a backslash as `\\`, the usual controls as `\n`,
    /// `\t` and the like, and anything else unprintable as `\ooo`.
    public static func unescapeListing(_ s: String) -> String {
        var out: [UInt8] = []
        let b = Array(s.utf8)
        var i = 0
        while i < b.count {
            guard b[i] == 0x5C, i + 1 < b.count else { out.append(b[i]); i += 1; continue }
            let c = b[i + 1]
            switch c {
            case 0x5C: out.append(0x5C); i += 2
            case UInt8(ascii: "a"): out.append(0x07); i += 2
            case UInt8(ascii: "b"): out.append(0x08); i += 2
            case UInt8(ascii: "f"): out.append(0x0C); i += 2
            case UInt8(ascii: "n"): out.append(0x0A); i += 2
            case UInt8(ascii: "r"): out.append(0x0D); i += 2
            case UInt8(ascii: "t"): out.append(0x09); i += 2
            case UInt8(ascii: "v"): out.append(0x0B); i += 2
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var v = 0, n = 0
                while n < 3, i + 1 + n < b.count, (0x30...0x37).contains(b[i + 1 + n]) {
                    v = v * 8 + Int(b[i + 1 + n] - 0x30); n += 1
                }
                out.append(UInt8(truncatingIfNeeded: v)); i += 1 + n
            default: out.append(b[i]); i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// A member name as an EXACT `bsdtar` pattern: its wildcard characters
    /// escaped, so `*.stl` asks for the member called `*.stl` and not for
    /// every model in the pack.
    public static func exactPattern(_ name: String) -> String {
        var out = ""
        for ch in name {
            if "[]*?\\".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// `bsdtar -t` (names, one a line) and `bsdtar -tv --numeric-owner` (the
    /// same entries with their mode and size) read together into members.
    /// Nil when the two do not line up — a name holding a newline, a listing
    /// cut short — because a member read against the wrong line is a member
    /// extracted under the wrong name.
    public static func members(names: String, long: String) -> [Member]? {
        let n = names.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let l = long.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard n.count == l.count else { return nil }
        var out: [Member] = []
        for (name, line) in zip(n, l) {
            guard let mode = line.first else { return nil }
            let type: EntryType = switch mode {
            case "-": .file
            case "d": .directory
            case "l", "h": .link
            default: .other
            }
            // The long line ends with the name — and a link's with
            // ` -> target` after it, searched from the front so a target
            // that repeats the name is not taken for it.
            let at: Range<String.Index>?
            if type == .link {
                at = line.range(of: " " + name + " -> ") ?? line.range(of: " " + name + " link to ")
            } else {
                at = line.hasSuffix(" " + name) ? line.range(of: " " + name, options: .backwards) : nil
            }
            guard let at else { return nil }
            let head = line[..<at.lowerBound].split(separator: " ", omittingEmptySubsequences: true)
            guard head.count >= 5 else { return nil }
            out.append(Member(path: unescapeListing(name), size: Int(head[4]), type: type))
        }
        return out
    }

    /// libarchive's complaint about a password: what an encrypted RAR or
    /// 7-Zip says when no passphrase opens it.
    public static func saysLocked(_ stderr: String) -> Bool {
        let s = stderr.lowercased()
        return s.contains("passphrase") || s.contains("encrypt") || s.contains("password")
    }
}
