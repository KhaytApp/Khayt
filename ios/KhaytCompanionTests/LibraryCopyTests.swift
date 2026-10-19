import KhaytCore
import XCTest
@testable import KhaytCompanion

/// The library away from the shop: what the phone keeps of `printFiles` from
/// a cloud pull, and the price it works out from it.
final class LibraryCopyTests: XCTestCase {
    private func record(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    func testSlimKeepsWhatAPriceNeedsAndDropsTheRest() throws {
        let row = try record(#"""
        {"id":"PF-1","rev":4,"name":"Lantern","folder":"Home","parsed":{"printTimeMins":318,"filamentGrams":154},
         "geometryKey":"1200:52000.5:80x80x120","riskAnalysis":{"totalAreaMm2":18000.25,"overhangs":[1,2,3]},
         "thumbnail":"data:image/png;base64,AAAA","userPhoto":"x","contentHash":"abc"}
        """#)
        guard case .object(let o)? = LibraryCopy.slim(row) else { return XCTFail("kept nothing") }
        XCTAssertEqual(o["areaMm2"], .number(18000.25), "the surface area the overhang check paid for")
        XCTAssertNil(o["riskAnalysis"])
        XCTAssertNil(o["thumbnail"], "pictures stay on the Mac")
        XCTAssertNil(o["contentHash"])
        XCTAssertEqual(o["rev"], .number(4), "rev, so cloud changes fold in by the sync's rule")
        XCTAssertNil(LibraryCopy.slim(try record(#"{"name":"no id"}"#)))
    }

    func testTheGeometryKeyReadsAsVolumeAndBox() {
        XCTAssertEqual(LibraryCopy.mesh("4295525:3487958.9:1141.57x757.09x207.37"),
                       .init(volume: 3487958.9, x: 1141.57, y: 757.09, z: 207.37))
        XCTAssertNil(LibraryCopy.mesh("12:0:1x1x1"), "no volume, nothing to estimate")
        XCTAssertNil(LibraryCopy.mesh("12:50:1x1"))
        XCTAssertNil(LibraryCopy.mesh(nil))
    }

    func testAKeptModelReadsAsTheMacSendsOne() throws {
        let unsliced = try XCTUnwrap(LibraryCopy.item(try record(#"""
        {"id":"PF-2","name":" ","originalName":"Bracket-v2.STL","geometryKey":"10:5000:40x20x10","tags":["parts"]}
        """#)))
        XCTAssertEqual(unsliced.name, "Bracket-v2.STL", "no title: the file's name")
        XCTAssertEqual(unsliced.ext, "stl")
        XCTAssertTrue(unsliced.estimable, "measured, so it can be priced from its shape")
        XCTAssertFalse(unsliced.thumb)

        let sliced = try XCTUnwrap(LibraryCopy.item(try record(#"""
        {"id":"PF-3","name":"Vase","sourceFile":{"ext":"3mf"},
         "parsed":{"printTimeMins":214,"filamentGrams":52,"plates":[{"index":1,"name":"A","printTimeMins":100,"filamentGrams":20}]}}
        """#)))
        XCTAssertEqual(sliced.grams, 52)
        XCTAssertEqual(sliced.plates.first?.grams, 20)
        XCTAssertTrue(sliced.estimable)

        let neither = try XCTUnwrap(LibraryCopy.item(try record(#"{"id":"PF-4","name":"Mystery.step"}"#)))
        XCTAssertFalse(neither.estimable)
    }

    func testTheSlicersFiguresComeFirstAndAPlateUsesItsOwn() async throws {
        let engine = try KhaytEngine()
        let row = try record(#"""
        {"id":"PF-5","name":"Lantern","material":"PLA Silk","geometryKey":"10:999999:200x200x200",
         "parsed":{"printTimeMins":318,"filamentGrams":154,"filamentType":"PLA",
                   "plates":[{"index":1,"name":"Body","printTimeMins":205,"filamentGrams":112},
                             {"index":2,"name":"Cap","printTimeMins":113,"filamentGrams":42}]}}
        """#)
        let whole = try await XCTUnwrapAsync(await LibraryCopy.figures(row, plate: nil, engine: engine, settings: [:], orders: []))
        XCTAssertEqual(whole.grams, 154)
        XCTAssertEqual(whole.hours, 5.3, accuracy: 0.001)
        XCTAssertTrue(whole.exact, "sliced, not the shape")
        let cap = try await XCTUnwrapAsync(await LibraryCopy.figures(row, plate: 2, engine: engine, settings: [:], orders: []))
        XCTAssertEqual(cap.grams, 42)
        XCTAssertEqual(cap.hours, 113.0 / 60, accuracy: 0.001)
        let missing = await LibraryCopy.figures(row, plate: 9, engine: engine, settings: [:], orders: [])
        XCTAssertNil(missing, "no such plate")
    }

    func testAnUnslicedModelIsPricedFromItsShapeAsTheMacWould() async throws {
        let engine = try KhaytEngine()
        let row = try record(#"{"id":"PF-6","name":"Cube","geometryKey":"12:64000:40x40x40","areaMm2":9600}"#)
        let here = try await XCTUnwrapAsync(await LibraryCopy.figures(row, plate: nil, engine: engine, settings: [:], orders: []))
        // The Mac's own call on the same fields (`LoadFigures.meshInputs`).
        let macs = try await engine.estimateMeshes(
            [KhaytEngine.MeshInput(volumeMm3: 64000, areaMm2: 9600, bbox: (x: 40, y: 40, z: 40))],
            settings: [:], orders: [])
        let mac = try XCTUnwrap(macs.first ?? nil)
        XCTAssertEqual(here.grams, mac.grams)
        XCTAssertEqual(here.hours, mac.hours)
        XCTAssertFalse(here.exact)
        XCTAssertEqual(here.reliable, !mac.shellUnreliable)
        let plate = await LibraryCopy.figures(row, plate: 1, engine: engine, settings: [:], orders: [])
        XCTAssertNil(plate, "one plate's share of a shape is not known")
    }

    func testTheSpoolIsTheModelsMaterialElseTheFirstWithAPrice() {
        func spool(_ id: String, _ material: String, _ cost: Double?) -> CalculatorShelf.Spool {
            .init(costing: .init(id: id, material: material, cost: cost, spoolWeight: 1000, color: nil), label: id, hex: nil)
        }
        let shelf = [spool("A", "PETG", nil), spool("B", "PETG", 25), spool("C", "PLA", 20)]
        XCTAssertEqual(LibraryCopy.spool(for: "PLA Silk", among: shelf)?.id, "C")
        XCTAssertEqual(LibraryCopy.spool(for: "petg", among: shelf)?.id, "B", "one with a price")
        XCTAssertEqual(LibraryCopy.spool(for: "Nylon", among: shelf)?.id, "B", "the first with a price")
        XCTAssertNil(LibraryCopy.spool(for: "PLA", among: [spool("A", "PLA", nil)]))
    }

    func testCloudChangesAndDeletionsFoldIntoTheCopy() async throws {
        let engine = try KhaytEngine()
        let rows = LibraryCopy.slimAll(try record(#"""
        [{"id":"PF-a","rev":1,"name":"Old title"},{"id":"PF-b","rev":1,"name":"Gone soon"}]
        """#))
        let delta = try JSONDecoder().decode([String: JSONValue].self, from: Data(#"""
        {"deltas":[{"collection":"printFiles","record":{"id":"PF-a","rev":2,"name":"New title","riskAnalysis":{"totalAreaMm2":5}}},
                   {"collection":"printFiles","record":{"id":"PF-c","rev":1,"name":"Added"}}],
         "tombstones":[{"id":"PF-b","collection":"printFiles","rev":2,"deletedAt":"2026-10-19T00:00:00Z"}]}
        """#.utf8))
        let folded = try await engine.foldDeltas(base: ["printFiles": .array(rows), "tombstones": .array([])], deltas: [delta])
        let items = LibraryCopy.items(LibraryCopy.slimAll(folded.store["printFiles"]))
        XCTAssertEqual(Set(items.map(\.id)), ["PF-a", "PF-c"])
        XCTAssertEqual(items.first { $0.id == "PF-a" }?.name, "New title")
        guard case .array(let kept)? = folded.store["printFiles"],
              case .object(let a)? = LibraryCopy.slimAll(.array(kept)).first(where: { if case .object(let o) = $0 { return o["id"] == .string("PF-a") } else { return false } })
        else { return XCTFail("PF-a missing") }
        XCTAssertEqual(a["areaMm2"], .number(5), "slimmed again after the fold")
    }
}

private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
