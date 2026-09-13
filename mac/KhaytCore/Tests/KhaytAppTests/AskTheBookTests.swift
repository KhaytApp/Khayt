import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Asking questions about the shop's own book.
///
/// ── WHAT LEAVES THE BUILDING IS THE THING TO TEST ─────────────────────────
///
/// Not the answer — the model writes that and nothing here can pin it. The
/// PAYLOAD is what a shop is owed a precise claim about, and it is a summary:
/// `buildShopContext` reduces orders, shelf, customers and settings to totals
/// and counts. The screen says "no customer names or order details leave your
/// Mac", and that sentence has to be true, so most of what follows checks that
/// the summary does not carry what the screen promises it does not.
@MainActor
struct AskTheBookTests {

    static func settings(assistant: Bool = true, master: Bool = true) -> [String: JSONValue] {
        ["ai": .object([
            "enabled": .bool(master), "provider": .string("anthropic"),
            "apiKey": .string("sk-test"),
            "features": .object(["assistant": .bool(assistant)]),
        ]),
         "currency": .string("SAR"), "bizEn": .string("Tuwaiq Additive")]
    }

    static let book: [String: JSONValue] = [
        "printLog": .array([
            .object(["id": .string("ORD-1"), "status": .string("completed"),
                     "project": .string("Turbine bracket"), "price": .number(400),
                     "costBasis": .number(220), "date": .string("2026-09-01"),
                     "clientId": .string("CLI-1")]),
            .object(["id": .string("ORD-2"), "status": .string("pending"),
                     "project": .string("Kaaba desk piece"), "price": .number(250),
                     "date": .string("2026-09-10"), "clientId": .string("CLI-1")]),
        ]),
        "inventory": .array([
            .object(["id": .string("SP-1"), "material": .string("PETG"),
                     "weight": .number(320), "cost": .number(85)]),
        ]),
        "clients": .array([
            .object(["id": .string("CLI-1"), "nameEn": .string("Maha Al-Qahtani"),
                     "email": .string("maha@example.com"),
                     "phone": .string("+966 50 111 2222")]),
        ]),
        "settings": .object(["currency": .string("SAR")]),
    ]

    // MARK: - The payload

    @Test("the model is given a summary, not the book")
    func itIsASummary() async throws {
        let engine = try KhaytEngine()
        let summary = try await engine.shopSummary(collections: Self.book, now: Date())
        guard case .object(let s) = summary else { Issue.record("no summary"); return }
        #expect(!s.isEmpty, "the summary is empty, so every answer will be 'not in the data'")

        // It is SMALL. The whole point is that a shop can be told what left.
        let bytes = try JSONEncoder().encode(summary).count
        #expect(bytes < 4000, Comment(rawValue: "the summary is \(bytes) bytes — that is a book, not a summary"))
    }

