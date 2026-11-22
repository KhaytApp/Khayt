import Foundation
import Testing
@testable import KhaytCore

/// The rules under "archives as folders": which names are archives, which
/// member paths are safe, when an archive is a bomb or locked, and how its
/// members are keyed. Nothing here touches a disk.
@Suite struct ArchiveFolderTests {

    typealias M = ArchiveFolder.Member
    static let kinds: Set<String> = ["stl", "3mf", "obj", "step", "gcode"]

    @Test("archive kinds come from the name's ending, and a bare ending is a hidden file")
    func kinds() {
        #expect(ArchiveFolder.kind(of: "Dragon.ZIP") == "zip")
        #expect(ArchiveFolder.kind(of: "pack.rar") == "rar")
        #expect(ArchiveFolder.kind(of: "pack.7z") == "7z")
        #expect(ArchiveFolder.kind(of: "pack.tar.gz") == "tgz")
        #expect(ArchiveFolder.kind(of: "pack.tgz") == "tgz")
        #expect(ArchiveFolder.kind(of: "pack.tar") == "tar")
        #expect(ArchiveFolder.kind(of: "model.3mf") == nil, "a 3MF is a zip, and it is a model")
        #expect(ArchiveFolder.kind(of: "model.stl") == nil)
        #expect(ArchiveFolder.kind(of: ".zip") == nil)
        #expect(ArchiveFolder.baseName(of: "Dragon Pack.tar.gz") == "Dragon Pack")
        #expect(ArchiveFolder.baseName(of: "a.b.zip") == "a.b")
    }

    @Test("a member path is safe only inside the archive: no .., no absolute, no drive, no controls")
    func safePaths() {
        #expect(ArchiveFolder.safePath("./STL/a.stl") == "STL/a.stl")
        #expect(ArchiveFolder.safePath("STL//a.stl") == "STL/a.stl")
        #expect(ArchiveFolder.safePath("STL\\a.stl") == "STL/a.stl", "a Windows zip's backslash is a folder")
        #expect(ArchiveFolder.safePath("../evil.stl") == nil)
        #expect(ArchiveFolder.safePath("a/../../evil.stl") == nil)
        #expect(ArchiveFolder.safePath("..\\evil.stl") == nil)
        #expect(ArchiveFolder.safePath("/etc/passwd") == nil)
        #expect(ArchiveFolder.safePath("~/x.stl") == nil)
        #expect(ArchiveFolder.safePath("C:\\Windows\\x.stl") == nil)
        #expect(ArchiveFolder.safePath("a\u{0}.stl") == nil)
        #expect(ArchiveFolder.safePath("a\n.stl") == nil)
        #expect(ArchiveFolder.safePath("./") == nil)
        #expect(ArchiveFolder.safePath("") == nil)
        #expect(ArchiveFolder.safePath("..foo/a.stl") == "..foo/a.stl", "a name that starts with two dots is a name")
    }

    @Test("an archive with ONE traversal is refused whole, whatever the member is")
    func traversalRefusesAll() {
        let members = [M(path: "a.stl", size: 10), M(path: "../../Library/LaunchAgents/x.plist", size: 10)]
        #expect(ArchiveFolder.judge(members, archiveBytes: 100, modelKinds: Self.kinds) == .refused("unsafe-path"))
        let absolute = [M(path: "/tmp/a.stl", size: 10)]
        #expect(ArchiveFolder.judge(absolute, archiveBytes: 100, modelKinds: Self.kinds) == .refused("unsafe-path"))
    }

