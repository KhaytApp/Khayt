import Foundation
import KhaytCore

/// Models arriving inside a zip.
///
/// ── WHY THIS IS NOT JUST AN UNZIP ─────────────────────────────────────────
///
/// A shop downloads a model as a zip, because that is how every model site
/// hands one over. Dropping it on the library did nothing at all: the import
/// walks for `stl`, `3mf`, `obj` and gcode, and a `.zip` is none of those, so
/// the file was silently ignored — no error, no model, nothing to explain it.
///
/// Expanding one is writing a stranger's bytes onto the shop's own disk, which
/// is the moment a member called `../../Library/LaunchAgents/x.plist` stops
/// being a curiosity. The rules for that already exist and are shared with the
/// customer-upload path: `lib/upload-scan.js` refuses a traversal, an archive
/// that expands to far more than it weighs, one with too many members, and one
/// that is not the kind of file its name claims. A shop's own download is more
/// trusted than a stranger's upload, but it is not a different rule — and the
/// zip a shop downloaded came from a stranger anyway.
///
/// So: scan first, expand second, and expand ONLY the members that are models.
/// A zip full of readmes and preview renders contributes its models and leaves
/// the rest on disk where it was.
@MainActor
enum ArchiveImport {

    /// Extensions this expands. Kept beside `LibraryImport.kinds`, which is
    /// what it expands them FOR.
    ///
    /// `zip` goes through this app's own reader, which lists the members and
    /// has them checked BEFORE anything is written. The rest go through
    /// libarchive — `bsdtar`, which macOS ships — because nothing here can
    /// read a RAR or a 7-Zip directory and a model pack arrives as one about
    /// as often as it arrives as a zip.
    static let kinds: Set<String> = ["zip", "rar", "7z", "tgz", "gz"]

    /// Formats opened by libarchive rather than by the zip reader.
    static let byLibarchive: Set<String> = ["rar", "7z", "tgz", "gz"]

    /// What a LOCAL import may be.
    ///
    /// The shared rule's own cap is the intake route's — thirty-two megabytes,
    /// sized for a stranger posting a file over HTTP. A pack the shop already
    /// has on its disk is not that: they run to hundreds of megabytes, and
    /// refusing one as "too large" when it is sitting in Downloads reads as
    /// the app being broken. A gigabyte is the read budget the library already
    /// works to elsewhere.
    static let localBudget = 1024 * 1024 * 1024

    /// The most an archive may become once opened.
    ///
    /// Checked AS IT UNPACKS rather than from a declared size, because nothing
    /// here can read these directories to be told one — and because a bomb
    /// lies in its own headers anyway. The same figure `lib/upload-scan.js`
    /// uses for the archives it can list.
    nonisolated static let unpackedBudget = 512 * 1024 * 1024

    enum Failure: Error, CustomStringConvertible {
        case refused(String, reason: String)
        case unreadable(String, any Error)
        case noModels(String)

        var description: String {
            switch self {
            case .refused(let name, let reason):
                // The reason is the shared rule's own word for it, said plainly.
                let said: String
                switch reason {
                case "unsafe-path":      said = "it names a file outside itself"
                case "expands-too-far":  said = "it expands to far more than it weighs"
                case "too-many-parts":   said = "it holds more files than an archive of models should"
                case "too-large":        said = "it is larger than this will open"
                case "not-what-it-says": said = "it is not actually a zip"
                case "empty":            said = "it is empty"
                default:                 said = reason
                }
                return "\(name) was not opened: \(said)."
            case .unreadable(let name, let why):
                return "Could not read \(name): \(why)"
            case .noModels(let name):
                return "\(name) holds no models Khayt can read."
            }
        }
    }

    /// What came out, and where it went.
    struct Expanded {
        /// The models, in a scratch directory the caller is expected to consume.
        let models: [URL]
        /// The scratch directory itself, so the caller can clear it up.
        let scratch: URL
        /// What the archive was called, without its extension — the natural
        /// group for everything that came out of it.
        let group: String
    }

