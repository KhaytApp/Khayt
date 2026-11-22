import Testing
import SwiftUI
import KhaytCore
@testable import KhaytApp

/// Settings → Online's customer-records and WhatsApp sections, in every state
/// a shop can see them in. `ImageRenderer` runs no `.task`, so the states set
/// here are the ones drawn: nothing reaches the cloud.
@Suite @MainActor struct CloudSectionsSnapshotTests {

    @Test("customer records and WhatsApp reports render in each of their states")
    func sections() async throws {
        guard SnapshotTests.outputDir != nil else { return }
        let shop = Shop()
        await shop.load(.sample)
        // Nothing in the background may change what is drawn.
        shop.stopPollingWhatsAppReports()
        shop.stopPublishingCustomerRecords()
        let snap = SnapshotTests()
        var settings = shop.settingsDict

        func shoot(_ name: String, _ height: CGFloat) throws {
            let page = VStack(alignment: .leading, spacing: 18) {
                CustomerRecordsSection(shop: shop)
                WhatsAppReportsSection(shop: shop)
            }
            .padding(20).frame(width: 560, height: height, alignment: .top)
            try snap.render(page.background(Khayt.ground), name, size: CGSize(width: 560, height: height))
            try snap.renderDark(page, name + "-dark", size: CGSize(width: 560, height: height))
        }

        // Held, and no cloud: what every shop sees in alpha.80.
        try shoot("70-cr-held-nocloud", 360)

        // Connected to the cloud, records allowed and on, published; hook set.
        settings["cloud"] = .object(["enabled": .bool(true), "shopId": .string("shop_abc"),
                                     "verified": .bool(true), "url": .string("https://cloud.khaytapp.com")])
        settings["customerRecords"] = .object(["enabled": .bool(true)])
        shop.settingsValue = .object(settings)
        shop.customerRecordsReady = true
        shop.customerRecordsSaid = shop.words.callIt("mac.cr_published", ["count": .string("31")])
        shop.whatsAppHook = .init(configured: true,
                                  url: "https://cloud.khaytapp.com/v1/hooks/whatsapp/shop_abc",
                                  verifyToken: "vt_0123456789abcdef", lastReportAt: "2026-10-18T08:01:00Z")
        #expect(shop.whatsAppHook?.configured == true)
        try shoot("71-cr-on-hook-set", 470)

        // A failure on each.
        shop.customerRecordsProblem = true
        shop.customerRecordsSaid = CustomerRecordsPublisher.Failure.tooLarge.said(shop.words)
        shop.whatsAppHook = .init(configured: false, url: nil, verifyToken: nil, lastReportAt: nil)
        shop.whatsAppHookProblem = WhatsAppReports.Failure.notAllowed.said(shop.words)
        try shoot("72-cr-failed-hook-none", 380)
    }
}
