import Foundation
import Testing
@testable import KhaytCore

/// The ids the Mac gives parts are the ids the desktop gives them.
///
/// `test/fixtures/part-ids-vectors.json` is what `test/part-ids.test.js`
/// pins under V8. Here the same vectors go through the copy this app SHIPS
/// (`KhaytEngine`, JavaScriptCore), Arabic included: a book two computers
/// share must get one id per part, not one per engine.
struct PartIdsParityTests {

    struct Vectors: Decodable {
        struct Hash: Decodable { let text: String; let hash: Double }
        struct Case: Decodable {
            let why: String
            let orderId: String
            let index: Int
            let part: JSONValue
            let text: String
            let id: String
        }
        let cyrb53: [Hash]
        let cases: [Case]
    }

    static func vectors() throws -> Vectors {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/Tests/KhaytCoreTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // …/KhaytCore
            .deletingLastPathComponent()   // …/mac
            .deletingLastPathComponent()   // the repository root
            .appending(path: "test/fixtures/part-ids-vectors.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    @Test("every vector gives the desktop's text and id under JavaScriptCore")
    func vectorsAgree() async throws {
        let engine = try KhaytEngine()
        let v = try Self.vectors()
        #expect(v.cases.count >= 8)
        #expect(v.cases.contains { $0.orderId == "INV-2026-0003-3y0z" && $0.text.contains("حامل جوال") },
                "the Arabic vector is missing")
        for c in v.cases {
            #expect(try await engine.partIdText(orderId: c.orderId, index: c.index, part: c.part) == c.text,
                    Comment(rawValue: c.why))
            #expect(try await engine.partIdFor(orderId: c.orderId, index: c.index, part: c.part) == c.id,
                    Comment(rawValue: c.why))
        }
    }

    @Test("assignPartIds through the engine: only the parts without one, and once")
    func assignsOnce() async throws {
        let engine = try KhaytEngine()
        let bare: JSONValue = .object(["name": .string("حامل"), "qty": .number(1)])
        let rows: [JSONValue] = [
            .object(["id": .string("J1"), "parts": .array([bare, .object(["id": .string("PRT-keep")])])]),
            .object(["id": .string("J2"), "parts": .array([.object(["id": .string("PRT-x")])])]),
        ]
        #expect(KhaytEngine.hasPartsWithoutIds(rows))
        let made = try await engine.assignPartIds(rows)
        let owed = try await engine.partIdFor(orderId: "J1", index: 0, part: bare)
        #expect(made.given == [.init(orderId: "J1", index: 0, id: owed)])
        #expect(!KhaytEngine.hasPartsWithoutIds(made.orders))
        #expect(try await engine.assignPartIds(made.orders).given.isEmpty)
        #expect(made.orders[1] == rows[1], "a job with nothing missing came back changed")
    }
}
