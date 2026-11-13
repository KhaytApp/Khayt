import Foundation
import JavaScriptCore
import Testing
@testable import KhaytCore

/// The Mac's colour families and file types, against the JavaScript they
/// came from (`lib/colour-family.js`, `lib/model-file-type.js`).
///
/// The library's matcher is synchronous and the engine is an actor, so these
/// two rules run natively (`ColourFamily`, `ModelFileType`). That is a second
/// implementation on purpose, and this is what makes it safe: the two are
/// run over the whole colour cube, every way a hex is written and every
/// shape of record, and may not differ. Move a threshold in the lib and this
/// fails until the Swift moves with it.
@MainActor
struct ColourFamilyParityTests {

    private func js() throws -> JSContext { try Parity.context(loading: ["colour-family", "model-file-type"]) }

    @Test("every colour in the cube lands in the same family in both")
    func cubeAgrees() throws {
        let context = try js()
        // Every third level of each channel, 0 and 255 included: 636,056
        // colours, as one string of family indexes.
        let fromJS = try Parity.run(context, """
            (function () {
              var C = globalThis.KhaytColourFamily, out = [];
              for (var r = 0; r <= 255; r += 3) for (var g = 0; g <= 255; g += 3) for (var b = 0; b <= 255; b += 3) {
                out.push(C.FAMILIES.indexOf(C.familyOfRgb(r, g, b)).toString(16));
              }
              return out.join('');
            })()
            """)
        guard case .string(let theirs) = fromJS else { Issue.record("no answer"); return }
        let order = ColourFamily.allCases
        var mine = [UInt8]()
        mine.reserveCapacity(theirs.utf8.count)
        let digits = Array("0123456789abcdef".utf8)
        for r in stride(from: 0, through: 255, by: 3) {
            for g in stride(from: 0, through: 255, by: 3) {
                for b in stride(from: 0, through: 255, by: 3) {
                    mine.append(digits[order.firstIndex(of: ColourFamily.family(r: r, g: g, b: b))!])
                }
            }
        }
        #expect(mine.count == 86 * 86 * 86, "the sweep shrank")
        let same = mine == Array(theirs.utf8)
        #expect(same, "Swift and lib/colour-family.js put some colour in different families")
        if !same, mine.count == theirs.utf8.count {
            let other = Array(theirs.utf8)
            if let i = mine.indices.first(where: { mine[$0] != other[$0] }) {
                Issue.record("first difference at r=\(i / (86 * 86) * 3) g=\(i / 86 % 86 * 3) b=\(i % 86 * 3)")
            }
        }
    }

