import Foundation
import Testing
@testable import KhaytCore

/// A module may only leave the bundle when nothing left in it reads the module.
///
/// ── THE MISTAKE THIS EXISTS FOR ───────────────────────────────────────────
///
/// Porting a rule to Swift and taking its JavaScript out of the bundle is two
/// steps, and the second one has a trap: another BUNDLED module may read the
/// global at run time. `lib/portal-refresh.js` reads `KhaytCurrencies` through
/// `sibling()`, so un-bundling the currency table left the portal printing
/// "EUR" where the invoice prints "€" — silently, and only for shops not
/// pricing in riyals.
///
/// An existing test caught it by accident. This catches it on purpose, for
/// every module, before the next one is removed.
///
/// A ported module therefore stays bundled until its last JavaScript reader is
/// ported too. That is not a failure of the port; it is the order the port has
/// to happen in.
@MainActor
struct UnbundlingIsSafeTests {

    /// Reads that are deliberately left dangling, with the reason.
    ///
    /// A module can be bundled for one of its jobs and not another. The Mac
    /// reads zips and meshes in SWIFT — `Zip.swift`, `Mesh.swift` — so the
    /// JavaScript paths that would have done it are never taken here, and
    /// bundling a second zip reader to satisfy a branch nothing calls would
    /// add weight to the app to make a test quieter.
    static let allowed: [String: Set<String>] = [
        "mf-convert": ["KhaytZip", "KhaytZipWrite"],
        "mf-mesh": ["KhaytZip"],
        "thumbnail-extract": ["KhaytZip"],
    ]

    @Test("every global a bundled module reads is itself bundled")
    func noDanglingGlobals() throws {
        let lib = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/Tests/KhaytCoreTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // …/KhaytCore
            .deletingLastPathComponent()   // …/mac
            .deletingLastPathComponent()   // the repository root
            .appending(path: "lib")

        // What each module DEFINES, read from the file rather than guessed
        // from its name — `feature-tiers.js` defines `KhaytTiers`, and a
        // derived name would miss it.
        //
        // SEVERAL modules may define one global: `stl-parse` and `stl-estimate`
        // both write `KhaytStl`, the second with `Object.assign(global.KhaytStl
        // || {}, api)` so the two halves merge. A module that assigns a global
        // is not depending on it, and the first version of this test read that
        // merge as a dangling reference.
        var definers: [String: Set<String>] = [:]
        let files = try FileManager.default.contentsOfDirectory(at: lib, includingPropertiesForKeys: nil)
        var source: [String: String] = [:]
        for url in files where url.pathExtension == "js" {
            let module = url.deletingPathExtension().lastPathComponent
            let text = try String(contentsOf: url, encoding: .utf8)
            source[module] = text
            for line in text.split(separator: "\n") where line.contains("Khayt") {
                guard let range = line.range(of: #"global(?:This)?\.(Khayt\w+)\s*="#,
                                             options: .regularExpression) else { continue }
                guard let name = line[range].split(separator: ".").last?
                    .split(whereSeparator: { $0 == " " || $0 == "=" }).first else { continue }
                definers[String(name), default: []].insert(module)
            }
        }
        #expect(definers.count > 150,
                Comment(rawValue: "found only \(definers.count) globals — the scan has rotted"))

        let bundled = Set(KhaytEngine.modules)
        #expect(bundled.count > 100)

        var dangling: [String] = []
        for module in bundled {
            guard let text = source[module] else { continue }
            for (global, owners) in definers {
                guard !owners.contains(module) else { continue }   // it defines it
                guard text.contains(global) else { continue }
                guard owners.isDisjoint(with: bundled) else { continue }  // somebody supplies it
                if Self.allowed[module]?.contains(global) == true { continue }
                dangling.append("\(module).js reads \(global), defined only by "
                                + "\(owners.sorted().joined(separator: "/")), which is not bundled")
            }
        }
        #expect(dangling.isEmpty, Comment(rawValue:
            "a bundled module reads a global nothing defines at run time — the read "
            + "returns undefined and the failure is silent:\n  "
            + dangling.sorted().joined(separator: "\n  ")))
    }
}
