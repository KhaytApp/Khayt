import AppKit
import Testing
@testable import KhaytApp

/// A table's heading stays over its own columns (Nov 11 2026 UI review, B20:
/// the Arabic Waste table drew "wasted weight" over the dates).
@MainActor struct TableHeaderFollowsBodyTests {

    @Test("the heading is moved to the body's origin only when they differ")
    func rule() {
        #expect(TableHeaderFollowsBody.correction(header: 0, body: 0) == nil)
        #expect(TableHeaderFollowsBody.correction(header: 0, body: 0.3) == nil)
        #expect(TableHeaderFollowsBody.correction(header: 0, body: 220) == 220)
        #expect(TableHeaderFollowsBody.correction(header: 477, body: 257) == 257)
    }

    /// The real thing, in AppKit: a table wider than its scroll view whose
    /// body has moved without a scroll. The probe puts the heading back.
    @Test("a heading left behind by a resize is put back over its columns")
    func followsTheBody() async throws {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 900, height: 200))
        for i in 0..<6 {
            let column = NSTableColumn(identifier: .init("c\(i)"))
            column.width = 150
            table.addTableColumn(column)
        }
        table.headerView = NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 900, height: 24))
        scroll.documentView = table
        scroll.hasHorizontalScroller = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView = root
        root.addSubview(scroll)
        let probe = TableHeaderFollowsBody.Probe(frame: NSRect(x: 150, y: 100, width: 0, height: 0))
        root.addSubview(probe)
        scroll.tile()
        try await Task.sleep(for: .milliseconds(100))

        let headerClip = try #require(table.headerView?.superview as? NSClipView)
        // The body moves the way a narrowing right-to-left pane moves it:
        // its origin changes and nobody scrolled.
        scroll.contentView.setBoundsOrigin(NSPoint(x: 220, y: 0))
        try await Task.sleep(for: .milliseconds(100))
        #expect(abs(headerClip.bounds.origin.x - scroll.contentView.bounds.origin.x) < 0.5,
                "the heading is at \(headerClip.bounds.origin.x) and the body at \(scroll.contentView.bounds.origin.x)")
    }

    @Test("both tables that share a split view with a summary ask for it")
    func wired() throws {
        let source = try #require(IconSources.all.first { $0.name == "Spending.swift" }).text
        #expect(source.components(separatedBy: ".headerFollowsBody()").count - 1 == 2)
    }
}
