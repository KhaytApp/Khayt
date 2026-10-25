import AppKit
import SwiftUI
import KhaytCore

/// ── LIBRARY STAGE 3A: PRINTER CHIPS, THE FITS FILTER AND ⌘J ─────────────
///
/// `KHAYT_SNAPSHOT_LIBSTAGE3A=1`: tiles with their printer chips at Medium and
/// Large (one chosen, so the chips on the accent are seen), the same on the
/// 600-model library (`scaled`, the grid scene's), the list's Fits column,
/// Fits <machine> on, and the ⌘J palette with nothing typed and with results.
///
/// ALL IN MEMORY. The sample's models all fit all three of its printers, so
/// two are stretched here — the lantern too tall for the X1C, the vase too
/// big for every bed — or no tile would show a "+N" or a refusal. Nothing is
/// written; the sample is loaded again at the end, and the tile size and
/// layout (this Mac's preference) are put back.
extension Snapshot {

    static func captureLibraryStage3a(_ shop: Shop, into dir: URL, dark: Bool) async {
        let tag = dark ? "-dark" : ""
        let display = LibraryDisplay.shared
        let was = (display.tileSize, display.layout)
        defer { display.tileSize = was.0; display.layout = was.1 }

        await shop.load(.sample)
        shop.clearLibraryFilter()
        shop.search = ""
        shop.libraryFlat = true
        shop.shelf = .library(nil)
        shop.fileSelection = []
        display.layout = .grid
        let rows = stretched(shop.libraryRows)
        shop.pretendLibrary(rows)
        shop.libraryRows = rows
        shop.recountLibrarySoon()
        await shop.settleLibraryFacets()

        // 1–2. The sample, Medium and Large, a King chosen.
        shop.fileSelection = ["PF-sample-king-2"]
        for (name, size) in [("l3a-01-tiles-medium", LibraryTileSize.medium), ("l3a-02-tiles-large", .large)] {
            display.tileSize = size
            await settle()
            try? await Task.sleep(for: .milliseconds(500))
            captureMain(named: name + tag, into: dir)
        }
        shop.fileSelection = []

        // 3. Fits on the X1C: the lantern and the vase are gone.
        display.tileSize = .medium
        shop.libraryFitsOn = "MACH-x1c"
        await shop.settleLibraryFacets()
        await settle()
        try? await Task.sleep(for: .milliseconds(400))
        captureMain(named: "l3a-03-fits-x1c" + tag, into: dir)
        shop.libraryFitsOn = nil

        // 4. The list, with its Fits column.
        display.layout = .list
        await settle()
        try? await Task.sleep(for: .milliseconds(500))
        captureMain(named: "l3a-04-list-fits" + tag, into: dir)
        display.layout = .grid

        // 5–7. Six hundred models: Medium, Large and the list.
        let scaled = Self.scaled(rows, to: 600)
        shop.pretendLibrary(scaled)
        shop.libraryRows = scaled
        shop.shelf = .library(nil)
        shop.recountLibrarySoon()
        await shop.settleLibraryFacets()
        for (name, size) in [("l3a-05-scale-medium", LibraryTileSize.medium), ("l3a-06-scale-large", .large)] {
            display.tileSize = size
            await settle()
            try? await Task.sleep(for: .milliseconds(600))
            captureMain(named: name + tag, into: dir)
        }
        display.tileSize = .medium
        display.layout = .list
        await settle()
        try? await Task.sleep(for: .milliseconds(600))
        captureMain(named: "l3a-07-scale-list" + tag, into: dir)
        display.layout = .grid

        // 8–10. ⌘J: nothing typed (recent models), then "dent" and "king".
        for (name, typed) in [("l3a-08-jump-recent", ""), ("l3a-09-jump-results", "dent"), ("l3a-10-jump-kings", "king")] {
            shop.libraryJumpSeed = typed
            shop.jumping = true
            await settle()
            try? await Task.sleep(for: .milliseconds(700))
            await settle()
            captureMain(named: name + tag, into: dir)
            shop.jumping = false
            await settle()
        }
        shop.libraryJumpSeed = ""

        shop.clearLibraryFilter()
        await shop.load(.sample)
        await settle()
    }

    /// The sample's rows with two models resized — see the note above.
    static func stretched(_ rows: [JSONValue]) -> [JSONValue] {
        rows.map { row in
            guard case .object(var o) = row, case .string(let id)? = o["id"] else { return row }
            if id == "PF-sample-lantern" { o["geometryKey"] = .string("512300:414963.0:120.0x120.0x262.0") }
            if id == "PF-sample-vase" { o["geometryKey"] = .string("168400:42412.4:400.0x400.0x200.0") }
            return .object(o)
        }
    }
}
