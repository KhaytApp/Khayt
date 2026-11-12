import AppKit
import SwiftUI
import Testing
import KhaytCore
@testable import KhaytApp

/// A sheet's margins are INSIDE its scroll view, its content ends with a foot,
/// and the New Job total is over the buttons (Nov 11 2026 UI review, B4, B5).
@Suite(.serialized) @MainActor struct SheetFrameMarginTests {

    @Test("more content than room is what draws the rule over the buttons")
    func overflowIsTheCue() {
        #expect(!SheetMetrics.overflows(content: 400, room: 400))
        // Half a point is two sizes that are the same size.
        #expect(!SheetMetrics.overflows(content: 400.5, room: 400))
        #expect(SheetMetrics.overflows(content: 700, room: 400))
        #expect(SheetMetrics.contentFoot >= 8, "the last row needs room over the rule")
    }

    /// The fault was a clip: the frame padded the OUTSIDE of its scroll view,
    /// so the scroll view was exactly as wide as the content and cut the
    /// border off every full-width field.
    @Test("the frame pads inside its scroll view, never round it")
    func marginIsInside() throws {
        let source = try #require(IconSources.all.first { $0.name == "SheetFrame.swift" }).text
        let body = try #require(source.components(separatedBy: "struct SheetFrame").last)
        let code = body.split(separator: "\n").map { String($0).components(separatedBy: "//").first ?? "" }
            .joined(separator: "\n")
        let scroll = try #require(code.components(separatedBy: "ScrollView(.vertical) {").last?
            .components(separatedBy: ".scrollBounceBehavior").first)
        #expect(scroll.contains(".padding(.horizontal, SheetMetrics.padding)"))
        #expect(scroll.contains(".padding(.bottom, SheetMetrics.contentFoot)"))
        // The old shape: one padding round the whole stack.
        #expect(!code.contains("\n        .padding(SheetMetrics.padding)\n"))
    }

    /// Every descendant of a view, depth first.
    static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// Measured, where AppKit will say: a sheet is as wide as its content plus
    /// both margins, and no control in it reaches into a margin's outer half.
    @Test("no field of the customer, product or machine sheet reaches the sheet's edge")
    func fieldsStayInside() {
        let shop = Shop()
        let sheets: [(String, CGFloat, AnyView)] = [
            ("CustomerSheet", CustomerSheet.width, AnyView(CustomerSheet(shop: shop, existing: Shop.newCustomer()))),
            ("ProductSheet", ProductSheet.width, AnyView(ProductSheet(shop: shop, existing: shop.newProduct()))),
            ("MachineSheet", MachineSheet.width, AnyView(MachineSheet(shop: shop, existing: shop.machines.first))),
        ]
        SheetsFitALaptopTests.onALaptop {
            for (name, width, view) in sheets {
                let host = NSHostingView(rootView: view)
                let size = host.fittingSize
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let outer = SheetMetrics.outerWidth(width)
                #expect(abs(size.width - outer) < 1, "\(name) is \(size.width) wide, not \(outer)")
                // The scroll view runs edge to edge now; it used to stop at
                // the content, which is where it clipped.
                // The frame's own scroll view: the outermost one, not a notes
                // editor inside it.
                let scrolls = Self.descendants(of: host).compactMap { $0 as? NSScrollView }
                    .filter { $0.enclosingScrollView == nil }
                for scroll in scrolls {
                    let frame = scroll.convert(scroll.bounds, to: host)
                    #expect(frame.width >= outer - 1,
                            "\(name): its scroll view is \(frame.width) wide in a \(outer) sheet and clips at the content")
                }
                let half = SheetMetrics.padding / 2
                for field in Self.descendants(of: host).compactMap({ $0 as? NSTextField })
                where field.isBezeled || field.isBordered {
                    let frame = field.convert(field.bounds, to: host)
                    #expect(frame.minX >= half && frame.maxX <= outer - half,
                            "\(name): a field runs \(frame.minX)…\(frame.maxX) in a \(outer) sheet")
                }
            }
        }
    }

    @Test("New Job keeps its total over the buttons, outside the scrolling part")
    func totalIsPinned() throws {
        let source = try #require(IconSources.all.first { $0.name == "NewJobSheet.swift" }).text
        #expect(source.contains("ScrollView { scrolled }"))
        let scrolled = try #require(source.components(separatedBy: "var scrolled: some View {").last?
            .components(separatedBy: "static let width").first)
        let code = scrolled.split(separator: "\n").map { String($0).components(separatedBy: "//").first ?? "" }
        #expect(!code.contains { $0.trimmingCharacters(in: .whitespaces) == "total" },
                "the total is back inside the part that scrolls")
        #expect(source.contains("pinnedTotal\n            footer"))
    }
}
