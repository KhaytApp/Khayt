import AppKit
import SwiftUI
import KhaytCore

/// ── THE MODEL PAGE AND THE MULTI-SELECT PANE, ON THE SAMPLE ──────────────
///
/// `KHAYT_SNAPSHOT_LIBINSP=1`: the redesigned inspector on four sample models
/// — one the slicer measured (the lantern, two plates, in the catalogue), one
/// it only timed (the dallah stand, in the catalogue), one never sliced (a
/// King relief, priced from its mesh), and one too big for every printer —
/// and the multi-select pane with the vault's Share & Sell and Storage groups.
///
/// ALL IN MEMORY. The too-big model is the sample's rows with one box made
/// larger, put up with `pretendLibrary`; the vault is an identity string. The
/// sample on disk is never written, and it is loaded again at the end.
extension Snapshot {

    static func captureLibraryInspector(_ shop: Shop, into dir: URL, dark: Bool) async {
        let tag = dark ? "-dark" : ""
        await shop.load(.sample)
        shop.pretendsWritable = true
        // Drawn as a shop that may quote would see them (enabled); the sample
        // has no build, so nothing is written either way.
        shop.pretendsControl = true
        defer { shop.pretendsWritable = false; shop.pretendsControl = false }
        shop.clearLibraryFilter()
        shop.libraryFlat = true
        shop.shelf = .library(nil)
        shop.fileSelection = []
        await shop.settleLibraryFacets()
        await settle()

        for (name, id) in [("li-01-lantern", "PF-sample-lantern"), ("li-02-dallah", "PF-sample-dallah"),
                           ("li-03-king-unsliced", "PF-sample-king-1"), ("li-05-falcon", "PF-sample-falcon")] {
            shop.fileSelection = [id]
            await settle(); await settle()
            capture(named: name + tag, into: dir)
            capturePanes(named: name + tag, into: dir)
        }

        // The same model under a minimum margin it does not make: the margin
        // turns red and says the floor. In memory only.
        if case .object(var held) = shop.settingsValue {
            let was = held
            held["minMarginPct"] = .number(65)
            shop.settingsValue = .object(held)
            shop.fileSelection = ["PF-sample-falcon"]
            await settle(); await settle()
            capture(named: "li-07-below-floor" + tag, into: dir)
            capturePanes(named: "li-07-below-floor" + tag, into: dir)
            shop.settingsValue = .object(was)
        }

        // One model too big for every printer: the King's box at a metre.
        var rows = shop.libraryRows
        if let i = rows.firstIndex(where: { Shop.recordId($0) == "PF-sample-king-2" }),
           case .object(var o) = rows[i] {
            o["geometryKey"] = .string("6290060:117171.2:1141.57x757.09x207.37")
            rows[i] = .object(o)
            shop.pretendLibrary(rows)
            shop.libraryRows = rows
            shop.recountLibrarySoon()
            await shop.settleLibraryFacets()
            shop.fileSelection = ["PF-sample-king-2"]
            await settle(); await settle()
            capture(named: "li-04-too-big" + tag, into: dir)
            capturePanes(named: "li-04-too-big" + tag, into: dir)
        }

        // Several at once, with the vault on so Share & Sell and Storage show.
        shop.libraryRemoteId = CloudLibrary.vaultIdentityPrefix + "snapshot"
        shop.libraryHasRemote = true
        let kings = shop.visibleFiles.filter { $0.id.hasPrefix("PF-sample-king") }.map(\.id)
        shop.fileSelection = Set(kings.prefix(5)) .union(["PF-sample-lantern"])
        await settle(); await settle()
        capture(named: "li-06-multi" + tag, into: dir)
        capturePanes(named: "li-06-multi" + tag, into: dir)

        shop.fileSelection = []
        shop.libraryRemoteId = nil
        shop.libraryHasRemote = false
        await shop.load(.sample)
        await settle()
    }
}
