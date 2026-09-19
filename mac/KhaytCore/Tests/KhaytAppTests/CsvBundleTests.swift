import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The shop's own copy of everything, in a form a spreadsheet opens.
///
/// ── WHAT THIS SUITE IS GUARDING ───────────────────────────────────────────
///
/// `lib/csv-bundle.js` has laid these files out since 3.0 and only the Electron
/// window ever called it, so a shop working on the Mac could not take its own
/// book out as spreadsheets at all. The rule is unchanged; what is new is that
/// this app reaches it.
///
/// The assertion that matters most is the formula guard. A cell beginning `=`,
/// `+`, `-` or `@` is neutralised, because a spreadsheet opens a CSV and RUNS
/// what looks like a formula — a customer named `=HYPERLINK(...)` is an attack
/// on whoever opens the export. A Swift writer joining the same fields with
/// commas would have produced files that looked identical and lost exactly
/// that.
@MainActor
struct CsvBundleTests {

    static func book() -> [String: JSONValue] {
        [
            "clients": .array([
                .object(["id": .string("C1"), "nameEn": .string("Najd Architects"),
                         "phone": .string("+966 50 000 0000")]),
            ]),
            "inventory": .array([
                .object(["id": .string("sp-1"), "material": .string("PLA+"),
                         "weight": .number(860), "cost": .number(75)]),
            ]),
            "machines": .array([
                .object(["id": .string("M1"), "name": .string("Bench")]),
            ]),
            // Empty on purpose: the rule leaves an empty collection out, and a
            // file with a header and no rows is a file a shop has to open to
            // find out it is empty.
            "expenses": .array([]),
        ]
    }

    static func file(_ files: [KhaytEngine.CsvFile], _ name: String) -> String? {
        files.first { $0.name == name }?.content
    }

    @Test("one file per collection that has anything in it, and none for the empty ones")
    func onlyWhatIsThere() async throws {
        let engine = try KhaytEngine()
        let files = try await engine.csvBundle(Self.book())
        let names = Set(files.map(\.name))
        #expect(names.contains("clients.csv"))
        #expect(names.contains("inventory.csv"))
        #expect(names.contains("machines.csv"))
        #expect(!names.contains("expenses.csv"),
                "an empty collection was written as a file with nothing in it")
        #expect(!names.contains("orders.csv"), "a collection the book does not have was written")
    }

    @Test("a cell that looks like a formula is neutralised")
    func formulaInjection() async throws {
        // The whole reason this is not a Swift string join. A shop opens the
        // export in Excel and Excel runs the cell.
        let engine = try KhaytEngine()
        let files = try await engine.csvBundle([
            "clients": .array([
                .object(["id": .string("C1"),
                         "nameEn": .string("=HYPERLINK(\"http://evil\",\"click\")")]),
            ]),
        ])
        let clients = try #require(Self.file(files, "clients.csv"))
        #expect(!clients.contains("\"=HYPERLINK"),
                "a formula reached the file unneutralised")
        #expect(clients.contains("'=HYPERLINK"), "the guard changed shape")
    }

    @Test("a quote inside a name does not end the cell")
    func quotingSurvives() async throws {
        let engine = try KhaytEngine()
        let files = try await engine.csvBundle([
            "clients": .array([
                .object(["id": .string("C1"), "nameEn": .string("The \"Big\" Shop")]),
            ]),
        ])
        let clients = try #require(Self.file(files, "clients.csv"))
        #expect(clients.contains("\"The \"\"Big\"\" Shop\""),
                "an embedded quote was not doubled, so the row splits into three")
    }

    @Test("an empty book produces no files at all, rather than eight empty ones")
    func nothingToExport() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.csvBundle([:]).isEmpty)
        #expect(try await engine.csvBundle(["clients": .array([])]).isEmpty)
    }

    // MARK: - The wiring

    @Test("the module is bundled, or the binding reaches nothing")
    func moduleIsBundled() throws {
        let text = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytCore/KhaytEngine.swift"), encoding: .utf8)
        #expect(text.contains("\"csv-bundle\","),
                "the binding exists but the module is not on the bundled list")
    }

    @Test("the export is offered, reads the book from disk, and writes every file")
    func offeredAndWired() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let menus = try String(contentsOf: sources.appending(path: "Menus.swift"), encoding: .utf8)
        #expect(menus.contains("shop.exportEverythingAsCsv()"), "the export is on no menu")

        let shop = try String(contentsOf: sources.appending(path: "Shop.swift"), encoding: .utf8)
        guard let from = shop.range(of: "func exportEverythingAsCsv("),
              let to = shop.range(of: "\n    /// The accounting packages",
                                  range: from.upperBound..<shop.endIndex) else {
            Issue.record("exportEverythingAsCsv has moved — this check has rotted"); return
        }
        let body = shop[from.lowerBound..<to.lowerBound]
        // FROM DISK. The screens decode two collections out of thirty-three,
        // and a bundle built from those is a bundle missing thirty-one.
        #expect(body.contains("Data(contentsOf: build.storeURL)"),
                "the export is built from what the screens happen to have decoded")
        #expect(body.contains("for file in files"), "only one of the files is written")
        #expect(body.contains("set.csv_export_empty"),
                "a book with nothing in it is not told why no files appeared")
    }
}