    @Test("no customer name, address or order reference is in it")
    func noPersonalDataLeaves() async throws {
        // THE CLAIM THE SCREEN MAKES, in as many words: "No customer names or
        // order details leave your Mac." A sentence like that is worth nothing
        // unless something checks it, and it is exactly the sentence that would
        // quietly stop being true when the summary gains a field.
        let engine = try KhaytEngine()
        let summary = try await engine.shopSummary(collections: Self.book, now: Date())
        let text = String(data: try JSONEncoder().encode(summary), encoding: .utf8) ?? ""
        for private_ in ["Maha", "Al-Qahtani", "maha@example.com", "+966", "CLI-1",
                         "ORD-1", "Turbine bracket", "Kaaba"] {
            #expect(!text.contains(private_),
                    Comment(rawValue: "the summary carries \"\(private_)\": \(text.prefix(400))"))
        }
    }

    // MARK: - Consent, at the wire

    @Test("a shop that has not agreed to the assistant cannot send one")
    func consentIsChecked() async throws {
        let engine = try KhaytEngine()
        let summary = try await engine.shopSummary(collections: Self.book, now: Date())
        for (why, s) in [("the feature is off", Self.settings(assistant: false)),
                         ("AI assist is off", Self.settings(master: false))] {
            var said = ""
            do {
                _ = try await engine.aiAssistantRequest(
                    settings: s, summary: summary, question: "how was last month?",
                    history: [], shopName: "Tuwaiq", language: "en", apiKey: "sk-test")
                Issue.record(Comment(rawValue: "a request was built when \(why)"))
            } catch { said = String(describing: error) }
            #expect(said.contains("AI_FEATURE_NOT_CONSENTED"),
                    Comment(rawValue: "\(why): refused with \(said)"))
        }
    }

    @Test("with consent, the question and the summary both reach the request")
    func requestCarriesBoth() async throws {
        let engine = try KhaytEngine()
        let summary = try await engine.shopSummary(collections: Self.book, now: Date())
        let req = try await engine.aiAssistantRequest(
            settings: Self.settings(), summary: summary,
            question: "how did this month compare with last?",
            history: [], shopName: "Tuwaiq Additive", language: "en", apiKey: "sk-test")
        guard case .object(let body) = req.body else { Issue.record("no body"); return }
        let text = String(data: try JSONEncoder().encode(body), encoding: .utf8) ?? ""
        #expect(text.contains("compare with last"), "the question did not reach the model")
        #expect(text.contains("Shop summary"), "the summary did not reach the model")
        // And the instruction that keeps it honest.
        guard case .string(let system)? = body["system"] else { Issue.record("no system"); return }
        #expect(system.contains("never invent"), Comment(rawValue: system))
    }

    @Test("an earlier turn is carried so a follow-up resolves")
    func historyIsCarried() async throws {
        // "And last month?" is only answerable if the model can see what was
        // asked before it.
        let engine = try KhaytEngine()
        let summary = try await engine.shopSummary(collections: Self.book, now: Date())
        let req = try await engine.aiAssistantRequest(
            settings: Self.settings(), summary: summary, question: "and last month?",
            history: [.object(["q": .string("how much did I make this month?"),
                               "a": .string("SAR 400 across one finished job.")])],
            shopName: "Tuwaiq", language: "en", apiKey: "sk-test")
        let text = String(data: try JSONEncoder().encode(req.body), encoding: .utf8) ?? ""
        #expect(text.contains("how much did I make this month"),
                "the earlier turn was dropped, so a follow-up cannot resolve")
    }

    @Test("the tool gives the model somewhere to put the answer")
    func theToolHasAnAnswerField() async throws {
        // `resolveTool` falls back to an EMPTY object schema when it is handed
        // nothing — a tool with no field, which the model cannot fill and
        // `pickAnswer` would read nothing back from. The first version of the
        // bridge passed null.
        let engine = try KhaytEngine()
        let summary = try await engine.shopSummary(collections: Self.book, now: Date())
        let req = try await engine.aiAssistantRequest(
            settings: Self.settings(), summary: summary, question: "anything?",
            history: [], shopName: "Tuwaiq", language: "en", apiKey: "sk-test")
        let text = String(data: try JSONEncoder().encode(req.body), encoding: .utf8) ?? ""
        #expect(text.contains("answer"),
                "the tool declares no answer field, so nothing can come back")
    }

    // MARK: - Reading one back

    @Test("an answer comes back; a refusal comes back as a reason")
    func readsAnAnswer() async throws {
        let engine = try KhaytEngine()
        let good = JSONValue.object([
            "content": .array([.object([
                "type": .string("tool_use"), "name": .string("shop_answer"),
                "input": .object(["answer": .string("You made SAR 400 this month.")]),
            ])]),
        ])
        let read = try await engine.aiAssistantRead(settings: Self.settings(), response: good)
        #expect(read.ok)
        #expect(read.answer?.contains("400") == true, Comment(rawValue: read.answer ?? "nil"))

        let refused = JSONValue.object(["stop_reason": .string("max_tokens"),
                                        "content": .array([])])
        let bad = try await engine.aiAssistantRead(settings: Self.settings(), response: refused)
        #expect(!bad.ok)
        #expect(!(bad.problem ?? "").isEmpty, "a refusal arrived with no reason")
    }
}

/// That the screen is reachable and asks the rules for everything.
@MainActor
struct AskTheBookWiringTests {

    static func source(_ file: String) throws -> String {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        return try String(contentsOf: dir.appending(path: file), encoding: .utf8)
    }

    @Test("the screen is openable, and only where the shop agreed")
    func itIsReachable() throws {
        let menus = try Self.source("Menus.swift")
        #expect(menus.contains("shop.askingTheBook = true"),
                "nothing opens the screen")
        #expect(menus.contains("if shop.aiAssistantAllowed"),
                "the menu offers to send a summary on a shop that switched the feature off")
        #expect(try Self.source("ShopWindow.swift").contains("AskTheBook(shop: shop)"),
                "the sheet is never presented")
    }

    @Test("the summary is built from a named list, not from the whole store")
    func thePayloadIsNamed() throws {
        let shop = try Self.source("Shop.swift")
        #expect(shop.contains("var bookForAssistant"),
                "there is no single place saying what the assistant is given")
        // A shop asking "what does it send?" is owed a list. Handing over the
        // store would make that question unanswerable.
        #expect(!shop.contains("shopSummary(collections: settingsDict"),
                "the summary is built from something other than the named list")
    }
}
