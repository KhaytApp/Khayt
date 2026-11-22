import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// What the attention engine is given, and what it therefore never says.
///
/// THE DEFECT THIS EXISTS FOR: `attention` is pure and refuses to reach for a
/// global, so its nozzle category is gated on `inp.nozzleWear` being passed in.
/// This app did not pass it — so an overdue nozzle produced no warning at all.
/// Not an error, not an empty state: silence.
///
/// That module's own comment says the warning exists precisely because it
/// "existed on the machine card and NOWHERE on any dashboard, which is the one
/// screen a shop leaves open". This app had reproduced the exact bug the
/// comment was written about.
@MainActor
struct AttentionInputsTests {

    /// A machine whose nozzle is long past what the shop set for it.
    static let worn: JSONValue = .object([
        "id": .string("M-1"), "name": .string("Bench"),
        "nozzle": .object([
            "material": .string("stainless"),
            "installedAt": .string("2020-01-01"),
            "gramsThreshold": .number(100),
        ]),
    ])

    /// Enough completed work to blow past a 100 g threshold.
    static let orders: [JSONValue] = (0..<6).map { i in
        .object([
            "id": .string("O-\(i)"), "status": .string("completed"),
            "date": .string("2026-08-0\(i + 1)"), "machineId": .string("M-1"),
            "parts": .array([.object(["printWeight": .number(500), "qty": .number(1),
                                      "material": .string("PLA")])]),
        ])
    }

    @Test("an overdue nozzle reaches the dashboard")
    func nozzleWarningAppears() async throws {
        let facts = try await KhaytEngine().dashboardFacts(
            orders: Self.orders, machines: [Self.worn], settings: [:])
        let kinds = facts.attn.items.map(\.kind)
        #expect(kinds.contains("nozzle"), "the nozzle category was silent, as it had been all along")
    }

    @Test("a fresh nozzle says nothing")
    func freshNozzleIsQuiet() async throws {
        let fresh: JSONValue = .object([
            "id": .string("M-2"), "name": .string("New"),
            "nozzle": .object(["material": .string("stainless"),
                               "installedAt": .string("2026-09-01"),
                               "gramsThreshold": .number(50000)]),
        ])
        let facts = try await KhaytEngine().dashboardFacts(
            orders: Self.orders, machines: [fresh], settings: [:])
        #expect(!facts.attn.items.map(\.kind).contains("nozzle"))
    }

    @Test("a machine with no nozzle recorded is not warned about")
    func noNozzleNoWarning() async throws {
        let bare: JSONValue = .object(["id": .string("M-3"), "name": .string("Bare")])
        let facts = try await KhaytEngine().dashboardFacts(
            orders: Self.orders, machines: [bare], settings: [:])
        #expect(!facts.attn.items.map(\.kind).contains("nozzle"))
    }

    @Test("one bad poll is a hiccup; three is a machine somebody must walk to")
    func machineNeedsTheFailureCount() async throws {
        // `machineState` reads `consecutiveFailures` and says "reconnecting"
        // until it reaches three — and reconnecting is excluded from attention
        // BY DESIGN. Without the count, a printer unreachable all day stayed
        // reconnecting for ever and the dashboard never mentioned it.
        let machine: JSONValue = .object(["id": .string("M-1"), "name": .string("Bench"),
                                          "printerApi": .object(["type": .string("moonraker")])])
        func facts(_ failures: Int) async throws -> DashboardFacts {
            try await KhaytEngine().dashboardFacts(
                orders: [], machines: [machine], settings: [:],
                statusCache: ["M-1": .object([
                    "state": .string("offline"), "error": .string("no answer"),
                    "consecutiveFailures": .number(Double(failures)),
                ])])
        }
        #expect(!(try await facts(1)).attn.items.map(\.kind).contains("machine"))
        #expect((try await facts(3)).attn.items.map(\.kind).contains("machine"))
        // The fleet tile counts it either way: it reads `state` directly, and
        // "not answering" is a fact whether or not it is worth interrupting for.
        #expect((try await facts(1)).fleet.offline == 1)
    }

    @Test("the watch counts consecutive failures and stops at a good poll")
    func theWatchCounts() {
        let watch = PrinterWatch()
        watch.setReadingForTesting("M-1", .init(status: nil, problem: "no answer", at: Date(),
                                                consecutiveFailures: 3))
        guard case .object(let row)? = watch.statusCache["M-1"] else { Issue.record("no row"); return }
        #expect(row["consecutiveFailures"] == .number(3))
    }
}
