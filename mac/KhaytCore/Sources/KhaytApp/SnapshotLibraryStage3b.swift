import AppKit
import SwiftUI
import KhaytCore

/// ── LIBRARY STAGE 3B: STACKS, FIND SIMILAR, THE VIEWER ───────────────────
///
/// `KHAYT_SNAPSHOT_LIBSTAGE3B=1`:
///   l3b-01  the Saudi Kings with three of them stacked, closed, and a King
///           chosen whose Variants section suggests a stack by SHAPE — so the
///           mirror caveat is on the page
///   l3b-02  the stack open, a member chosen: "In a stack of 3"
///   l3b-03  Find Similar's focus, with the mirror caveat above the grid
///   l3b-03b Find Similar with no match (the banner)
///   l3b-03c a bundle import's note and a refusal
///   l3b-03d the stack in the list layout, its badge on the row
///   l3b-04  a two-plate project in the Views section, plate 2, from the front
///   l3b-05  the same project from the top, plate 1
///   l3b-06  the Falcon hood with figures from an older version (beta.8 M1)
///
/// The Export Model Bundle panel is the system's save panel, which a window
/// capture cannot draw; its choices (`BundleExportOptions`) are drawn by
/// `SnapshotTests.bundleExportAndNotes` instead.
///
/// ALL IN MEMORY, over the sample (`pretendLibrary`): the stack, the shared
/// key and the project row are laid over its rows. The project is a real
/// two-plate 3MF written to a temp folder and LINKED (`externalPath`), so the
/// viewer has bytes to draw. Nothing is written to any book, the Views
/// section's open state (this Mac's preference) is put back, and the sample
/// is loaded again at the end.
extension Snapshot {

    static let stage3bProject = "PF-snap-plates"

    static func captureLibraryStage3b(_ shop: Shop, into dir: URL, dark: Bool) async {
        let tag = dark ? "-dark" : ""
        let display = LibraryDisplay.shared
        let was = (display.tileSize, display.layout)
        let viewsKey = InspectorSection<EmptyView>.defaultsKey("views")
        let viewsWas = UserDefaults.standard.object(forKey: viewsKey)
        let work = FileManager.default.temporaryDirectory.appending(path: "khayt-lib3b-\(UUID().uuidString)")
        defer {
            display.tileSize = was.0; display.layout = was.1
            if let viewsWas { UserDefaults.standard.set(viewsWas, forKey: viewsKey) }
            else { UserDefaults.standard.removeObject(forKey: viewsKey) }
        }
        defer { try? FileManager.default.removeItem(at: work) }
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        await shop.load(.sample)
        shop.clearLibraryFilter()
        shop.search = ""
        shop.libraryFlat = true
        shop.libraryOpenStacks = []
        display.layout = .grid
        display.tileSize = .medium
        let project = work.appending(path: "two-plates.3mf")
        try? twoPlateProject(at: project)
        let rows = stage3bRows(shop.libraryRows, project: project)
        shop.pretendLibrary(rows)
        shop.libraryRows = rows
        shop.recountLibrarySoon()
        await shop.settleLibraryFacets()

        // 1. Stacked and closed; King Khalid's page suggests one by shape.
        shop.shelf = .library("Saudi Kings")
        shop.fileSelection = ["PF-sample-king-4"]
        await settle(); await settle()
        try? await Task.sleep(for: .milliseconds(500))
        captureMain(named: "l3b-01-stack-closed" + tag, into: dir)
        capturePanes(named: "l3b-01-stack-closed" + tag, into: dir)

        // 2. Open, a member chosen.
        shop.libraryOpenStacks = ["ST-snap-kings"]
        shop.fileSelection = ["PF-sample-king-2"]
        await settle(); await settle()
        try? await Task.sleep(for: .milliseconds(500))
        captureMain(named: "l3b-02-stack-open" + tag, into: dir)
        capturePanes(named: "l3b-02-stack-open" + tag, into: dir)

        // 3. Find Similar on King Khalid: the focus, and the mirror caveat.
        if let king = shop.files.first(where: { $0.id == "PF-sample-king-4" }) { shop.findSimilar(to: king) }
        await shop.settleLibraryFacets()
        await settle(); await settle()
        try? await Task.sleep(for: .milliseconds(500))
        captureMain(named: "l3b-03-find-similar" + tag, into: dir)
        shop.clearLibraryFilter()

        // 3b. Find Similar with nothing like it: the library's banner says so.
        //     (The sentence the seam writes, put up directly so the picture
        //     does not depend on what the sample happens to hold.)
        shop.shelf = .library("Saudi Kings")
        shop.fileSelection = ["PF-sample-king-4"]
        shop.importNote = shop.words.callIt("mac.sim_none", ["name": .string("KING Khalid")])
        await settle(); await settle()
        captureMain(named: "l3b-03b-find-similar-none" + tag, into: dir)

        // 3c. What a model bundle's export and import leave behind: the note,
        //     and a refusal.
        shop.importNote = shop.words.callIt("mac.mb_imported", ["name": .string("KING Khalid")])
        shop.importProblem = shop.words.callIt("mac.mb_bad_name", ["name": .string("model/../../escape.stl")])
        await settle(); await settle()
        captureMain(named: "l3b-03c-bundle-notes" + tag, into: dir)
        shop.importNote = nil
        shop.importProblem = nil

        // 3d. The stack in the LIST layout: its badge on the row.
        display.layout = .list
        shop.libraryOpenStacks = []
        await settle(); await settle()
        try? await Task.sleep(for: .milliseconds(500))
        captureMain(named: "l3b-03d-stack-list" + tag, into: dir)
        display.layout = .grid

        // 4–5. The project in the viewer: plate 2 from the front, plate 1 from the top.
        UserDefaults.standard.set(true, forKey: viewsKey)
        shop.shelf = .library(nil)
        shop.fileSelection = [stage3bProject]
        for (name, angle, plate) in [("l3b-04-views-plate2-front", ModelViewAngle.front, 2),
                                     ("l3b-05-views-plate1-top", .top, 1)] {
            shop.libraryViewAngle = angle
            shop.libraryViewPlate = plate
            await settle(); await settle()
            try? await Task.sleep(for: .milliseconds(1500))
            await settle()
            captureMain(named: name + tag, into: dir)
            capturePanes(named: name + tag, into: dir)
        }
        shop.libraryViewAngle = .iso
        shop.libraryViewPlate = nil

        // 6. A model whose figures are an older version's: the inspector's
        //    note, ≈ on its figures, and the reason under "As sliced".
        shop.fileSelection = ["PF-sample-falcon"]
        await settle(); await settle()
        try? await Task.sleep(for: .milliseconds(500))
        captureMain(named: "l3b-06-figures-stale" + tag, into: dir)
        capturePanes(named: "l3b-06-figures-stale" + tag, into: dir)

        shop.fileSelection = []
        shop.libraryOpenStacks = []
        shop.clearLibraryFilter()
        await shop.load(.sample)
        await settle()
    }

