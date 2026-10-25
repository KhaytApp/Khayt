import Foundation
import KhaytCore

/// Listing a compressed file's members and extracting ONE of them — the
/// plumbing under "archives as folders" (`ArchiveFolder` holds the rules).
///
/// ── TWO READERS, CHOSEN BY KIND ──────────────────────────────────────────
///
/// A ZIP is read by this app's own reader (`Zip`): the central directory is
/// listed from the end of the file without inflating anything, it says which
/// members are encrypted and which are symlinks, and one member is streamed
/// out with a cap on what it may become. RAR, 7-Zip and tar go through
/// libarchive — `/usr/bin/tar`, the `bsdtar` macOS ships — run as a separate
/// process with an argument list, never a shell string, so a hostile archive
/// that crashed libarchive would take `tar` with it and not the app.
///
/// ── NOTHING IS WRITTEN WHERE THE ARCHIVE SAYS ────────────────────────────
///
/// `bsdtar` is never asked to extract to a directory. It is run with `-O`,
/// which writes the ONE member's bytes to its standard output, and that is
/// pointed at a file whose path this app computed (`Cache.url`). A member
/// named `../../x` cannot land anywhere, because nothing is landed by name —
/// and `ArchiveFolder.judge` has refused that archive before any of this.
/// The member is asked for by an EXACT pattern (`exactPattern`), and its
/// size is checked against the listing afterwards, so a name with a `*` in
/// it cannot pull out every model in the pack as one file.
///
/// ── A LOCKED ARCHIVE IS NEVER A PROMPT ──────────────────────────────────
///
/// `bsdtar` asks for a passphrase on the terminal when it meets an encrypted
/// member — thirty times, measured, before it gives up. It is handed a
/// passphrase that opens nothing (`--passphrase`), so it fails at once and
/// says so; that sentence (`saysLocked`) marks the member locked. A zip's
/// encrypted members are known from the directory and never extracted.
enum ArchiveMembers {

    enum Failure: Error, CustomStringConvertible, Equatable {
        /// Encrypted: listed, not opened.
        case locked
        /// It grew past what it may be — a bomb, or a listing that lied.
        case tooBig
        /// It did not come out as the listing said it would.
        case unreadable(String)

        var description: String {
            switch self {
            case .locked: "the file is locked with a password"
            case .tooBig: "it expands past what Khayt will open"
            case .unreadable(let why): why
            }
        }
    }

    /// The passphrase `bsdtar` is handed so that it never asks for one. It
    /// opens nothing; it is not a secret.
    nonisolated static let noPassphrase = "khayt-does-not-ask"
    nonisolated static let tar = "/usr/bin/tar"
    /// How long one listing may take, and one member.
    nonisolated static let listPatience: TimeInterval = 120
    nonisolated static let extractPatience: TimeInterval = ArchiveImport.tarPatience

    // MARK: - Listing

    /// Every entry the archive lists, nothing inflated.
    nonisolated static func list(_ url: URL) throws -> [ArchiveFolder.Member] {
        if ArchiveFolder.kind(of: url.lastPathComponent) == "zip", let entries = try? Zip.entries(of: url) {
            return entries.map { e in
                ArchiveFolder.Member(path: e.name, size: e.size,
                                     type: e.isDirectory ? .directory : e.isSymlink ? .link : .file,
                                     encrypted: e.isEncrypted)
            }
        }
        let common = ["-f", url.path, "--passphrase", noPassphrase]
        let names = try BoundedProcess.run(tar, ["-t"] + common, timeout: listPatience,
                                           keepOut: 32 << 20, every: 0.25)
        let said = String(decoding: names.stderr, as: UTF8.self)
        guard !names.timedOut, names.status == 0 else {
            if ArchiveFolder.saysLocked(said) { throw Failure.locked }
            throw Failure.unreadable(oneLine(said))
        }
        let long = try BoundedProcess.run(tar, ["-t", "-v", "--numeric-owner"] + common, timeout: listPatience,
                                          keepOut: 64 << 20, every: 0.25)
        guard !long.timedOut, long.status == 0,
              let members = ArchiveFolder.members(names: String(decoding: names.stdout, as: UTF8.self),
                                                  long: String(decoding: long.stdout, as: UTF8.self)) else {
            throw Failure.unreadable("the listing could not be read")
        }
        return members
    }

    // MARK: - Extracting one member

