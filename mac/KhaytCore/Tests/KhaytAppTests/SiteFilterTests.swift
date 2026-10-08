import Foundation
import SwiftUI
import Testing
import KhaytCore
@testable import KhaytApp

/// One site at a time (SiteFilter.swift, `lib/site-filter.js`).
///
/// The rule is pinned against the desktop's originals in
/// `test/site-filter.test.js`. These are about the screens: that the sample
/// shop reaches the filter at all, that each narrowed screen really narrows,
/// and that what has no site is still shown.
@Suite @MainActor struct SiteFilterTests {

    static func sample() async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        return shop
    }

    @Test("the sample shop reaches the filter, and every narrowed screen narrows")
    func narrows() async throws {
        let shop = await Self.sample()
        #expect(shop.locations.count == 2, "no sites, no filter to test")
        #expect(shop.siteScope == nil)
        let allJobs = shop.shown.count, allMachines = shop.siteMachines.count
        let allSpools = shop.siteSpools.count
        let boardAll = shop.board.values.reduce(0) { $0 + $1.count }

        shop.siteFilter = "LOC-sample-ryd"
        await shop.refreshSiteScope()
        let scope = try #require(shop.siteScope)
        #expect(scope.active == "LOC-sample-ryd")
        #expect(shop.siteName == "Riyadh workshop")

        // Jobs: fewer, but some — and every one is Riyadh's or nobody's.
        #expect(shop.shown.count < allJobs && shop.shown.count > 0)
        #expect(shop.board.values.reduce(0) { $0 + $1.count } < boardAll)
        // Machines: the U1 and the X1C, and the laser, which has no site.
        #expect(Set(shop.siteMachines.map(\.id)) == ["MACH-u1", "MACH-x1c", "MACH-LASER"])
        #expect(shop.siteMachines.count < allMachines)
        // Spools: Riyadh's four and the six with no site, not Jeddah's three.
        #expect(shop.siteSpools.count == 10 && allSpools == 13)
        #expect(!shop.siteSpools.contains { $0.id == "sp-4" }, "a Jeddah spool shown in Riyadh")
        #expect(shop.siteSpools.contains { $0.id == "INV-RESIN01" }, "stock with no site went missing")

        // The two sites and the unplaced split the book with nothing lost.
        let riyadh = Set(shop.shown.map(\.id))
        shop.siteFilter = "LOC-sample-jed"
        await shop.refreshSiteScope()
        let jeddah = Set(shop.shown.map(\.id))
        #expect(riyadh.union(jeddah).count == allJobs, "a job is shown at neither site")

        shop.siteFilter = nil
        await shop.refreshSiteScope()
        #expect(shop.siteScope == nil)
        #expect(shop.shown.count == allJobs)
    }

    @Test("a filter naming a site the book no longer has shows the whole shop")
    func staleSite() async {
        let shop = await Self.sample()
        let all = shop.shown.count
        shop.siteFilter = "LOC-deleted"
        await shop.refreshSiteScope()
        #expect(shop.siteFilter == nil)
        #expect(shop.siteScope == nil)
        #expect(shop.shown.count == all)
    }

    @Test("a selected job the site does not show is let go")
    func selectionLetGo() async throws {
        let shop = await Self.sample()
        shop.siteFilter = "LOC-sample-jed"
        await shop.refreshSiteScope()
        let jeddah = Set(shop.shown.map(\.id))
        let elsewhere = try #require(shop.orders.first { !jeddah.contains($0.id) })
        shop.siteFilter = nil
        await shop.refreshSiteScope()
        shop.selection = elsewhere.id
        shop.siteFilter = "LOC-sample-jed"
        await shop.refreshSiteScope()
        #expect(shop.selection == nil)
    }

    @Test("the picker and the banner, photographed")
    func picture() async throws {
        let shop = await Self.sample()
        shop.siteFilter = "LOC-sample-ryd"
        await shop.refreshSiteScope()
        let snap = SnapshotTests()
        let picker = SitePicker(shop: shop).frame(width: Wide.sidebar).padding(.vertical, 8).background(Role.navy)
        try snap.render(picker, "site-picker", size: CGSize(width: Wide.sidebar, height: 48))
        try snap.render(VStack(spacing: 0) {
            SiteScopeBanner(shop: shop, counting: .jobs)
            SiteScopeBanner(shop: shop, counting: .spools)
            SiteScopeBanner(shop: shop, counting: .none)
        }.frame(width: 900).background(Khayt.ground), "site-banner", size: CGSize(width: 900, height: 110))
        try snap.renderDark(SiteScopeBanner(shop: shop, counting: .machines).frame(width: 900),
                            "site-banner-dark", size: CGSize(width: 900, height: 40))
        // Not the screens themselves: they sit in ScrollViews, which a
        // photograph cannot see into. What they show is asserted above.
    }
}
