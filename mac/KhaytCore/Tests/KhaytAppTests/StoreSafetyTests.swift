import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Findings from the September 2026 file-safety scan and bug hunt, pinned.
@MainActor
struct StoreSafetyTests {

    static func scratch(_ root: [String: JSONValue]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "khayt-store.json")
        try JSONEncoder().encode(root).write(to: url)
        return url
    }

    static func read(_ url: URL) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
    }

    /// The save moved the book to `.prev` and then moved the new file in: a
    /// crash between the two left no book at all.
    @Test("a save leaves the book in place and the old one as .prev")
    func atomicSwap() throws {
        let url = try Self.scratch(["n": .number(1)])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try StoreWriter.atomicWrite(try JSONEncoder().encode(["n": 2]), to: url)
        #expect(try Self.read(url)["n"] == .number(2))
        #expect(try Self.read(url.appendingPathExtension("prev"))["n"] == .number(1))
        // And a second save moves .prev along, not onto the same file.
        try StoreWriter.atomicWrite(try JSONEncoder().encode(["n": 3]), to: url)
        #expect(try Self.read(url)["n"] == .number(3))
        #expect(try Self.read(url.appendingPathExtension("prev"))["n"] == .number(2))
    }

    /// An async change suspended inside its mutation, another write landed,
    /// and the first wrote its stale copy over it.
    @Test("a write that lands while another is being worked out is not lost")
    func interleavedWrites() async throws {
        let url = try Self.scratch(["a": .number(0), "b": .number(0)])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var runs = 0
        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            runs += 1
            if runs == 1 {
                // While this change is "asking the engine", another write lands.
                try StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { other in
                    other["b"] = .number(2)
                }
                await Task.yield()
            }
            root["a"] = .number(1)
        }
        let book = try Self.read(url)
        #expect(book["a"] == .number(1), "the slow change was written")
        #expect(book["b"] == .number(2), "the change that landed in between was kept")
        #expect(runs == 2, "the slow change was worked out again on the new book")
    }
}
