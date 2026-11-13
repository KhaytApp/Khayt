import Testing
@testable import KhaytApp

/// The capture run photographs the inspectors, the empty screens, and in dark
/// everything it photographs in light (Nov 11 2026 UI review, B14). Tooling:
/// nothing here is app behaviour.
@MainActor struct CaptureRunCoverageTests {

    @Test("a dark run's pictures say dark after the number; a light run's names are untouched")
    func names() {
        #expect(Snapshot.fileName("00-dashboard", dark: false) == "00-dashboard")
        // The names the short dark run already used.
        #expect(Snapshot.fileName("00-dashboard", dark: true) == "00-dark-dashboard")
        #expect(Snapshot.fileName("03-library", dark: true) == "03-dark-library")
        #expect(Snapshot.fileName("17-settings-general", dark: true) == "17-dark-settings-general")
        #expect(Snapshot.fileName("15b-edit-customer", dark: true) == "15b-dark-edit-customer")
        // Never tagged twice.
        #expect(Snapshot.fileName("98-empty-drawn-dark", dark: true) == "98-empty-drawn-dark")
        #expect(Snapshot.fileName("b5-1-machines-live-dark", dark: true) == "b5-1-machines-live-dark")
        #expect(Snapshot.fileName("03f-dark-library-storage", dark: true) == "03f-dark-library-storage")
        #expect(Snapshot.fileName("eod", dark: true) == "dark-eod")
        // "darkroom" is not "dark".
        #expect(Snapshot.fileName("40-darkroom", dark: true) == "40-dark-darkroom")
    }

    @Test("the details panel is told from the sidebar and the table by its width and its edge")
    func whichPaneIsTheInspector() {
        // 1440-point window: sidebar 248 at the leading edge, inspector 310 at
        // the trailing one, the table between.
        #expect(Snapshot.isDetailsPane(width: 310, minX: 1130, maxX: 1440, windowWidth: 1440, rtl: false))
        #expect(!Snapshot.isDetailsPane(width: 248, minX: 0, maxX: 248, windowWidth: 1440, rtl: false))
        #expect(!Snapshot.isDetailsPane(width: 882, minX: 248, maxX: 1130, windowWidth: 1440, rtl: false))
        // A 310-point scroll view in the middle of a screen is not it.
        #expect(!Snapshot.isDetailsPane(width: 310, minX: 500, maxX: 810, windowWidth: 1440, rtl: false))
        // Arabic: the panel is on the left.
        #expect(Snapshot.isDetailsPane(width: 310, minX: 0, maxX: 310, windowWidth: 1440, rtl: true))
        #expect(!Snapshot.isDetailsPane(width: 310, minX: 1130, maxX: 1440, windowWidth: 1440, rtl: true))
    }

    @Test("the run walks one sequence for both appearances, and opens the panel before the inspectors")
    func oneSequence() throws {
        let source = try #require(IconSources.all.first { $0.name == "KhaytApp.swift" }).text
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).components(separatedBy: "//").first ?? "" }.joined(separator: "\n")
        // The short dark run ended the process after nine pictures.
        #expect(!code.contains("if dark {\n                capture(named: \"00-dark-dashboard\""))
        for name in ["02c-job-inspector", "06c-customer-inspector",
                     "97-empty-jobs", "97-empty-customers", "97-empty-inventory", "97-empty-catalogue"] {
            #expect(code.contains("\"\(name)\""), "the run no longer takes \(name)")
        }
        let job = try #require(code.components(separatedBy: "captureInspector(named: \"02c-job-inspector\"").first)
        #expect(job.components(separatedBy: "await openDetails()").count >= 2)
        // Every writer goes through the one name.
        #expect(code.components(separatedBy: "fileName(name, dark: darkRun)").count - 1 >= 5)
    }

    @Test("emptying the book for a picture touches nothing on disk and a load brings it back")
    func emptyBook() async {
        let shop = Shop()
        await shop.load(.sample)
        #expect(!shop.orders.isEmpty && !shop.spools.isEmpty)
        shop.pretendEmptyBook()
        #expect(shop.orders.isEmpty && shop.clients.isEmpty && shop.spools.isEmpty
                && shop.consumables.isEmpty && shop.productRows.isEmpty && shop.catalogueRows.isEmpty)
        await shop.load(.sample)
        #expect(!shop.orders.isEmpty && !shop.spools.isEmpty)
    }
}
