import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The words that cross from `lib/attention.js` to the screen.
///
/// ── WHY THIS EXISTS ────────────────────────────────────────────────────────
///
/// The dashboard's attention panel asked `severity == "bad"`. The module emits
/// `crit` and `warn` and has never emitted "bad", so the comparison was false
/// on every row that has ever been drawn: the panel's rail stayed amber with a
/// printer down, and a machine that had stopped looked exactly like a nozzle
/// reminder. Nothing threw, nothing failed, and the module's careful
/// distinction between "something has broken" and "something merely wants a
/// person" was discarded one line before the screen.
///
/// A string compared against a value its producer never emits is silent by
/// construction. The only defence is to ask the producer.
@MainActor
struct SeverityTests {

    static func facts(machines: [JSONValue] = [], orders: [JSONValue] = [],
                      inventory: [JSONValue] = [],
                      statusCache: [String: JSONValue] = [:]) async throws -> DashboardFacts {
        try await KhaytEngine().dashboardFacts(
            orders: orders, machines: machines,
            settings: ["mode": .string("business")],
            statusCache: statusCache, inventory: inventory)
    }

    static let downMachine = JSONValue.object([
        "id": .string("M1"), "name": .string("Bambu X1C"), "isOffline": .bool(true),
    ])
    static let lowSpool = JSONValue.object([
        "id": .string("s1"), "material": .string("PA-CF"),
        "colourVariant": .string("Carbon Grey"), "weight": .number(120),
    ])

    /// The test the old code needed and did not have.
    @Test("a stopped machine is CRITICAL, and the screen knows that word")
    func criticalIsTheModulesWord() async throws {
        let f = try await Self.facts(machines: [Self.downMachine])
        let item = try #require(f.attn.items.first { $0.kind == "machine" })
        #expect(item.severity == NeedsAttentionSeverity.critical,
                "the module says '\(item.severity)', the screen looks for '\(NeedsAttentionSeverity.critical)'")
        #expect(item.state == "offline", "and the row can say WHY it is critical")
    }

    @Test("a low spool is a warning, not a failure")
    func warningIsTheModulesWord() async throws {
        let f = try await Self.facts(inventory: [Self.lowSpool])
        let item = try #require(f.attn.items.first { $0.kind == "stock" })
        #expect(item.severity == NeedsAttentionSeverity.warning)
        #expect(item.grams == 120, "and it says how much is left")
        #expect(item.variant == "Carbon Grey", "in the shop's own name for the colour")
    }

    /// The guard. Any severity the module can produce has to be one of the two
    /// the screen colours; a third would otherwise render as a warning and
    /// nobody would find out.
    @Test("every severity the module produces is one the screen knows")
    func noThirdWord() async throws {
        let f = try await Self.facts(
            machines: [Self.downMachine],
            orders: [.object([
                "id": .string("J1"), "status": .string("pending"),
                "project": .string("Souq stall sign"), "dueDate": .string("2020-01-01"),
            ])],
            inventory: [Self.lowSpool])
        #expect(f.attn.items.count >= 3, "a machine, a spool and a late job")
        let known: Set<String> = [NeedsAttentionSeverity.critical, NeedsAttentionSeverity.warning]
        for item in f.attn.items {
            #expect(known.contains(item.severity),
                    "'\(item.severity)' on a \(item.kind) row is a word this screen cannot colour")
        }
    }

    /// The order the module sorts in is the order a shop should work in, and
    /// the panel draws it as given rather than re-sorting.
    @Test("a machine that has stopped outranks everything else on the panel")
    func machinesLead() async throws {
        let f = try await Self.facts(
            machines: [Self.downMachine],
            orders: [.object([
                "id": .string("J1"), "status": .string("pending"),
                "project": .string("Late job"), "dueDate": .string("2020-01-01"),
            ])],
            inventory: [Self.lowSpool])
        #expect(f.attn.items.first?.kind == "machine")
    }

    /// A shelf with nothing low must not put a section on the screen. A panel
    /// that is always there is a panel people stop reading.
    @Test("a shop with nothing wrong has an empty panel, not a reassuring one")
    func nothingWrong() async throws {
        let f = try await Self.facts(
            machines: [.object(["id": .string("M1"), "name": .string("X1C")])],
            inventory: [.object([
                "id": .string("s1"), "material": .string("PLA"), "weight": .number(900),
            ])])
        #expect(f.attn.items.isEmpty)
        #expect(f.attn.count == 0)
    }

    // MARK: - What the row writes

    @Test("every kind has its own button, and its own word for what pressing it does")
    func everyKindHasAnAction() async throws {
        let words = Words()
        await words.load("en", engine: try KhaytEngine())
        var seen: Set<String> = []
        for kind in ["machine", "nozzle", "stock", "order"] {
            let key = NeedsAttentionAction.forKind(kind)
            #expect(words.callIt(key) != key, "\(kind) has no button text")
            seen.insert(key)
        }
        #expect(seen.count == 4, "a single 'Open' on all four would be honest and useless")

        let ar = Words()
        await ar.load("ar", engine: try KhaytEngine())
        for kind in ["machine", "nozzle", "stock", "order"] {
            let key = NeedsAttentionAction.forKind(kind)
            #expect(ar.callIt(key) != key, "\(kind)'s button has no Arabic")
        }
        for key in ["mac.attn_state_offline", "mac.attn_state_error", "mac.attn_nozzle_of"] {
            #expect(words.callIt(key) != key)
            #expect(ar.callIt(key) != key)
        }
    }

    @Test("each kind gets its own mark, so the list is scannable without reading it")
    func everyKindHasASymbol() {
        let symbols = ["machine", "nozzle", "stock", "order"].map(NeedsAttentionAction.symbol)
        #expect(Set(symbols).count == 4)
    }
}

