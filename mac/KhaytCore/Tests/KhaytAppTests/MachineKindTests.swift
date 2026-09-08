import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Khayt was written for filament printers and said so everywhere.
///
/// A machine had a nozzle diameter, an extruder type and a colour count; the
/// thing that wore out was a nozzle. A shop that also runs a resin printer, a
/// UV flatbed or a laser cutter had to record all three as FDM printers, and
/// the app told the laser its nozzle was 0.4 mm.
///
/// `lib/machine-kinds.js` is the vocabulary. These test the crossing and the
/// two decisions it would be easy to re-make in Swift and get wrong.
@MainActor
struct MachineKindTests {

    static func machine(_ id: String, kind: String? = nil) -> JSONValue {
        var row: [String: JSONValue] = ["id": .string(id), "name": .string(id)]
        if let kind { row["kind"] = .string(kind) }
        return .object(row)
    }

    static func kinds(_ machines: [JSONValue]) async throws -> [String: KhaytEngine.MachineKind] {
        try await KhaytEngine().machineKinds(machines)
    }

    @Test("a machine with no kind crosses back as a filament printer")
    func absentIsFdm() async throws {
        // Not a default: until this existed nothing else could be recorded, so
        // every machine in every existing book genuinely is one.
        let k = try await Self.kinds([Self.machine("M1")])
        #expect(k["M1"]?.kind == "fdm")
        #expect(k["M1"]?.consumable == "filament")
        #expect(k["M1"]?.unit == "g")
    }

    @Test("a kind this build has not learned still comes back as a machine")
    func unknownKindStillDraws() async throws {
        // A newer Khayt writing `kind: "waterjet"` into a synced book must not
        // make a machine vanish from an older one. Wrong is survivable.
        let k = try await Self.kinds([Self.machine("M1", kind: "waterjet")])
        #expect(k["M1"]?.kind == "fdm")
    }

    @Test("each kind says what it eats and what wears out on it")
    func eachKind() async throws {
        let k = try await Self.kinds([
            Self.machine("F", kind: "fdm"), Self.machine("R", kind: "resin"),
            Self.machine("U", kind: "uv"), Self.machine("L", kind: "laser"),
            Self.machine("C", kind: "cnc"),
        ])
        #expect(k["R"]?.consumable == "resin" && k["R"]?.unit == "ml")
        #expect(k["U"]?.consumable == "ink" && k["U"]?.unit == "ml")
        #expect(k["L"]?.consumable == "sheet")
        #expect(k["C"]?.consumable == "stock")
        // A resin printer has two things wearing on two different clocks.
        #expect(k["R"]?.wear.map(\.part) == ["fep", "lcd"])
        #expect(k["F"]?.wear.map(\.part) == ["nozzle"])
    }

    /// The bug this exists to stop.
    @Test("nothing but a filament printer is offered a nozzle, an extruder or colours")
    func noNozzleOnALaser() async throws {
        let k = try await Self.kinds(["fdm", "resin", "uv", "laser", "cnc"].map {
            Self.machine($0, kind: $0)
        })
        for field in ["nozzleDiameter", "extruderType", "maxColors"] {
            #expect(k["fdm"]?.shows(field) == true)
            for kind in ["resin", "uv", "laser", "cnc"] {
                #expect(k[kind]?.shows(field) == false,
                        "a \(kind) would be shown its \(field)")
            }
        }
        // And every kind has a size and a power bill.
        for kind in ["fdm", "resin", "uv", "laser", "cnc"] {
            #expect(k[kind]?.shows("bed") == true)
            #expect(k[kind]?.shows("powerDraw") == true)
        }
    }

    /// The distinction the band draws on.
    @Test("only a filament printer claims a protocol this app actually has")
    func onlyFdmIsPolled() async throws {
        let k = try await Self.kinds(["fdm", "resin", "uv", "laser", "cnc"].map {
            Self.machine($0, kind: $0)
        })
        #expect(k["fdm"]?.polled == true)
        for kind in ["resin", "uv", "laser", "cnc"] {
            #expect(k[kind]?.polled == false,
                    "a \(kind) claiming a protocol would be drawn as a printer that has stopped answering")
        }
    }

    @Test("the picker offers every kind, each with a name this app can say")
    func pickerIsComplete() async throws {
        let engine = try KhaytEngine()
        let choices = try await engine.machineKindChoices()
        #expect(choices.map(\.kind) == ["fdm", "resin", "uv", "laser", "cnc"])

        for words in [Words(), Words()] { _ = words }
        let en = Words(); await en.load("en", engine: engine)
        let ar = Words(); await ar.load("ar", engine: engine)
        for choice in choices {
            for key in [choice.nameKey, choice.consumableKey, choice.unitKey] {
                #expect(en.callIt(key) != key, "\(choice.kind): \(key) has no English")
                #expect(ar.callIt(key) != key, "\(choice.kind): \(key) has no Arabic")
            }
            for wear in choice.wear {
                #expect(en.callIt(wear.label) != wear.label, "\(wear.part) has no English")
                #expect(ar.callIt(wear.label) != wear.label, "\(wear.part) has no Arabic")
                #expect(en.callIt(wear.unit) != wear.unit, "\(wear.unit) has no English")
                #expect(ar.callIt(wear.unit) != wear.unit, "\(wear.unit) has no Arabic")
            }
        }
    }

    /// A screen that cannot ask a machine anything must say which of the two
    /// reasons applies, and the words have to exist in both languages.
    @Test("'no protocol' and 'not answering' are different sentences")
    func twoDifferentSentences() async throws {
        let engine = try KhaytEngine()
        let en = Words(); await en.load("en", engine: engine)
        let ar = Words(); await ar.load("ar", engine: engine)
        for key in ["mac.band_no_protocol", "mac.band_cannot_ask",
                    "mac.band_not_asked", "mac.band_unknown"] {
            #expect(en.callIt(key) != key, "\(key) has no English")
            #expect(ar.callIt(key) != key, "\(key) has no Arabic")
        }
        #expect(en.callIt("mac.band_no_protocol") != en.callIt("mac.band_cannot_ask"),
                "a laser cutter and a printer that has stopped must not read the same")
        #expect(en.callIt("mac.band_not_asked") != en.callIt("mac.band_unknown"))
    }
}
