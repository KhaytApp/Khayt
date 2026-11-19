import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A rated product's online line: its parts are built at the ORDERED count
/// and cut inside the write, and its labour and packaging are priced there
/// for the pieces the FRESH shelf reading says to make (#2593 money review,
/// HIGH). The shelf moves between the queue read and Accept in every
/// direction here, through the real write (`WebStoreOrdersTests.put`).
@MainActor
struct OnlineLineFreshTests {

    /// Labour for a line of n of this product: (0.25 + 0.5 n) × 90 × 1.1.
    static func labour(_ n: Double) -> Double { ((0.25 + 0.5 * n) * 90 * 1.1 * 100).rounded() / 100 }

    static func scratch(shelf: Int) throws -> WebStoreOrdersTests.Scratch {
        let s = try WebStoreOrdersTests.scratch()
        var root = try s.read()
        root["products"] = .array([.object([
            "id": .string("PRD-A"), "nameEn": .string("Flexi Dragon"),
            "rates": .object(["laborRate": .number(90), "prepTime": .number(0.25), "postTime": .number(0.5),
                              "failureRate": .number(10)]),
            "labourPerPart": .bool(false),
            "parts": .array([.object(["name": .string("a"), "printWeight": .number(10), "printTime": .number(1),
                                      "qty": .number(1)])]),
        ])])
        WebStoreOrdersTests.setShelf(shelf, in: &root)
        try JSONEncoder().encode(root).write(to: s.url)
        return s
    }

    /// What `onlineJobInput` now hands over: the line built at the ordered 3,
    /// each part marked with its line and its count per piece.
    static let input: [String: JSONValue] = [
        "project": .string("Medusa order — #1042"),
        "source": .string("medusa"),
        "sourceOrderId": .string("medusa:#1042"),
        "labourCost": .number(999), "packagingCost": .number(999),   // queue-time figures: must be replaced
        "parts": .array([.object([
            "name": .string("a"), "qty": .number(3), "printWeight": .number(10), "printTime": .number(1),
            "unitCost": .number(1), "baseCost": .number(3), "orderLevelCosts": .bool(true),
            Shop.lineKey: .number(0), Shop.perPieceKey: .number(1),
        ])]),
    ]

    static func job(_ s: WebStoreOrdersTests.Scratch) throws -> [String: JSONValue] {
        try #require(WebStoreOrdersTests.jobs(try s.read()).first)
    }

    static func partQty(_ job: [String: JSONValue]) -> Double? {
        guard case .array(let parts)? = job["parts"], case .object(let p)? = parts.first,
              case .number(let q)? = p["qty"] else { return nil }
        return q
    }

    @Test("queued with 1 on the shelf (print 2); one sold before Accept: print 3, labour for 3")
    func moreToPrint() async throws {
        let engine = try KhaytEngine()
        let s = try Self.scratch(shelf: 1)
        defer { try? FileManager.default.removeItem(at: s.dir) }
        _ = try await WebStoreOrdersTests.put(WebStoreOrdersTests.payload(qty: 3), intakeId: "1", input: Self.input,
                                              into: s, engine: engine) { WebStoreOrdersTests.setShelf(0, in: &$0) }
        let job = try Self.job(s)
        #expect(Self.partQty(job) == 3)
        #expect(job["labourCost"] == .number(Self.labour(3)))
    }

    @Test("queued with none on the shelf (print 3); two counted in before Accept: print 1, labour for 1")
    func lessToPrint() async throws {
        let engine = try KhaytEngine()
        let s = try Self.scratch(shelf: 0)
        defer { try? FileManager.default.removeItem(at: s.dir) }
        _ = try await WebStoreOrdersTests.put(WebStoreOrdersTests.payload(qty: 3), intakeId: "1", input: Self.input,
                                              into: s, engine: engine) { WebStoreOrdersTests.setShelf(2, in: &$0) }
        let job = try Self.job(s)
        #expect(Self.partQty(job) == 1)
        #expect(job["labourCost"] == .number(Self.labour(1)))
    }

    @Test("queued all from the shelf; the shelf emptied before Accept: the parts are there to print, labour for 3")
    func shelfToPrint() async throws {
        let engine = try KhaytEngine()
        let s = try Self.scratch(shelf: 5)
        defer { try? FileManager.default.removeItem(at: s.dir) }
        _ = try await WebStoreOrdersTests.put(WebStoreOrdersTests.payload(qty: 3), intakeId: "1", input: Self.input,
                                              into: s, engine: engine) { WebStoreOrdersTests.setShelf(0, in: &$0) }
        let job = try Self.job(s)
        #expect(Self.partQty(job) == 3, "the line had no parts to resize: THE SHELF, COUNTED AGAIN")
        #expect(job["labourCost"] == .number(Self.labour(3)))
        #expect(job["fromStock"] == nil)
    }

    @Test("queued some to print; the shelf filled before Accept: all from the shelf, recorded at the whole line")
    func printToShelf() async throws {
        let engine = try KhaytEngine()
        let s = try Self.scratch(shelf: 0)
        defer { try? FileManager.default.removeItem(at: s.dir) }
        _ = try await WebStoreOrdersTests.put(WebStoreOrdersTests.payload(qty: 3), intakeId: "1", input: Self.input,
                                              into: s, engine: engine) { WebStoreOrdersTests.setShelf(5, in: &$0) }
        let job = try Self.job(s)
        #expect(job["fromStock"] == .bool(true))
        // A job recorded from stock costs the whole line (`all ? qty : toPrint`).
        #expect(Self.partQty(job) == 3)
        #expect(job["labourCost"] == .number(Self.labour(3)))
    }
}
