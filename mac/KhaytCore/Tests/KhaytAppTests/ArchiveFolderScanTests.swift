import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Compressed files as folders: a ZIP, 7-Zip or tar in a linked folder shows
/// its models as tiles without being unpacked (`Shop+ArchiveFolders.swift`).
///
/// Every archive here is made by the test — a pack, a traversal, a bomb's
/// shape, a locked one, a symlink — in a temp folder, with a temp book and a
/// temp extraction cache. Nothing reads or writes the shop's book.
@MainActor
struct ArchiveFolderScanTests {

    typealias Bench = LibraryImportEndToEndTests.Bench

    struct Rig {
        let bench: Bench
        let linked: URL
        let cache: ArchiveMembers.Cache
        func tidy() { try? FileManager.default.removeItem(at: bench.dir) }
    }

    static func rig() throws -> Rig {
        let bench = try LibraryImportEndToEndTests.bench()
        let linked = bench.dir.appending(path: "My Drive")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        let cache = ArchiveMembers.Cache(root: bench.dir.appending(path: "cache"), cap: 64 << 20)
        return Rig(bench: bench, linked: linked, cache: cache)
    }

    static func stl(_ size: Double) -> Data { MeshTests.binarySTL(MeshTests.boxFacets(size, size, size)) }

    /// `files` (name → bytes) written under `src`, then packed by bsdtar in
    /// `format` (`zip`, `7zip`, or nil for a gzipped tar) into `archive`.
    static func pack(_ files: [String: Data], into archive: URL, format: String?,
                     extra: [String] = [], links: [String: String] = [:]) throws {
        let src = archive.deletingLastPathComponent().appending(path: "src-\(UUID().uuidString)")
        for (name, data) in files {
            let at = src.appending(path: name)
            try FileManager.default.createDirectory(at: at.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: at)
        }
        for (name, target) in links {
            let at = src.appending(path: name)
            try FileManager.default.createDirectory(at: at.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: at.path, withDestinationPath: target)
        }
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        var args = format.map { ["-c", "--format", $0] } ?? ["-cz"]
        args += extra + ["-f", archive.path, "-C", src.path, "."]
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = args
        tar.standardInput = FileHandle.nullDevice
        try tar.run()
        tar.waitUntilExit()
        try? FileManager.default.removeItem(at: src)
        #expect(tar.terminationStatus == 0, "bsdtar could not make \(archive.lastPathComponent)")
    }

    static func rows(_ rig: Rig) throws -> [[String: JSONValue]] {
        try LibraryImportEndToEndTests.printFiles(in: rig.bench).compactMap { if case .object(let o) = $0 { o } else { nil } }
    }

    static func index(_ rig: Rig, _ archives: [URL], known: Set<String> = [],
                      online: @escaping @Sendable (URL) -> Bool = { _ in false },
                      limits: ArchiveFolder.Limits = .init()) async throws -> Shop.ArchiveScan {
        await Shop.indexArchives([(root: rig.linked, archives: archives)], known: known,
                                 storeURL: rig.bench.store, libraryRoot: rig.bench.library,
                                 engine: try KhaytEngine(), isOnline: online, cache: rig.cache, limits: limits,
                                 owns: { true }, whoHasIt: { nil })
    }

    static func decoded(_ o: [String: JSONValue]) throws -> LibraryFile {
        try JSONDecoder().decode(LibraryFile.self, from: JSONEncoder().encode(JSONValue.object(o)))
    }

    // MARK: - A pack, three ways

    @Test("a zip's models become records filed under the zip's name, measured and pictured, the zip untouched")
    func zipPack() async throws {
        let rig = try Self.rig()
        defer { rig.tidy() }
        let zip = rig.linked.appending(path: "Dragons/Dragon_Pack-model_files.zip")
        try Self.pack(["STL/head.stl": Self.stl(10), "STL/tail.stl": Self.stl(14), "readme.txt": Data("hi".utf8)],
                      into: zip, format: "zip")
        let before = try LibraryImport.contentHash(of: zip)

        let scan = try await Self.index(rig, [zip])
        #expect(scan.added == 2 && scan.failures.isEmpty && scan.refused.isEmpty, "\(scan)")
        let rows = try Self.rows(rig)
        #expect(rows.count == 2, "the readme is not a model")
        let path = zip.standardizedFileURL.path
        for o in rows {
            #expect(o["externalPath"] == .string(path), "a member's record points at its ARCHIVE")
            #expect(o["archiveHash"] == before.map(JSONValue.string))
            #expect(o["group"] == .string("Dragons/Dragon Pack"), "filed under the archive, spelled as a person would")
            #expect(o["geometryKey"] != .null, "measured from its extracted copy")
            #expect(o["thumbFile"] == .string("thumb.png"), "pictured into its own vault folder")
            #expect(o["archiveLocked"] == nil)
        }
        let head = try #require(rows.first { $0["archiveMember"] == .string("./STL/head.stl") })
        #expect(head["originalName"] == .string("head.stl"))
        let loose = rig.bench.dir.appending(path: "h.stl")
        try Self.stl(10).write(to: loose)
        let want = try LibraryImport.contentHash(of: loose)
        #expect(head["contentHash"] == want.map(JSONValue.string),
                "the hash is the MEMBER's bytes, so Library Health sees a copy of it elsewhere")
        #expect(try LibraryImport.contentHash(of: zip) == before, "the archive was rewritten")

