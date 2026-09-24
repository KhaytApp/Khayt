import Foundation
import CryptoKit
import KhaytCore

/// Moving the library's existing files to wherever it now lives — a port of
/// `lib/print-library-migrate.js`, written twice for the reason
/// `LibraryLocation` is: the module needs Node's `path`, which JavaScriptCore
/// does not have. `LibraryMoveParityTests` runs both over the same inputs.
///
/// THE RULE EVERYTHING FOLLOWS, the other app's: a duplicate is recoverable, a
/// deletion is not. An original is removed in exactly one case — its copy has
/// been READ BACK and hashes the same — and on the Mac it goes to the Trash
/// rather than away, like every other removal this app makes.
enum LibraryMove {

    static let same = "duplicate"
    static let move = "move"
    static let collision = "collision"
    /// Room left over after the move, so the destination is not filled to 0.
    static let headroom: Double = 256 * 1024 * 1024

    private static func norm(_ p: String) -> String {
        URL(fileURLWithPath: p.trimmingCharacters(in: .whitespacesAndNewlines)).standardizedFileURL.path
    }

    /// `convert-paths.js under`: the folder itself, or inside it.
    static func under(_ child: String, _ dir: String) -> Bool {
        let c = norm(child), d = norm(dir)
        return c == d || c.hasPrefix(d.hasSuffix("/") ? d : d + "/")
    }

