import AppKit
import SwiftUI
import KhaytCore

/// ── LIBRARY HEALTH AND PRINT NEXT, ON THE SAMPLE ─────────────────────────
///
/// `KHAYT_SNAPSHOT_LIBHEALTH=1`: the Library Health page with every group in
/// it, the grid narrowed to one group from its Show button (the Show menu
/// says so), the page with nothing to fix, and Print next — the card's mark
/// and note, the badge on the tiles and the Show menu's list.
///
/// ALL IN MEMORY. The sample has no missing files, no copies and no orphaned
/// product, so they are made here: copies of its own rows with one field
/// changed each, where the bytes are said by `pretendHealthPresence`, and one
/// product whose model is gone by `pretendProducts`. Nothing is written, and
/// the sample is loaded again at the end.
extension Snapshot {

    static func captureLibraryHealth(_ shop: Shop, into dir: URL, dark: Bool) async {
        let tag = dark ? "-dark" : ""
        await shop.load(.sample)
        shop.pretendsWritable = true
        shop.pretendsControl = true
        defer { shop.pretendsWritable = false; shop.pretendsControl = false; shop.pretendHealthPresence = nil }
        shop.clearLibraryFilter()
        shop.libraryFlat = true
        shop.shelf = .library(nil)
        shop.fileSelection = []

        let (rows, presence) = healthRows(shop.libraryRows)
        shop.pretendLibrary(rows)
        shop.libraryRows = rows
        shop.pretendHealthPresence = presence
        shop.pretendProducts(shop.productRows + [Self.orphanProduct])
        shop.recountLibrarySoon()
        await shop.settleLibraryFacets()

        // 1. Every group.
        shop.openLibraryHealth()
        await shop.checkLibraryHealth()
        await settle(); await settle()
        try? await Task.sleep(for: .milliseconds(400))
        capture(named: "lh-01-health" + tag, into: dir)
        capturePanes(named: "lh-01-health" + tag, into: dir)

        // 2. One group on the grid, from its Show button: the Show menu
        // names it, and Clear filters takes it off.
        if let missing = shop.libraryHealthGroups?.first(where: { $0.kind == .missing }) {
            shop.showHealthGroup(missing)
            await shop.settleLibraryFacets()
            await settle(); await settle()
            capture(named: "lh-02-missing-on-grid" + tag, into: dir)
        }
        // 3. The copies side by side.
        if let copies = shop.libraryHealthGroups?.first(where: { $0.kind == .looksSame }) {
            shop.showHealthGroup(copies)
            await shop.settleLibraryFacets()
            await settle(); await settle()
            capture(named: "lh-03-looks-same-on-grid" + tag, into: dir)
        }
        shop.clearLibraryFilter()

        // 4–5. Print next: the card, with its note, and the list.
        shop.fileSelection = ["PF-sample-lantern"]
        await settle(); await settle()
        capture(named: "lh-04-print-next-card" + tag, into: dir)
        capturePanes(named: "lh-04-print-next-card" + tag, into: dir)
        shop.fileSelection = []
        shop.libraryPrintNextOnly = true
        await shop.settleLibraryFacets()
        await settle(); await settle()
        try? await Task.sleep(for: .milliseconds(400))
        capture(named: "lh-05-print-next-list" + tag, into: dir)
        shop.libraryPrintNextOnly = false

        // 6. Nothing to fix.
        await shop.load(.sample)
        shop.pretendsWritable = true
        let clean = shop.libraryRows.filter { ["PF-sample-lantern", "PF-sample-dallah"].contains(Shop.recordId($0) ?? "") }
        shop.pretendLibrary(clean)
        shop.libraryRows = clean
        shop.pretendHealthPresence = [:]
        shop.pretendProducts([])
        shop.openLibraryHealth()
        await shop.checkLibraryHealth()
        await settle(); await settle()
        capture(named: "lh-06-all-good" + tag, into: dir)

        shop.libraryHealthOpen = false
        shop.pretendHealthPresence = nil
        await shop.load(.sample)
        await settle()
    }

    /// A product that prints from a model nobody has any more.
    static let orphanProduct: JSONValue = .object([
        "id": .string("PRD-snap-orphan"), "name": .string("Desk organiser"),
        "parts": .array([.object(["name": .string("Tray"), "printFileId": .string("PF-deleted-long-ago")])]),
    ])

    /// The sample's rows with one of every problem added, and where each
    /// model's bytes are.
    static func healthRows(_ rows: [JSONValue]) -> ([JSONValue], [String: LibraryHealth.Presence]) {
        var out = rows
        var presence: [String: LibraryHealth.Presence] = [:]
        func copy(_ id: String, as newId: String, _ change: (inout [String: JSONValue]) -> Void) {
            guard let row = rows.first(where: { Shop.recordId($0) == id }), case .object(var o) = row else { return }
            o["id"] = .string(newId)
            o.removeValue(forKey: "printNextAt")
            o.removeValue(forKey: "printNextFor")
            change(&o)
            out.append(.object(o))
        }
        func edit(_ id: String, _ change: (inout [String: JSONValue]) -> Void) {
            guard let i = out.firstIndex(where: { Shop.recordId($0) == id }), case .object(var o) = out[i] else { return }
            change(&o)
            out[i] = .object(o)
        }
        // The same file twice: the falcon hood imported again.
        copy("PF-sample-falcon", as: "PF-snap-falcon-again") { $0["name"] = .string("Falcon hood (import 2)") }
        // Looks the same: the bracket, mirrored — different bytes, same key.
        copy("PF-sample-bracket", as: "PF-snap-bracket-mirror") {
            $0["name"] = .string("Turbine bracket — mirrored")
            $0["contentHash"] = .string("snapshot-mirror-hash")
        }
        // Missing: two models whose files are gone, one filed in a group.
        presence["PF-sample-king-6"] = .missing
        presence["PF-sample-gripper"] = .missing
        // Online and never measured.
        copy("PF-sample-vase", as: "PF-snap-vase-online") {
            $0["name"] = .string("Spiral vase — 150 mm")
            $0["contentHash"] = .null; $0["geometryKey"] = .null; $0["parsed"] = .object([:])
        }
        presence["PF-snap-vase-online"] = .online
        // On this Mac with no figures at all.
        copy("PF-sample-gripper", as: "PF-snap-gripper-raw") {
            $0["name"] = .string("Gripper fingers — raw export")
            $0["contentHash"] = .string("snapshot-raw-hash")
            $0["geometryKey"] = .null; $0["parsed"] = .object([:]); $0["colors"] = .array([])
        }
        // Too big: a King relief at a metre.
        edit("PF-sample-king-2") { $0["geometryKey"] = .string("6290060:117171.2:1141.57x757.09x207.37") }
        // Nothing to find them by: the dental set with no category or tags.
        edit("PF-sample-dental-a") { $0["category"] = .null; $0["tags"] = .array([]) }
        edit("PF-sample-dental-b") { $0["category"] = .null; $0["tags"] = .array([]) }
        for row in out { if let id = Shop.recordId(row), presence[id] == nil { presence[id] = .here } }
        return (out, presence)
    }
}