    /// Open an archive and put the models in it somewhere the importer can take
    /// them from.
    ///
    /// Throws rather than returning an empty list when the archive is refused:
    /// a shop that dropped a zip in and got nothing back deserves the sentence
    /// saying why, and "no models" and "this looked like a zip bomb" are not
    /// the same outcome.
    static func expand(_ url: URL, engine: KhaytEngine) async throws -> Expanded {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        if byLibarchive.contains(ext) {
            return try await expandWithLibarchive(url, ext: ext, engine: engine)
        }

        let entries: [Zip.Entry]
        do { entries = try Zip.entries(of: url) }
        catch { throw Failure.unreadable(name, error) }

        let size = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int) .flatMap { $0 } ?? 0

        // THE SHARED RULE DECIDES, not this file. Both apps refuse the same
        // archives for the same reasons, and the reasons have tests.
        let facts = entries.map { e in
            JSONValue.object([
                "name": .string(e.name),
                "size": .number(Double(e.size)),
                "compressedSize": .number(Double(e.compressedSize)),
            ])
        }
        let verdict = try await engine.scanUpload(ext: "zip", size: size,
                                                  header: header(of: url), entries: facts,
                                                  maxBytes: localBudget)
        guard verdict.ok else {
            throw Failure.refused(name, reason: verdict.reason ?? "refused")
        }

        // Only the models. `Zip.entries` reports directories too, and a zip from
        // a model site is mostly licence text and render previews.
        let wanted = entries.filter { e in
            !e.name.hasSuffix("/")
                && LibraryImport.kinds.contains((e.name as NSString).pathExtension.lowercased())
                // A __MACOSX/._foo.stl resource fork is not a model; it is four
                // hundred bytes of Finder metadata wearing a model's name.
                && !e.name.hasPrefix("__MACOSX/")
                && !(e.name as NSString).lastPathComponent.hasPrefix("._")
        }
        guard !wanted.isEmpty else { throw Failure.noModels(name) }

        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "khayt-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        var out: [URL] = []
        for entry in wanted {
            // FLATTENED ON PURPOSE, to the member's own last component.
            //
            // The scan has already refused a traversal, so this is belt and
            // braces rather than the only guard — but it is the cheap kind: a
            // name that cannot contain a separator cannot escape the scratch
            // directory whatever else is wrong with it. The archive's folder
            // structure is not lost, it is simply not what groups the models:
            // the archive's own name is, below.
            let leaf = (entry.name as NSString).lastPathComponent
            guard !leaf.isEmpty, leaf != ".", leaf != ".." else { continue }
            let dest = uniqueName(in: scratch, leaf: leaf)
            guard let data = try? Zip.data(of: entry, in: url, limit: .max) else { continue }
            do { try data.write(to: dest) } catch { continue }
            out.append(dest)
        }
        guard !out.isEmpty else {
            try? FileManager.default.removeItem(at: scratch)
            throw Failure.noModels(name)
        }

