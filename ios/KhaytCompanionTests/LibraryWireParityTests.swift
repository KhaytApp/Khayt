import KhaytCore
import XCTest
@testable import KhaytCompanion

/// The phone's own answer to `GET /api/library` (its cloud copy and the
/// sample shop: `SampleLibrary.page`) against the server's, case by case, on
/// the shared fixture `test/fixtures/library-wire/` (`printFiles.json`, and
/// `answers.json` written from `lib/lan-library.js`). The two libraries away
/// from the shop and at it must list, count and filter the same models.
///
/// The fixture lands with the Mac's half (#2444). Missing, this FAILS — a
/// parity test that skips is a parity test nobody runs.
@MainActor
final class LibraryWireParityTests: XCTestCase {
    private var dir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../test/fixtures/library-wire").standardizedFileURL
    }

    private struct Case { let name: String; let opts: [String: Any]; let answer: Any }

    private func cases() throws -> [Case] {
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("answers.json")))
        func one(_ name: String, _ c: Any) -> Case? {
            guard let c = c as? [String: Any], let answer = c["answer"] else { return nil }
            return Case(name: (c["name"] as? String) ?? name, opts: (c["opts"] as? [String: Any]) ?? [:], answer: answer)
        }
        if let byName = raw as? [String: Any] {
            return byName.sorted { $0.key < $1.key }.compactMap { one($0.key, $0.value) }
        }
        if let list = raw as? [Any] { return list.enumerated().compactMap { one("case \($0.offset)", $0.element) } }
        return []
    }

    private func items() throws -> [KhaytCompanion.LibraryItem] {
        let rows = try JSONDecoder().decode([JSONValue].self, from: Data(contentsOf: dir.appendingPathComponent("printFiles.json")))
        return LibraryCopy.items(rows)
    }

    private func phone(_ items: [KhaytCompanion.LibraryItem], _ opts: [String: Any]) -> LibraryPage {
        let filter = LibraryFilter(colours: LibraryFilter.keys(opts["colour"] as? String, among: LibraryFilter.colourKeys),
                                   types: LibraryFilter.keys(opts["type"] as? String, among: LibraryFilter.typeKeys))
        return SampleLibrary.page(items, query: (opts["q"] as? String) ?? "", folder: (opts["folder"] as? String) ?? "",
                                  limit: 200, filter: filter)
    }

    func testTheFixtureIsThere() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("answers.json").path),
                      "test/fixtures/library-wire/ is missing: it comes with the Mac's half (#2444)")
    }

    func testThePhoneAgreesWithTheServerOnEveryCase() throws {
        let items = try items()
        XCTAssertEqual(items.count, 12)
        let all = try cases()
        XCTAssertGreaterThanOrEqual(all.count, 13)
        var report: [String] = []
        for c in all {
            let server = try JSONDecoder().decode(LibraryPage.self, from: JSONSerialization.data(withJSONObject: c.answer))
            let phone = phone(items, c.opts)
            func line(_ what: String, _ a: Any, _ b: Any) { report.append("\(c.name) \(what): server=\(a) phone=\(b)") }
            if server.total != phone.total { line("total", server.total, phone.total) }
            if server.matchedTotal != phone.matchedTotal { line("matchedTotal", server.matchedTotal as Any, phone.matchedTotal as Any) }
            if server.unfilteredTotal != phone.unfilteredTotal {
                line("unfilteredTotal", server.unfilteredTotal as Any, phone.unfilteredTotal as Any)
            }
            if server.facets != phone.facets { line("facets", server.facets as Any, phone.facets as Any) }
            let sf = server.folders.map { "\($0.path):\($0.count)" }.sorted()
            let pf = phone.folders.map { "\($0.path):\($0.count)" }.sorted()
            if sf != pf { line("folders", sf, pf) }
            if Set(server.items.map(\.id)) != Set(phone.items.map(\.id)) {
                line("items", server.items.map(\.id).sorted(), phone.items.map(\.id).sorted())
            }
        }
        XCTAssertEqual(report, [], report.joined(separator: "\n"))
    }

    /// The figures the Mac lane stated, pinned so a regenerated fixture that
    /// drifts from the agreed scope is noticed on this side too.
    func testThePinnedCases() throws {
        let items = try items()
        let none = phone(items, [:])
        XCTAssertEqual(none.total, 2, "two models filed at the top")
        XCTAssertEqual(none.matchedTotal, 12)
        XCTAssertEqual(none.unfilteredTotal, 12, "the menus reach the whole library")
        XCTAssertEqual(none.facets, LibraryFilter().facets(items), "counted over the whole library")

        let red = phone(items, ["colour": "red"])
        XCTAssertEqual(red.total, 0)
        XCTAssertEqual(red.matchedTotal, 2)
        XCTAssertEqual(red.unfilteredTotal, 12)
        XCTAssertTrue(red.items.isEmpty)
        XCTAssertEqual(red.folders.map { "\($0.path):\($0.count)" }, ["Home:2"])
        XCTAssertEqual(red.facets?.colour["red"], 2)
    }
}
