import AppKit
import SwiftUI
import KhaytCore

/// ── THE LIBRARY GRID, EVERY WAY IT CAN BE SHOWN ─────────────────────────
///
/// Small, Medium and Large tiles, the list, a selection with the Edit menu,
/// the empty library and a filter that matches nothing — and the same again
/// on a 600-model library built in memory from the sample's own rows, because
/// fifteen models never show what a grid does at the size a shop's really is.
///
/// ALL IN MEMORY. The big library is the sample's rows copied with new ids
/// and put up with `pretendLibrary`; nothing is written, and the sample is
/// loaded again at the end. Tile size and layout are this Mac's preference,
/// so they are put back as they were.
///
/// `KHAYT_SNAPSHOT_LIBGRID=1` runs only these, in whichever appearance and
/// language the run was started in.
extension Snapshot {

    static func captureLibraryGrid(_ shop: Shop, into dir: URL, dark: Bool) async {
        let tag = dark ? "-dark" : ""
        let display = LibraryDisplay.shared
        let was = (display.tileSize, display.layout)
        defer { display.tileSize = was.0; display.layout = was.1 }

        await shop.load(.sample)
        shop.clearLibraryFilter()
        shop.libraryFlat = true
        shop.shelf = .library(nil)
        shop.fileSelection = []
        display.layout = .grid

        // 1–3. The three densities on the sample.
        for (name, size) in [("lg-01-small", LibraryTileSize.small), ("lg-02-medium", .medium),
                             ("lg-03-large", .large)] {
            display.tileSize = size
            await settle()
            try? await Task.sleep(for: .milliseconds(500))
            capture(named: name + tag, into: dir)
        }
        display.tileSize = .medium

        // 4. A selection: the Edit menu says how many.
        let ids = shop.visibleFiles.prefix(3).map(\.id)
        shop.fileSelection = Set(ids)
        await settle()
        capture(named: "lg-04-selected" + tag, into: dir)
        shop.fileSelection = []

        // 5. The list, sorted by print time.
        display.layout = .list
        shop.librarySort = .printTime
        await settle()
        try? await Task.sleep(for: .milliseconds(500))
        capture(named: "lg-05-list" + tag, into: dir)
        shop.librarySort = .added
        display.layout = .grid

        // 6. Groups view, medium.
        shop.libraryFlat = false
        await settle()
        capture(named: "lg-06-groups" + tag, into: dir)
        shop.libraryFlat = true

        // 7. A filter that matches nothing: menus stay, greyed where empty.
        shop.search = "material:unobtainium"
        await settle()
        capture(named: "lg-07-no-match" + tag, into: dir)
        shop.search = ""

        // 8. The empty library: the Import button under the sentence.
        shop.pretendLibrary([])
        await settle()
        capture(named: "lg-08-empty" + tag, into: dir)

        // 9–12. Six hundred models.
        shop.pretendLibrary(Self.scaled(shop.libraryRows, to: 600))
        shop.shelf = .library(nil)
        await settle()
        for (name, size) in [("lg-09-scale-small", LibraryTileSize.small),
                             ("lg-10-scale-medium", .medium), ("lg-11-scale-large", .large)] {
            display.tileSize = size
            await settle()
            try? await Task.sleep(for: .milliseconds(600))
            capture(named: name + tag, into: dir)
        }
        display.tileSize = .medium
        display.layout = .list
        shop.librarySort = .name
        await settle()
        try? await Task.sleep(for: .milliseconds(600))
        capture(named: "lg-12-scale-list" + tag, into: dir)
        shop.librarySort = .added
        display.layout = .grid

        await shop.load(.sample)
        await settle()
    }

    /// The sample's model rows, copied until there are `count` of them: new
    /// ids, a version suffix, every third one in a group so the folders and
    /// the facts both have something to show, and some with no picture so the
    /// placeholder is seen.
    static func scaled(_ rows: [JSONValue], to count: Int) -> [JSONValue] {
        let models = rows.compactMap { row -> [String: JSONValue]? in
            if case .object(let o) = row { return o }
            return nil
        }
        guard !models.isEmpty else { return [] }
        let groups = ["Dental", "Cosplay", "Hueforge", "Miniatures", "Functional", "Seasonal"]
        var out: [JSONValue] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            var o = models[i % models.count]
            let round = i / models.count + 1
            o["id"] = .string("PF-scale-\(i)")
            if case .string(let name)? = o["name"] { o["name"] = .string(name + " #" + String(round)) }
            if i % 3 == 1 { o["group"] = .string(groups[(i / 3) % groups.count]); o["folder"] = nil }
            if i % 7 == 3 { o["userPhoto"] = .null }
            out.append(.object(o))
        }
        return out
    }
}
