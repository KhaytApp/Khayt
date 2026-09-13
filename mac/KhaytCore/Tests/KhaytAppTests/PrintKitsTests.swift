import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Several printed jobs that are one physical object.
///
/// A figure printed as Head, Hand, Body and Legs on four evenings is four
/// print-log entries, and "what did that figure cost me" was arithmetic across
/// four rows that nobody does. The Electron app has grouped them since its
/// Orders Log learnt to; the Mac could not, because `lib/print-kits.js` was
/// never bundled.
///
/// ── WHAT IS ACTUALLY AT RISK HERE ─────────────────────────────────────────
///
/// Not the addition. The module's own header says what it exists to prevent:
/// summing `actualPrintTime` across entries where some are null yields a number
/// that LOOKS like the kit's total and silently omits whatever was never
/// measured. Every total therefore arrives with the count behind it, and a
/// screen that draws one without the other has reintroduced the bug at the last
/// step. Most of what is pinned below is that refusal surviving the crossing
/// into Swift — because a `Decodable` that quietly drops `measuredTime` would
/// compile, run, and take the guard with it.
@MainActor
struct PrintKitsTests {

    /// One print-log entry. `printWeight` lives on the PART and the measured
    /// figures live on the ORDER, which is the shape the whole feature turns
    /// on: no part in this codebase carries its own measurement, and that is
    /// why kits group across orders instead of merging them.
    static func job(_ id: String, kit: String? = nil, status: String = "completed",
                    estHours: Double? = nil, estGrams: Double? = nil,
                    actualHours: Double? = nil, actualGrams: Double? = nil,
                    cost: Double? = nil, currency: String? = nil,
                    project: String = "Part") -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "status": .string(status), "project": .string(project),
        ]
        if let kit { o["kitId"] = .string(kit) }
        if let estHours { o["printTime"] = .number(estHours) }
        if let estGrams {
            o["parts"] = .array([.object(["name": .string("p"), "printWeight": .number(estGrams)])])
        }
        if let actualHours { o["actualPrintTime"] = .number(actualHours) }
        if let actualGrams { o["actualWeight"] = .number(actualGrams) }
        if let cost { o["costBasis"] = .number(cost) }
        if let currency { o["currency"] = .string(currency) }
        return .object(o)
    }

    static func def(_ id: String, _ name: String) -> JSONValue {
        .object(["id": .string(id), "name": .string(name)])
    }

    /// A figure: four jobs, all counted, all measured.
    static let dragon: [JSONValue] = [
        job("O1", kit: "K1", estHours: 4, estGrams: 100, actualHours: 4.5, actualGrams: 104,
            cost: 20, currency: "SAR", project: "Dragon head"),
        job("O2", kit: "K1", estHours: 3, estGrams: 80, actualHours: 3.2, actualGrams: 82,
            cost: 16, currency: "SAR", project: "Dragon body"),
        job("O3", kit: "K1", estHours: 2, estGrams: 50, actualHours: 2.1, actualGrams: 51,
            cost: 10, currency: "SAR", project: "Dragon wing L"),
        job("O4", kit: "K1", estHours: 2, estGrams: 50, actualHours: 2.2, actualGrams: 53,
            cost: 10, currency: "SAR", project: "Dragon wing R"),
    ]

    // MARK: - The grouping

    @Test("four jobs become one object, and the totals are the object's")
    func groupsAndTotals() async throws {
        let engine = try KhaytEngine()
        let kits = try await engine.kits(orders: Self.dragon, defs: [Self.def("K1", "Dragon")])

        let kit = try #require(kits.first, "four jobs sharing a kitId produced no kit")
        #expect(kit.name == "Dragon")
        #expect(kit.rollup.jobs == 4)
        #expect(kit.jobIds == ["O1", "O2", "O3", "O4"], "the jobs lost their order within the kit")
        // 4.5 + 3.2 + 2.1 + 2.2
        #expect(abs(kit.rollup.actualHours - 12.0) < 0.005,
                Comment(rawValue: "hours came to \(kit.rollup.actualHours)"))
        // 104 + 82 + 51 + 53
        #expect(abs(kit.rollup.actualGrams - 290) < 0.005,
                Comment(rawValue: "grams came to \(kit.rollup.actualGrams)"))
        #expect(kit.rollup.cost == 56)
        #expect(kit.rollup.currency == "SAR")
        #expect(kit.complete, "every job is counted and measured; the kit is not finished")
    }

    @Test("a job in no kit is not in a kit")
    func ungroupedStaysOut() async throws {
        let engine = try KhaytEngine()
        let kits = try await engine.kits(
            orders: Self.dragon + [Self.job("O9", estHours: 1, actualHours: 1)],
            defs: [Self.def("K1", "Dragon")])
        #expect(kits.count == 1)
        #expect(!(kits.first?.jobIds.contains("O9") ?? true), "a loose job was swept into a kit")
    }

    @Test("a cancelled job's figures are not the kit's")
    func cancelledIsNotCounted() async throws {
        // "Statuses whose numbers are real." A print that was abandoned cost
        // the shop something, and it did not go into THIS object.
        let engine = try KhaytEngine()
        let withFailure = Self.dragon + [
            Self.job("O5", kit: "K1", status: "cancelled",
                     estHours: 9, estGrams: 900, actualHours: 9, actualGrams: 900),
        ]
        let kit = try #require(try await engine.kits(orders: withFailure,
                                                     defs: [Self.def("K1", "Dragon")]).first)
        #expect(kit.rollup.jobs == 4, "a cancelled job was counted into the kit")
        #expect(abs(kit.rollup.actualGrams - 290) < 0.005,
                "a cancelled job's 900 g reached the kit's total")
    }

    // MARK: - The count behind every total

    @Test("an unmeasured job is reported, not quietly left out of the total")
    func measuredCountsSurviveTheCrossing() async throws {
        // THE BUG THE WHOLE MODULE EXISTS TO PREVENT, and the one a Swift
        // struct could silently undo: drop `measuredTime` from the `Decodable`
        // and everything still compiles, the total still looks like the kit's,
        // and the shop is told a four-part figure took the hours of three.
        let engine = try KhaytEngine()
        var jobs = Self.dragon
        jobs[3] = Self.job("O4", kit: "K1", estHours: 2, estGrams: 50,
                           cost: 10, currency: "SAR")   // printed, never measured
        let kit = try #require(try await engine.kits(orders: jobs,
                                                     defs: [Self.def("K1", "Dragon")]).first)

        #expect(kit.rollup.jobs == 4, "the unmeasured job left the kit entirely")
        #expect(kit.rollup.measuredTime == 3,
                Comment(rawValue: "measuredTime is \(kit.rollup.measuredTime), so the count is gone"))
        #expect(kit.rollup.measuredWeight == 3)
        #expect(!kit.complete, "a kit with an unmeasured job reported itself finished")
        // And absent stayed absent: 9.8 is the three that WERE measured, not
        // four with a zero in it.
        #expect(abs(kit.rollup.actualHours - 9.8) < 0.005,
                Comment(rawValue: "hours came to \(kit.rollup.actualHours) — a missing figure became a zero"))
    }

    @Test("a kit that was not fully measured has no kit-level accuracy")
    func accuracyRefusesAPartialKit() async throws {
        // "A kit where three of four are measured has a real per-job story but
        // no kit-level delta — the estimate covers four jobs and the actual
        // covers three, and dividing one by the other invents a number."
        let engine = try KhaytEngine()
        var jobs = Self.dragon
        jobs[3] = Self.job("O4", kit: "K1", estHours: 2, estGrams: 50)
        let partial = try #require(try await engine.kits(orders: jobs,
                                                         defs: [Self.def("K1", "Dragon")]).first)
        #expect(partial.accuracy?.time == nil,
                "a percentage was invented from an estimate of four and an actual of three")

        let whole = try #require(try await engine.kits(orders: Self.dragon,
                                                       defs: [Self.def("K1", "Dragon")]).first)
        // 12.0 actual against 11.0 estimated is +9.1%.
        let off = try #require(whole.accuracy?.time, "a fully measured kit reported no delta")
        #expect(abs(off - 9.1) < 0.05, Comment(rawValue: "delta came out \(off)%"))
    }

    @Test("two currencies in a kit refuse to add rather than add wrongly")
    func mixedCurrencyRefuses() async throws {
        // "12 SAR + 3 EUR = 15 of nothing."
        let engine = try KhaytEngine()
        var jobs = Self.dragon
        jobs[1] = Self.job("O2", kit: "K1", estHours: 3, estGrams: 80,
                           actualHours: 3.2, actualGrams: 82, cost: 16, currency: "EUR")
        let kit = try #require(try await engine.kits(orders: jobs,
                                                     defs: [Self.def("K1", "Dragon")]).first)
        #expect(kit.rollup.mixedCurrency)
        #expect(kit.rollup.cost == nil, "two currencies were added together")
        // The hours and grams are still real — only money has a currency.
        #expect(abs(kit.rollup.actualHours - 12.0) < 0.005)
    }

    // MARK: - A kit whose name was deleted

    @Test("a deleted name does not take the shop's history off the screen")
    func orphanKeepsItsJobs() async throws {
        // `groupByKit` keeps an orphan on purpose, and names it from its own
        // work rather than showing a raw id, "which reads as corruption to
        // anyone looking at it".
        let engine = try KhaytEngine()
        let kit = try #require(try await engine.kits(orders: Self.dragon, defs: []).first,
                               "a kit with no definition vanished, and its four jobs with it")
        #expect(kit.orphaned)
        #expect(kit.id == "K1")
        #expect(kit.name == "Dragon head", "the orphan is showing a raw id")
        #expect(kit.rollup.jobs == 4, "the orphan lost its jobs")
    }

    // MARK: - Naming one

    @Test("a name a kit already has IS that kit")
    func exactNameReuses() async throws {
        // The whole point: you print three parts, file them as "Dragon", print
        // the fourth next week, and reproducing the string from memory must not
        // cost you a second kit with the rollup split between them.
        let engine = try KhaytEngine()
        let defs = [Self.def("K1", "Dragon")]
        for typed in ["Dragon", "dragon", "  DRAGON  ", "Dragon"] {
            let out = try #require(try await engine.resolveKitName(typed, known: defs, newId: "KIT-new"))
            #expect(!out.created, Comment(rawValue: "\"\(typed)\" minted a second kit"))
            #expect(out.id == "K1", Comment(rawValue: "\"\(typed)\" resolved to \(out.id)"))
            #expect(out.name == "Dragon", "the existing kit's spelling was not adopted")
        }
    }

    @Test("a genuinely new name makes a kit, with the id the host minted")
    func newNameMints() async throws {
        // The id comes from Swift. Nothing in `lib/` may invent one, for the
        // same reason nothing in there reads a clock.
        let engine = try KhaytEngine()
        let out = try #require(try await engine.resolveKitName(
            "Falcon", known: [Self.def("K1", "Dragon")], newId: "KIT-falcon-abc123"))
        #expect(out.created)
        #expect(out.id == "KIT-falcon-abc123", Comment(rawValue: "id came back as \(out.id)"))
        #expect(out.name == "Falcon")
    }

    @Test("an empty name is not a kit")
    func emptyNameIsNothing() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.resolveKitName("   ", known: [], newId: "KIT-x") == nil)
    }

    @Test("a near miss is offered, and an exact match is not a near miss")
    func nearMisses() async throws {
        let engine = try KhaytEngine()
        let defs = [Self.def("K1", "Dragon"), Self.def("K2", "Falcon")]

        let near = try await engine.similarKitNames("Dragn", known: defs)
        #expect(near.first?.id == "K1", "a one-character slip was not offered")

        // An exact match is a MATCH, handled by resolveKitName, and offering it
        // here would ask the shop a question that has already been answered.
        #expect(try await engine.similarKitNames("Dragon", known: defs).isEmpty,
                "an exact name was offered as a near miss")
        #expect(try await engine.similarKitNames("Sword", known: defs).isEmpty,
                "an unrelated name was offered as a near miss")
    }

    @Test("two short names one edit apart are NOT merged on a guess")
    func shortNamesGetATighterBudget() async throws {
        // "Leg L" and "Leg R" are one edit apart and genuinely different. The
        // rule never decides — it only ever asks — but at three characters two
        // edits is a different word, so the budget tightens rather than
        // offering nonsense.
        let engine = try KhaytEngine()
        let near = try await engine.similarKitNames("Arm", known: [Self.def("K1", "Leg")])
        #expect(near.isEmpty, "\"Arm\" was offered \"Leg\" as a possible typo")
    }

    @Test("a name attached to nothing is reported")
    func emptyDefinitions() async throws {
        let engine = try KhaytEngine()
        let dead = try await engine.emptyKitIds(
            orders: Self.dragon, defs: [Self.def("K1", "Dragon"), Self.def("K2", "Falcon")])
        #expect(dead == ["K2"], Comment(rawValue: "reported \(dead)"))
    }

    // MARK: - What the Mac itself decides

    @Test("filing a job writes the id; unfiling REMOVES the key")
    func unfilingRemovesTheKey() {
        // Not set to an empty string. `groupByKit` reads the field with a trim
        // and treats blank as ungrouped, so "" would work — right up until the
        // record syncs to a machine running a build that checks the key's
        // presence instead. A field that is absent on one side and empty on the
        // other is the shape of a bug nobody can reproduce.
        var root: [String: JSONValue] = ["printLog": .array(Self.dragon)]

        Shop.stampKit(&root, ids: ["O1"], to: nil)
        guard case .array(let rows)? = root["printLog"], case .object(let o1) = rows[0] else {
            Issue.record("the print log is no longer a list of jobs"); return
        }
        #expect(o1["kitId"] == nil, "unfiling left an empty kitId behind")
        #expect(o1["id"] == JSONValue.string("O1"), "unfiling changed something else")

        // And the jobs nobody named are untouched.
        guard case .object(let o2) = rows[1] else { Issue.record("row 2"); return }
        #expect(o2["kitId"] == JSONValue.string("K1"), "unfiling one job took another with it")
    }

    @Test("filing stamps a revision, and only on what changed")
    func stampingIsMinimal() {
        // A row stamped without changing pushes to the cloud as an edit nobody
        // made, and on a shop with two machines that is how the older build
        // wins with a stale copy.
        var root: [String: JSONValue] = ["printLog": .array(Self.dragon)]
        Shop.stampKit(&root, ids: ["O1"], to: "K1")      // already K1 — a no-op
        guard case .array(let rows)? = root["printLog"], case .object(let o1) = rows[0] else {
            Issue.record("the print log is no longer a list of jobs"); return
        }
        #expect(o1["rev"] == nil && o1["updatedAt"] == nil,
                "a job already in that kit was stamped as edited anyway")

        Shop.stampKit(&root, ids: ["O1"], to: "K2")      // a real move
        guard case .array(let moved)? = root["printLog"], case .object(let now) = moved[0] else {
            Issue.record("the print log is no longer a list of jobs"); return
        }
        #expect(now["kitId"] == JSONValue.string("K2"))
        #expect(now["updatedAt"] != nil, "a real move was not stamped, so it will not sync")
    }
}

