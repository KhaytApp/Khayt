import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// How long a 10,000-model book's per-model figures add to a load.
///
/// RELATIVE, so a slower machine slows both sides: the same book is loaded
/// twice, once with every model measured, summarised and licensed as on the
/// shop's real library and once with none of that, and the difference is
/// what the figures cost.
///
/// Measured on a debug build (Oct 14 2026, an M-series Mac with other work
/// running): one engine call per model made the full book's load take ~235 s
/// against ~6 s bare — a mesh estimate carried the whole 1 MB settings across
/// for each of 3,600 meshes. Batched, the full book loads in ~7 s.
///
/// The budget is four times the bare load plus twenty seconds. It was twice
/// plus ten, and a loaded CI runner went past it on an unrelated PR (28.0 s
/// against 21.4 s, run 39099662401, beside two other suites): the bare and
/// full loads run minutes apart, and the runner's load changes in between.
/// About 45 s still fails the old code fivefold.
///
/// In `LibraryEditPerfTests`, the one serialised suite that may set the test
/// support folder (a single global).
extension LibraryEditPerfTests {

    static func reloadSeconds(_ root: [String: JSONValue]) async throws -> Double {
        var took = 0.0
        try await withPerfBook(root) { shop, _ in
            let start = Date()
            await shop.load(shop.source)
            took = Date().timeIntervalSince(start)
            #expect(shop.files.count == 10_000)
        }
        return took
    }

    @Test("a 10,000-model library's figures add seconds to a load, not minutes")
    func figuresDoNotDominateALoad() async throws {
        let full = FiguresBook.synthesize(models: 10_000)
        var bare = full
        var rows = Shop.rows(full, "printFiles")
        for i in rows.indices {
            guard case .object(var record) = rows[i] else { continue }
            for key in ["geometryKey", "printRisk", "licence", "source"] { record.removeValue(forKey: key) }
            rows[i] = .object(record)
        }
        bare["printFiles"] = .array(rows)

        let bareSeconds = try await Self.reloadSeconds(bare)
        let fullSeconds = try await Self.reloadSeconds(full)
        let budget = bareSeconds * 4 + 20
        #expect(fullSeconds < budget,
                "the full book took \(fullSeconds) s against \(bareSeconds) s bare (budget \(budget) s)")
    }
}