    @Test("only model FILES are shown: no folders, links, readmes, resource forks or hidden files")
    func onlyModels() {
        let members = [
            M(path: "./", size: 0, type: .directory),
            M(path: "pack/", size: 0, type: .directory),
            M(path: "pack/a.stl", size: 10),
            M(path: "pack/link.stl", size: 0, type: .link),
            M(path: "pack/readme.txt", size: 10),
            M(path: "__MACOSX/pack/._a.stl", size: 10),
            M(path: "pack/._b.stl", size: 10),
            M(path: "pack/.hidden.stl", size: 10),
            M(path: "pack/STEP/b.STEP", size: 10),
        ]
        guard case .open(let shown) = ArchiveFolder.judge(members, archiveBytes: 100, modelKinds: Self.kinds) else {
            Issue.record("not opened"); return
        }
        #expect(shown.map(\.path) == ["pack/a.stl", "pack/STEP/b.STEP"])
        #expect(ArchiveFolder.judge([M(path: "readme.txt", size: 1)], archiveBytes: 1, modelKinds: Self.kinds) == .noModels)
    }

    @Test("a bomb's shape is refused: past the ratio, past the total, or too many entries")
    func bombs() {
        // Declared at 900 MB from a 100 KB file: no DEFLATE stream does that.
        let bomb = [M(path: "a.stl", size: 900 << 20)]
        #expect(ArchiveFolder.judge(bomb, archiveBytes: 100_000, modelKinds: Self.kinds) == .refused("expands-too-far"))
        var limits = ArchiveFolder.Limits()
        limits.totalBytes = 1_000
        let big = [M(path: "a.stl", size: 600), M(path: "b.stl", size: 600)]
        #expect(ArchiveFolder.judge(big, archiveBytes: 1_200, modelKinds: Self.kinds, limits: limits) == .refused("too-large"))
        limits = .init()
        limits.maxEntries = 3
        let many = (0..<4).map { M(path: "m\($0).stl", size: 1) }
        #expect(ArchiveFolder.judge(many, archiveBytes: 10, modelKinds: Self.kinds, limits: limits) == .refused("too-many-parts"))
        limits = .init()
        limits.maxModels = 2
        let models = (0..<3).map { M(path: "m\($0).stl", size: 1) }
        #expect(ArchiveFolder.judge(models, archiveBytes: 10, modelKinds: Self.kinds, limits: limits) == .refused("too-many-parts"))
    }