/// That the rule above is actually REACHED.
///
/// ── THE BUG THIS SUITE'S SIBLING CANNOT SEE ───────────────────────────────
///
/// Every test above passes against a correct module with no caller. This
/// project's recurring failure is exactly that: a lifted rule, fully tested,
/// wired to nothing, so the app goes on answering the old way — or in this
/// case, not answering at all. `PrintKitsTests` would be perfectly green on a
/// build where `Shop.load` never asks for the kits and no screen draws them.
///
/// So this reads the source. Delete any one of these calls and a test fails,
/// which is the only property that matters here.
@MainActor
struct PrintKitWiringTests {

    static func source(_ file: String) throws -> String {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        return try String(contentsOf: dir.appending(path: file), encoding: .utf8)
    }

    @Test("the book reads its kits when it loads")
    func loadAsksForThem() throws {
        let shop = try Self.source("Shop.swift")
        #expect(shop.contains("await readKits(root)"),
                "Shop.load never asks for the kits, so shop.kits is always empty")
        // AFTER the orders are read, because it groups them. Before, it would
        // group the previous book's jobs — or on first load, nothing.
        let ordersAt = try #require(shop.range(of: "orderRows = jobs")?.lowerBound,
                                    "the print log is no longer read into orderRows")
        let kitsAt = try #require(shop.range(of: "await readKits(root)")?.lowerBound)
        #expect(ordersAt < kitsAt, "the kits are grouped before the jobs they group are read")
    }

    @Test("the jobs screen draws the band and the inspector draws the section")
    func theScreensDrawThem() throws {
        #expect(try Self.source("ShopWindow.swift").contains("KitBand(shop: shop)"),
                "nothing puts the kit band on the jobs screen")
        #expect(try Self.source("OrderInspector.swift").contains("KitSection(shop: shop"),
                "the selected job never says which kit it is in")
    }

    @Test("every write a kit needs has a caller")
    func theWritesAreReachable() throws {
        let kits = try Self.source("Kits.swift")
        for (call, why) in [
            ("shop.fileJobs(", "nothing can file a job into a kit"),
            ("shop.unfileJobs(", "a job filed into the wrong kit cannot be taken out"),
            ("shop.renameKit(", "an orphaned kit can never be named again"),
            ("shop.disbandKit(", "a kit cannot be undone"),
            ("shop.nearKits(", "a name one edit from an existing kit is never questioned"),
        ] {
            #expect(kits.contains(call), Comment(rawValue: why))
        }
    }
}
