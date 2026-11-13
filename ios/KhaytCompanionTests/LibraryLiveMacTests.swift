import XCTest
@testable import KhaytCompanion

/**
 * The Library filters against a REAL server: the Mac's native LanServer on
 * its SAMPLE book (LanServerTests.Bench in serve mode, #2444), reached through
 * the phone's own KhaytAPIClient over localhost with the owner PIN.
 *
 * Opt-in: runs only with `TEST_RUNNER_KHAYT_LIVE_MAC=host:port:pin` (a test
 * value, never a real shop's). Without it, it skips, so CI and everyday runs
 * never touch the network.
 *
 * It does not know the sample book's shape, so it checks what the contract
 * promises at every level it can reach:
 * - the File types partition the reach (they sum to M), and N ≤ M;
 * - picking one colour gives exactly that colour's count as N;
 * - N = the models listed here + every listed folder's count;
 * - each menu ignores its own pick (the colour counts don't move when a colour
 *   is picked) and the type counts then sum to N;
 * - a search's totals agree with each other.
 */
@MainActor
final class LibraryLiveMacTests: XCTestCase {

    private func liveClient() throws -> (KhaytAPIClient, () -> Void) {
        guard let spec = ProcessInfo.processInfo.environment["KHAYT_LIVE_MAC"], !spec.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_KHAYT_LIVE_MAC=host:port:pin to run against a sample-book Mac")
        }
        let parts = spec.split(separator: ":").map(String.init)
        guard parts.count == 3, let port = Int(parts[1]) else { throw XCTSkip("KHAYT_LIVE_MAC must be host:port:pin") }
        let s = ConnectionSettings()
        let saved = (s.host, s.port, s.pin, s.isPaired, s.isSampleShop)
        s.host = parts[0]; s.port = port; s.pin = parts[2]; s.isPaired = true; s.isSampleShop = false
        let api = KhaytAPIClient(settings: s, withBook: false)
        return (api, { (s.host, s.port, s.pin, s.isPaired, s.isSampleShop) = saved })
    }

    /// Everything the server answered, for the PR body.
    private var log: [String] = []

    private func page(_ api: KhaytAPIClient, folder: String = "", q: String = "",
                      colours: Set<String> = [], types: Set<String> = []) async throws -> LibraryPage {
        var f = LibraryFilter(); f.colours = colours; f.types = types
        let p = try await api.fetchLibrary(query: q, folder: folder, limit: 200, filter: f)
        log.append("folder=\"\(folder)\" q=\"\(q)\" colour=\(colours.sorted()) type=\(types.sorted()): "
                   + "total \(p.total) matched \(p.matchedTotal.map(String.init) ?? "nil") "
                   + "of \(p.unfilteredTotal.map(String.init) ?? "nil"), folders \(p.folders.map { "\($0.path):\($0.count)" })")
        return p
    }

    private func checkLevel(_ api: KhaytAPIClient, folder: String, colour: String?, depth: Int) async throws {
        let picked: Set<String> = colour.map { [$0] } ?? []
        let p = try await page(api, folder: folder, colours: picked)
        let facets = try XCTUnwrap(p.facets, "\(folder): a #2444 server sends facets")
        let m = try XCTUnwrap(p.unfilteredTotal, "\(folder): unfilteredTotal")
        let n = try XCTUnwrap(p.matchedTotal, "\(folder): matchedTotal")
        XCTAssertLessThanOrEqual(n, m, folder)
        XCTAssertEqual(n, p.items.count + p.folders.reduce(0) { $0 + $1.count },
                       "\(folder): N = the models listed here + each listed folder's count")
        XCTAssertEqual(facets.type.values.reduce(0, +), n,
                       "\(folder): the type counts (counted over the colour pick) sum to N")
        if colour == nil {
            XCTAssertEqual(n, m, "\(folder): nothing picked, so N = M")
            for (key, count) in facets.colour where count > 0 && key != "multi" {
                let one = try await page(api, folder: folder, colours: [key])
                XCTAssertEqual(one.matchedTotal, count, "\(folder): picking \(key) gives its count")
                XCTAssertEqual(one.facets?.colour, facets.colour, "\(folder): the colour menu ignores its own pick")
            }
        }
        guard depth < 3 else { return }
        for sub in p.folders { try await checkLevel(api, folder: sub.path, colour: colour, depth: depth + 1) }
    }

    func testTheFiltersHoldAtEveryLevelOfARealServer() async throws {
        let (api, restore) = try liveClient()
        defer { restore() }
        try await checkLevel(api, folder: "", colour: nil, depth: 0)
        let top = try await page(api)
        if let colour = top.facets?.colour.first(where: { $0.value > 0 && $0.key != "none" && $0.key != "multi" })?.key {
            try await checkLevel(api, folder: "", colour: colour, depth: 0)
        }
        // A search: everything the search found, so its three totals agree.
        if let word = top.items.first?.name.split(separator: " ").first.map(String.init) {
            let s = try await page(api, q: word)
            XCTAssertEqual(s.matchedTotal, s.total, "a search lists all it matched")
            XCTAssertEqual(s.unfilteredTotal, s.total, "nothing picked")
        }
        let out = ProcessInfo.processInfo.environment["KHAYT_LIVE_LOG"] ?? NSTemporaryDirectory() + "library-live.log"
        try log.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        print("library-live: \(log.count) answers checked, log at \(out)")
    }

    /// A server from before the filters (the Mac's simulated one on its
    /// `KHAYT_LIVE_OLD_MAC` port): it ignores the picks and sends no facets,
    /// so the phone must hide both menus rather than show stale counts.
    func testAnOlderServerHidesTheMenus() async throws {
        guard let spec = ProcessInfo.processInfo.environment["KHAYT_LIVE_OLD_MAC"], !spec.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_KHAYT_LIVE_OLD_MAC=host:port:pin")
        }
        let parts = spec.split(separator: ":").map(String.init)
        let s = ConnectionSettings()
        let saved = (s.host, s.port, s.pin, s.isPaired, s.isSampleShop)
        defer { (s.host, s.port, s.pin, s.isPaired, s.isSampleShop) = saved }
        s.host = parts[0]; s.port = Int(parts[1]) ?? 0; s.pin = parts[2]; s.isPaired = true; s.isSampleShop = false
        let api = KhaytAPIClient(settings: s, withBook: false)
        var f = LibraryFilter(); f.colours = ["brown"]
        let p = try await api.fetchLibrary(query: "", folder: "", limit: 200, filter: f)
        XCTAssertNil(p.facets, "an older server sends no facets")
        XCTAssertNil(p.matchedTotal)
        XCTAssertNil(p.unfilteredTotal)
        // That IS the screen's rule: LibraryView draws the bar only
        // `if let facets = page.facets`, so no facets means no menus.
        print("library-live-old: total \(p.total), folders \(p.folders.map { "\($0.path):\($0.count)" }), facets nil")
    }
}