    @Test("a member past the read budget is left out, not the archive")
    func oneTooBig() {
        var limits = ArchiveFolder.Limits()
        limits.memberBytes = 100
        let members = [M(path: "huge.stl", size: 1_000), M(path: "ok.stl", size: 50)]
        #expect(ArchiveFolder.judge(members, archiveBytes: 1_000, modelKinds: Self.kinds, limits: limits)
                == .open([M(path: "ok.stl", size: 50)]))
    }

    @Test("an encrypted model member makes the archive locked — never opened, no password asked")
    func locked() {
        let members = [M(path: "a.stl", size: 10, encrypted: true), M(path: "b.stl", size: 10)]
        guard case .locked(let shown) = ArchiveFolder.judge(members, archiveBytes: 30, modelKinds: Self.kinds) else {
            Issue.record("not locked"); return
        }
        #expect(shown.count == 2)
        // An encrypted readme locks nothing a shop prints.
        let readme = [M(path: "a.stl", size: 10), M(path: "notes.txt", size: 10, encrypted: true)]
        #expect(ArchiveFolder.judge(readme, archiveBytes: 30, modelKinds: Self.kinds) == .open([M(path: "a.stl", size: 10)]))
        #expect(ArchiveFolder.saysLocked("a.stl: Incorrect passphrase: Unknown error: -1"))
        #expect(ArchiveFolder.saysLocked("Encrypted file is unsupported"))
        #expect(!ArchiveFolder.saysLocked("Unrecognized archive format"))
    }

    @Test("a member's book key and cache key: the archive's path or bytes, and the member exactly")
    func keys() {
        #expect(ArchiveFolder.memberKey(archive: "/x/Pack.zip", member: "STL/a.stl") == "/x/Pack.zip!/STL/a.stl")
        let a = ArchiveFolder.cacheKey(archiveHash: "h1", member: "a.stl")
        #expect(a.count == 32 && a.allSatisfy(\.isHexDigit))
        #expect(a == ArchiveFolder.cacheKey(archiveHash: "h1", member: "a.stl"))
        #expect(a != ArchiveFolder.cacheKey(archiveHash: "h2", member: "a.stl"), "a changed archive is a new key")
        #expect(a != ArchiveFolder.cacheKey(archiveHash: "h1", member: "./a.stl"))
        // The leaf is a plain file name, never a path.
        #expect(ArchiveFolder.cacheLeaf(M(path: "STL/dragon head.stl", size: 1)) == "dragon head.stl")
        #expect(ArchiveFolder.cacheLeaf(M(path: "STL/.stl", size: 1)) == "stl")
        #expect(!ArchiveFolder.cacheLeaf(M(path: String(repeating: "x", count: 300) + ".stl", size: 1)).contains("/"))
        #expect(ArchiveFolder.cacheLeaf(M(path: String(repeating: "x", count: 300) + ".stl", size: 1)).hasSuffix(".stl"))
    }

    @Test("the cache lets go of the least recently used first, never what is in use")
    func eviction() {
        let entries = [
            ArchiveFolder.CacheEntry(key: "old", bytes: 40, usedAt: 1),
            ArchiveFolder.CacheEntry(key: "mid", bytes: 40, usedAt: 2),
            ArchiveFolder.CacheEntry(key: "new", bytes: 40, usedAt: 3),
        ]
        #expect(ArchiveFolder.evictions(entries, cap: 200).isEmpty)
        #expect(ArchiveFolder.evictions(entries, cap: 80) == ["old"])
        #expect(ArchiveFolder.evictions(entries, cap: 40) == ["old", "mid"])
        #expect(ArchiveFolder.evictions(entries, cap: 40, keep: ["old"]) == ["mid", "new"])
        #expect(ArchiveFolder.evictions(entries, cap: 0) == ["old", "mid", "new"])
    }

    @Test("bsdtar's listing: names unescaped, sizes and types read, wildcards escaped back")
    func bsdtarListing() {
        let names = "./*.stl\n./back\\\\slash.stl\n./t\\tab.stl\n./sub/\n./sub/link.stl\n./two  spaces/d.3mf\n"
        let long = """
        -rw-r--r--  0 0      0           5 25 Oct 07:49 ./*.stl
        -rw-r--r--  0 0      0           3 25 Oct 07:49 ./back\\\\slash.stl
        -rw-r--r--  0 0      0           1 25 Oct 07:49 ./t\\tab.stl
        drwxr-xr-x  0 0      0           0 25 Oct 07:49 ./sub/
        lrwxr-xr-x  0 0      0           0 25 Oct 07:43 ./sub/link.stl -> ./sub/link.stl
        -rw-r--r--  0 0      0           2 25 Oct 07:43 ./two  spaces/d.3mf

        """
        let members = ArchiveFolder.members(names: names, long: long)
        #expect(members?.map(\.path) == ["./*.stl", "./back\\slash.stl", "./t\tab.stl", "./sub/", "./sub/link.stl",
                                         "./two  spaces/d.3mf"])
        #expect(members?.map(\.size) == [5, 3, 1, 0, 0, 2])
        #expect(members?.map(\.type) == [.file, .file, .file, .directory, .link, .file])
        // Two listings that do not line up are not read at all.
        #expect(ArchiveFolder.members(names: "./a.stl\n", long: "") == nil)
        #expect(ArchiveFolder.members(names: "./a.stl\n", long: "-rw-r--r--  0 0 0 5 25 Oct 07:49 ./b.stl\n") == nil)
        #expect(ArchiveFolder.exactPattern("./a[1]*?.stl") == "./a\\[1\\]\\*\\?.stl")
        #expect(ArchiveFolder.exactPattern("back\\slash") == "back\\\\slash")
    }
}
