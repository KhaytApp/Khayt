import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// What the shop pays every month, which this app could read and not write.
///
/// The sharpest instance of the pattern: `BreakEven` has always told a shop
/// with no fixed costs to "add rent, subscriptions and anything else that is
/// paid every month **in Settings**" — a sentence written for the other app's
/// Settings and shipped in this one, so following it arrived nowhere.
///
/// And it is not only a missing target. `lib/pnl-report.js` puts a quarter's
/// share of these into the Profit & Loss, so a Mac-only shop's P&L was
/// computed as though the business had no overhead: a wrong figure rather than
/// an absent one.
@MainActor
struct FixedCostsSettingsTests {

    static func book(_ rows: [JSONValue]) -> [String: JSONValue] {
        ["settings": .object(["fixedCosts": .array(rows)])]
    }

    static func cost(_ id: String, _ name: String, _ amount: Double) -> JSONValue {
        .object(["id": .string(id), "name": .string(name), "amount": .number(amount)])
    }

    @Test("reading the book gives one line per cost, with its id")
    func readsTheBook() {
        let lines = FixedCostsSettings.read([
            "fixedCosts": .array([Self.cost("a", "Rent", 3000),
                                  Self.cost("b", "Electricity", 450)]),
        ])
        #expect(lines.map(\.name) == ["Rent", "Electricity"])
        #expect(lines.map(\.amount) == [3000, 450])
        // THE ID SURVIVES. Editing a row has to be editing it — the other app
        // keys its list on this, so a new id on every read would turn one
        // edited row into a deletion and an addition on the next sync.
        #expect(lines.map(\.id) == ["a", "b"])
    }

    @Test("an empty book is an empty list, not a crash or a phantom row")
    func readsNothing() {
        #expect(FixedCostsSettings.read([:]).isEmpty)
        #expect(FixedCostsSettings.read(["fixedCosts": .array([])]).isEmpty)
    }

    /// The half that did not exist.
    @Test("a saved cost actually reaches the book")
    func theSaveIsNotSwallowed() async throws {
        let engine = try KhaytEngine()
        var root: [String: JSONValue] = ["settings": .object([:])]
        try await Shop.applySettings(to: &root, form: [
            "fixedCosts": .array([Self.cost("a", "  Rent  ", 3000)]),
        ], country: nil, engine: engine)

        guard case .object(let settings)? = root["settings"],
              case .array(let rows)? = settings["fixedCosts"],
              case .object(let first)? = rows.first else {
            Issue.record("no fixedCosts were written at all"); return
        }
        #expect(rows.count == 1)
        #expect(first["name"] == .string("Rent"), "a typed name keeps its spaces")
        #expect(first["amount"] == .number(3000))
        #expect(first["id"] == .string("a"))
    }

    /// The one a merge would get wrong.
    @Test("removing every cost removes them from the book")
    func removalSticks() async throws {
        let engine = try KhaytEngine()
        var root = Self.book([Self.cost("a", "Rent", 3000)])
        try await Shop.applySettings(to: &root, form: ["fixedCosts": .array([])],
                                     country: nil, engine: engine)
        guard case .object(let settings)? = root["settings"],
              case .array(let rows)? = settings["fixedCosts"] else {
            Issue.record("fixedCosts disappeared entirely"); return
        }
        // A list a person edits is sent WHOLE. Merged into the stored one, a
        // row deleted on screen would come back on the next load, and the
        // shop would delete it again.
        #expect(rows.isEmpty, "a cost removed on screen stayed in the book")
    }

    @Test("a form with no costs in it leaves the stored ones alone")
    func absentFormChangesNothing() async throws {
        let engine = try KhaytEngine()
        var root = Self.book([Self.cost("a", "Rent", 3000)])
        // The difference between "the form does not carry these" and "the form
        // carries none" is the whole of the previous test — saving the shop's
        // NAME must not wipe its costs.
        try await Shop.applySettings(to: &root, form: ["bizEn": .string("Acme")],
                                     country: nil, engine: engine)
        guard case .object(let settings)? = root["settings"],
              case .array(let rows)? = settings["fixedCosts"] else {
            Issue.record("fixedCosts disappeared entirely"); return
        }
        #expect(rows.count == 1, "saving something else wiped the shop's costs")
    }

    @Test("a half-typed row is not stored, and a negative one is not a credit")
    func rubbishIsRefused() async throws {
        let engine = try KhaytEngine()
        var root: [String: JSONValue] = ["settings": .object([:])]
        try await Shop.applySettings(to: &root, form: [
            "fixedCosts": .array([
                .object(["name": .string(""), "amount": .number(0)]),   // started, abandoned
                .object(["name": .string("Power"), "amount": .string("450")]),
                .object(["name": .string("Odd"), "amount": .number(-99)]),
            ]),
        ], country: nil, engine: engine)
        guard case .object(let settings)? = root["settings"],
              case .array(let rows)? = settings["fixedCosts"] else {
            Issue.record("no fixedCosts"); return
        }
        #expect(rows.count == 2, "the empty row was stored: \(rows)")
        guard case .object(let power)? = rows.first else { Issue.record("no row"); return }
        #expect(power["amount"] == .number(450), "a figure typed as text was dropped")
        guard case .object(let odd)? = rows.last else { Issue.record("no row"); return }
        // A monthly cost below zero is money coming IN, which break-even would
        // read as a lower target — a shop could talk itself into profit.
        #expect(odd["amount"] == .number(0), "a negative cost was stored as one")
    }

    /// The screen exists and something opens it.
    @Test("the monthly costs are actually drawn on a settings page")
    func theScreenIsReachable() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/SettingsWindow.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.isEmpty, "SettingsWindow.swift was not read — this would pass vacuously")
        #expect(text.contains("FixedCostsSettings(shop: shop)"),
                "the monthly-costs screen exists and nothing opens it")
    }

    /// The sentence that sent shops here has to still be true.
    @Test("break-even still tells a shop where to add them")
    func theInstructionStillHolds() async throws {
        let words = Words()
        let engine = try KhaytEngine()
        await words.load("en", engine: engine)
        let said = words.callIt("an.be_none")
        #expect(said != "an.be_none", "the key is gone")
        // It says "in Settings", and now there is one. If this sentence is
        // ever reworded to name another app, that is the thing to catch.
        #expect(said.lowercased().contains("settings"),
                "break-even no longer says where to add them: \(said)")
        for elsewhere in ["windows", "linux", "the other app"] {
            #expect(!said.lowercased().contains(elsewhere),
                    "break-even sends the shop to another app: \(said)")
        }
    }
}