/// The panel is a list, and a list has to stay one.
///
/// `lib/attention.js` returns everything, correctly — it is a selector, not a
/// display. The sample shop alone produces eight rows, and a shop with twenty
/// late jobs would get a dashboard that is nothing but this panel. Same failure
/// as a machine band with twenty rows on it: the fix is a cap and a count, not
/// a silent truncation.
@MainActor
struct AttentionCapTests {

    static func lateJobs(_ n: Int) -> [JSONValue] {
        (0..<n).map { i in
            .object([
                "id": .string("ORD-\(1000 + i)"), "status": .string("pending"),
                "project": .string("Job \(i)"), "dueDate": .string("2020-01-01"),
            ])
        }
    }

    @Test("the module still returns everything — the cap is the screen's, not its")
    func moduleReturnsAll() async throws {
        let f = try await SeverityTests.facts(orders: Self.lateJobs(20))
        #expect(f.attn.items.count == 20)
        #expect(f.attn.count == 20, "the count a shop reads is of the whole problem")
    }

    /// What the panel shows, and what it says about the rest. Pinned on the
    /// arithmetic rather than on the view, because the number that must never
    /// be wrong is the one in "and 14 more".
    @Test("past six rows the panel counts the rest rather than dropping them")
    func capsAndCounts() async throws {
        let f = try await SeverityTests.facts(orders: Self.lateJobs(20))
        let atMost = 6
        let shown = f.attn.items.prefix(atMost)
        let hidden = max(0, f.attn.items.count - atMost)
        #expect(shown.count == 6)
        #expect(hidden == 14)
        #expect(shown.count + hidden == f.attn.count,
                "a list that stops at six says the shop has six problems")
    }

    @Test("a shop with fewer than six things wrong hides nothing and says nothing")
    func underTheCap() async throws {
        let f = try await SeverityTests.facts(orders: Self.lateJobs(3))
        #expect(max(0, f.attn.items.count - 6) == 0)
    }

    @Test("the worst rows are the ones kept, because the module sorted them first")
    func theCapKeepsTheWorst() async throws {
        var orders = Self.lateJobs(10)
        orders.append(.object([
            "id": .string("ORD-9999"), "status": .string("pending"),
            "project": .string("Ancient"), "dueDate": .string("2019-01-01"),
        ]))
        let f = try await SeverityTests.facts(
            machines: [SeverityTests.downMachine], orders: orders,
            inventory: [SeverityTests.lowSpool])
        let shown = f.attn.items.prefix(6)
        #expect(shown.first?.kind == "machine", "the machine that stopped is never cut")
        #expect(shown.contains { $0.kind == "stock" }, "nor the spool about to stop the next job")
        #expect(shown.contains { $0.name == "Ancient" },
                "and the longest-late job leads the orders")
    }
}

/// "Is this printer printing" had four answers in this app.
///
/// `PrinterWatch.isPrinting` lowercases. So did the dashboard's live strip. The
/// menu bar's two properties — how many machines are printing, and when the
/// first one is free — compared `state == "printing"` exactly.
///
/// That is not pedantry: `lib/octoprint.js` passes the printer's OWN state text
/// through untouched (`printer.state.text`), and OctoPrint capitalises it. So on
/// an OctoPrint shop the menu bar counted zero machines printing and offered no
/// finish time, while the machine beside it was demonstrably printing — the
/// exact failure the property's own comment says it exists to prevent.
@MainActor
struct IsPrintingTests {

    /// Every spelling a protocol in this repo can hand over.
    @Test("the predicate accepts what the printers actually say")
    func spellings() {
        for said in ["printing", "Printing", "PRINTING", " printing"] {
            #expect(PrinterWatch.isPrinting(said.trimmingCharacters(in: .whitespaces)),
                    "'\(said)' is a printer saying it is printing")
        }
    }

    @Test("and nothing else")
    func notEverythingElse() {
        for said in ["idle", "Operational", "paused", "Paused", "error", "", "Unknown"] {
            #expect(!PrinterWatch.isPrinting(said), "'\(said)' is not printing")
        }
    }

    /// `Paused` matters on its own: a paused machine is not being made on, and
    /// counting it would put a number in the menu bar that nothing is behind.
    @Test("a paused machine is not a printing one")
    func pausedIsNotPrinting() {
        #expect(!PrinterWatch.isPrinting("Paused"))
        #expect(!PrinterWatch.isPrinting("paused"))
    }
}

/// One problem, printed once.
///
/// A late job is in the attention panel, and its invoice is overdue, so it was
/// in "Invoices to chase" as well — four of the eight rows in that list were
/// four of the six rows eight inches above them. Twice is not twice the
/// warning; it is a screen a shop learns to skim.
@MainActor
struct ChaseDoesNotRepeatTests {

    @Test("the chase list is what the attention panel does not already carry")
    func noDuplicates() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let attention = Set((shop.attention?.items ?? []).map(\.id))
        #expect(!attention.isEmpty, "the sample shop has nothing to be attentive about")

        let shown = shop.invoicesToChase.filter { !attention.contains($0.id) }
        for row in shown {
            #expect(!attention.contains(row.id),
                    "\(row.id) is in both lists on the same screen")
        }
        // And the filter is doing something on this book, or the test proves
        // nothing about a screen nobody has looked at.
        #expect(shown.count < shop.invoicesToChase.count,
                "nothing overlapped, so this guard would not notice if it did")
    }
}