    @Test("the lists are the same lists, in the same order")
    func listsAgree() throws {
        let context = try js()
        #expect(try Parity.run(context, "globalThis.KhaytColourFamily.FAMILIES")
                == .array(ColourFamily.allCases.map { .string($0.rawValue) }))
        #expect(try Parity.run(context, "globalThis.KhaytColourFamily.TOKENS")
                == .array(ColourFamily.tokens.map(JSONValue.string)))
        #expect(try Parity.run(context, "globalThis.KhaytModelFileType.TYPES")
                == .array(ModelFileType.allCases.map { .string($0.rawValue) }))
        for family in ColourFamily.allCases {
            #expect(try Parity.run(context, "globalThis.KhaytColourFamily.SWATCH[ARG0]", [.string(family.rawValue)])
                    == .string(family.swatchHex))
            #expect(ColourFamily.family(ofHex: family.swatchHex) == family, "the \(family) swatch is not \(family)")
        }
    }

    static let hexes: [String] = [
        "#D4AF37", "#0A2A50", "#1A1A1E", "#FAF7F0", "#C8AD7F", "#C0C0C0", "#0E8A7E", "#008080", "#00B7EB",
        "#FF00FF", "#F28C28", "#F2A541", "#808000", "#800000", "#FFDAB9",
        "F28C28", "#f28c28", "f28C28", "  #F28C28 ", "#F28C28FF", "F28C2800", "#F00", "0f0", "#00F8",
        "", "#", "#12", "#12345", "#1234567", "#GGGGGG", "red", "rgb(1,2,3)", "#F28C28FFF", "##FF0000",
        "#FF 00 00", "\u{FF11}\u{FF12}\u{FF13}", "#١٢٣", "0x123456", "-12345", "+12345", "#12345g",
    ]

    @Test("every way a hex is written reads the same, or is refused, in both")
    func hexShapesAgree() throws {
        let context = try js()
        for hex in Self.hexes {
            let theirs = try Parity.run(context, "globalThis.KhaytColourFamily.familyOf(ARG0)", [.string(hex)])
            let mine: JSONValue = ColourFamily.family(ofHex: hex).map { .string($0.rawValue) } ?? .null
            #expect(mine == theirs, Comment(rawValue: "\(hex.debugDescription): swift \(mine) vs js \(theirs)"))
        }
    }

    @Test("the decided colours are where the owner put them")
    func decided() {
        let decided: [(String, ColourFamily)] = [
            ("#D4AF37", .yellow), ("#0A2A50", .blue), ("#1A1A1E", .black), ("#FAF7F0", .white),
            ("#C8AD7F", .brown), ("#C0C0C0", .grey), ("#0E8A7E", .green), ("#00B7EB", .blue),
            ("#FF00FF", .purple), ("#F28C28", .orange), ("#F2A541", .orange), ("#808000", .green),
            ("#800000", .red), ("#FFDAB9", .orange),
        ]
        for (hex, family) in decided { #expect(ColourFamily.family(ofHex: hex) == family, "\(hex)") }
    }

    @Test("a model's filter rows agree: each family, multi, none")
    func tokensAgree() throws {
        let context = try js()
        let lists: [[String]] = [
            [], ["#FF0000"], ["#FF0000", "#D92D20"], ["#FFFFFF", "#FF0000", "#000000"], ["nope"],
            ["#FF0000", "??"], ["#0F5257", "#7FB2AD", "#E8D8B0", "#D4AF37"], Self.hexes,
        ]
        for list in lists {
            let record = JSONValue.array(list.map { .object(["hex": .string($0), "label": .string("x")]) })
            let theirs = try Parity.run(context, "globalThis.KhaytColourFamily.tokensOf(ARG0)", [record])
            #expect(JSONValue.array(ColourFamily.tokens(ofHexes: list).map(JSONValue.string)) == theirs,
                    Comment(rawValue: "\(list)"))
        }
        #expect(ColourFamily.tokens(ofHexes: [nil, nil]) == ["none"])
        #expect(ColourFamily.tokens(ofHexes: ["#FFFFFF", "#FF0000", "#000000"]) == ["red", "black", "white", "multi"])
        #expect(ColourFamily.tokens(ofHexes: ["#FF0000", "#D92D20"]) == ["red"], "two reds are not multicolour")
    }

    @Test("a record's file type agrees, whatever shape the record is")
    func typesAgree() throws {
        let context = try js()
        func sf(_ fields: [String: String]) -> JSONValue {
            .object(["sourceFile": .object(fields.mapValues(JSONValue.string))])
        }
        var records: [JSONValue] = [
            .null, .object([:]), .array([]), .string("x"), .number(4),
            .object(["sourceFile": .null]), .object(["sourceFile": .array([])]), .object(["sourceFile": .object([:])]),
            .object(["sourceFile": .null, "externalPath": .string("")]),
            .object(["externalPath": .string("/Volumes/Models/benchy.3mf")]),
            .object(["externalPath": .string("C:\\Models\\benchy.obj")]),
            .object(["externalPath": .string("/Downloads/Pack.zip"), "archiveMember": .string("minis/knight.stl")]),
            .object(["externalPath": .string("/Downloads/plate_1.gcode.3mf")]),
            .object(["externalPath": .number(3)]),
            .object(["id": .string("PF-web"), "savedFromWebAt": .string("2026-11-01T10:00:00.000Z"), "colors": .array([])]),
            sf(["filename": "stored.3mf", "originalName": "Plate.GCODE.3MF", "ext": "3mf"]),
            sf(["filename": "plate.bin", "ext": "bin", "kind": "gcode"]),
            sf(["filename": "plate.bin", "ext": "bin", "kind": " GCode "]),
            sf(["filename": "README", "ext": ""]),
            sf(["filename": "Dragon.v2.STL"]), sf(["originalName": "part.step"]), sf(["filename": ".hidden"]),
            sf(["filename": "trailing."]), sf(["filename": "x.constructor"]), sf(["filename": "a.b/c"]),
            sf(["ext": " .OBJ "]), sf(["ext": "..stl"]),
        ]
        for ext in ["3mf", "3MF", "stl", "step", "stp", "STP", "obj", ".obj", "gcode", "gco", "g", "bgcode",
                    "scad", "zip", "f3d", "amf", "toString"] {
            for kind in ["model", "gcode", ""] {
                records.append(sf(["filename": "a." + ext, "ext": ext, "kind": kind]))
            }
        }
        for record in records {
            let theirs = try Parity.run(context, "globalThis.KhaytModelFileType.typeOf(ARG0)", [record])
            #expect(JSONValue.string(ModelFileType.type(of: record).rawValue) == theirs,
                    Comment(rawValue: "\(record): swift \(ModelFileType.type(of: record).rawValue) vs js \(theirs)"))
        }
        #expect(records.count > 70, "the sweep shrank")
    }
}
