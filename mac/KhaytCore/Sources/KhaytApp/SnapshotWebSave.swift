import AppKit
import SwiftUI
import KhaytCore
import KhaytWebSave

/// ── SAVE TO KHAYT ─────────────────────────────────────────────────────────
///
/// `KHAYT_SNAPSHOT_WEBSAVE=1`: the "Saved from web" smart folder with three
/// pages saved from Printables, MakerWorld and Thingiverse, one of them open in
/// the inspector ("From the web", Open Page), and Settings ▸ Preferences ▸
/// Browser extension on its own, with Safari reported on and a page saved.
///
/// ALL IN MEMORY. The saved pages are made by `WebSaveRecord.apply` — the
/// rule a real save goes through — over the sample's rows and put up with
/// `pretendLibrary`; their covers are drawn here, not fetched. Nothing is
/// written, and the sample is loaded again at the end.
extension Snapshot {

    static func captureWebSave(_ shop: Shop, into dir: URL, dark: Bool) async {
        let tag = dark ? "-dark" : ""
        await shop.load(.sample)
        shop.clearLibraryFilter()
        shop.search = ""
        shop.libraryFlat = true
        shop.fileSelection = []

        var rows = shop.libraryRows
        let saved = webSavedPages()
        for (i, (page, colour)) in saved.enumerated() {
            let id = "PF-snap-web-\(i + 1)"
            WebSaveRecord.apply(page, to: &rows, newId: id, nowMs: Date().timeIntervalSince1970 * 1000 - Double(i) * 3_600_000,
                                nowISO: StoreWriter.iso(Date().addingTimeInterval(-Double(i) * 86_400)))
            if let uri = cover(colour) { _ = WebSaveRecord.setCover(uri, id: id, in: &rows) }
        }
        shop.pretendLibrary(rows)
        shop.libraryRows = rows
        shop.recountLibrarySoon()
        shop.openLibraryQuery(LibrarySmartFolder.fromWeb.query)
        await shop.settleLibraryFacets()
        await settle(); await settle()

        // 1. The smart folder, with the three pages on the grid.
        captureMain(named: "ws-01-saved-from-web" + tag, into: dir)
        capturePanes(named: "ws-01-saved-from-web" + tag, into: dir)

        // 2. One open in the inspector: where it came from, and Open Page.
        shop.fileSelection = ["PF-snap-web-1"]
        await settle(); await settle()
        captureMain(named: "ws-02-inspector" + tag, into: dir)
        capturePanes(named: "ws-02-inspector" + tag, into: dir)

        // 3. Settings ▸ Preferences ▸ Browser extension, on its own window so
        //    the section is the whole picture (the pane is longer than the
        //    window, and where in its scroll the section falls moves with
        //    every row added above it).
        BrowserExtensionSettings.pretendSafari = .on
        WebSaveInbox.shared.pretendLastSaved(title: saved[0].0.title)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 460),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = shop.words.callIt("mac.sfw_settings")
        window.contentView = NSHostingView(rootView:
            Form { BrowserExtensionSettings(shop: shop) }
                .formStyle(.grouped)
                .frame(width: 600, height: 460))
        window.center()
        window.makeKeyAndOrderFront(nil)
        await settle(); await settle()
        capture(named: "ws-03-settings" + tag, window: window, into: dir)

        // 4. And without an app group (an ad-hoc build): said, not hidden.
        WebSaveInbox.shared.directory = { nil }
        await settle(); await settle()
        capture(named: "ws-04-settings-no-group" + tag, window: window, into: dir)
        window.close()

        WebSaveInbox.shared.directory = { WebInbox.directory() }
        WebSaveInbox.shared.pretendLastSaved(title: nil)
        BrowserExtensionSettings.pretendSafari = nil
        shop.fileSelection = []
        shop.clearLibraryFilter()
        await shop.load(.sample)
        await settle()
    }

    /// Three pages, as the extension would read them, each with its colour.
    static func webSavedPages() -> [(WebSave.Page, NSColor)] {
        [
            (WebSave.Page(url: "https://www.printables.com/model/123456-articulated-dragon", site: .printables,
                          title: "Articulated Dragon", creator: "Maker Bob", licence: "cc-by-nc-sa",
                          description: "A print-in-place dragon. No supports, about 4 h on a 0.4 mm nozzle.",
                          tags: ["dragon", "flexi", "print-in-place"],
                          files: [.init(url: "https://files.printables.com/dragon_body.3mf", name: "dragon_body.3mf")]),
             .systemTeal),
            (WebSave.Page(url: "https://makerworld.com/en/models/88231", site: .makerworld,
                          title: "Gridfinity Bin 2x3", creator: "Grid Maker", licence: "Standard Digital File License",
                          description: "A stackable bin for the 42 mm grid.", tags: ["gridfinity", "storage"]),
             .systemOrange),
            (WebSave.Page(url: "https://www.thingiverse.com/thing:4711", site: .thingiverse,
                          title: "Cable Clip", creator: "printguy", licence: "cc-by",
                          description: "Clips onto a desk edge.", tags: ["cable", "desk"]),
             .systemPurple),
        ]
    }

    /// A cover picture, drawn — what a fetched one becomes (`LibraryPhoto`).
    static func cover(_ colour: NSColor) -> String? {
        let image = NSImage(size: NSSize(width: 480, height: 360), flipped: false) { rect in
            NSGradient(starting: colour.blended(withFraction: 0.35, of: .white) ?? colour, ending: colour)?
                .draw(in: rect, angle: -60)
            let symbol = NSImage(systemSymbolName: "cube.transparent", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 150, weight: .light))
            symbol?.draw(in: NSRect(x: 150, y: 90, width: 180, height: 180), from: .zero,
                         operation: .sourceOver, fraction: 0.55)
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        return Shop.coverURI(png)
    }
}

extension WebSaveInbox {
    /// A page saved, for a snapshot of the Settings row. Nil clears it.
    func pretendLastSaved(title: String?) { setLastSaved(title.map { ($0, Date()) }) }
}
