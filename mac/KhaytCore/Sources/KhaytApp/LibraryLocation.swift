import Foundation
import KhaytCore

/// Where the shop's print files actually live.
///
/// A port of `lib/print-library-location.js`, and the only piece of shared logic
/// in this app that is written twice. `lib/` reaches it through
/// `require('path')`, so it cannot load in JavaScriptCore the way the money
/// modules do — the choice was a second implementation or a `path` polyfill
/// inside the engine, and a polyfill of `path.resolve` is itself a second
/// implementation, of something subtler.
///
/// So it is duplicated, and `LibraryLocationParityTests` runs the same inputs
/// through both and compares. If someone changes the rules in `lib/`, that test
/// fails here rather than a shop's thumbnails quietly going blank.
///
/// The rule that earns the test: **the library remembers everywhere it has
/// lived.** A shop that moves its models to a NAS, then moves again, still has
/// records pointing at the first custom folder. Drop the history and those files
/// stop being findable — not moved, not deleted, just invisible.
enum LibraryLocation {

    struct Roots: Equatable, Encodable {
        /// Where files are read and written now.
        let primary: String
        /// A second copy, written after every write and never read from. Nil
        /// when unset or the same as primary.
        let mirror: String?
        /// True when the shop has chosen a folder that is not the built-in vault.
        let isCustom: Bool
        /// Every folder this install considers part of its library, in search
        /// order: where it is now, the built-in vault, the mirror, then
        /// everywhere it used to be.
        let roots: [String]

        /// Written by hand so an absent mirror encodes as `null` rather than
        /// vanishing. Swift's synthesised conformance drops a nil optional, and
        /// the parity test would then be comparing a Swift value with no mirror
        /// key against a JS value with `mirror: null` — a difference in the
        /// encoder, reported as a difference in the rules.
        enum CodingKeys: String, CodingKey { case primary, mirror, isCustom, roots }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(primary, forKey: .primary)
            try c.encode(mirror, forKey: .mirror)
            try c.encode(isCustom, forKey: .isCustom)
            try c.encode(roots, forKey: .roots)
        }
    }

    /// `String(v == null ? '' : v).trim()` — JS stringifies a number here, so
    /// a root that arrived as one is not silently dropped.
    private static func str(_ value: JSONValue?) -> String {
        switch value {
        case .string(let s): return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case .number(let n):
            let whole = n.rounded() == n && n.magnitude < 1e15
            return (whole ? String(Int64(n)) : String(n)).trimmingCharacters(in: .whitespacesAndNewlines)
        case .bool(let b): return String(b)
        case .none, .null: return ""
        // An object or array stringifies to something no filesystem will match,
        // which is the JS behaviour and is harmless: it fails to resolve.
        default: return ""
        }
    }

    /// The built-in vault — where the library lived when it could only live here.
    static func defaultRoot(for build: StoreReader.Build) -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/\(build.rawValue)/print-files-vault")
            .path
    }

    /// `/` — the root of a volume path — is never a library folder.
    static func isDriveRoot(_ p: String) -> Bool {
        let s = p.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return false }
        return URL(fileURLWithPath: s).standardizedFileURL.path == "/"
    }

    /// @param settings `settings.printLibrary`
    static func resolveRoots(settings: JSONValue?, defaultRoot: String) -> Roots {
        var s: [String: JSONValue] = [:]
        if case .object(let dict)? = settings { s = dict }

        let base = str(.string(defaultRoot))
        // A drive root is never a library folder, wherever it came from (a
        // restore, a sync): as a root it would make the whole disk "inside
        // the library" — `isDriveRoot` in the other app, Sep 2026.
        let configured = isDriveRoot(str(s["root"])) ? "" : str(s["root"])
        let mirror = isDriveRoot(str(s["mirror"])) ? "" : str(s["mirror"])
        let primary = configured.isEmpty ? base : configured

        var past: [String] = []
        if case .array(let rows)? = s["history"] {
            past = rows.map { str($0) }.filter { !$0.isEmpty && !isDriveRoot($0) }
        }

        var roots: [String] = []
        for r in [primary, base, mirror] + past where !r.isEmpty && !roots.contains(r) {
            roots.append(r)
        }

        return Roots(
            primary: primary,
            mirror: (!mirror.isEmpty && mirror != primary) ? mirror : nil,
            isCustom: !configured.isEmpty && configured != base,
            roots: roots
        )
    }

    /// Where one record's files sit under a given root.
    ///
    /// Mirrors main.js's own id sanitising. Getting this wrong does not error —
    /// it looks in a folder that is not there and reports the model as missing.
    static func itemDirName(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        // JS is `split(/[\\/]/).pop()`, and an empty segment counts: a trailing
        // slash pops "" and falls through to "unsorted". Swift's split drops
        // empty subsequences by default and would pop the segment before it.
        let segments = trimmed.split(omittingEmptySubsequences: false,
                                     whereSeparator: { $0 == "/" || $0 == "\\" })
        let base = segments.last.map(String.init) ?? ""
        // `replace(/[^a-zA-Z0-9_-]/g, '_')` runs over UTF-16 code units, so a
        // character outside the BMP — one Swift Character, two code units —
        // becomes TWO underscores there. Mapping Characters here would write
        // one, and the app would look in a folder that does not exist.
        var out = String.UnicodeScalarView()
        for unit in Array(base.utf16) {
            let kept = (unit >= 0x41 && unit <= 0x5A)   // A-Z
                    || (unit >= 0x61 && unit <= 0x7A)   // a-z
                    || (unit >= 0x30 && unit <= 0x39)   // 0-9
                    || unit == 0x5F || unit == 0x2D     // _ -
            out.append(kept ? Unicode.Scalar(unit)! : "_")
        }
        let cleaned = String(out)
        return cleaned.isEmpty ? "unsorted" : cleaned
    }

    /// The first root that actually has this record's folder on disk.
    ///
    /// Returns nil when the model is in the library's records but not on this
    /// Mac — a NAS that is not mounted, or a file that only ever reached S3.
    /// That is a normal state, not an error, and the screen says so.
    static func directory(for id: String, roots: [String]) -> URL? {
        let dir = itemDirName(id)
        for root in roots {
            let url = URL(fileURLWithPath: root).appending(path: dir)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return url
            }
        }
        return nil
    }
}
