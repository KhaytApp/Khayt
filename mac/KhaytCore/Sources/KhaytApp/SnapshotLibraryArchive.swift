import AppKit
import SwiftUI
import KhaytCore

/// ── COMPRESSED FILES AS FOLDERS ─────────────────────────────────────────
///
/// `KHAYT_SNAPSHOT_LIBARCHIVE=1`: a ZIP in a linked folder drawn as a folder
/// (its zipper badge and "Compressed file · N models"), opened (each member a
/// tile with its picture, its figures and the zipper mark), one member in the
/// inspector ("Inside … — in …", Show Compressed File in Finder), the sample's
/// locked 7-Zip member, Library Health with a compressed file gone (one line
/// for the archive, however many models), and Remove from Library's question.
///
/// A REAL PACK, made here: three box STLs of different shapes zipped by
/// `bsdtar` into a temp folder and indexed by the real pass
/// (`Shop.indexArchives`) into a throwaway book, with a throwaway extraction
/// cache. Its rows are laid over the sample's in memory (`pretendLibrary`) —
/// the sample book has no library folder, so each member's picture rides in
/// `userPhoto`. Nothing is written to any book, and the sample is loaded
/// again at the end.
extension Snapshot {

    static func captureLibraryArchive(_ shop: Shop, into dir: URL, dark: Bool) async {
        let tag = dark ? "-dark" : ""
        await shop.load(.sample)
        shop.pretendsWritable = true
        defer { shop.pretendsWritable = false; shop.pretendHealthPresence = nil }
        let work = FileManager.default.temporaryDirectory.appending(path: "khayt-libarchive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let previous = ArchiveMembers.Cache.shared
        ArchiveMembers.Cache.shared = .init(root: work.appending(path: "cache"), cap: 256 << 20)
        defer { ArchiveMembers.Cache.shared = previous }

        let made = await archiveRows(in: work)
        let rows = shop.libraryRows + made
        shop.pretendLibrary(rows)
        shop.libraryRows = rows
        shop.clearLibraryFilter()
        shop.search = ""
        shop.libraryFlat = false
        shop.shelf = .library(nil)
        shop.fileSelection = []
        // The pack's figures, worked out as a load works them out — the
        // sample's were figured before these rows were laid over it.
        if let engine = shop.engine,
           let worked = await LoadFigures.work(
               .init(files: shop.files, machines: Shop.modelMachineRows(shop.machineRowsInUse, kinds: shop.machineKinds),
                     settings: shop.settingsDict, orders: shop.orderRows, nozzle: shop.nozzleForRisk),
               engine: engine, wanted: { true }) {
            shop.estimates = worked.estimates
            shop.fits = worked.fits
        }
        shop.recountLibrarySoon()
        await shop.settleLibraryFacets()
        await settle(); await settle()

        // 1. The library's folders: the two compressed files among them.
        captureMain(named: "la-01-folders" + tag, into: dir)

        // 2. The pack opened, its first member chosen: the inspector says
        // where it is, and Open / Show Compressed File in Finder are there.
        let pack = "Gridfinity Bins"
        shop.shelf = .library(pack)
        if let first = shop.archiveMembers(ofGroup: pack).first {
            shop.fileSelection = [first.id]
            await shop.materialise(first)
        }
        await settle(); await settle()
        try? await Task.sleep(for: .milliseconds(400))
        captureMain(named: "la-02-pack-open" + tag, into: dir)
        capturePanes(named: "la-02-pack-open" + tag, into: dir)

        // 3. The sample's locked member: listed, never opened.
        shop.shelf = .library("Patreon Minis")
        shop.fileSelection = ["PF-sample-arc-knight"]
        await settle(); await settle()
        try? await Task.sleep(for: .milliseconds(300))
        captureMain(named: "la-03-locked" + tag, into: dir)
        capturePanes(named: "la-03-locked" + tag, into: dir)
        shop.fileSelection = []

        // 4. Library Health with the pack gone: ONE line for it.
        var presence: [String: LibraryHealth.Presence] = [:]
        for f in shop.files { presence[f.id] = f.archivePath?.hasSuffix("Gridfinity Bins.zip") == true ? .missing : .here }
        shop.pretendHealthPresence = presence
        shop.shelf = .library(nil)
        shop.openLibraryHealth()
        await shop.checkLibraryHealth()
        await settle(); await settle()
        try? await Task.sleep(for: .milliseconds(400))
        captureMain(named: "la-04-health-missing" + tag, into: dir)
        shop.libraryHealthOpen = false
        shop.pretendHealthPresence = nil

        // 5. Remove from Library on the pack's folder: exactly its models on
        // the grid, and the library's own question with their count.
        shop.libraryFlat = false
        shop.shelf = .library(nil)
        await settle()
        shop.askToRemoveArchive(ofGroup: pack)
        await shop.settleLibraryFacets()
        await settle(); await settle()
        try? await Task.sleep(for: .milliseconds(500))
        captureMain(named: "la-05-remove-asks" + tag, into: dir)
        shop.pendingLibraryDeletes = []
        await settle()

        shop.clearLibraryFilter()
        await shop.load(.sample)
        await settle()
    }

    /// Three boxes of different shapes in `Gridfinity Bins.zip`, indexed by
    /// the real pass into a throwaway book; their pictures inlined.
    static func archiveRows(in work: URL) async -> [JSONValue] {
        // lock: system — a snapshot scene: it writes only a throwaway book and vault in a temp folder.
        let fm = FileManager.default
        let linked = work.appending(path: "Linked/Downloads")
        let src = work.appending(path: "src/STL")
        let library = work.appending(path: "vault")
        let store = work.appending(path: "book.json")
        do {
            try fm.createDirectory(at: src, withIntermediateDirectories: true)
            try fm.createDirectory(at: linked, withIntermediateDirectories: true)
            try fm.createDirectory(at: library, withIntermediateDirectories: true)
            try Data(#"{"printFiles":[],"settings":{}}"#.utf8).write(to: store)
            for (name, dims) in [("bin-1x1", (42.0, 42.0, 28.0)), ("bin-2x1", (84.0, 42.0, 28.0)),
                                 ("bin-2x2-tall", (84.0, 84.0, 56.0))] {
                try boxSTL(dims.0, dims.1, dims.2).write(to: src.appending(path: name + ".stl"))
            }
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-c", "--format", "zip", "-f", linked.appending(path: "Gridfinity Bins.zip").path,
                             "-C", work.appending(path: "src").path, "."]
            tar.standardInput = FileHandle.nullDevice
            try tar.run()
            tar.waitUntilExit()
        } catch {
            FileHandle.standardError.write(Data("libarchive scene: \(error)\n".utf8))
            return []
        }
        guard let engine = try? KhaytEngine() else { return [] }
        let scan = await Shop.indexArchives([(root: work.appending(path: "Linked"),
                                              archives: [linked.appending(path: "Gridfinity Bins.zip")])],
                                            known: [], storeURL: store, libraryRoot: library, engine: engine,
                                            isOnline: { _ in false }, owns: { true }, whoHasIt: { nil })
        FileHandle.standardError.write(Data("libarchive scene: \(scan.added) members indexed\n".utf8))
        guard let data = try? Data(contentsOf: store),
              let root = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              case .array(let rows)? = root["printFiles"] else { return [] }
        return rows.map { row in
            guard case .object(var o) = row, case .string(let id)? = o["id"] else { return row }
            let thumb = library.appending(path: LibraryLocation.itemDirName(id)).appending(path: "thumb.png")
            if let png = try? Data(contentsOf: thumb) {
                o["userPhoto"] = .string("data:image/png;base64," + png.base64EncodedString())
            }
            o["tags"] = .array([.string("gridfinity")])
            o["category"] = .string("Functional parts")
            return .object(o)
        }
    }

    /// A closed box, as a binary STL: twelve facets.
    static func boxSTL(_ w: Double, _ d: Double, _ h: Double) -> Data {
        let c: [(Float, Float, Float)] = [(0, 0, 0), (Float(w), 0, 0), (Float(w), Float(d), 0), (0, Float(d), 0),
                                          (0, 0, Float(h)), (Float(w), 0, Float(h)), (Float(w), Float(d), Float(h)),
                                          (0, Float(d), Float(h))]
        let faces = [(0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7), (0, 1, 5), (0, 5, 4),
                     (1, 2, 6), (1, 6, 5), (2, 3, 7), (2, 7, 6), (3, 0, 4), (3, 4, 7)]
        var out = Data(count: 80)
        func f32(_ v: Float) { withUnsafeBytes(of: v.bitPattern.littleEndian) { out.append(contentsOf: $0) } }
        withUnsafeBytes(of: UInt32(faces.count).littleEndian) { out.append(contentsOf: $0) }
        for (a, b, cc) in faces {
            f32(0); f32(0); f32(0)
            for v in [c[a], c[b], c[cc]] { f32(v.0); f32(v.1); f32(v.2) }
            out.append(contentsOf: [0, 0])
        }
        return out
    }
}
