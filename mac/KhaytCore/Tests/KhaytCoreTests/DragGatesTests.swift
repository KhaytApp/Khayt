import Foundation
import Testing
@testable import KhaytCore

/// Every column's answer, asked once, for the card in the air.
///
/// `statusGate` — one order, one status — had existed since the board was
/// written, documented as "what greys out a drop target before anything is
/// dragged onto it". Nothing called it. So the board lit every column the same
/// while a job was dragged over it and refused the move AFTER the drop, as an
/// error: a shop learnt where a job could go by trying, and the picture in
/// front of it gave no help.
///
/// `statusGates` is the same rule asked for all seven columns in one crossing.
/// The batching is the part worth testing — a per-column answer that disagrees
/// with the single-column one would grey out the wrong columns, which is worse
/// than greying out none.
@Suite struct DragGatesTests {

    static let columns = ["quote", "pending", "on_hold", "printing",
                          "post", "qc", "completed", "delivered", "cancelled"]

    static func job(_ id: String, _ status: String) -> JSONValue {
        .object(["id": .string(id), "status": .string(status),
                 "project": .string("Bracket"), "price": .number(100)])
    }

    /// A shop that has said "no more than one job printing at a time", and
    /// means it.
    static var hardLimit: [String: JSONValue] {
        ["wipLimits": .object(["printing": .number(1)]),
         "wipEnforceHardLimit": .bool(true)]
    }

    @Test("a full column refuses the card, and says which column and what limit")
    func aFullColumnRefuses() async throws {
        let engine = try KhaytEngine()
        let book = [Self.job("a", "printing"), Self.job("b", "pending")]
        let gates = try await engine.statusGates(order: Self.job("b", "pending"),
                                                 to: Self.columns, orders: book,
                                                 settings: Self.hardLimit)
        let printing = try #require(gates["printing"])
        #expect(printing.ok == false, "the column is full and took the job anyway")
        #expect(printing.block?.code == "wip_blocked")
        // The sentence a shop reads is built from these, so a refusal that
        // cannot name the column is a refusal that cannot be explained.
        #expect(printing.block?.params["col"] == JSONValue.string("printing"))
        #expect(printing.block?.params["n"] == JSONValue.number(1))
    }

    @Test("the columns that are not full still take it")
    func theOthersAreOpen() async throws {
        let engine = try KhaytEngine()
        let book = [Self.job("a", "printing"), Self.job("b", "pending")]
        let gates = try await engine.statusGates(order: Self.job("b", "pending"),
                                                 to: Self.columns, orders: book,
                                                 settings: Self.hardLimit)
        // The whole point of asking every column: a board where one is barred
        // and six are open must not read as a board where nothing may move.
        for open in ["post", "qc", "completed", "delivered", "cancelled"] {
            #expect(gates[open]?.ok == true, "\(open) refused a job for no reason")
        }
    }

    /// Every column gets an entry, including the ones that refuse. A missing
    /// key and a blocked column look identical to the board, and only one of
    /// them means "do not drop here".
    @Test("no column is left without an answer")
    func everyColumnAnswers() async throws {
        let engine = try KhaytEngine()
        let gates = try await engine.statusGates(order: Self.job("b", "pending"),
                                                 to: Self.columns,
                                                 orders: [Self.job("b", "pending")],
                                                 settings: Self.hardLimit)
        #expect(gates.count == Self.columns.count)
        for column in Self.columns { #expect(gates[column] != nil, "\(column) has no answer") }
    }

    /// The batched call and the single one are the same rule, or the board is
    /// showing a second opinion.
    @Test("asking seven at once is asking one, seven times")
    func batchedMatchesSingle() async throws {
        let engine = try KhaytEngine()
        let book = [Self.job("a", "printing"), Self.job("b", "pending")]
        let subject = Self.job("b", "pending")
        let batched = try await engine.statusGates(order: subject, to: Self.columns,
                                                   orders: book, settings: Self.hardLimit)
        for column in Self.columns {
            let one = try await engine.statusGate(order: subject, to: column,
                                                  orders: book, settings: Self.hardLimit)
            #expect(batched[column] == one, "\(column) answered differently in a batch")
        }
    }

    /// A shop with no limits set has nothing barred, which is the common case
    /// and the one a regression here would break loudest.
    @Test("a shop that set no limits has every column open")
    func noLimitsBarsNothing() async throws {
        let engine = try KhaytEngine()
        let gates = try await engine.statusGates(order: Self.job("b", "pending"),
                                                 to: Self.columns,
                                                 orders: [Self.job("a", "printing"), Self.job("b", "pending")],
                                                 settings: [:])
        for column in Self.columns where column != "quote" {
            #expect(gates[column]?.block == nil, "\(column) was barred with no limit set")
        }
    }
}
