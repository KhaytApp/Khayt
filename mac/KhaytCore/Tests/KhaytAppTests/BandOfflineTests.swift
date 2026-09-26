import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The shop's CORE One, switched off: the dashboard said "not answering", the
/// band said "Free" with 48 hours counted into the total, "Next up" said
/// "Reporting a fault", and a footnote said something was printing blind.
/// One printer, four stories. They agree now.
@MainActor
struct BandOfflineTests {

    @Test("three missed polls make a printer 'not answering' on the band, out of the totals")
    func offlineOnTheBand() async throws {
        let shop = Shop()
        await shop.load(.sample)
        // The sample machine with nothing printing in the book: a job the book
        // says is printing goes through the running path, which already says
        // "no estimate" for a printer that is silent.
        let core = try #require(shop.machines.first { $0.id == "MACH-UVFLAT" })
        shop.printers.setReadingForTesting(core.id, PrinterWatch.Reading(
            status: nil, problem: "connect ECONNREFUSED", at: Date(), consecutiveFailures: 3))
        let band = try #require(await shop.machineBand())
        let row = try #require(band.rows.first { $0.machineId == core.id })
        #expect(row.state == "offline")
        #expect(!row.known, "an unanswering printer's free hours were counted")
    }

    @Test("one missed poll is a wifi hiccup, not an offline printer")
    func oneMissIsNotOffline() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let core = try #require(shop.machines.first { $0.id == "MACH-UVFLAT" })
        shop.printers.setReadingForTesting(core.id, PrinterWatch.Reading(
            status: nil, problem: "timed out", at: Date(), consecutiveFailures: 1))
        let band = try #require(await shop.machineBand())
        #expect(band.rows.first { $0.machineId == core.id }?.state != "offline")
    }

    /// The shop's real book, Sep 2026: both printers set up, neither had ever
    /// answered. "Next up" said "Not answering"; the band said "Free · 48:00"
    /// for each and "96:00 free" in total.
    @Test("a connected printer that has never answered is not free on the band")
    func neverAnsweredIsNotFree() async throws {
        let shop = Shop()
        await shop.load(.sample)
        // A filament printer with nothing printing in the book, so the row
        // goes through the idle path — the one that used to say "Free".
        let core = try #require(shop.machines.first { $0.id == "MACH-u1" })
        shop.connectMachineForTesting(core.id, type: "moonraker")
        shop.clearPrintingForTesting(on: core.id)
        let watched = try #require(shop.machines.first { $0.id == core.id })
        #expect(shop.quiet(watched) == .notAnswering, "the other screens call it not answering")
        let band = try #require(await shop.machineBand())
        let row = try #require(band.rows.first { $0.machineId == core.id })
        #expect(row.state == "offline")
        #expect(!row.known, "its 48 hours were counted into the free total")
        #expect(row.freeMinutes == 0)
    }

    @Test("a machine with no printer connection is still planned by hand, and free")
    func notSetUpStaysFree() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let core = try #require(shop.machines.first { $0.id == "MACH-x1c" })
        #expect(shop.quiet(core) == .notSetUp)
        let band = try #require(await shop.machineBand())
        #expect(band.rows.first { $0.machineId == core.id }?.state != "offline")
    }

    @Test("every band state has words, and the footnote counts only unknown rows")
    func wordsAndFootnote() throws {
        let words = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Words.swift"), encoding: .utf8)
        for state in ["printing", "queued", "free", "down", "offline"] {
            #expect(words.contains("\"mac.band_state_\(state)\""),
                    "a \(state) machine shows the raw key mac.band_state_\(state)")
        }
        let view = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/MachineBand.swift"), encoding: .utf8)
        #expect(view.contains("let blank = band.rows.filter { !$0.known }"),
                "a free machine made the band say something was printing blind")
    }
}
