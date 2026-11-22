import Foundation
import JavaScriptCore
import Testing
@testable import KhaytCore

/// How far along an order is, against the JavaScript it came from.
///
/// The module exists because two copies of its list had drifted and a customer
/// who had already received their print saw a tracker saying the job had not
/// started. The fault it prevents is exactly the fault a port can reintroduce,
/// so this asks about every status either side knows — and the names that only
/// break one of them.
@MainActor
struct OrderProgressParityTests {

    @Test("every status agrees, including ones neither side has heard of")
    func statusesAgree() throws {
        let js = try JSModule(["order-progress"])
        var names = ["quote", "pending", "on_hold", "queued", "printing", "post",
                     "qc", "completed", "delivered", "split",
                     // Statuses the app knows elsewhere but this map may not.
                     "cancelled", "shipped", "void", "",
                     // Nonsense, and near-misses.
                     "Quote", "PENDING", " printing", "printing ", "unknown-status"]
        // ── THE NAMES THAT ONLY BREAK ONE LANGUAGE ────────────────────────
        //
        // The JavaScript guards its lookup with `hasOwnProperty` because a
        // status called `constructor` would otherwise find a function on the
        // prototype. A Swift dictionary has no prototype, so the guard is free
        // here — which is a claim worth checking rather than asserting.
        names += ["constructor", "toString", "hasOwnProperty", "__proto__", "valueOf"]
        for name in names {
            let mine = OrderProgress.index(of: name)
            let theirs = try js.int("globalThis.KhaytOrderProgress.progressIndex(ARG0)",
                                    [.string(name)])
            #expect(mine == theirs,
                    Comment(rawValue: "\(name.isEmpty ? "(empty)" : name): swift \(mine) vs js \(theirs.map(String.init) ?? "nil")"))
        }
    }

    @Test("null and a missing status agree too")
    func nullAgrees() throws {
        let js = try JSModule(["order-progress"])
        #expect(OrderProgress.index(of: nil)
                == (try js.int("globalThis.KhaytOrderProgress.progressIndex(null)")))
    }

    @Test("the steps are the same list, in the same order")
    func stepsAgree() throws {
        let js = try JSModule(["order-progress"])
        #expect(OrderProgress.steps == (try js.strings("globalThis.KhaytOrderProgress.STEPS")))
    }

    @Test("whether a step is reached agrees at every step")
    func reachedAgrees() throws {
        let js = try JSModule(["order-progress"])
        for name in ["quote", "pending", "printing", "post", "qc", "completed", "delivered", "nope"] {
            for step in -1...5 {
                let mine = OrderProgress.reached(name, step: step)
                let theirs = try js.bool("globalThis.KhaytOrderProgress.stepReached(ARG0, ARG1)",
                                         [.string(name), .number(Double(step))])
                #expect(mine == theirs, Comment(rawValue: "\(name) at step \(step)"))
            }
        }
    }
}

/// The currency table, against the JavaScript it came from.
///
/// A transcribed table is a table with one wrong symbol in it, and the symbols
/// are not decoration: the invoice prints them. So every row is compared rather
/// than a few spot-checked.
@MainActor
struct CurrenciesParityTests {

    @Test("every currency, symbol, label and position matches")
    func tableMatches() throws {
        let js = try JSModule(["currencies"])
        guard case .object(let theirs) = try js.value("globalThis.KhaytCurrencies.CURRENCIES") else {
            Issue.record("the table did not come back as an object"); return
        }
        #expect(Set(theirs.keys) == Set(Currencies.all.keys),
                Comment(rawValue: "codes differ: only-swift \(Set(Currencies.all.keys).subtracting(theirs.keys)), "
                        + "only-js \(Set(theirs.keys).subtracting(Currencies.all.keys))"))
        for (code, value) in theirs {
            guard case .object(let row) = value else { Issue.record("\(code) is not an object"); continue }
            let mine = try #require(Currencies.all[code], Comment(rawValue: "\(code) missing from Swift"))
            if case .string(let symbol)? = row["symbol"] {
                #expect(mine.symbol == symbol, Comment(rawValue: "\(code) symbol: \(mine.symbol) vs \(symbol)"))
            } else { Issue.record("\(code) has no symbol") }
            if case .string(let label)? = row["label"] {
                #expect(mine.label == label, Comment(rawValue: "\(code) label"))
            } else { Issue.record("\(code) has no label") }
            if case .string(let pos)? = row["pos"] {
                #expect(mine.pos == pos, Comment(rawValue: "\(code) pos"))
            } else { Issue.record("\(code) has no pos") }
        }
        #expect(theirs.count > 20, "the table shrank")
    }
}
