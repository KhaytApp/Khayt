import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Putting a printer on the floor, and correcting one.
///
/// The RULES are `lib/machine-edit.js` and `lib/printer-catalog.js`, tested
/// where they live — `applySpecs` against the renderer's own `fillSpecs`, over
/// every printer in the catalogue. What is tested here is that this app asks
/// for them in the right ORDER (a model first, then the fields the shop typed,
/// so a typed value wins over a catalogue one), stamps an edit and not a new
/// record, and carries through the connection settings it deliberately does not
/// offer.
@MainActor
struct MachineTests {

    static func floor() -> [String: JSONValue] {
        [
            "machines": .array([
                .object(["id": .string("M1"), "name": .string("Bench"), "color": .string("#5b9cf0"),
                         "rev": .number(3),
                         // What this app does not offer, and must not lose.
                         "printerApi": .object(["type": .string("bambu"), "host": .string("10.0.0.9")]),
                         "webcam": .object(["enabled": .bool(true)]),
                         "downtimeBlocks": .array([.object(["id": .string("DT1")])])]),
                .object(["id": .string("M2"), "name": .string("Spare"), "rev": .number(1)]),
            ]),
            "settings": .object([:]),
        ]
    }

    static func rows(_ root: [String: JSONValue]) -> [[String: JSONValue]] {
        Shop.rows(root, "machines").compactMap { if case .object(let o) = $0 { return o } else { return nil } }
    }
    static func string(_ v: JSONValue?) -> String? { Shop.plainString(v) }
    static func number(_ v: JSONValue?) -> Double? { Shop.plainNumber(v) }
    static func object(_ v: JSONValue?) -> [String: JSONValue] {
        if case .object(let o)? = v { return o }
        return [:]
    }