    /// The folders to move files OUT of: every root this install has used,
    /// never the destination, never the mirror (moving out of a backup is the
    /// one move guaranteed to leave the shop worse off), and never a root
    /// nested inside or around the destination.
    static func sources(roots: [String], primary: String, mirror: String?) -> [String] {
        let p = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        let m = (mirror ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var out: [String] = []
        for r in roots {
            let root = r.trimmingCharacters(in: .whitespacesAndNewlines)
            if root.isEmpty || root == p || root == m { continue }
            if under(root, p) || under(p, root) { continue }
            if !out.contains(root) { out.append(root) }
        }
        return out
    }

    /// What to do with one file, given what is already where it is going.
    static func decide(destExists: Bool, srcHash: String?, destHash: String?) -> String {
        if !destExists { return move }
        if let s = srcHash, let d = destHash, !s.isEmpty, s == d { return same }
        return collision
    }

    /// A free name, suffixed before the extension so it still opens in a slicer.
    static func collisionName(_ filename: String, taken: [String]) -> String {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "file" : trimmed
        let held = Set(taken.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        if !held.contains(name) { return name }
        let dot = name.lastIndex(of: ".").flatMap { $0 > name.startIndex ? $0 : nil }
        let stem = dot.map { String(name[..<$0]) } ?? name
        let ext = dot.map { String(name[$0...]) } ?? ""
        for n in 2..<1000 {
            let candidate = "\(stem) (moved\(n > 2 ? " \(n)" : ""))\(ext)"
            if !held.contains(candidate) { return candidate }
        }
        return "\(stem) (moved \(String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)))\(ext)"
    }

    /// Room enough? Asked before the first copy. An unknown figure is not a
    /// refusal: the copies then fail one by one, and are reported.
    static func enoughSpace(bytes: Double, free: Double?) -> (ok: Bool, shortBy: Double) {
        guard let free, free.isFinite else { return (true, 0) }
        let ok = free >= bytes + headroom
        return (ok, ok ? 0 : bytes + headroom - free)
    }

    /// The library's settings with `nextRoot` as its root and the root it is
    /// leaving remembered — or a second move orphans the first folder's files.
    static func rememberRoot(_ settings: [String: JSONValue], next nextRoot: String,
                             defaultRoot: String) -> [String: JSONValue] {
        func str(_ v: JSONValue?) -> String {
            if case .string(let s)? = v { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
            return ""
        }
        let leaving = str(settings["root"])
        let base = defaultRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = nextRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        var history: [String] = []
        if case .array(let rows)? = settings["history"] {
            history = rows.map { str($0) }.filter { !$0.isEmpty }
        }
        if !leaving.isEmpty, leaving != base, leaving != next, !history.contains(leaving) {
            history.append(leaving)
        }
        var out = settings
        out["root"] = .string(next)
        out["history"] = .array(history.filter { $0 != next }.map(JSONValue.string))
        return out
    }

    // MARK: - The disk

    struct Item: Sendable { let root: String; let rel: String; let size: Int }

    /// Every file under a root — `printLibWalk`: `.DS_Store` skipped, symlinks
    /// not ours to move, an unmounted share read as empty.
    static func walk(_ root: String) -> [Item] {
        let base = URL(fileURLWithPath: root)
        guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        else { return [] }
        var out: [Item] = []
        let prefix = base.standardizedFileURL.path + "/"
        while let url = e.nextObject() as? URL {
            if url.lastPathComponent == ".DS_Store" { continue }
            guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  v.isRegularFile == true, v.isSymbolicLink != true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            out.append(Item(root: root, rel: String(path.dropFirst(prefix.count)), size: v.fileSize ?? 0))
        }
        return out
    }

    static func sha256(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var sha = SHA256()
        while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { sha.update(data: chunk) }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    enum Failure: Error, Equatable { case copyDiffers }

    /// Move one file and PROVE it arrived before the original goes (to the
    /// Trash). `moveOne` in the other app, step for step.
    @discardableResult
    static func moveOne(_ src: URL, to destDir: URL, filename: String,
                        trash: (URL) throws -> Void) throws -> (action: String, name: String) {
        let fm = FileManager.default
        let target = destDir.appending(path: filename)
        let destExists = fm.fileExists(atPath: target.path)
        let srcHash = try sha256(src)
        let destHash = destExists ? try? sha256(target) : nil
        let action = decide(destExists: destExists, srcHash: srcHash, destHash: destHash)
        if action == same {
            try trash(src)
            return (action, filename)
        }
        let name = action == collision
            ? collisionName(filename, taken: (try? fm.contentsOfDirectory(atPath: destDir.path)) ?? [])
            : filename
        let dest = destDir.appending(path: name)
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        try fm.copyItem(at: src, to: dest)
        guard (try? sha256(dest)) == srcHash else {
            // The bad copy out, so a retry does not keep it forever as a
            // collision. The ORIGINAL stays.
            try? fm.removeItem(at: dest)
            throw Failure.copyDiffers
        }
        try trash(src)
        return (action, name)
    }
}

// MARK: - The shop's side

extension Shop {

    /// The shop's iCloud Drive, if this Mac has one switched on.
    nonisolated static var iCloudDrive: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue ? url : nil
    }

    /// Move the print library to `folder`, then move the files already on
    /// this Mac into it. The location is saved FIRST, as the other app does,
    /// so a move that stops half way leaves every file findable: the old
    /// folder is remembered, and a model is read from wherever it is.
    func moveLibrary(to folder: URL) async {
        libraryMoveProblem = nil
        libraryMoveNote = nil
        guard let build = source.build, StoreLock.weOwnIt(build) else {
            libraryMoveProblem = words.callIt("mac.move_sample"); return
        }
        guard !libraryMoveBusy else { return }
        libraryMoveBusy = true
        defer { libraryMoveBusy = false; libraryMoveProgress = nil }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            guard fm.isWritableFile(atPath: folder.path) else {
                libraryMoveProblem = words.callIt("mac.libmove_not_writable", ["path": .string(folder.path)]); return
            }
            let defaultRoot = LibraryLocation.defaultRoot(for: build)
            // The built-in vault is spelled as blank, as the other app does.
            let next = folder.standardizedFileURL.path == URL(fileURLWithPath: defaultRoot).standardizedFileURL.path
                ? "" : folder.standardizedFileURL.path
            try StoreWriter.update(build) { root in
                var settings = Self.settings(root)
                var library: [String: JSONValue] = [:]
                if case .object(let l)? = settings["printLibrary"] { library = l }
                settings["printLibrary"] = .object(LibraryMove.rememberRoot(library, next: next, defaultRoot: defaultRoot))
                root["settings"] = .object(settings)
            }
            await load(source)
        } catch {
            libraryMoveProblem = String(describing: error); return
        }
        await moveStrandedFiles()
    }

    /// Everything sitting in a folder the library no longer writes to, moved
    /// in — copied, read back, compared, and only then the original to the
    /// Trash. Nothing is overwritten; a failure leaves that file where it was.
    func moveStrandedFiles() async {
        guard let roots = libraryRoots else { return }
        let primary = roots.primary
        let from = LibraryMove.sources(roots: roots.roots, primary: primary, mirror: roots.mirror)
        let items = await Task.detached { from.flatMap(LibraryMove.walk) }.value
        guard !items.isEmpty else {
            libraryMoveNote = words.callIt("mac.libmove_nothing"); return
        }
        let bytes = Double(items.reduce(0) { $0 + $1.size })
        let free = (try? URL(fileURLWithPath: primary)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage.map(Double.init)
        let space = LibraryMove.enoughSpace(bytes: bytes, free: free)
        guard space.ok else {
            let short = (try? await engine?.formatBytes(space.shortBy)) ?? ""
            libraryMoveProblem = words.callIt("mac.libmove_no_room", ["short": .string(short ?? "")]); return
        }
        var moved = 0, duplicates = 0
        var failures: [String] = []
        for (i, item) in items.enumerated() {
            libraryMoveProgress = (i, items.count, (item.rel as NSString).lastPathComponent)
            let src = URL(fileURLWithPath: item.root).appending(path: item.rel)
            let destDir = URL(fileURLWithPath: primary).appending(path: (item.rel as NSString).deletingLastPathComponent)
            let name = (item.rel as NSString).lastPathComponent
            do {
                let r = try await Task.detached {
                    try LibraryMove.moveOne(src, to: destDir, filename: name, trash: Shop.trash)
                }.value
                if r.action == LibraryMove.same { duplicates += 1 } else { moved += 1 }
            } catch {
                failures.append(item.rel + ": " + ((error as? LocalizedError)?.errorDescription ?? String(describing: error)))
            }
        }
        // Folders emptied by the move, and only empty ones, never a root.
        for root in from {
            let dirs = Set(items.filter { $0.root == root }.map { ($0.rel as NSString).deletingLastPathComponent })
            for d in dirs where !d.isEmpty {
                let url = URL(fileURLWithPath: root).appending(path: d)
                if ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? ["x"]).filter({ $0 != ".DS_Store" }).isEmpty {
                    try? Shop.trash(url)
                }
            }
        }
        libraryMoveNote = words.callIt("mac.libmove_done", ["n": .number(Double(moved)), "same": .number(Double(duplicates))])
        if !failures.isEmpty {
            libraryMoveProblem = words.callIt("mac.libmove_some_failed", ["n": .number(Double(failures.count))])
                + "\n" + failures.prefix(3).joined(separator: "\n")
        }
        await load(source)
    }
}
