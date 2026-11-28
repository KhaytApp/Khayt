import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The Shop floor tile's heads (page 29, frame 2): the filament TYPE under each
/// nozzle, never its colour (Turki, Nov 28: "show filament type not color name").
struct FloorHeadsTests {

    @Test("the type is the material's first word")
    func type() {
        #expect(FloorHeads.type("PLA SnapSpeed") == "PLA")
        #expect(FloorHeads.type("PETG") == "PETG")
        #expect(FloorHeads.type("PLA-CF Matte") == "PLA-CF")
        #expect(FloorHeads.type("") == "")
    }

    @Test("the tile reads the card's own status: it never asks the printer, and it shows no colour code")
    func wiring() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let floor = try String(contentsOf: app.appending(path: "ShopFloor.swift"), encoding: .utf8)
        #expect(floor.contains("FloorHeads(loaded: loaded, words: shop.words)"))
        let start = try #require(floor.range(of: "struct FloorHeads: View"))
        let mine = String(floor[start.lowerBound...])
        for never in ["machineHeads(", "PrinterWatch.get", "filament_detect", "slot.hex)"] {
            #expect(!mine.contains(never), Comment(rawValue: never))
        }
    }
}