    /// The sample's rows with Kings 1–3 stacked (1 on top), Kings 4 and 5
    /// sharing one shape key (a same-shape suggestion), and the linked
    /// two-plate project.
    static func stage3bRows(_ rows: [JSONValue], project: URL) -> [JSONValue] {
        var out: [JSONValue] = rows.map { row in
            guard case .object(var o) = row, case .string(let id)? = o["id"] else { return row }
            switch id {
            case "PF-sample-king-1", "PF-sample-king-2", "PF-sample-king-3":
                o["stackId"] = .string("ST-snap-kings")
                if id == "PF-sample-king-1" { o["stackTop"] = .bool(true) }
            case "PF-sample-king-5":
                o["geometryKey"] = .string("6290060:117223.2:200x200x4.56")
            case "PF-sample-falcon":
                // Another Mac's newer version arrived; these figures are the
                // old bytes' (l3b-06: the stale-figures note and its ≈).
                o["figuresStaleFor"] = .string("snap-newer-bytes")
            default: break
            }
            return .object(o)
        }
        out.append(.object([
            "id": .string(stage3bProject), "name": .string("Two-plate project"),
            "originalName": .string("two-plates.3mf"), "externalPath": .string(project.path),
            "sourceFile": .object(["filename": .string("two-plates.3mf"), "originalName": .string("two-plates.3mf"),
                                   "ext": .string("3mf"), "kind": .string("model")]),
            "geometryKey": .string("24:14000:20x20x60"), "folder": .string(""), "tags": .array([]),
            "colors": .array([]), "createdAt": .number(1_761_000_000_000),
        ]))
        return out
    }

    /// A 3MF laid out on two plates: a 20 mm cube on plate 1, a 10 × 10 × 60
    /// post on plate 2, each its own object, as a slicer project lays them out.
    static func twoPlateProject(at url: URL) throws {
        func box(_ w: Double, _ d: Double, _ h: Double) -> String {
            let v = [(0.0, 0.0, 0.0), (w, 0, 0), (w, d, 0), (0, d, 0), (0, 0, h), (w, 0, h), (w, d, h), (0, d, h)]
            let faces = [(0,3,2),(0,2,1),(4,5,6),(4,6,7),(0,1,5),(0,5,4),
                         (1,2,6),(1,6,5),(2,3,7),(2,7,6),(3,0,4),(3,4,7)]
            let vertices = v.map { "<vertex x=\"\($0.0)\" y=\"\($0.1)\" z=\"\($0.2)\"/>" }.joined()
            let triangles = faces.map { "<triangle v1=\"\($0.0)\" v2=\"\($0.1)\" v3=\"\($0.2)\"/>" }.joined()
            return "<mesh><vertices>\(vertices)</vertices><triangles>\(triangles)</triangles></mesh>"
        }
        let root = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
         <resources>
          <object id="1" type="model">\(box(20, 20, 20))</object>
          <object id="2" type="model">\(box(10, 10, 60))</object>
         </resources>
         <build><item objectid="1"/><item objectid="2" transform="1 0 0 0 1 0 0 0 1 200 0 0"/></build>
        </model>
        """
        let config = """
        <?xml version="1.0" encoding="UTF-8"?>
        <config><plate><metadata key="object_id" value="1"/></plate>
        <plate><metadata key="object_id" value="2"/></plate></config>
        """
        try ZipWrite.archive([ZipWrite.Member("3D/3dmodel.model", Data(root.utf8)),
                              ZipWrite.Member("Metadata/model_settings.config", Data(config.utf8))]).write(to: url)
    }
}
