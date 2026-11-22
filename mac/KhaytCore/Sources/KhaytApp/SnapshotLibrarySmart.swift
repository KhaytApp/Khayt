import AppKit
import SwiftUI
import KhaytCore

/// ── SMART FOLDERS, SAVED SEARCHES AND RANGES ────────────────────────────
///
/// `KHAYT_SNAPSHOT_LIBSMART=1`: the sidebar's smart folders with their
/// counts, the sample's saved search opened (a range, and its order), the
/// Ranges popover, Save Search…, a built-in folder, Edit Search's Update
/// button, and the same on a 600-model library built in memory from the
/// sample's own rows (`scaled`, the grid scene's).
///
/// ALL IN MEMORY. Nothing is saved — the sample has no build to write to —
/// and the sample is loaded again at the end.
extension Snapshot {

    static func captureLibrarySmart(_ shop: Shop, into dir: URL, dark: Bool) async {
        let tag = dark ? "-dark" : ""
        await shop.load(.sample)
        shop.clearLibraryFilter()
        shop.search = ""
        shop.libraryFlat = true
        shop.shelf = .library(nil)
        shop.fileSelection = []
        await shop.settleLibraryFacets()
        await settle()

        // 1. The library, with the smart folders under it in the sidebar.
        captureMain(named: "ls-01-sidebar" + tag, into: dir)

        // 2. The sample's saved search, opened: a range and its order.
        if let saved = shop.librarySmartRows.first(where: { $0.saved != nil }) {
            shop.openSmartRow(saved)
            await shop.settleLibraryFacets()
            await settle()
            captureMain(named: "ls-02-saved-open" + tag, into: dir)

            // 3. Its ranges, in the popover, with what each leaves out.
            shop.libraryRangesShown = true
            await settle(); await settle()
            captureMain(named: "ls-03-ranges" + tag, into: dir)
            capturePopover(named: "ls-03-ranges-popover" + tag, into: dir)
            shop.libraryRangesShown = false
            await settle()

            // 4. Edit Search, then a change: the bar offers Update.
            shop.openSmartRow(saved, editing: true)
            shop.libraryCategory = .named("Decorative")
            await shop.settleLibraryFacets()
            await settle()
            captureMain(named: "ls-04-editing" + tag, into: dir)

            // 5. Save Search…, with a name typed over the one being edited.
            shop.librarySaveSearchShown = true
            await settle(); await settle()
            capturePopover(named: "ls-05-save-popover" + tag, into: dir)
            shop.librarySaveSearchShown = false
            shop.libraryEditingSearchId = nil
            await settle()
        }

        // 6. A built-in one: no print figures.
        shop.openLibraryQuery(LibrarySmartFolder.noFigures.query)
        await shop.settleLibraryFacets()
        await settle()
        captureMain(named: "ls-06-builtin-no-figures" + tag, into: dir)

        // 7. Ranges with a date: added in the last 90 days, under 200 g.
        shop.clearLibraryFilter()
        var r = LibraryQuery.Ranges()
        r.grams = .init(max: 200)
        r.added = .init(lastDays: 90)
        shop.libraryRanges = r
        shop.libraryRangesShown = true
        await shop.settleLibraryFacets()
        await settle(); await settle()
        capturePopover(named: "ls-07-ranges-dates-popover" + tag, into: dir)
        shop.libraryRangesShown = false
        await settle()

        // 8. Six hundred models: the sidebar's counts and a range on.
        shop.clearLibraryFilter()
        shop.pretendLibrary(Self.scaled(shop.libraryRows, to: 600))
        shop.libraryRanges.minutes = .init(min: 60, max: 300)
        shop.shelf = .library(nil)
        await shop.settleLibraryFacets()
        await settle(); await settle()
        captureMain(named: "ls-08-scale-range" + tag, into: dir)

        shop.clearLibraryFilter()
        await shop.load(.sample)
        await settle()
    }

    /// The shop's window — the biggest visible one, never a popover.
    static func captureMain(named name: String, into dir: URL) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil && !isPopover($0) }
        guard let main = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else { return capture(named: name, into: dir) }
        capture(named: name, window: main, into: dir)
    }

    /// The open popover's own window.
    static func capturePopover(named name: String, into dir: URL) {
        guard let pop = NSApp.windows.first(where: { $0.isVisible && isPopover($0) }) else {
            FileHandle.standardError.write(Data("no popover to capture for \(name)\n".utf8))
            return
        }
        capture(named: name, window: pop, into: dir)
    }

    static func isPopover(_ w: NSWindow) -> Bool {
        String(describing: type(of: w)).localizedCaseInsensitiveContains("popover")
    }
}
