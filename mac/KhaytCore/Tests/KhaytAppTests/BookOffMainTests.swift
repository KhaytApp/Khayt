import Foundation
import Testing
@testable import KhaytApp

/// The whole book is decoded off the main thread on the paths that run often.
///
/// Auto-sync runs 2.5 s after every write and read the book on the main actor
/// three times a sync; every reload (each phone fold and cloud pull) decoded
/// every job there; the jobs table filtered and sorted every job twice per
/// draw. On a 15 MB, 5,000-job book each was a second or more of a frozen
/// window (Mac reliability review, Nov 2026).
@MainActor
struct BookOffMainTests {

    @Test("cloud sync reads the book through BookWork, never inline")
    func syncReadsOffMain() {
        let cloud = MenuCoverageTests.source("Shop+Cloud.swift")
        #expect(!cloud.contains("(try? Data(contentsOf: build.storeURL))\n                .flatMap"),
                "a sync path decodes the whole book on the main actor again")
        #expect(cloud.components(separatedBy: "await Shop.readBookOffMain(build.storeURL)").count - 1 >= 3)
    }

    @Test("the off-main read decodes the book, and an unreadable one is empty")
    func readsAndFails() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "bookoffmain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "store.json")
        try Data(#"{"printLog":[{"id":"J1"}],"settings":{}}"#.utf8).write(to: url)
        let book = await Shop.readBookOffMain(url)
        #expect(book["printLog"] != nil && book["settings"] != nil)
        #expect(await Shop.readBookOffMain(dir.appending(path: "missing.json")).isEmpty)
    }

    @Test("a reload decodes the jobs and their print history with the library, off the main thread")
    func reloadDecodesOffMain() {
        let shop = MenuCoverageTests.source("Shop.swift")
        #expect(shop.contains("orders: try? Self.decodeOrders(raw)"))
        #expect(shop.contains("let decoded = try preDecoded?.orders ?? Self.decodeOrders(root)"))
    }

    @Test("the jobs table sorts once per draw")
    func sortsOnce() {
        #expect(MenuCoverageTests.source("OrdersTable.swift").contains("let rows = self.rows"))
    }
}
