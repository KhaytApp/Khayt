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
        // A printer that HAS answered before: the grace is for a hiccup, not
        // for a printer that has never said a word.
        shop.printers.setReadingForTesting(core.id, PrinterWatch.Reading(
            status: nil, problem: "timed out", at: Date(), consecutiveFailures: 1,
            lastGood: Self.idle))
        let band = try #require(await shop.machineBand())
        #expect(band.rows.first { $0.machineId == core.id }?.state != "offline")
        #expect(shop.quiet(core) == .idle)
    }

    static let idle = KhaytEngine.PrinterStatus(
        state: "idle", progress: 0, progressSource: "layers", filename: "",
        timeRemaining: nil, tempNozzle: 25, tempBed: 25, type: "moonraker")

    /// The alpha.51 review, on the shop's real book: the CORE One had missed
    /// a poll and never answered. The band said "• Free" and "48:00 free in
    /// 48 h" and counted it into the total; Next up said "Not answering". One
    /// status source now, so the three are asked the same question.
    @Test("a printer that has never answered is not answering on the band, the tile and Next up alike")
    func neverAnsweredAgreesEverywhere() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let core = try #require(shop.machines.first { $0.id == "MACH-u1" })
        shop.connectMachineForTesting(core.id, type: "moonraker")
        shop.clearPrintingForTesting(on: core.id)
        let watched = try #require(shop.machines.first { $0.id == core.id })
        for misses in 1...4 {
            shop.printers.setReadingForTesting(core.id, PrinterWatch.Reading(
                status: nil, problem: "connect ECONNREFUSED", at: Date(),
                consecutiveFailures: misses))
            #expect(shop.quiet(watched) == .notAnswering, "tile, after \(misses) miss(es)")
            let band = try #require(await shop.machineBand())
            let row = try #require(band.rows.first { $0.machineId == core.id })
            #expect(row.state == "offline", "band, after \(misses) miss(es)")
            #expect(!row.known && row.freeMinutes == 0, "its free hours were counted")
            guard case .object(let entry)? = shop.dispatchLive()[core.id],
                  case .string(let err)? = entry["error"] else {
                Issue.record("Next up was not told it is not answering"); continue
            }
            #expect(!err.isEmpty)
        }
    }

    @Test("inside the grace, the band, the tile and Next up all keep its last word")
    func graceAgreesEverywhere() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let core = try #require(shop.machines.first { $0.id == "MACH-u1" })
        shop.connectMachineForTesting(core.id, type: "moonraker")
        shop.clearPrintingForTesting(on: core.id)
        let watched = try #require(shop.machines.first { $0.id == core.id })
        shop.printers.setReadingForTesting(core.id, PrinterWatch.Reading(
            status: nil, problem: "timed out", at: Date(), consecutiveFailures: 2,
            lastGood: Self.idle))
        #expect(shop.quiet(watched) == .idle)
        let band = try #require(await shop.machineBand())
        #expect(band.rows.first { $0.machineId == core.id }?.state != "offline")
        guard case .object(let entry)? = shop.dispatchLive()[core.id] else {
            Issue.record("Next up was told nothing"); return
        }
        #expect(entry["error"] == nil, "Next up called a printer in its grace not answering")
        #expect(entry["state"] == .string("idle"))

        // The third miss ends the grace for all three at once.
        shop.printers.setReadingForTesting(core.id, PrinterWatch.Reading(
            status: nil, problem: "timed out", at: Date(), consecutiveFailures: 3,
            lastGood: Self.idle))
        #expect(shop.quiet(watched) == .notAnswering)
        let after = try #require(await shop.machineBand())
        #expect(after.rows.first { $0.machineId == core.id }?.state == "offline")
        guard case .object(let gone)? = shop.dispatchLive()[core.id] else {
            Issue.record("Next up was told nothing"); return
        }
        #expect(gone["error"] != nil)
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