    @Test("a new machine takes the next colour along, and a nameless one is refused")
    func newMachine() async throws {
        let engine = try KhaytEngine()
        let first = try await engine.newMachine(["name": .string(" Bench ")], id: "M1", count: 0)
        #expect(Self.string(Self.object(first.machine)["name"]) == "Bench")
        let second = try await engine.newMachine(["name": .string("B")], id: "M2", count: 1)
        #expect(Self.string(Self.object(first.machine)["color"])
                != Self.string(Self.object(second.machine)["color"]),
                "two printers added in a row are two colours")
        let none = try await engine.newMachine(["name": .string("  ")], id: "M3", count: 0)
        #expect(none.machine == nil)
        #expect(none.refused == "name")
    }

    @Test("the catalogue is offered with what it has checked about each printer")
    func catalogue() async throws {
        let engine = try KhaytEngine()
        let printers = try await engine.printerCatalog()
        #expect(printers.count > 10, "the catalogue came back empty")
        let x1 = try #require(printers.first { $0.name.contains("X1 Carbon") })
        #expect(x1.specs.contains("mm"), "the bed and the nozzle are in the line")
        #expect(x1.specs.contains("hardened"), "and what the nozzle is made of, which is the point")
    }

    @Test("picking a model fills the specs in, and a threshold the shop typed survives it")
    func model() async throws {
        let engine = try KhaytEngine()
        let printers = try await engine.printerCatalog()
        let x1 = try #require(printers.first { $0.name.contains("X1 Carbon") })

        let blank: JSONValue = .object(["id": .string("M1"), "name": .string("Bench")])
        let filled = try #require(try await engine.applyPrinterModel(blank, catalogId: x1.id, settings: [:]).machine)
        let nozzle = Self.object(Self.object(filled)["nozzle"])
        #expect(Self.string(nozzle["material"]) == "hardened")
        #expect((Self.number(nozzle["gramsThreshold"]) ?? 0) > 10_000,
                "hardened steel's expected life, not brass's")
        #expect(Self.number(Self.object(filled)["powerDraw"]) != nil)

        let typed: JSONValue = .object(["id": .string("M1"), "name": .string("Bench"),
                                        "nozzle": .object(["material": .string("brass"),
                                                           "gramsThreshold": .number(5000),
                                                           "installedAt": .string("2026-01-01"),
                                                           "gramsAtInstall": .number(90)])])
        let kept = try #require(try await engine.applyPrinterModel(typed, catalogId: x1.id, settings: [:]).machine)
        let keptNozzle = Self.object(Self.object(kept)["nozzle"])
        #expect(Self.number(keptNozzle["gramsThreshold"]) == 5000,
                "the app cannot tell a default from a decision, so it must not guess")
        #expect(Self.string(keptNozzle["installedAt"]) == "2026-01-01")
    }

    @Test("an unknown model refuses rather than half-filling a machine")
    func unknownModel() async throws {
        let engine = try KhaytEngine()
        let out = try await engine.applyPrinterModel(.object(["id": .string("M1")]),
                                                     catalogId: "no-such-printer", settings: [:])
        #expect(out.refused == "unknown_model")
    }

    @Test("the nozzle fitments come from the wear data, not from a list in Swift")
    func nozzleMaterials() async throws {
        let engine = try KhaytEngine()
        let materials = try await engine.nozzleMaterials()
        #expect(materials.count >= 4)
        // The one that caught it: a hand-written list said "steel" where the
        // data says "stainless", so the sample shop's U1 matched nothing and
        // the picker came out blank.
        let stainless = try #require(materials.first { $0.key == "stainless" })
        #expect(stainless.label == "Stainless steel", "and it carries the data's own label")
        #expect(stainless.grams > 0, "and what it is expected to last")
        #expect(materials.contains { $0.key == "brass" })
    }

    @Test("every nozzle material the sample shop uses is one the picker offers")
    func sampleMaterialsAreKnown() async throws {
        let shop = Shop()
        await shop.load(.sample)
        await shop.readCatalog()
        let known = Set(shop.nozzleMaterials.map(\.key))
        #expect(!known.isEmpty)
        for machine in shop.machines {
            guard let material = machine.nozzle?.material else { continue }
            #expect(known.contains(material), "\(machine.name) has a nozzle the picker cannot show: \(material)")
        }
    }

    // MARK: - On disk

    @Test("an edit keeps the connection settings this app does not offer, and is stamped")
    func onDisk() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let url = try Self.tempStore(Self.floor())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            var floor = Shop.rows(root, "machines")
            let out = try await engine.editMachine(floor[0], input: ["name": .string("Bench 2"),
                                                                     "powerDraw": .string("120")],
                                                    settings: Shop.settings(root))
            guard case .object(var record)? = out.machine else { return }
            StoreWriter.stamp(&record)
            floor[0] = .object(record)
            root["machines"] = .array(floor)
        }
        let floor = Self.rows(try Self.read(url))
        #expect(Self.string(floor[0]["name"]) == "Bench 2")
        #expect(Self.number(floor[0]["powerDraw"]) == 120)
        #expect(Self.number(floor[0]["rev"]) == 4, "an edit is stamped")
        // The three things this app deliberately does not offer.
        #expect(Self.string(Self.object(floor[0]["printerApi"])["host"]) == "10.0.0.9",
                "the printer's connection must survive an edit made here")
        #expect(floor[0]["webcam"] != nil)
        #expect(floor[0]["downtimeBlocks"] != nil)
        #expect(Self.number(floor[1]["rev"]) == 1, "and the machine nobody touched is not stamped")
    }

    @Test("the sample shop's floor cannot be changed, and it says why")
    func sampleRefuses() async throws {
        let shop = Shop()
        await shop.load(.sample)
        await shop.saveMachine(["name": .string("Bench")], id: nil, catalogId: nil, opened: nil)
        #expect(shop.spendProblem == shop.words.callIt("mac.move_sample"))
    }

    // MARK: -

    static func tempStore(_ root: [String: JSONValue]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-mach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "khayt-store.json")
        try JSONEncoder().encode(root).write(to: url)
        return url
    }

    static func read(_ url: URL) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
    }
}
