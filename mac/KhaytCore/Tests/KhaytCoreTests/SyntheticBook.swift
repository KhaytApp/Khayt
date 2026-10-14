import Foundation
@testable import KhaytCore

/// A made-up book the shape of a real one: `records` library entries with the
/// fields a scan writes, plus a settings block and a few orders. Deterministic,
/// so two runs time the same text.
enum SyntheticBook {

    struct Rand {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 11
        }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
        mutating func pick<T>(_ xs: [T]) -> T { xs[int(xs.count)] }
    }

    static let words = ["Buzz", "Lightyear", "Wing", "detail", "white", "Benchy", "Vase", "Dragon",
                        "Gear", "Bracket", "Hinge", "Planter", "Keychain", "Mount", "Lid", "Base"]
    static let arabic = ["ملك", "مزهرية", "حامل", "قاعدة", "غطاء", "تنين", "ترس", "مفصلة"]
    static let id = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    static func make(records: Int, seed: UInt64 = 42) -> Data {
        var r = Rand(state: seed)
        var files: [JSONValue] = []
        files.reserveCapacity(records)
        for n in 0..<records {
            files.append(record(n, &r))
        }
        var settings: [String: JSONValue] = [:]
        for k in 0..<136 {
            settings["setting\(k)"] = k % 3 == 0 ? .string("value \(k) \(r.pick(arabic))")
                : k % 3 == 1 ? .number(Double(r.int(10_000)) / 100) : .bool(k % 2 == 0)
        }
        settings["logo"] = .string("data:image/png;base64," + String(repeating: "iVBORw0KGgoAAAANSUhEUgAA", count: 2000))
        let orders: [JSONValue] = (0..<20).map { k in
            .object([
                "id": .string("ORD-\(k)"), "priority": .bool(false), "paidAmount": .number(50),
                "project": .string("Portrait \(k) — \(r.pick(arabic))"), "status": .string("completed"),
                "timestamp": .string("2026-09-17T04:26:06.018Z"), "queuePos": .number(Double(k)),
                "attachedFiles": .array([]), "note": .null,
            ])
        }
        let root: [String: JSONValue] = [
            "version": .number(2),
            "printFiles": .array(files),
            "settings": .object(settings),
            "printLog": .array(orders),
            "clients": .array([]),
            "tombstones": .array((0..<88).map { .object(["id": .string("T-\($0)"), "at": .number(1791826094386 + Double($0))]) }),
        ]
        return try! JSONEncoder().encode(root)
    }

    static func record(_ n: Int, _ r: inout Rand) -> JSONValue {
        let a = r.pick(words), b = r.pick(words), c = r.pick(words)
        let name = "\(a)_\(b)_\(c)_\(n)"
        let folder = n % 4 == 0 ? "\(r.pick(arabic)) \(a)/\(b)" : "\(a) \(b)/Toy size \(r.int(40))cm"
        var o: [String: JSONValue] = [
            "id": .string("PF-" + String((0..<10).map { _ in r.pick(id) })),
            "name": .string(name),
            "originalName": .string(name + ".stl"),
            "folder": .string(folder), "group": .string(folder), "autoGroup": .string(folder),
            "externalPath": .string("/Volumes/Models/\(folder)/\(name).stl"),
            "updatedAt": .string("2026-10-13T04:50:57.910Z"),
            "indexedOnline": .string("2026-10-12T17:28:14.386Z"),
            "createdAt": .number(1791826094386.221 + Double(n)),
            "rev": .number(Double(1 + r.int(5))),
            "swapCount": .number(0),
            "favorite": .bool(r.int(10) == 0),
            "thumbFile": .null, "userPhoto": .null, "geometryKey": .null, "geometryReader": .null,
            "contentHash": n % 2 == 0 ? .null : .string(String(repeating: "ab12", count: 16)),
            "material": .string(n % 3 == 0 ? "PLA" : ""),
            "licence": .string(""), "source": .string(""), "testedNotes": .string(""),
            "slicerProfileId": .null, "thumbSource": .null,
            "colors": .array(n % 5 == 0 ? [.string("#FFFFFF"), .string("#1A1A1A")] : []),
            "tags": .array([.string("Aug26 Giga Tier")]),
            "parsed": .object(n % 3 == 0 ? [
                "printTime": .number(Double(r.int(90_000))),
                "filamentG": .number(Double(r.int(50_000)) / 100),
                "layerHeight": .number(0.2),
                "plates": .array([.object(["index": .number(1), "weight": .number(12.5)])]),
            ] : [:]),
            "sourceFile": .object([
                "path": .string("/Users/shop/Models/\(folder)/\(name).3mf"),
                "size": .number(Double(r.int(50_000_000))),
                "mtime": .number(1791826094386.5),
            ]),
        ]
        if n % 50 == 0 {
            o["thumbData"] = .string("data:image/png;base64," + String(repeating: "R0lGODlhAQABAIAAAP", count: 120))
        }
        return .object(o)
    }
}
