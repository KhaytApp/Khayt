import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// "What can I start now?" A machine that says what it has loaded, a chip
/// that counts the models it could start, and a grid that shows those.
///
/// Wired end to end on purpose, because the recurring bug in this app is a
/// rule with tests and no caller: the reading goes in where PrinterWatch puts
/// it, and what comes out is what the grid draws (`shownFiles`), not the
/// filter state that feeds it.
@MainActor
struct ReadyOnMachineTests {

    /// The sample's seven kings are printed in these four colours, PLA.
    static let kingsLoaded: [KhaytEngine.LoadedSlot] = [
        .init(slot: 0, hex: "#C8A97E", material: "PLA"),
        .init(slot: 1, hex: "#8F5D1C", material: "PLA"),
        .init(slot: 2, hex: "#3B2F22", material: "PLA"),
        .init(slot: 3, hex: "#EDE3D2", material: "PLA"),
    ]

    static func reading(_ loaded: [KhaytEngine.LoadedSlot]) -> PrinterWatch.Reading {
        PrinterWatch.Reading(
            status: KhaytEngine.PrinterStatus(state: "standby", progress: 0, progressSource: nil,
                                              filename: "", timeRemaining: nil, tempNozzle: 25,
                                              tempBed: 25, type: "moonraker", loaded: loaded),
            problem: nil, at: Date(), consecutiveFailures: 0)
    }

    @Test("a machine with the kings' colours loaded can start the kings, and the chip shows them")
    func readyOnTheMachine() async throws {
        let shop = Shop()
        await shop.load(.sample)
        shop.shelf = .library(nil)
        let machine = try #require(shop.machines.first)
        shop.printers.setReadingForTesting(machine.id, Self.reading(Self.kingsLoaded))
        shop.loadedChanged()
        await shop.settleLibraryFacets()

        let chip = try #require(shop.libraryFacets.ready.first { $0.machineId == machine.id },
                                "a machine reporting its spools got no Ready chip")
        #expect(chip.count >= 7, "the seven kings are in exactly these colours (got \(chip.count))")

        shop.libraryReadyOn = machine.id
        await shop.settleLibraryFacets()
        let shown = shop.shownFiles
        #expect(shown.count == chip.count, "the chip said \(chip.count) and the grid shows \(shown.count)")
        #expect(shown.allSatisfy { ($0.colors ?? []).count > 0 }, "a model with no colours was called ready")
        // The inspector reads the same answer the chip counted.
        #expect(shown.allSatisfy { shop.isReady($0, on: machine.id) })
        #expect(shop.libraryFilterOn)
        shop.clearLibraryFilter()
        #expect(shop.libraryReadyOn == nil)
    }

    @Test("a machine that does not say what is loaded gets no chip")
    func noReadingNoChip() async throws {
        let shop = Shop()
        await shop.load(.sample)
        shop.shelf = .library(nil)
        let machine = try #require(shop.machines.first)
        shop.printers.setReadingForTesting(machine.id, Self.reading([]))
        shop.loadedChanged()
        await shop.settleLibraryFacets()
        #expect(shop.libraryFacets.ready.isEmpty)
    }
}
