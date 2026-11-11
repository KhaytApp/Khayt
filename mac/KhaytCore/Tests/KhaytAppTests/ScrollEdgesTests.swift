import AppKit
import SwiftUI
import Testing
@testable import KhaytApp

/// The fade at the end of a horizontal row is on the end that has more, in
/// both writing directions (Nov 11 2026 UI review, B19: in Arabic the first
/// filter chip of Gift cards and the Catalogue was faded out, "ـطة 3").
@MainActor struct ScrollEdgesTests {

    @Test("a row that fits fades nowhere, whatever its offset reads")
    func fitsMeansNoFade() {
        for rtl in [false, true] {
            for offset: CGFloat in [-400, -120, 0, 120, 400] {
                #expect(ScrollEdges.hidden(offset: offset, container: 800, content: 300, rightToLeft: rtl) == .none,
                        "offset \(offset), rtl \(rtl)")
            }
            // With the row's own margins counted: 28 of padding either side.
            #expect(ScrollEdges.hidden(offset: 0, container: 800, content: 760,
                                       insetLow: 0, insetHigh: 0, rightToLeft: rtl) == .none)
        }
    }

    @Test("left to right: nothing before the start, a fade after; both in the middle; only before at the end")
    func leftToRight() {
        #expect(ScrollEdges.hidden(offset: 0, container: 300, content: 900, rightToLeft: false)
                == ScrollEdges(before: false, after: true))
        #expect(ScrollEdges.hidden(offset: 200, container: 300, content: 900, rightToLeft: false)
                == ScrollEdges(before: true, after: true))
        #expect(ScrollEdges.hidden(offset: 600, container: 300, content: 900, rightToLeft: false)
                == ScrollEdges(before: true, after: false))
    }

    /// A right-to-left row rests at its RIGHT end: everything still to come is
    /// to the left, which is its trailing side.
    @Test("right to left: the same three, mirrored")
    func rightToLeft() {
        #expect(ScrollEdges.hidden(offset: 600, container: 300, content: 900, rightToLeft: true)
                == ScrollEdges(before: false, after: true))
        #expect(ScrollEdges.hidden(offset: 200, container: 300, content: 900, rightToLeft: true)
                == ScrollEdges(before: true, after: true))
        #expect(ScrollEdges.hidden(offset: 0, container: 300, content: 900, rightToLeft: true)
                == ScrollEdges(before: true, after: false))
    }

    /// What a real scroll view reports at rest, read from one.
    final class Reading { var seen: [(x: CGFloat, container: CGFloat, content: CGFloat)] = [] }

    static func atRest(chips: Int, rtl: Bool) -> (x: CGFloat, container: CGFloat, content: CGFloat)? {
        let reading = Reading()
        let row = ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(0..<chips, id: \.self) { _ in Color.gray.frame(width: 60, height: 16) }
            }
        }
        .onScrollGeometryChange(for: [CGFloat].self) { g in
            [g.contentOffset.x, g.containerSize.width, g.contentSize.width]
        } action: { _, now in
            reading.seen.append((now[0], now[1], now[2]))
        }
        .frame(width: 300, height: 40)
        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 40),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: row)
        window.contentView?.layoutSubtreeIfNeeded()
        // The geometry is reported on a later turn of the run loop.
        for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        window.contentView?.layoutSubtreeIfNeeded()
        return reading.seen.last
    }

    /// The arithmetic above is only right if a scroll view counts the way it
    /// assumes. This asks one. When a headless run reports no geometry at all
    /// there is nothing to compare, and the test says so rather than passing
    /// as though it had looked.
    @Test("a real right-to-left row at rest fades its far end and never its first chip")
    func aRealRowAtRest() {
        for rtl in [false, true] {
            for chips in [3, 40] {
                guard let g = Self.atRest(chips: chips, rtl: rtl) else {
                    print("ScrollEdgesTests: no geometry reported (chips \(chips), rtl \(rtl))")
                    continue
                }
                print("ScrollEdgesTests: chips \(chips) rtl \(rtl) offset \(g.x) container \(g.container) content \(g.content)")
                let edges = ScrollEdges.hidden(offset: g.x, container: g.container, content: g.content, rightToLeft: rtl)
                #expect(!edges.before,
                        "the first chip is faded at rest: chips \(chips), rtl \(rtl), offset \(g.x), container \(g.container), content \(g.content)")
                #expect(edges.after == (chips == 40),
                        "chips \(chips), rtl \(rtl), offset \(g.x), container \(g.container), content \(g.content)")
            }
        }
    }
}
