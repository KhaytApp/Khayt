import Foundation
import KhaytCore
@testable import KhaytApp

/// A library that reaches every branch of the per-model figures `load` works
/// out: fits, mesh estimates, licence standings and stored print risks.
///
/// `PerfBook` times the READ of a big book, and its models carry no geometry,
/// so not one of them has a fit or an estimate. This one is shaped like the
/// shop's real library where those figures come from — about a third of the
/// models measured, a third with a stored overhang summary, a few percent
/// with a licence — and then pushed into the corners: a model too big for
/// every bed, one that fits only turned, a zero-volume mesh, an unparseable
/// geometry key, an infinite one, a summary describing a replaced file, a
/// licence written in capitals, one nobody recognises, a source and no
/// licence. Deterministic, so two runs compare the same book.
enum FiguresBook {

    struct Rand {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 11
        }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
        mutating func unit() -> Double { Double(next() % 1_000_000) / 1_000_000 }
        mutating func pick<T>(_ xs: [T]) -> T { xs[int(xs.count)] }
    }

    static let licences = ["", "", "CC-BY", "cc-by-nc", "CC-BY-NC-SA", "cc0", "own", "commercial",
                           "cc-by-nd", " cc-by-sa ", "GPL-3.0", "Standard Digital File License"]
    static let sources = ["", "", "https://www.printables.com/model/12345", "makerworld",
                          "thingiverse.com/thing:99", "Bought at a fair"]

    static func geometryKey(_ i: Int, _ r: inout Rand) -> JSONValue {
        switch i % 97 {
        case 0: return .string("12:0:10x10x10")                    // a zero-volume mesh
        case 1: return .string("not a key")                        // unreadable
        case 2: return .string("12:1e999:10x10x10")                // infinite volume
        case 3: return .string("4000:9000000:600x500x400")         // too big for every bed
        case 4: return .string("4000:200000:190x290x40")           // fits only turned, on one bed
        case 5: return .string("4000:200000:200x200x300")          // too tall
        case 6: return .string("4000:nan:20x20x20")                // NaN volume
        default:
            let x = 5 + r.unit() * 280, y = 5 + r.unit() * 240, z = 1 + r.unit() * 260
            let vol = x * y * z * (0.05 + r.unit() * 0.6)
            return .string("\(1000 + r.int(7_000_000)):\(vol):\(x)x\(y)x\(z)")
        }
    }

    static func analysis(_ i: Int, _ r: inout Rand) -> JSONValue {
        let buckets = i % 5 == 0 ? 64 : 91
        let histogram = JSONValue.array((0..<buckets).map { b in
            .number(r.unit() * 1500 / Double(b + 1))
        })
        var a: [String: JSONValue] = [
            "triangleCount": .number(Double(1000 + r.int(7_000_000))),
            "histogram": histogram,
            "bedContactAreaMm2": .number(r.unit() * 400),
            "windingFlipped": .bool(i % 31 == 0),
            "degenerateTriangles": .number(Double(r.int(5))),
            "windingFromVolume": .bool(true),
            "bedZ": .number(0),
            "downwardAreaMm2": .number(r.unit() * 30_000),
        ]
        // Thin walls in some (area large against the volume), none in others,
        // and a summary missing its area in a few.
        if i % 23 != 0 { a["totalAreaMm2"] = .number(1_000 + r.unit() * (i % 4 == 0 ? 400_000 : 60_000)) }
        if i % 29 != 0 { a["volumeMm3"] = .number(500 + r.unit() * 800_000) }
        return .object(a)
    }

    static func synthesize(models count: Int, seed: UInt64 = 7, logo: Bool = true) -> [String: JSONValue] {
        var r = Rand(state: seed)
        var rows: [JSONValue] = []
        rows.reserveCapacity(count)
        for i in 0..<count {
            let id = String(format: "pf%010d", i)
            let name = "Model \(i) part \(i % 97)"
            let hash = String(format: "%064x", i)
            var o: [String: JSONValue] = [
                "id": .string(id), "name": .string(name), "originalName": .string(name + ".3mf"),
                "folder": .string(""), "group": .string(i % 12 == 0 ? "" : "Group \(i % 811)"),
                "tags": .array([.string("tag \(i % 23)")]), "colors": .array([]),
                "favorite": .bool(i % 50 == 0), "material": .string(""),
                "createdAt": .number(1_750_000_000_000 + Double(i) * 1000),
                "updatedAt": .string("2026-09-20T10:00:00.000Z"),
                "contentHash": i % 7 == 0 ? .null : .string(hash),
                "sourceFile": .object(["ext": .string("3mf"), "filename": .string(name + ".3mf"),
                                       "kind": .string("model"), "size": .number(Double(100_000 + i))]),
            ]
            // A third measured, as on the shop's book (3,553 of 9,802).
            if i % 11 < 4 { o["geometryKey"] = geometryKey(i, &r) } else { o["geometryKey"] = .null }
            // A third with a stored summary; some of them measured from a file
            // the record no longer points at, which must not be judged.
            if i % 3 == 1 {
                let from = i % 41 == 1 ? String(format: "%064x", i + 1) : hash
                o["printRisk"] = .object(["contentHash": .string(from), "analysis": analysis(i, &r),
                                          "at": .number(1_760_000_000_000)])
            }
            if i % 17 == 2 { o["printRisk"] = .object(["analysis": .object([:])]) }
            if i % 9 == 0 {
                o["licence"] = .string(r.pick(licences))
                o["source"] = .string(r.pick(sources))
            } else if i % 13 == 5 {
                o["source"] = .string(r.pick(sources))
            }
            rows.append(.object(o))
        }
        // Two beds and a nozzle each, as on the shop's book, plus one with no
        // bed recorded (which must not be counted as a bed nothing fits).
        let machines: [JSONValue] = [
            .object(["id": .string("MACH-a"), "name": .string("Big"), "nozzleDiameter": .number(0.4),
                     "bed": .object(["x": .number(300), "y": .number(200), "z": .number(270)])]),
            .object(["id": .string("MACH-b"), "name": .string("Small"), "nozzleDiameter": .number(0.6),
                     "bed": .object(["x": .number(250), "y": .number(220), "z": .number(270)])]),
            .object(["id": .string("MACH-c"), "name": .string("Unknown bed")]),
        ]
        // Enough measured jobs for the estimator to learn a rate.
        var orders: [JSONValue] = []
        for k in 0..<24 {
            let hours = 2 + Double(k % 7)
            let grams = hours * (14 + Double(k % 5))
            let part: JSONValue = .object(["id": .string("P\(k)"),
                                           "printFileId": .string(String(format: "pf%010d", k * 3))])
            var o: [String: JSONValue] = [:]
            o["id"] = .string("ORD-\(k)")
            o["status"] = .string("completed")
            o["priority"] = .bool(false)
            o["machineId"] = .string(k % 2 == 0 ? "MACH-a" : "MACH-b")
            o["project"] = .string("Job \(k)")
            o["parts"] = .array([part])
            o["actualPrintTime"] = .number(hours)
            o["actualWeight"] = .number(grams)
            o["actualsSource"] = .object(["time": .string("printer"), "weight": .string("printer")])
            o["createdAt"] = .string("2026-09-\(10 + k % 18)T10:00:00.000Z")
            orders.append(.object(o))
        }
        var settings: [String: JSONValue] = [
            "currency": .string("SAR"), "lang": .string("en"), "bizEn": .string("Figures Shop"),
            "estimator": .object(["densityGPerCm3": .number(1.27), "infillPct": .number(0.18),
                                  "wallThicknessMm": .number(1.2)]),
        ]
        if logo {
            settings["bizLogo"] = .string("data:image/png;base64," + String(repeating: "iVBO", count: 180_000))
            settings["printLibrary"] = .object(["pictureChecks": .object(Dictionary(uniqueKeysWithValues:
                (0..<200).map { ("pf\($0)", JSONValue.string(String(repeating: "f", count: 1_700))) }))])
        }
        return ["version": .number(1), "printFiles": .array(rows), "settings": .object(settings),
                "machines": .array(machines), "printLog": .array(orders), "inventory": .array([]),
                "clients": .array([]), "tombstones": .array([])]
    }
}