        return Expanded(models: out, scratch: scratch,
                        group: url.deletingPathExtension().lastPathComponent)
    }

    /// Two members called `head.stl` in different folders both want that name
    /// once they are flattened. The second becomes `head-2.stl`.
    private static func uniqueName(in dir: URL, leaf: String) -> URL {
        let base = (leaf as NSString).deletingPathExtension
        let ext = (leaf as NSString).pathExtension
        var candidate = dir.appending(path: leaf)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            candidate = dir.appending(path: next)
            n += 1
        }
        return candidate
    }

    // MARK: - RAR, 7-Zip and gzipped tar, through libarchive

    /// Opened by `bsdtar`, which macOS ships — libarchive, and no dependency
    /// this app has to carry.
    ///
    /// ── WHY IT UNPACKS FIRST AND CHECKS AS IT GOES ────────────────────────
    ///
    /// The zip path lists the members and has them judged before a byte is
    /// written, which is the better order. Nothing here can read a RAR or a
    /// 7-Zip directory, and `bsdtar` has no machine-readable listing — a
    /// long-format table parsed by column breaks on the first file name with
    /// two spaces in it.
    ///
    /// So the budget is enforced on what LANDS. That is a stronger promise
    /// than the declared sizes the zip path trusts: an archive that lies about
    /// its contents cannot lie about what it wrote to the disk. It is cut off
    /// mid-way and the scratch directory goes with it.
    private static func expandWithLibarchive(_ url: URL, ext: String,
                                             engine: KhaytEngine) async throws -> Expanded {
        let name = url.lastPathComponent
        let size = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int).flatMap { $0 } ?? 0

        // The name and the size are still the shared rule's to judge, and the
        // magic number is what stops a `.rar` that is really something else.
        let verdict = try await engine.scanUpload(ext: ext, size: size,
                                                  header: header(of: url),
                                                  maxBytes: localBudget)
        guard verdict.ok else {
            throw Failure.refused(name, reason: verdict.reason ?? "refused")
        }

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "khayt-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        // `-x` extracts, `-f` names the archive, `-C` puts it in the scratch.
        // No `-v`: nothing reads the output and a pack of ten thousand members
        // would fill a pipe nobody drains.
        task.arguments = ["-x", "-f", url.path, "-C", scratch.path]
        task.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        task.standardError = errors
        do { try task.run() } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw Failure.unreadable(name, error)
        }

        // Watched while it runs: a bomb is stopped part way rather than after
        // it has filled the disk.
        let watcher = Task.detached {
            while task.isRunning {
                try? await Task.sleep(for: .milliseconds(400))
                if bytes(under: scratch) > unpackedBudget { task.terminate(); return true }
            }
            return false
        }
        task.waitUntilExit()
        let stopped = await watcher.value
        let said = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(),
                          as: UTF8.self)

        if stopped || bytes(under: scratch) > unpackedBudget {
            try? FileManager.default.removeItem(at: scratch)
            throw Failure.refused(name, reason: "too-big-unpacked")
        }
        guard task.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: scratch)
            // libarchive's own sentence, which names the format it could not
            // read — far more use than "could not open".
            throw Failure.refused(name, reason: said.isEmpty
                                  ? "unreadable" : Self.oneLine(said))
        }

        // The models, wherever they ended up. The group is the archive's own
        // name, as it is for a zip.
        var models: [URL] = []
        let walker = FileManager.default.enumerator(at: scratch,
                                                    includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles])
        while let next = walker?.nextObject() as? URL {
            if LibraryImport.kinds.contains(next.pathExtension.lowercased()) {
                models.append(next)
            }
        }
        guard !models.isEmpty else {
            try? FileManager.default.removeItem(at: scratch)
            throw Failure.noModels(name)
        }
        return Expanded(models: models.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }, scratch: scratch,
           // The archive's own name, decorations stripped — and its bare name
           // if the rule finds nothing in it worth calling a group.
           group: ImportGrouping.meaningful((name as NSString).deletingPathExtension)
               ?? (name as NSString).deletingPathExtension)
    }

    /// What has landed so far, in bytes.
    private nonisolated static func bytes(under dir: URL) -> Int {
        var total = 0
        let walker = FileManager.default.enumerator(at: dir,
                                                    includingPropertiesForKeys: [.fileSizeKey])
        while let next = walker?.nextObject() as? URL {
            total += (try? next.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
        }
        return total
    }

    /// libarchive's complaint, on one line.
    private static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? "unreadable"
    }

    /// The first bytes, as hex — what the shared rule checks the name against.
    private static func header(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 16)) ?? Data()
        return head.map { String(format: "%02x", $0) }.joined()
    }
}
