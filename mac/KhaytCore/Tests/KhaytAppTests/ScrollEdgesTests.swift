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
        for offset: CGFloat in [-400, -120, 0, 120, 400] {
            #expect(ScrollEdges.hidden(offset: offset, container: 800, content: 300) == .none, "offset \(offset)")
        }
        #expect(ScrollEdges.hidden(offset: 0, container: 800, content: 800.5) == .none)
    }

    /// From the leading edge, so the same three hold in Arabic: see
    /// `aRealRowAtRest`, which asks a right-to-left scroll view.
    @Test("nothing before the start and a fade after; both in the middle; only before at the end")
    func threePlaces() {
        #expect(ScrollEdges.hidden(offset: 0, container: 300, content: 900)
                == ScrollEdges(before: false, after: true))
        #expect(ScrollEdges.hidden(offset: 200, container: 300, content: 900)
                == ScrollEdges(before: true, after: true))
        #expect(ScrollEdges.hidden(offset: 600, container: 300, content: 900)
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
    /// assumes. This asks one. (It answered: from the leading edge, in both
    /// directions. A first version of the fix mirrored the offset for Arabic
    /// and this test is what refused it.) When a headless run reports no geometry at all
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
                let edges = ScrollEdges.hidden(offset: g.x, container: g.container, content: g.content)
                #expect(!edges.before,
                        "the first chip is faded at rest: chips \(chips), rtl \(rtl), offset \(g.x), container \(g.container), content \(g.content)")
                #expect(edges.after == (chips == 40),
                        "chips \(chips), rtl \(rtl), offset \(g.x), container \(g.container), content \(g.content)")
            }
        }
    }

    /// What the Arabic capture showed after the fade was ruled out: the chip
    /// was still cut. A row that fits is drawn without a scroll view at all.
    @Test("the filter bar scrolls only when its chips do not fit")
    func fitsWithoutAScrollView() throws {
        let source = try #require(IconSources.all.first { $0.name == "FilterBar.swift" }).text
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).components(separatedBy: "//").first ?? "" }.joined(separator: "\n")
        let fits = try #require(code.components(separatedBy: "ViewThatFits(in: .horizontal) {").last)
        let first = try #require(fits.split(separator: "\n").map(String.init)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        #expect(first.contains("row.frame(maxWidth: .infinity, alignment: .leading)"),
                "the first choice must be the plain row; a scroll view always fits")
        #expect(fits.contains("ScrollView(.horizontal) { row }"))
    }
}
