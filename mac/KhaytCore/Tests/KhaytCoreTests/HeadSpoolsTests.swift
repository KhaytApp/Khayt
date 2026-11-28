import Foundation
import Testing
@testable import KhaytCore

/// One spool, one head, through the engine the Mac and the phone ship, against
/// the vectors the desktop's own test reads (`test/head-spools.test.js`).
struct HeadSpoolsTests {

    struct Vectors: Decodable {
        struct Call: Decodable { let op: String; let machineId: String; let head: JSONValue; let spoolId: String? }
        struct Want: Decodable { let after: [String: [String: String]]; let moved: [KhaytEngine.HeadLinkResult.Moved]; let changed: [String]; let error: String? }
        struct Case: Decodable { let why: String; let before: [String: [String: String]?]; let call: Call; let want: Want }
        struct ShownCase: Decodable { let why: String; let linked: String?; let reportsEmpty: Bool?; let want: String }
        struct Shown: Decodable { let cases: [ShownCase] }
        let cases: [Case]
        let shown: Shown
    }

    static func vectors() throws -> Vectors {
        try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: CrossAppFixtureTests.fixture("head-spools-vectors.json")))
    }

    @Test("the shared cases, through the engine: a spool leaves every other head")
    func cases() async throws {
        let engine = try KhaytEngine()
        let v = try Self.vectors()
        #expect(v.cases.count >= 8, "the fixture lost cases")
        for c in v.cases {
            let machines: [JSONValue] = c.before.keys.sorted().map { id in
                var m: [String: JSONValue] = ["id": .string(id), "name": .string(id)]
                if let h = c.before[id] ?? nil { m["headSpools"] = .object(h.mapValues(JSONValue.string)) }
                return .object(m)
            }
            // The rule takes "0" or 0; a head that is not a number is the refusal case.
            let head: Int
            switch c.call.head {
            case .number(let n): head = Int(n)
            case .string(let s): head = Int(s) ?? -1
            default: head = -1
            }
            let r = c.call.op == "link"
                ? try await engine.headSpoolsLink(machines: machines, machineId: c.call.machineId, head: head, spoolId: c.call.spoolId ?? "")
                : try await engine.headSpoolsUnlink(machines: machines, machineId: c.call.machineId, head: head)
            var after: [String: [String: String]] = [:]
            for m in r.machines {
                guard case .object(let o) = m, case .string(let id)? = o["id"] else { continue }
                var h: [String: String] = [:]
                if case .object(let links)? = o["headSpools"] { for (k, v) in links { if case .string(let s) = v { h[k] = s } } }
                after[id] = h
            }
            for (id, want) in c.want.after { #expect(after[id] == want, Comment(rawValue: "\(c.why): \(id)")) }
            #expect(r.moved == c.want.moved, Comment(rawValue: c.why))
            #expect(r.changed.sorted() == c.want.changed.sorted(), Comment(rawValue: c.why))
            #expect(r.error == c.want.error, Comment(rawValue: c.why))
        }
    }

    @Test("an empty read keeps the link and says so; an unanswered printer is not an empty head")
    func shown() async throws {
        let engine = try KhaytEngine()
        for c in try Self.vectors().shown.cases {
            #expect(try await engine.headSpoolsShown(linked: c.linked, reportsEmpty: c.reportsEmpty) == c.want, Comment(rawValue: c.why))
        }
    }
}