        // The app reads it back as a member, and its bytes are the cache's.
        let file = try Self.decoded(head)
        #expect(file.inArchive && !file.isLocked && file.archivePath == path)
        let copy = try #require(Shop.archiveCopy(of: file, cache: rig.cache))
        #expect(copy.path.hasPrefix(rig.cache.root.path), "a member is read from the cache, never the archive")
        #expect(try Data(contentsOf: copy) == Self.stl(10))
        // Nothing of the archive was written next to it.
        let beside = try FileManager.default.contentsOfDirectory(atPath: zip.deletingLastPathComponent().path)
        #expect(beside == ["Dragon_Pack-model_files.zip"])
    }

    @Test("a 7-Zip and a gzipped tar open through libarchive, a wildcard name taken exactly")
    func libarchiveKinds() async throws {
        let rig = try Self.rig()
        defer { rig.tidy() }
        let seven = rig.linked.appending(path: "Kit.7z"), tgz = rig.linked.appending(path: "Bits.tar.gz")
        // `*.stl` is a NAME here; asked for loosely it is every model at once.
        try Self.pack(["*.stl": Self.stl(10), "a[1].stl": Self.stl(12)], into: seven, format: "7zip")
        try Self.pack(["sub/b c.stl": Self.stl(16)], into: tgz, format: nil)
        let scan = try await Self.index(rig, [seven, tgz])
        #expect(scan.added == 3 && scan.failures.isEmpty, "\(scan)")
        let rows = try Self.rows(rig)
        #expect(Set(rows.compactMap { if case .string(let g)? = $0["group"] { g } else { nil } }) == ["Kit", "Bits"])
        let star = try #require(rows.first { $0["originalName"] == .string("*.stl") })
        let file = try Self.decoded(star)
        let copy = try #require(Shop.archiveCopy(of: file, cache: rig.cache))
        #expect(try Data(contentsOf: copy) == Self.stl(10), "the `*` member came out as all of them")
    }

    // MARK: - Hostile archives

    @Test("a traversal archive is refused whole: nothing indexed, nothing written outside the cache")
    func traversal() async throws {
        let rig = try Self.rig()
        defer { rig.tidy() }
        let zip = rig.linked.appending(path: "evil.zip")
        let data = try ZipWrite.archive([.init("ok.stl", Self.stl(10)), .init("../../escape.stl", Self.stl(10)),
                                         .init("/tmp/khayt-absolute.stl", Self.stl(10))])
        try data.write(to: zip)
        let scan = try await Self.index(rig, [zip])
        #expect(scan.added == 0)
        #expect(scan.refused.count == 1 && scan.refused[0].contains("unsafe-path"), "\(scan.refused)")
        #expect(try Self.rows(rig).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: rig.bench.dir.appending(path: "escape.stl").path))
        #expect(!FileManager.default.fileExists(atPath: rig.linked.appending(path: "../escape.stl").standardizedFileURL.path))
        #expect(rig.cache.bytes() == 0, "a refused archive extracted something")
    }

    @Test("a bomb's shape is refused from its listing, and a member that grows past its cap is cut off")
    func bombs() async throws {
        let rig = try Self.rig()
        defer { rig.tidy() }
        // A zip whose directory CLAIMS a member of 900 MB, in a few hundred bytes.
        var data = try ZipWrite.archive([.init("bomb.stl", Data(repeating: 0, count: 4096))])
        let central = try #require(Self.lastRange(of: [0x50, 0x4b, 0x01, 0x02], in: data))
        data.replaceSubrange((central + 24)..<(central + 28), with: Self.le32(900 << 20))
        let zip = rig.linked.appending(path: "bomb.zip")
        try data.write(to: zip)
        let scan = try await Self.index(rig, [zip])
        #expect(scan.added == 0 && scan.refused.first?.contains("expands-too-far") == true, "\(scan)")

        // Honest about its size, but past the cap it is extracted under.
        let tgz = rig.linked.appending(path: "big.tgz")
        try Self.pack(["zeros.stl": Data(repeating: 0, count: 2 << 20)], into: tgz, format: nil)
        let dest = rig.cache.url(key: "k", leaf: "zeros.stl")
        let member = ArchiveFolder.Member(path: "./zeros.stl", size: nil)
        #expect(throws: ArchiveMembers.Failure.tooBig) {
            try ArchiveMembers.extract(member, from: tgz, to: dest, cap: 1 << 20)
        }
        #expect(!FileManager.default.fileExists(atPath: dest.path), "a cut-off member was left in the cache")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: dest.deletingLastPathComponent().path)) ?? []
        #expect(left.isEmpty, "a partial file was left: \(left)")
    }

    @Test("a locked zip is listed as locked members — never extracted, never a password prompt")
    func lockedZip() async throws {
        let rig = try Self.rig()
        defer { rig.tidy() }
        let zip = rig.linked.appending(path: "Secret.zip")
        try Self.pack(["a.stl": Self.stl(10)], into: zip, format: "zip",
                      extra: ["--options", "zip:encryption=zipcrypt", "--passphrase", "pw"])
        let scan = try await Self.index(rig, [zip])
        #expect(scan.added == 1 && scan.locked == 1, "\(scan)")
        let o = try #require(try Self.rows(rig).first)
        #expect(o["archiveLocked"] == .bool(true))
        #expect(o["contentHash"] == .null && o["geometryKey"] == .null, "a locked member was read")
        #expect(rig.cache.bytes() == 0)
        let file = try Self.decoded(o)
        #expect(file.isLocked && Shop.archiveCopy(of: file, cache: rig.cache) == nil)
        // libarchive, asked directly, refuses at once rather than prompting.
        #expect(throws: ArchiveMembers.Failure.locked) {
            try ArchiveMembers.extract(.init(path: "a.stl", size: nil), from: Self.renamed(zip, to: "Secret.rar"),
                                       to: rig.cache.url(key: "x", leaf: "a.stl"), cap: 1 << 20)
        }
    }

    @Test("a symlink wearing a model's name is not a model, and is never followed")
    func symlinkMember() async throws {
        let rig = try Self.rig()
        defer { rig.tidy() }
        let tgz = rig.linked.appending(path: "links.tgz")
        try Self.pack(["real.stl": Self.stl(10)], into: tgz, format: nil, links: ["passwd.stl": "/etc/passwd"])
        let listed = try ArchiveMembers.list(tgz)
        #expect(listed.contains { $0.path.hasSuffix("passwd.stl") && $0.type == .link })
        let scan = try await Self.index(rig, [tgz])
        #expect(scan.added == 1)
        #expect(try Self.rows(rig).map { $0["originalName"] } == [.string("real.stl")])
        #expect(throws: (any Error).self) {
            try ArchiveMembers.extract(.init(path: "./passwd.stl", size: nil, type: .link), from: tgz,
                                       to: rig.cache.url(key: "l", leaf: "passwd.stl"), cap: 1 << 20)
        }
    }

    // MARK: - Online, known, deleted

    @Test("an online-only archive lists nothing and is not read")
    func onlineArchive() async throws {
        let rig = try Self.rig()
        defer { rig.tidy() }
        let zip = rig.linked.appending(path: "Cloud.zip")
        try Self.pack(["a.stl": Self.stl(10)], into: zip, format: "zip")
        let scan = try await Self.index(rig, [zip], online: { _ in true })
        #expect(scan.online == 1 && scan.added == 0)
        #expect(try Self.rows(rig).isEmpty && rig.cache.bytes() == 0)
    }

    @Test("a member already indexed, or deleted by the shop, is not indexed again")
    func knownAndDeleted() async throws {
        let rig = try Self.rig()
        defer { rig.tidy() }
        let zip = rig.linked.appending(path: "Pack.zip")
        try Self.pack(["a.stl": Self.stl(10), "b.stl": Self.stl(12)], into: zip, format: "zip")
        let path = zip.standardizedFileURL.path
        let scan = try await Self.index(rig, [zip], known: [ArchiveFolder.memberKey(archive: path, member: "./a.stl")])
        #expect(scan.added == 1)
        let b = try Self.decoded(try #require(try Self.rows(rig).first))
        #expect(b.archiveMember == "./b.stl")
        #expect(b.archiveKey == ArchiveFolder.memberKey(archive: path, member: "./b.stl"))
        // Deleting it remembers the MEMBER, not the archive.
        let remembered = Shop.notAdoptedAfterDeleting([b], roots: [rig.linked.path], already: [])
        #expect(remembered == [.string(ArchiveFolder.memberKey(archive: path, member: "./b.stl"))])
        // And a member's vault folder holds its picture, never the archive:
        // the delete trashes that folder, so the archive cannot go with it.
        let dir = try #require(LibraryLocation.directory(for: b.id, roots: [rig.bench.library.path]))
        let inside = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!inside.contains { ArchiveFolder.kind(of: $0) != nil }, "\(inside)")
    }

    // MARK: - The walk, the cache, Health

    @Test("the linked walk keeps archives apart from models, and none of them as models")
    func walkFindsArchives() throws {
        let rig = try Self.rig()
        defer { rig.tidy() }
        try Self.pack(["a.stl": Self.stl(10)], into: rig.linked.appending(path: "P/Pack.zip"), format: "zip")
        try Self.stl(10).write(to: rig.linked.appending(path: "loose.stl"))
        let found = Shop.linkedWalk([rig.linked], skippingAll: [rig.bench.library.path], known: [], stop: nil)
        #expect(found.first?.archives.map(\.lastPathComponent) == ["Pack.zip"])
        #expect(found.first?.models.map(\.lastPathComponent) == ["loose.stl"])
        #expect(Shop.archiveGroup(rig.linked.appending(path: "P/Pack.zip"), under: rig.linked) == "P/Pack")
    }

    @Test("a member let go by the cache is extracted again; a gone archive means a gone member, once")
    func cacheAndHealth() async throws {
        let rig = try Self.rig()
        defer { rig.tidy() }
        let zip = rig.linked.appending(path: "Pack.zip")
        try Self.pack(["a.stl": Self.stl(10), "b.stl": Self.stl(11)], into: zip, format: "zip")
        _ = try await Self.index(rig, [zip])
        let files = try Self.rows(rig).map(Self.decoded)
        let a = try #require(files.first)
        let key = ArchiveFolder.cacheKey(archiveHash: a.archiveHash ?? "", member: a.archiveMember ?? "")
        try FileManager.default.removeItem(at: rig.cache.folder(key))
        #expect(Shop.archiveCopy(of: a, cache: rig.cache) == nil)
        let again = try ArchiveMembers.materialise(try #require(a.archiveEntry), of: zip,
                                                   archiveHash: a.archiveHash ?? "", cache: rig.cache)
        #expect(try Data(contentsOf: again) == Self.stl(10))

        // Cap: a cache of one member's room lets the older go.
        let small = ArchiveMembers.Cache(root: rig.bench.dir.appending(path: "small"), cap: 1_000)
        for f in files {
            _ = try ArchiveMembers.materialise(try #require(f.archiveEntry), of: zip,
                                               archiveHash: f.archiveHash ?? "", cache: small)
        }
        #expect(small.bytes() <= 1_000, "the cache grew past its cap: \(small.bytes())")

        // The archive gone: every member missing, asked of the disk once.
        try FileManager.default.removeItem(at: zip)
        let presence = Shop.healthPresence(files, roots: [rig.bench.library.path], online: [],
                                           linkedOnline: { _ in false })
        #expect(files.allSatisfy { presence[$0.id] == .missing })
        #expect(Shop.archiveCopy(of: a, cache: rig.cache) == nil, "a cached copy outlived its archive")
        let models = files.map { Shop.healthModel($0, presence: presence[$0.id] ?? .here) }
        let missing = LibraryHealth.groups(models: models).first { $0.kind == .missing }
        #expect(missing?.archives.count == 1 && missing?.archives.first?.modelIds.count == 2)
    }

    @Test("every word this adds has English and Arabic")
    func words() {
        let keys = ["mac.arc_scanned", "mac.arc_locked_n", "mac.arc_online_n", "mac.arc_refused_n", "mac.arc_reveal",
                    "mac.arc_where", "mac.arc_member", "mac.arc_locked", "mac.arc_locked_says", "mac.arc_extracting",
                    "mac.arc_not_here", "mac.arc_untouched", "mac.arc_tile", "mac.arc_tile_a11y", "mac.arc_remove",
                    "mac.lh_arc_row"]
        for key in keys {
            #expect(Words.own[key]?["en"]?.isEmpty == false, "\(key) has no English")
            #expect(Words.own[key]?["ar"]?.isEmpty == false, "\(key) has no Arabic")
        }
    }

    // MARK: - Bytes

    static func le32(_ v: Int) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }

    static func lastRange(of sig: [UInt8], in data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= sig.count else { return nil }
        for i in stride(from: bytes.count - sig.count, through: 0, by: -1) where Array(bytes[i..<(i + sig.count)]) == sig {
            return i
        }
        return nil
    }

    /// A copy under another name — so the same encrypted bytes go through
    /// libarchive rather than the zip reader.
    static func renamed(_ url: URL, to name: String) throws -> URL {
        let to = url.deletingLastPathComponent().appending(path: name)
        try FileManager.default.copyItem(at: url, to: to)
        return to
    }
}