    /// One member's bytes into `dest` — a path the caller computed — capped
    /// at `cap`, and at the listed size when there is one. Written beside it
    /// first and moved into place only once it is whole, so a half-written
    /// member is never handed out.
    nonisolated static func extract(_ member: ArchiveFolder.Member, from archive: URL, to dest: URL,
                                    cap: Int) throws {
        // lock: system — writes only into Khayt's own extraction cache, never the book or the shop's files.
        guard !member.encrypted else { throw Failure.locked }
        guard member.type == .file, member.safe != nil else { throw Failure.unreadable("not a file") }
        let limit = min(cap, member.size ?? cap)
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = dest.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).part")
        guard fm.createFile(atPath: part.path, contents: nil) else { throw Failure.unreadable("the cache is not writable") }
        defer { try? fm.removeItem(at: part) }
        let out = try FileHandle(forWritingTo: part)
        var written = 0
        do {
            if ArchiveFolder.kind(of: archive.lastPathComponent) == "zip",
               let entry = try? Zip.entries(of: archive).first(where: { $0.name == member.path }),
               entry.method == 0 || entry.method == 8 {
                guard !entry.isEncrypted else { throw Failure.locked }
                var failure: Error?
                do {
                    try Zip.stream(entry, in: archive, totalLimit: limit) { chunk in
                        do { try out.write(contentsOf: Data(chunk)); written += chunk.count; return true }
                        catch { failure = error; return false }
                    }
                } catch Zip.Failure.tooBig { throw Failure.tooBig }
                if let failure { throw Failure.unreadable(failure.localizedDescription) }
            } else {
                let args = ["-x", "-O", "-f", archive.path, "--passphrase", noPassphrase,
                            "--no-same-owner", "--no-same-permissions", "--no-acls", "--no-fflags",
                            "--no-xattrs", "--no-mac-metadata", "--",
                            ArchiveFolder.exactPattern(member.path)]
                let ran = try BoundedProcess.run(tar, args, timeout: extractPatience, keepOut: 0, every: 0.25,
                                                 stdoutTo: out,
                                                 watch: { size(of: part) > limit })
                written = size(of: part)
                let said = String(decoding: ran.stderr, as: UTF8.self)
                if ran.stopped || written > limit { throw Failure.tooBig }
                guard !ran.timedOut, ran.status == 0 else {
                    if ArchiveFolder.saysLocked(said) { throw Failure.locked }
                    throw Failure.unreadable(oneLine(said))
                }
            }
            try out.close()
        } catch {
            try? out.close()
            throw error
        }
        // What came out is what the listing said would — or it is not this
        // member (a pattern that matched two, a listing that lied).
        if let want = member.size, written != want {
            throw Failure.unreadable("\(member.leaf) came out as \(written) bytes, not \(want)")
        }
        guard written > 0 else { throw Failure.unreadable("\(member.leaf) is empty") }
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: part, to: dest)
    }

    nonisolated static func size(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
    }

    nonisolated static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? "unreadable"
    }

    // MARK: - The cache

    /// Members extracted so far, one folder per `ArchiveFolder.cacheKey`,
    /// capped in size and let go of least recently used first. A copy of
    /// bytes the archive still holds, so losing any of it loses nothing.
    final class Cache: @unchecked Sendable {
        let root: URL
        let cap: Int
        private let lock = NSLock()

        init(root: URL, cap: Int) { self.root = root; self.cap = cap }

        /// Four gigabytes in `~/Library/Caches`, which the system may also
        /// clear — never in the library, never synced, never backed up.
        static let defaultCap = 4 << 30

        /// The one the app uses. Tests make their own.
        nonisolated(unsafe) static var shared: Cache = {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            return Cache(root: caches.appending(path: "app.khayt.mac/archive-members"), cap: defaultCap)
        }()

        func folder(_ key: String) -> URL { root.appending(path: key) }

        func url(key: String, leaf: String) -> URL { folder(key).appending(path: leaf) }

        /// The member's file, when it is already here — marked as used unless
        /// `touching` is false (a view asking whether it is here).
        func cached(key: String, leaf: String, touching: Bool = true) -> URL? {
            let u = url(key: key, leaf: leaf)
            guard ArchiveImport.isOwnRegularFile(u, under: root) else { return nil }
            if touching { touch(key) }
            return u
        }

        func touch(_ key: String) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: folder(key).path)
        }

        /// Make room for `incoming` more bytes, keeping `keep`.
        func makeRoom(for incoming: Int, keep: Set<String> = []) {
            // lock: system — removes only copies in Khayt's own extraction cache, never the book or the shop's files.
            lock.lock(); defer { lock.unlock() }
            let fm = FileManager.default
            let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                    options: [.skipsHiddenFiles])) ?? []
            let entries = dirs.map { dir -> ArchiveFolder.CacheEntry in
                let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
                let bytes = files.reduce(0) { $0 + ArchiveMembers.size(of: $1) }
                let used = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)??
                    .timeIntervalSince1970 ?? 0
                return .init(key: dir.lastPathComponent, bytes: bytes, usedAt: used)
            }
            for key in ArchiveFolder.evictions(entries, cap: max(0, cap - incoming), keep: keep) {
                try? fm.removeItem(at: folder(key))
            }
        }

        /// What it holds, in bytes.
        func bytes() -> Int {
            let fm = FileManager.default
            let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
            var total = 0
            while let next = walker?.nextObject() as? URL { total += ArchiveMembers.size(of: next) }
            return total
        }
    }

    /// The member's extracted file, extracting it now when it is not cached.
    /// Blocking: called on a dispatch queue (`PinWork`), never the main actor.
    nonisolated static func materialise(_ member: ArchiveFolder.Member, of archive: URL, archiveHash: String,
                                        cache: Cache = .shared) throws -> URL {
        let key = ArchiveFolder.cacheKey(archiveHash: archiveHash, member: member.path)
        let leaf = ArchiveFolder.cacheLeaf(member)
        if let here = cache.cached(key: key, leaf: leaf) { return here }
        let cap = ArchiveFolder.Limits().memberBytes
        cache.makeRoom(for: member.size ?? 0, keep: [key])
        let dest = cache.url(key: key, leaf: leaf)
        try extract(member, from: archive, to: dest, cap: cap)
        cache.touch(key)
        return dest
    }
}

extension LibraryFile {
    /// The member this record names, as the cache keys it.
    var archiveEntry: ArchiveFolder.Member? {
        guard inArchive, let m = archiveMember else { return nil }
        return ArchiveFolder.Member(path: m, size: sourceFile?.size.map { Int($0) },
                                    encrypted: archiveLocked == true)
    }
}
