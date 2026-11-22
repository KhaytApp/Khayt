import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A phone's changes reaching a shop's book on disk.
///
/// `LanServerTests` proves the ROUTE — the PIN, the refusals, the shape. This
/// proves the part that touches a real file: the fold composed with the writer,
/// which is what `Shop.foldFromPhone` does when the app switches the capability
/// on.
@MainActor
struct FoldFromPhoneTests {

    /// A book on disk, as a shop has one.
    private func storeOnDisk(_ store: [String: JSONValue]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "fold-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "khayt-store.json")
        try JSONEncoder().encode(JSONValue.object(store)).write(to: url)
        return url
    }

    private func read(_ url: URL) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
    }

    private func orders(_ store: [String: JSONValue]) -> [String: [String: JSONValue]] {
        guard case .array(let rows)? = store["printLog"] else { return [:] }
        var byId: [String: [String: JSONValue]] = [:]
        for row in rows {
            guard case .object(let o) = row, case .string(let id)? = o["id"] else { continue }
            byId[id] = o
        }
        return byId
    }

    @Test("a phone's edit reaches the book, and a stale one loses to the desk")
    func foldsIntoTheBook() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)

        let url = try storeOnDisk([
            "printLog": .array([
                // Advanced at the desk after the phone last pulled.
                .object(["id": .string("O-1"), "status": .string("completed"), "rev": .number(9)]),
                .object(["id": .string("O-2"), "status": .string("pending"), "rev": .number(1)]),
            ]),
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // What the phone sends: one genuine edit, and one stale record it was
        // holding from before the desk touched it.
        let payload: [String: JSONValue] = [
            "deltas": .array([
                .object(["collection": .string("printLog"),
                         "record": .object(["id": .string("O-2"), "status": .string("printing"),
                                            "rev": .number(2)])]),
                .object(["collection": .string("printLog"),
                         "record": .object(["id": .string("O-1"), "status": .string("qc"),
                                            "rev": .number(2)])]),
            ]),
            "tombstones": .array([]),
            "cursor": .null,
        ]

        // Exactly what `Shop.foldFromPhone` composes: the fold, inside the write.
        var folded: KhaytEngine.Folded?
        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            let result = try await engine.foldDeltas(base: root, deltas: [payload])
            root = result.store
            folded = result
        }

        let report = try #require(folded)
        #expect(report.applied == 1)
        #expect(report.skipped == 1, "the stale record should have lost to the desk's newer one")

        let after = orders(try read(url))
        #expect(after["O-2"]?["status"] == .string("printing"), "the phone's real edit did not land")
        #expect(after["O-1"]?["status"] == .string("completed"),
                "a stale phone overwrote a job the desk had already finished")
        #expect(after["O-1"]?["rev"] == .number(9))
    }

    @Test("the book survives the write the way every other write leaves it")
    func leavesARollback() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)

        let url = try storeOnDisk(["printLog": .array([
            .object(["id": .string("O-1"), "status": .string("pending"), "rev": .number(1)]),
        ])])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let payload: [String: JSONValue] = [
            "deltas": .array([.object(["collection": .string("printLog"),
                                       "record": .object(["id": .string("O-1"),
                                                          "status": .string("printing"),
                                                          "rev": .number(2)])])]),
            "tombstones": .array([]), "cursor": .null,
        ]
        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            root = try await engine.foldDeltas(base: root, deltas: [payload]).store
        }

        // `.prev` is the one generation of rollback a corrupt book is recovered
        // from, and a phone's write is no more exempt from it than a desk's.
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("prev").path))
    }

    @Test("the app actually switches the capability on")
    func theCapabilityIsWired() throws {
        // `Host.fold` is nil by default, on purpose. A fold handler that is
        // written, tested and never assigned is the shape of bug this repo
        // keeps finding: correct code with no caller.
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/LanServer.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(text.contains("host.fold = "),
                "nothing assigns host.fold, so the Mac answers 405 and a phone's edits never land")
        #expect(text.contains("func foldFromPhone"))
    }
}
