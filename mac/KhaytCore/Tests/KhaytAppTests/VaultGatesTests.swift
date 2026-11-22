import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Sharing or selling vault files moves them off this Mac, so with the staff
/// lock on every such action asks it (`cloud`/`edit`), not just `canWrite` —
/// which is this Mac's writer lock, not who is at it (beta.6 review).
struct VaultGatesTests {
    static func source(_ file: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../Sources/KhaytApp/\(file)").standardizedFileURL, encoding: .utf8)
    }

    @Test("every action that shares, sells or delivers a vault file asks the lock")
    func gated() throws {
        let gate = #"guard shop.permitted("cloud", "edit")"#
        let sheets: [(String, [String])] = [
            ("VaultShareSheet.swift", ["private func create() async {"]),
            ("VaultLinksSheet.swift", ["private func run(", "private func copy() async {"]),
            ("VaultProductsSheet.swift", ["private func remove(_ p: VaultProducts.Product)", "private func disconnect()",
                                          "private func addPreview()", "private func clearPreviews()",
                                          "private func release()", "private func add()", "private func revoke(_ b:",
                                          "private func remove(_ p: String)"]),
        ]
        for (file, funcs) in sheets {
            let src = try Self.source(file)
            for f in funcs {
                let at = try #require(src.range(of: f), "\(file): \(f)")
                let next = src[at.upperBound...].prefix(400)
                #expect(next.contains(gate), "\(file): \(f) does not ask the lock")
            }
        }
        #expect(try Self.source("VaultProductsSheet.swift").components(separatedBy: "private func save() async {\n        " + gate).count == 3)
        let links = try Self.source("Shop+VaultLinks.swift")
        #expect(links.components(separatedBy: #"permitted("cloud", "edit")"#).count == 4)
        #expect(try Self.source("Shop+VaultProducts.swift").contains(#"canWrite, permitted("cloud", "edit")"#))
    }

    @Test("a release goes ahead only on exactly the files and versions shown")
    func releaseMatches() {
        #expect(Shop.releaseMatches(shown: ["a": 3, "b": 1], now: ["a": 3, "b": 1]))
        #expect(!Shop.releaseMatches(shown: ["a": 3], now: ["a": 4]), "a new version arrived")
        #expect(!Shop.releaseMatches(shown: ["a": 3], now: ["a": 3, "b": 1]), "a file shown missing came back")
        #expect(!Shop.releaseMatches(shown: [:], now: [:]))
    }

    static func model(_ id: String, licence: String = "", source: String = "", url: String = "") throws -> LibraryFile {
        var row: [String: JSONValue] = ["id": .string(id), "name": .string(id), "title": .string(id),
                                        "licence": .string(licence), "source": .string(source)]
        if !url.isEmpty { row["sourceUrl"] = .string(url) }
        return try JSONDecoder().decode(LibraryFile.self, from: JSONEncoder().encode(JSONValue.object(row)))
    }

    @Test("a release names the files that may not be the shop's to sell as files")
    func resaleDoubts() throws {
        let files = [
            try Self.model("own"), // nothing recorded and from nowhere: the shop's own
            try Self.model("mine", licence: "own", source: "https://printables.com/model/1"),
            try Self.model("by", licence: "cc-by"),
            try Self.model("nc", licence: "cc-by-nc"),
            try Self.model("sdfl", licence: "sdfl"),
            try Self.model("bought", licence: "commercial"),
            try Self.model("web", url: "https://makerworld.com/en/models/2"),
            try Self.model("site", source: "Thingiverse"),
        ]
        let records = Dictionary(uniqueKeysWithValues: files.map { ($0.id, "F-" + $0.id) })
        let doubts = Shop.resaleDoubts(files.map { "F-" + $0.id }, records: records, files: files)
        #expect(doubts == ["nc", "sdfl", "bought", "web", "site"])
        #expect(Shop.resaleDoubts(["F-unknown"], records: records, files: files).isEmpty)
    }
}

