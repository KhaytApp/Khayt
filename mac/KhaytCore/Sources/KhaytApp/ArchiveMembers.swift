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
/// ── AND IN A CAGE ────────────────────────────────────────────────────────
///
/// A crash is not an exploit, though, and a linked folder's archives are
/// read with nobody clicking anything. So libarchive gets ONLY the format
/// the file's name claims (`ArchiveFolder.bytesMatch` on its first bytes),
/// a `.zip` the app's own reader refused is refused — never handed on to
/// libarchive to guess at — and `tar` runs under `sandbox-exec` with a
/// deny-by-default profile (`cage`): it may read, and nothing else. No
/// network, no file written or made; the member's bytes leave through the
/// standard output the app opened for it. `sandbox-exec` is deprecated but
/// shipped; where it is not there `tar` runs as before.
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
    nonisolated static let sandboxExec = "/usr/bin/sandbox-exec"
    /// What `tar` may do: be started (`/usr/bin/tar` is a link to `bsdtar`),
    /// read files and ask the kernel its settings. Everything else — the
    /// network, writing or making any file, other programs — is refused.
    nonisolated static let cage = """
        (version 1)(deny default)\
        (allow process-exec (literal "/usr/bin/tar") (literal "/usr/bin/bsdtar"))\
        (allow file-read*)(allow sysctl-read)
        """

    /// `tar`, in its cage when the cage is there.
    nonisolated static func runTar(_ args: [String], timeout: TimeInterval, keepOut: Int, every: TimeInterval,
                                   stdoutTo: FileHandle? = nil,
                                   watch: (@Sendable () -> Bool)? = nil) throws -> BoundedProcess.Outcome {
        if FileManager.default.isExecutableFile(atPath: sandboxExec) {
            return try BoundedProcess.run(sandboxExec, ["-p", cage, tar] + args, timeout: timeout, keepOut: keepOut,
                                          every: every, stdoutTo: stdoutTo, watch: watch)
        }
        return try BoundedProcess.run(tar, args, timeout: timeout, keepOut: keepOut, every: every,
                                      stdoutTo: stdoutTo, watch: watch)
    }

    /// The first bytes of a file — enough for every signature
    /// `ArchiveFolder.bytesMatch` knows (a tar's is at 257).
    nonisolated static func header(_ url: URL) -> [UInt8] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        return [UInt8]((try? h.read(upToCount: 512)) ?? Data())
    }

    /// Refused unless the bytes are the kind the name says — before any of
    /// libarchive sees them.
    nonisolated static func checkKind(_ url: URL) throws {
        guard let kind = ArchiveFolder.kind(of: url.lastPathComponent),
              ArchiveFolder.bytesMatch(kind: kind, header: header(url)) else {
            throw Failure.unreadable("it is not the kind of file its name says")
        }
    }
    /// How long one listing may take, and one member.
    nonisolated static let listPatience: TimeInterval = 120
    nonisolated static let extractPatience: TimeInterval = ArchiveImport.tarPatience

    // MARK: - Listing

    /// Every entry the archive lists, nothing inflated.
    nonisolated static func list(_ url: URL) throws -> [ArchiveFolder.Member] {
        if ArchiveFolder.kind(of: url.lastPathComponent) == "zip" {
            // The app's own reader decides a zip; one it cannot read is not
            // handed to libarchive to guess what else it might be.
            guard let entries = try? Zip.entries(of: url) else { throw Failure.unreadable("the zip could not be read") }
            return entries.map { e in
                ArchiveFolder.Member(path: e.name, size: e.size,
                                     type: e.isDirectory ? .directory : e.isSymlink ? .link : .file,
                                     encrypted: e.isEncrypted)
            }
        }
        try checkKind(url)
        let common = ["-f", url.path, "--passphrase", noPassphrase]
        let names = try runTar(["-t"] + common, timeout: listPatience, keepOut: 32 << 20, every: 0.25)
        let said = String(decoding: names.stderr, as: UTF8.self)
        guard !names.timedOut, names.status == 0 else {
            if ArchiveFolder.saysLocked(said) { throw Failure.locked }
            throw Failure.unreadable(oneLine(said))
        }
        let long = try runTar(["-t", "-v", "--numeric-owner"] + common, timeout: listPatience,
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
            let isZip = ArchiveFolder.kind(of: archive.lastPathComponent) == "zip"
            let zipEntry = isZip ? (try? Zip.entries(of: archive))?.first(where: { $0.name == member.path }) : nil
            // A zip the app's own reader cannot read (or that does not hold
            // this member) is refused, never passed on to libarchive.
            if isZip, zipEntry == nil { throw Failure.unreadable("the zip could not be read") }
            if !isZip { try checkKind(archive) }
            if let entry = zipEntry, entry.method == 0 || entry.method == 8 {
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
                let ran = try runTar(args, timeout: extractPatience, keepOut: 0, every: 0.25, stdoutTo: out,
                                     watch: { size(of: out) > limit })
                written = size(of: out)
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
        // A member of a quarantined download is quarantined too, as Archive
        // Utility does it: opened from the inspector, Gatekeeper still asks.
        carryQuarantine(from: archive, to: part)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: part, to: dest)
    }

    nonisolated static let quarantineKey = "com.apple.quarantine"

    /// The archive's quarantine mark, when it has one, put on `file`.
    nonisolated static func carryQuarantine(from archive: URL, to file: URL) {
        let size = getxattr(archive.path, quarantineKey, nil, 0, 0, 0)
        guard size > 0, size < 4096 else { return }
        var value = [UInt8](repeating: 0, count: size)
        guard getxattr(archive.path, quarantineKey, &value, size, 0, 0) == size else { return }
        _ = setxattr(file.path, quarantineKey, value, size, 0, 0)
    }

    /// A file's size as it is on disk NOW. Not `URL.resourceValues`: that
    /// caches on the URL and is cleared only by a run-loop pass, which the
    /// extraction thread never runs, so a size read while bsdtar was still
    /// writing stayed frozen — a slow member "came out as 0 bytes" and the
    /// bomb cap never tripped.
    nonisolated static func size(of url: URL) -> Int {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return 0 }
        return Int(st.st_size)
    }

    /// The size of the file behind a handle we are writing through.
    nonisolated static func size(of handle: FileHandle) -> Int {
        var st = stat()
        guard fstat(handle.fileDescriptor, &st) == 0 else { return 0 }
        return Int(st.st_size)
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
