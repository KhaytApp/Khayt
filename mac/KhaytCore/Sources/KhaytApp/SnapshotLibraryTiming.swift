import AppKit
import SwiftUI
import KhaytCore

/// `KHAYT_SNAPSHOT_LIBTIME=1` (with `KHAYT_SNAPSHOT_REAL=1` for the shop's
/// own book, read-only) — how long opening the Library holds the main thread.
///
/// Nov 2 2026: a shop with 14,151 models in 1,200 groups waited seconds for
/// the Library to appear. The sample has fifteen models and cannot show it.
/// Each round goes Board → Library and times the switch plus the layout and
/// drawing it causes, then times the shop-side figures the screen reads, each
/// on its own, so a slow one is named rather than guessed at.
///
/// The cause that day was the filter bar's `ViewThatFits` building every
/// candidate row with full menus: 1,100 ms with the display asleep and about
/// 6 s with it awake, down to ~350 ms (`LibraryFilterBar`). It was found by
/// leaving each part of the screen out in turn and timing what was left.
extension Snapshot {
    static func timeLibrary(_ shop: Shop, into dir: URL) async {
        func say(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
        func ms(_ start: ContinuousClock.Instant) -> String {
            let d = ContinuousClock.now - start
            return String(format: "%.0f ms", Double(d.components.attoseconds) / 1e15
                          + Double(d.components.seconds) * 1000)
        }
        await settle()
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil
            && $0.frame.width >= 600 }) else { say("libtime: no window"); return }
        say("libtime: \(shop.files.count) models, \(shop.groups.count) groups")
        for round in 1...3 {
            shop.shelf = .board
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            await settle()
            let t = ContinuousClock.now
            shop.shelf = .library(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            say("libtime round \(round): board → library \(ms(t))")
            await settle()
        }
        // Every other screen, the same way: one switch from the Board, timed
        // through its layout and drawing, twice (the first pays for anything
        // made once).
        let screens: [(String, Shop.Shelf)] = [
            ("dashboard", .dashboard), ("jobs", .jobs(nil)), ("customers", .customers),
            ("machines", .machines), ("inventory", .inventory), ("expenses", .expenses),
            ("waste", .waste), ("reports", .reports), ("catalogue", .catalogue),
            ("colour", .colour), ("calculator", .calculator), ("portfolio", .portfolio),
            ("giftCards", .giftCards)]
        for (name, shelf) in screens {
            for round in 1...2 {
                shop.shelf = .board
                window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                await settle()
                let t = ContinuousClock.now
                shop.shelf = shelf
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                say("libtime screen \(name) round \(round): \(ms(t))")
                await settle()
            }
        }
        // `KHAYT_SNAPSHOT_SCREENLOOP=jobs:n`: switch to that screen n times
        // over, for a `sample` of where the switch spends its time.
        if let spec = ProcessInfo.processInfo.environment["KHAYT_SNAPSHOT_SCREENLOOP"],
           let colon = spec.firstIndex(of: ":"), let n = Int(spec[spec.index(after: colon)...]),
           let shelf = screens.first(where: { $0.0 == String(spec[..<colon]) })?.1 {
            say("libtime: screen loop start")
            let loopStart = ContinuousClock.now
            for _ in 0..<n {
                shop.shelf = .board
                window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                shop.shelf = shelf
                window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                await Task.yield()
            }
            say("libtime: screen loop end, \(n) in \(ms(loopStart))")
        }
        shop.shelf = .library(nil)
        await settle()
        // The figures the screen reads, each alone, after it has drawn once.
        var t = ContinuousClock.now
        _ = shop.groups; say("libtime   groups \(ms(t))")
        t = .now; _ = shop.folderPaths; say("libtime   folderPaths \(ms(t))")
        t = .now; _ = shop.visibleGroupPaths; say("libtime   visibleGroupPaths \(ms(t))")
        t = .now; _ = shop.selectedGroups; say("libtime   selectedGroups \(ms(t))")
        t = .now
        for row in shop.librarySmartRows { _ = shop.libraryCount(row.query) }
        say("libtime   smart-row counts (\(shop.librarySmartRows.count)) \(ms(t))")
        t = .now; _ = shop.memoEntries(); say("libtime   memoEntries \(ms(t))")
        t = .now; _ = shop.memoShownFiles(); say("libtime   memoShownFiles \(ms(t))")
        say("libtime: selected \(shop.selectedFiles.count) models")
        // Choosing models: the toolbar's Group menu, the Edit menu and the
        // inspector each list every group once something is chosen.
        let tiles = shop.visibleFiles
        say("libtime: \(tiles.count) model tiles drawn at the top level")
        if tiles.count >= 3 {
            for round in 1...2 {
                shop.clearLibrarySelection()
                window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                await settle()
                t = .now
                shop.select(tiles[0], modifiers: .replace)
                window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                say("libtime round \(round): select one \(ms(t))")
                await settle()
                t = .now
                shop.select(tiles[2], modifiers: .extend)
                window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                say("libtime round \(round): extend to three \(ms(t))")
                await settle()
            }
            shop.clearLibrarySelection()
            await settle()
            // `KHAYT_SNAPSHOT_SELLOOP=n`: choose models n times over, so a
            // `sample` of the process sees where choosing spends its time.
            if let n = Int(ProcessInfo.processInfo.environment["KHAYT_SNAPSHOT_SELLOOP"] ?? "") {
                say("libtime: selection loop start")
                let loopStart = ContinuousClock.now
                // From nothing chosen to one model each time: that is when the
                // inspector and the selection menus appear.
                for i in 0..<n {
                    shop.clearLibrarySelection()
                    window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    shop.select(tiles[i % tiles.count], modifiers: .replace)
                    window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    await Task.yield()
                }
                say("libtime: selection loop end, \(n) in \(ms(loopStart))")
            }
        }
        // The filter bar at a wide and a narrow window: how many axis menus
        // it chose to draw inline is visible in the picture.
        for width in [1500.0, 1000.0] {
            window.setContentSize(NSSize(width: width, height: 800))
            await settle(); await settle()
            say("libtime   window now \(Int(window.frame.width))pt")
            capture(named: "libtime-\(Int(width))", window: window, into: dir)
        }
    }
}
