import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// What the note on a receipt suggests the expense is.
///
/// ── WHAT THIS SUITE IS GUARDING ───────────────────────────────────────────
///
/// `lib/expense-categorize.js` has existed since long before this app, and only
/// the Electron window ever called it — so a shop filing receipts on the Mac
/// got no suggestion at all, while the same receipt typed into the other window
/// offered one. The rule is unchanged; what is new is that this app reaches it.
///
/// The keyword list is NOT restated here. Every assertion goes through the
/// engine, so a word added to the shared list on either side of the bridge is
/// answered the same way by both apps — which is the whole reason the guess
/// lives in `lib/` and not in a Swift dictionary.
@MainActor
struct ExpenseGuessTests {

    @Test("a receipt that names a courier is filed under shipping")
    func englishKeywords() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.suggestedCategory(for: "Aramex courier to Jeddah") == "shipping")
        #expect(try await engine.suggestedCategory(for: "2 rolls of PETG") == "filament")
        #expect(try await engine.suggestedCategory(for: "nozzle and belt for the X1") == "maintenance")
    }

    @Test("Arabic is read too, because the shop writes its receipts in it")
    func arabicKeywords() async throws {
        // This is the half a Swift keyword list would have been most likely to
        // get wrong, and the half the shop actually types.
        let engine = try KhaytEngine()
        #expect(try await engine.suggestedCategory(for: "فاتورة كهرباء") == "electricity")
        #expect(try await engine.suggestedCategory(for: "بكرة خيط PLA") == "filament")
    }

    @Test("a note that suggests nothing gets no suggestion, rather than a guess")
    func silenceIsAnAnswer() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.suggestedCategory(for: "") == nil)
        #expect(try await engine.suggestedCategory(for: "   ") == nil)
        #expect(try await engine.suggestedCategory(for: "invoice 4471") == nil)
    }

    @Test("every category the rule can suggest is one this app's picker has")
    func suggestionsAreSelectable() async throws {
        // A suggestion naming a category the picker cannot select would draw a
        // button that does nothing — or worse, set `category` to a value the
        // book's own list has never heard of, filing the expense out of every
        // total on the Expenses screen.
        let engine = try KhaytEngine()
        let notes = ["spool of PLA", "electricity bill", "nozzle repair",
                     "DHL shipping", "glue and tape"]
        var seen: Set<String> = []
        for note in notes {
            let guess = try await engine.suggestedCategory(for: note)
            if let guess { seen.insert(guess) }
        }
        #expect(seen.count == 5, "the five categories the rule knows were not all reached")
        for category in seen {
            #expect(Shop.expenseCategories.contains(category),
                    Comment(rawValue: "the rule suggests \(category), which the picker cannot select"))
        }
    }

    // MARK: - The wiring

    @Test("the app asks the rule, and says nothing when there is no engine")
    func shopAsksTheRule() async throws {
        let shop = Shop()
        await shop.load(.sample)
        #expect(shop.engineProblem == nil, "no engine means this proves nothing")
        #expect(await shop.categoryFor("Aramex courier") == "shipping")
        // A blank note is not a question, and a shop that has typed nothing
        // should see nothing rather than a suggestion for the empty string.
        #expect(await shop.categoryFor("  ") == nil)
    }

    @Test("the sheet offers the suggestion and does not apply it")
    func offeredNotApplied() throws {
        // The keyword list is short and a form that silently re-filed what the
        // shop had already chosen would be wrong in its books without saying
        // so. The other app offers it as a link; this one offers a button.
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let sheet = try String(contentsOf: sources.appending(path: "SpendSheets.swift"),
                               encoding: .utf8)
        #expect(sheet.contains("shop.categoryFor(note)"), "the sheet never asks")
        #expect(sheet.contains("exp.suggested"), "the suggestion is never drawn")
        #expect(sheet.contains("suggestion != category"),
                "the suggestion is drawn even when it agrees with what is chosen")
        // The only place `category` is assigned from the suggestion is inside
        // the button's action — nothing sets it as the note is typed.
        #expect(!sheet.contains("category = await"), "the sheet applies the guess by itself")
    }

    @Test("the module is bundled, or none of this runs in the app at all")
    func moduleIsBundled() throws {
        let engineSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytCore/KhaytEngine.swift")
        let text = try String(contentsOf: engineSource, encoding: .utf8)
        #expect(text.contains("\"expense-categorize\","),
                "the binding exists but the module is not on the bundled list")
    }
}
