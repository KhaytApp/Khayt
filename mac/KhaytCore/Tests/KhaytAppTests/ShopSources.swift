import Foundation

/// `Shop` is one class written across several files: `Shop.swift` holds the
/// class, its stored properties and `init`, and each `Shop+<Area>.swift` holds
/// one area's sections as an extension.
///
/// A test that reads "Shop.swift" as text means the CLASS, not the file. So
/// `read` answers a request for `Shop.swift` with every one of Shop's files,
/// `Shop.swift` first and the rest by name, joined by newlines — and any other
/// file exactly as `String(contentsOf:encoding:)` would. Without this, a guard
/// over the class goes vacuous the day a section moves to its own file: a
/// `contains` fails loudly, but a `!contains` passes over code it no longer
/// reads.
enum ShopSources {

    /// Whether a source file is part of `Shop`.
    static func isShop(_ name: String) -> Bool {
        name == "Shop.swift" || (name.hasPrefix("Shop+") && name.hasSuffix(".swift"))
    }

    /// Shop's files in `dir`: `Shop.swift` first, then the extensions by name.
    static func files(in dir: URL) throws -> [URL] {
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { isShop($0) && $0 != "Shop.swift" }.sorted()
        return [dir.appending(path: "Shop.swift")] + names.map { dir.appending(path: $0) }
    }

    /// The text at `url` — all of Shop when `url` names `Shop.swift`.
    static func read(_ url: URL) throws -> String {
        guard url.lastPathComponent == "Shop.swift" else {
            return try String(contentsOf: url, encoding: .utf8)
        }
        return try files(in: url.deletingLastPathComponent())
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }
}
