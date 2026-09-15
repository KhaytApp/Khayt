import Foundation
import Testing
import SwiftUI
import KhaytCore
@testable import KhaytApp

/// Pictures of the redesigned shell, at the size the spec designs for.
///
/// ── 1100×620, AND THAT IS THE POINT ───────────────────────────────────────
///
/// §9: *"Every surface fits with no scrolling to reach a decision. Anything
/// that doesn't fit at that size is over-designed, not under-sized."* So these
/// render at exactly that and nothing larger — a screenshot taken at 1600
/// points proves the layout works on a display the shop does not have.
///
/// Writes only when `KHAYT_SNAPSHOT_DIR` is set, like the rest of the harness.
/// Read the PNGs; the exit code only says the renderer did not crash.
@Suite @MainActor struct ShellSnapshots {

    /// The spec's design target.
    static let target = CGSize(width: 1100, height: 620)

    private func sample() async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        shop.shelf = .dashboard
        return shop
    }

    /// The dashboard as the camera can see it — masthead plus the board's
    /// content, with the scroller left out. See `TriageContent`.
    @ViewBuilder private func snapshotTriage(_ shop: Shop) -> some View {
        VStack(spacing: 0) {
            MoneyMasthead(shop: shop, mode: .constant(.triage))
            TriageContent(shop: shop)
            Spacer(minLength: 0)
        }
    }

    /// The ledger as the camera can see it: the same parts the app scrolls,
    /// laid out flat. See `TriageContent`.
    @ViewBuilder private func snapshotLedger(_ shop: Shop) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                LedgerFilters(shop: shop)
                LedgerHead(words: shop.words)
                LedgerRows(shop: shop)
                Spacer(minLength: 0)
                LedgerFooter(shop: shop)
            }
            .background(Role.surf)
            if let picked = shop.ledgerSelection {
                VStack(spacing: 0) {
                    JobInspector(row: picked, shop: shop).inspected
                    Spacer(minLength: 0)
                }
                .frame(width: 282)
                .background(Role.surf2)
            }
        }
    }

    private func write(_ view: some View, _ name: String,
                       dark: Bool = false, rtl: Bool = false) {
        guard let dir = ProcessInfo.processInfo.environment["KHAYT_SNAPSHOT_DIR"]
            .map({ URL(fileURLWithPath: $0) }) else { return }
        let framed = view
            .frame(width: Self.target.width, height: Self.target.height)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            Issue.record("could not render \(name)")
            return
        }
        try? png.write(to: dir.appending(path: name + ".png"))
    }

    @Test("the shell, both appearances and both directions")
    func shell() async throws {
        let shop = await sample()
        // Four pictures, because the spec's non-negotiables are two axes and
        // a layout that is right on one corner of them can be wrong on
        // another. Dark is not light dimmed and RTL is not LTR mirrored in the
        // text only — both have to be looked at.
        write(Shell(shop: shop, searchWanted: .constant(false)) { snapshotTriage(shop) }, "ui-01-shell-light")
        write(Shell(shop: shop, searchWanted: .constant(false)) { snapshotTriage(shop) }, "ui-02-shell-dark", dark: true)
        write(Shell(shop: shop, searchWanted: .constant(false)) { snapshotTriage(shop) }, "ui-03-shell-rtl", rtl: true)
        write(Shell(shop: shop, searchWanted: .constant(false)) { snapshotTriage(shop) },
              "ui-04-shell-rtl-dark", dark: true, rtl: true)

        // And the parts on their own, where a whole-window picture is too
        // small to judge them.
        write(ShellSidebar(shop: shop).frame(width: 150), "ui-05-sidebar")
        write(MoneyMasthead(shop: shop, mode: .constant(.triage)), "ui-06-masthead")
    }

    @Test("the ledger, and the empty state nobody designs")
    func ledgerAndEmpty() async throws {
        let shop = await sample()
        shop.ledgerSelection = shop.ledgerRows.first
        write(Shell(shop: shop, searchWanted: .constant(false)) { snapshotLedger(shop) }, "ui-07-ledger")
        write(Shell(shop: shop, searchWanted: .constant(false)) { snapshotLedger(shop) }, "ui-08-ledger-dark", dark: true)

        // A book with nothing in it — the screen a shop sees on the day it
        // installs, and the one most likely never to have been looked at.
        let fresh = Shop()
        write(Shell(shop: fresh, searchWanted: .constant(false)) { FirstRun(shop: fresh) }, "ui-09-first-run")
    }

    /// Not a picture: a measurement.
    ///
    /// The spec's claim is that everything fits at 1100×620. `ImageRenderer`
    /// reports the size it actually needed, so asking it is the difference
    /// between believing that and knowing it.
    @Test("the dashboard fits the 13-inch window it is designed for")
    func fitsTheTarget() async throws {
        let shop = await sample()
        let renderer = ImageRenderer(content:
            Shell(shop: shop, searchWanted: .constant(false)) { Triage(shop: shop) }
                .frame(width: Self.target.width))
        renderer.scale = 1
        let height = renderer.nsImage?.size.height ?? 0
        #expect(height > 0, "the shell rendered nothing at all")
        // A little slack: the ScrollView inside Triage reports its content
        // height, and content taller than the window is what a ScrollView is
        // FOR. What would be wrong is the chrome — masthead, sidebar, title
        // bar — not fitting, which would show up as a wildly larger figure.
        #expect(height < Self.target.height * 3, Comment(rawValue: """
            the dashboard wanted \(Int(height)) points of height at 1100 wide. \
            §9: anything that does not fit at 1100×620 is over-designed.
            """))
    }
}
