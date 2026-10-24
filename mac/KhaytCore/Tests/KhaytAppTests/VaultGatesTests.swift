import Foundation
import Testing
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
}
