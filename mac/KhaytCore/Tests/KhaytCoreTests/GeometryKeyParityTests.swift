import Foundation
import JavaScriptCore
import Testing
@testable import KhaytCore

/// The ported geometry key, against the JavaScript it came from.
///
/// The module's own comment says a key is "exactly the kind of thing two
/// implementations agree on until they do not: a rounding, a separator, an
/// order". This is that claim, checked — over generated geometry rather than
/// cases somebody thought of, because the cases somebody thinks of are the
/// ones both implementations already get right.
@MainActor
struct GeometryKeyParityTests {

    private func js() throws -> JSContextBox { try JSContextBox(["geometry-key"]) }

    @Test("the key agrees over awkward numbers, in every position")
    func keysAgree() throws {
        let box = try js()
        var checked = 0
        for tris in Awkward.numbers {
            for volume in Awkward.numbers.prefix(12) {
                for dim in Awkward.numbers.prefix(12) {
                    let geometry = JSONValue.object([
                        "triangleCount": .number(tris),
                        "volumeMm3": .number(volume),
                        "bbox": .object(["x": .number(dim),
                                         "y": .number(dim * 1.5),
                                         "z": .number(dim + 0.005)]),
                    ])
                    let fromJS = try box.key(of: geometry)
                    let fromSwift = GeometryKey.key(of: geometry)
                    #expect(fromSwift == fromJS, Comment(rawValue:
                        "tris=\(tris) vol=\(volume) dim=\(dim): swift \(fromSwift ?? "nil") "
                        + "vs js \(fromJS ?? "nil")"))
                    checked += 1
                }
            }
        }
        #expect(checked > 3_000, "the sweep shrank")
    }

    @Test("it agrees on things that are not numbers, which Number() still takes")
    func coercionAgrees() throws {
        let box = try js()
        for odd in Awkward.notNumbers {
            for position in ["triangleCount", "volumeMm3"] {
                var g: [String: JSONValue] = [
                    "triangleCount": .number(1000), "volumeMm3": .number(5000),
                    "bbox": .object(["x": .number(10), "y": .number(20), "z": .number(30)]),
                ]
                g[position] = odd
                let geometry = JSONValue.object(g)
                #expect(GeometryKey.key(of: geometry) == (try box.key(of: geometry)),
                        Comment(rawValue: "\(position) = \(odd)"))
            }
            // And in the bounding box, where a null dimension voids the key.
            let geometry = JSONValue.object([
                "triangleCount": .number(1000), "volumeMm3": .number(5000),
                "bbox": .object(["x": odd, "y": .number(20), "z": .number(30)]),
            ])
            #expect(GeometryKey.key(of: geometry) == (try box.key(of: geometry)),
                    Comment(rawValue: "bbox.x = \(odd)"))
        }
    }

    @Test("it agrees on geometry that is missing, empty or the wrong shape")
    func shapesAgree() throws {
        let box = try js()
        let shapes: [JSONValue] = [
            .null, .object([:]), .array([]), .string("nope"), .number(3),
            .object(["triangleCount": .number(10)]),
            .object(["triangleCount": .number(10), "volumeMm3": .number(1)]),
            .object(["triangleCount": .number(10), "volumeMm3": .number(1),
                     "bbox": .object([:])]),
            .object(["triangleCount": .number(0), "volumeMm3": .number(1),
                     "bbox": .object(["x": .number(1), "y": .number(1), "z": .number(1)])]),
            .object(["triangleCount": .number(-5), "volumeMm3": .number(1),
                     "bbox": .object(["x": .number(1), "y": .number(1), "z": .number(1)])]),
        ]
        for shape in shapes {
            #expect(GeometryKey.key(of: shape) == (try box.key(of: shape)),
                    Comment(rawValue: "shape \(shape)"))
        }
    }

    @Test("the reader number and the due test agree")
    func remeasureAgrees() throws {
        let box = try js()
        #expect(GeometryKey.reader == (try box.reader()))
        for value in Awkward.notNumbers + [.number(0), .number(1), .number(2), .number(3), .number(1.5)] {
            let record = JSONValue.object(["geometryReader": value])
            #expect(GeometryKey.needsRemeasure(record) == (try box.needsRemeasure(record)),
                    Comment(rawValue: "geometryReader = \(value)"))
        }
        // A record with no reader at all, and one that is not a record.
        for record: JSONValue in [.object([:]), .null, .string("x")] {
            #expect(GeometryKey.needsRemeasure(record) == (try box.needsRemeasure(record)),
                    Comment(rawValue: "record \(record)"))
        }
    }

    @Test("the key this shop's own library holds still comes out of the port")
    func theRealLibrary() throws {
        // `2439876:1142945.9:163.53x167.58x55.21`, off a real record. A port
        // that cannot reproduce a key already written is a port that orphans
        // every model in the book.
        let geometry = JSONValue.object([
            "triangleCount": .number(2_439_876),
            "volumeMm3": .number(1_142_945.9),
            "bbox": .object(["x": .number(163.53), "y": .number(167.58), "z": .number(55.21)]),
        ])
        #expect(GeometryKey.key(of: geometry) == "2439876:1142945.9:163.53x167.58x55.21")
    }
}
