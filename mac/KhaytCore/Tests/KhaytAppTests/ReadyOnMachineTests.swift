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
        // The X1C: no spools typed in the sample, and a reading that says nothing.
        let machine = try #require(shop.machines.first { $0.id == "MACH-x1c" })
        shop.printers.setReadingForTesting(machine.id, Self.reading([]))
        shop.loadedChanged()
        await shop.settleLibraryFacets()
        #expect(!shop.libraryFacets.ready.contains { $0.machineId == machine.id })
    }

    /// The sample has to reach this, or the chip and the sheet's rows are
    /// screens nobody has ever seen drawn.
    @Test("the sample shop has typed spools, so its library shows a Ready chip")
    func sampleShowsIt() async throws {
        let shop = Shop()
        await shop.load(.sample)
        shop.shelf = .library(nil)
        await shop.settleLibraryFacets()
        let u1 = try #require(shop.libraryFacets.ready.first { $0.machineId == "MACH-u1" },
                              "the sample U1's typed spools gave no Ready chip")
        #expect(u1.count >= 7, "the seven kings are loaded on the sample U1")
    }
}

/// Spools typed by hand, for a printer that cannot report them.
@MainActor
struct LoadedByHandTests {

    @Test("the shared rule cleans typed spools on the Mac too, where there is no require")
    func throughTheEngine() async throws {
        let engine = try KhaytEngine()
        let record: JSONValue = .object(["id": .string("m1"), "name": .string("CORE One"),
                                         "maxColors": .number(1)])
        let out = try await engine.editMachine(record, input: [
            "loaded": .array([
                .object(["slot": .number(0), "hex": .string("#FF6600"), "material": .string("PETG")]),
                .object(["slot": .number(1), "hex": .string("orange"), "material": .string("PLA")]),
            ]),
        ], settings: [:])
        guard case .object(let m)? = out.machine, case .array(let loaded)? = m["loaded"] else {
            Issue.record("the edit wrote no `loaded` — in JavaScriptCore the rule could not find loaded-colours")
            return
        }
        #expect(loaded.count == 1, "a colour that is not one was kept")
    }

    @Test("a machine reads its typed spools, and a row it cannot read is skipped, not fatal")
    func decoding() throws {
        let json = #"""
        {"id":"m1","name":"CORE One","maxColors":2,
         "loaded":[{"slot":0,"hex":"#FF6600","material":"PETG"},{"slot":1}]}
        """#
        let machine = try JSONDecoder().decode(Machine.self, from: Data(json.utf8))
        #expect(machine.loadedByHand == [.init(slot: 0, hex: "#FF6600", material: "PETG")])
        // The sheet shows both heads, the typed one on.
        let rows = LoadedRow.rows(for: machine)
        #expect(rows.count == 2)
        #expect(rows[0].on && rows[0].material == "PETG")
        #expect(!rows[1].on)
    }

    @Test("the library falls back to typed spools only when the printer says nothing")
    func fallbackIsWired() throws {
        let shop = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Shop.swift"), encoding: .utf8)
        #expect(shop.contains("if !reported.isEmpty { return reported }"), "the printer's own reading no longer wins")
        #expect(shop.contains("?.loadedByHand ?? []"), "typed spools are no longer read")
        let sheet = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/MachineSheet.swift"), encoding: .utf8)
        #expect(sheet.contains(#"input["loaded"]"#), "the sheet no longer saves what is loaded")
        #expect(sheet.contains("shop.loadedChanged()"), "a save no longer recounts the Ready chips")
    }
}
