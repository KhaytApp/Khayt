import AppKit
import SwiftUI
import KhaytCore

/// `KHAYT_SNAPSHOT_SETTINGS=1` — only the Settings window: every pane at the
/// size it opens at and at the smallest the shop can drag it to, with a line
/// for each pane saying whether it fits the window.
///
/// Nov 1: the Online pane ran off the window in a shop using the Vault and
/// the store quote form, and the sample (signed out) could not show it. With
/// `KHAYT_SNAPSHOT_REAL=1` this opens the shop's own book read-only — a
/// running Khayt holds it — so the pane draws what that shop sees. The
/// pictures are of real settings: keep them on this Mac.
extension Snapshot {
    static func captureSettingsOnly(_ shop: Shop, into dir: URL) async {
        await settle()
        let main = NSApp.windows.first { $0.isVisible && $0.contentView != nil }
        if let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.keyEquivalent == "," }) {
            NSApp.sendAction(item.action ?? #selector(NSApplication.terminate(_:)), to: item.target, from: item)
        }
        await settle()
        try? await Task.sleep(for: .seconds(1))
        guard let settings = NSApp.windows.first(where: {
            $0.isVisible && $0 !== main && $0.contentView != nil
                && $0.frame.width >= 300 && $0.frame.height >= 300
        }) else {
            FileHandle.standardError.write(Data("settings-only: no settings window\n".utf8))
            return
        }
        let sizes: [(String, NSSize?)] = [("open", nil), ("min", settings.contentMinSize)]
        for (tag, size) in sizes {
            if let size { settings.setContentSize(size) }
            for pane in SettingsPane.allCases {
                shop.settingsPane = pane
                await settle()
                // The Online pane asks the cloud for the plan, the team and the
                // quote form; give the answers time to arrive and lay out.
                if pane == .online { try? await Task.sleep(for: .seconds(4)); await settle() }
                capture(named: "settings-\(tag)-\(pane.rawValue)", window: settings, into: dir)
                FileHandle.standardError.write(Data((paneFit(settings, "\(tag) \(pane.rawValue)") + "\n").utf8))
            }
        }
        settings.close()
    }

    /// "fits" when the pane's scroll view is no wider than the room beside
    /// the sidebar; "RUNS OFF" with both widths when it is wider. A pane that
    /// grows past the window centres itself over the sidebar and loses its
    /// right edge, and nothing else reports it.
    static func paneFit(_ window: NSWindow, _ label: String) -> String {
        var sidebar: CGFloat = 0, pane: CGFloat = 0
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, !(s.documentView is NSTextView) {
                if s.documentView is NSOutlineView { sidebar = max(sidebar, s.frame.width) }
                else { pane = max(pane, s.frame.width) }
            }
            v.subviews.forEach(walk)
        }
        if let root = window.contentView { walk(root) }
        let room = window.contentLayoutRect.width - sidebar - 1
        let verdict = pane <= room + 0.5 ? "fits" : "RUNS OFF"
        return "settings \(label): \(verdict) — pane \(Int(pane))pt, room \(Int(room))pt, window \(Int(window.frame.width))pt"
    }
}
