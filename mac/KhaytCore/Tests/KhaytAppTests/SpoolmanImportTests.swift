import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A shop's Spoolman spools, onto the Mac's shelf.
///
/// What each spool becomes is `lib/spoolman-import.js`, tested against
/// Spoolman's own models in `test/spoolman-import.test.js`. This holds the
/// Mac's side: the address guard, reading every page, and the write — against
/// a real file, twice, to prove a second import adds nothing.
@MainActor
struct SpoolmanImportTests {

    static func engine() async throws -> KhaytEngine {
        let shop = Shop()
        await shop.load(.sample)
        return try #require(shop.engine)
    }

    static func spool(_ id: Int, archived: Bool = false) -> JSONValue {
        .object([
            "id": .number(Double(id)), "registered": .string("2025-03-04T08:30:00Z"), "archived": .bool(archived),
            "price": .number(79), "remaining_weight": .number(600), "initial_weight": .number(1000),
            "used_weight": .number(400), "location": .null, "lot_nr": .null, "first_used": .null,
            "filament": .object([
                "id": .number(7), "name": .string("Galaxy Black"), "material": .string("PETG"),
                "color_hex": .string("1b1b1f"), "density": .number(1.27), "diameter": .number(1.75),
                "vendor": .object(["id": .number(1), "name": .string("Sunlu")]),
            ]),
        ])
    }

    @Test("an address is read however the shop pastes it, and only this network is allowed")
    func addresses() async throws {
        let engine = try await Self.engine()
        #expect(try await SpoolmanImport.base("192.168.1.20", engine: engine).absoluteString == "http://192.168.1.20:7912")
        #expect(try await SpoolmanImport.base(" http://192.168.1.20:8000/ ", engine: engine).absoluteString
                == "http://192.168.1.20:8000")
        await #expect(throws: SpoolmanImport.Problem.notALanAddress("8.8.8.8")) {
            _ = try await SpoolmanImport.base("8.8.8.8:7912", engine: engine)
        }
        await #expect(throws: SpoolmanImport.Problem.noAddress) {
            _ = try await SpoolmanImport.base("   ", engine: engine)
        }
    }

    final class Asked: @unchecked Sendable { var paths: [String] = [] }

    @Test("every page is read, and reading stops at the total")
    func pages() async throws {
        let engine = try await Self.engine()
        let asked = Asked()
        let fetched = try await SpoolmanImport.fetchAll(URL(string: "http://192.168.1.20:7912")!, engine: engine) { request in
            let url = request.url!
            asked.paths.append(url.path + "?" + (url.query ?? ""))
            let offset = Int(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "offset" }?.value ?? "0") ?? 0
            let count = offset == 0 ? 500 : 3
            let rows = JSONValue.array((0..<count).map { Self.spool(offset + $0) })
            let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["x-total-count": "503"])!
            return (try JSONEncoder().encode(rows), r)
        }
        #expect(fetched.count == 503)
        #expect(asked.paths == ["/api/v1/spool?allow_archived=false&limit=500&offset=0",
                                "/api/v1/spool?allow_archived=false&limit=500&offset=500"])
    }

    @Test("a refusal, a redirect, or something that is not Spoolman is said, not imported")
    func refusals() async throws {
        let engine = try await Self.engine()
        let base = URL(string: "http://192.168.1.20:7912")!
        for (status, body) in [(302, "[]"), (404, "[]"), (200, #"{"detail":"Not Found"}"#)] {
            await #expect(throws: (any Error).self) {
                _ = try await SpoolmanImport.fetchAll(base, engine: engine) { request in
                    (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!)
                }
            }
        }
    }

    @Test("into a real shelf on disk, and a second import adds nothing")
    func intoARealFile() async throws {
        let engine = try await Self.engine()
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "spoolman-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "khayt-store.json")
        try JSONEncoder().encode(JSONValue.object(["inventory": .array([
            .object(["id": .string("INV-OLD"), "material": .string("PLA"), "weight": .number(300), "rev": .number(6)]),
        ])])).write(to: url)
        let spools = [Self.spool(1), Self.spool(2), Self.spool(3, archived: true)]
        var plans: [KhaytEngine.SpoolmanPlan] = []
        for _ in 1...2 {
            try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
                plans.append(try await Shop.addFromSpoolman(into: &root, spools: spools, engine: engine, today: "2026-09-23"))
            }
        }
        #expect(plans[0].add.count == 2)
        #expect(plans[0].skipped.archived == 1)
        #expect(plans[1].add.isEmpty, "a second import brought the same spools across again")
        #expect(plans[1].skipped.already == 2)
        let written = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
        guard case .array(let shelf)? = written["inventory"], shelf.count == 3,
              case .object(let old) = shelf[0], case .object(let new) = shelf[1] else {
            Issue.record("the shelf is not the old spool plus two"); return
        }
        #expect(old["rev"] == .number(6), "a spool nobody touched was re-stamped")
        #expect(new["material"] == .string("Sunlu PETG"))
        #expect(new["weight"] == .number(600))
        #expect(new["spoolmanId"] == .number(1))
        #expect(new["rev"] == .number(1))
    }

    @Test("the import is reachable from the shelf")
    func wired() {
        #expect(MenuCoverageTests.source("ScreenActions.swift").contains("shop.importingSpoolman = true"))
        #expect(MenuCoverageTests.source("ShopWindow.swift").contains(".sheet(isPresented: $shop.importingSpoolman) { SpoolmanSheet("))
        #expect(MenuCoverageTests.source("SpoolmanSheet.swift").contains("try await shop.importFromSpoolman(typed)"))
    }
}
