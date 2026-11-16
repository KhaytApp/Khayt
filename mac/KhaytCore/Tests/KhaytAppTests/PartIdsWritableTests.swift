import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A job the book keys by a number (or by nothing) has its parts given ids on
/// screen, and is never "owed" a write: `Shop.write` cannot find it, and
/// counting it had every load rewrite the whole book for nothing (beta.38 review).
@MainActor
struct PartIdsWritableTests {

    static let bare: JSONValue = .object(["name": .string("Bracket"), "qty": .number(1)])

    @Test("only string-keyed jobs are writable; a book with none is left exactly as it was")
    func numericIds() async throws {
        let engine = try KhaytEngine()
        let rows: [JSONValue] = [
            .object(["id": .number(5), "parts": .array([Self.bare])]),
            .object(["parts": .array([Self.bare])]),
        ]
        let made = try #require(await Shop.rowsWithPartIds(rows, engine: engine))
        #expect(!made.given.isEmpty, "the rule still gives ids, for the screen")
        #expect(Shop.writable(made, in: rows).isEmpty)
        var root: [String: JSONValue] = ["printLog": .array(rows)]
        let before = root
        #expect(await Shop.givePartIds(&root, engine: engine) == 0)
        #expect(root == before, "nothing written")
    }

    @Test("a mixed book: only the string-keyed job is written, and counted")
    func mixed() async throws {
        let engine = try KhaytEngine()
        let rows: [JSONValue] = [
            .object(["id": .number(5), "parts": .array([Self.bare])]),
            .object(["id": .string("INV-2026-0001"), "parts": .array([Self.bare, Self.bare])]),
        ]
        var root: [String: JSONValue] = ["printLog": .array(rows)]
        #expect(await Shop.givePartIds(&root, engine: engine) == 2)
        guard case .array(let out)? = root["printLog"] else { Issue.record("no printLog"); return }
        #expect(out[0] == rows[0], "the numeric-keyed job is untouched")
        #expect(KhaytEngine.hasPartsWithoutIds([out[1]]) == false)
    }
}
