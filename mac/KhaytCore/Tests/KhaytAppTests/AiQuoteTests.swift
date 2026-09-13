import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Drafting a quote from a description, on the Mac.
///
/// ── THE SCREEN EXISTED BEFORE THE FEATURE DID ─────────────────────────────
///
/// The assistant pane offered a provider and a switch per feature with what
/// each one sends written beside it — and this app bundled `ai-providers` and
/// `ai-privacy`, the half that decides *which* vendor and *whether* a feature
/// may run, and none of the features. A shop could switch on a feature, read
/// exactly what it transmits, save, and find nothing here ever sent anything.
///
/// ── WHAT IS ACTUALLY AT RISK ──────────────────────────────────────────────
///
/// Not the network call. The GOVERNING CONTRACT, which `lib/ai-quote.js` states
/// in its own header: the model fills the quote *form*; the shop's calculator
/// computes the *price*. A model that returns money, or a Swift caller that
/// treats a guess as a figure, is the failure this feature has to be incapable
/// of — so the tests below spend most of their time on what must NOT come back.
///
/// And consent, which is checked where the data leaves rather than on the
/// screen that offered it.
@MainActor
struct AiQuoteTests {

    /// A shop with the feature switched on and a key. `apiKey` is passed
    /// separately in real use — it is sealed on disk — but the rule reads
    /// either, and a fixture that seals nothing is testing the rule not the
    /// Keychain.
    static func settings(quote: Bool = true, master: Bool = true,
                         provider: String = "anthropic",
                         key: String = "sk-test") -> [String: JSONValue] {
        ["ai": .object([
            "enabled": .bool(master),
            "provider": .string(provider),
            "apiKey": .string(key),
            "features": .object(["quote": .bool(quote)]),
        ])]
    }

    static let shelf: [JSONValue] = [
        .object(["id": .string("SP-1"), "material": .string("PETG"),
                 "color": .string("black"), "cost": .number(85),
                 "spoolWeight": .number(1000), "weight": .number(740)]),
        .object(["id": .string("SP-2"), "material": .string("PLA"),
                 "cost": .number(60), "spoolWeight": .number(1000)]),
    ]

    // MARK: - Consent, where the data leaves

    @Test("a feature the shop has not agreed to cannot be sent")
    func consentIsCheckedAtTheWire() async throws {
        // NOT only on the screen that offered the switch. This is the single
        // point where shop data leaves the device, so a call site that forgets
        // to ask — or a future one that never knew to — still cannot transmit.
        // `main.js` enforces it at exactly the same place.
        // ── THE REASON, NOT MERELY "IT THREW" ─────────────────────────────
        //
        // `#expect(throws: (any Error).self)` passes for ANY error — including a
        // typo in the bridge's JavaScript, which would throw a ReferenceError
        // and read as the consent gate working. Both of these assert the
        // sentence, so the test fails if the gate stops being the reason.
        let engine = try KhaytEngine()
        for (why, s) in [("the feature is off", Self.settings(quote: false)),
                         ("AI assist is off", Self.settings(quote: true, master: false))] {
            var said = ""
            do {
                _ = try await engine.aiQuoteRequest(settings: s, description: "a bracket",
                                                    materials: Self.shelf, apiKey: "sk-test")
                Issue.record(Comment(rawValue: "a request was built when \(why)"))
            } catch {
                said = String(describing: error)
            }
            #expect(said.contains("AI_FEATURE_NOT_CONSENTED"),
                    Comment(rawValue: "\(why): refused with \(said)"))
        }
    }

    @Test("with consent, the request is addressed to the provider the shop chose")
    func consentedRequestIsShaped() async throws {
        let engine = try KhaytEngine()
        let req = try await engine.aiQuoteRequest(
            settings: Self.settings(), description: "20 cable clips in black PETG",
            materials: Self.shelf, apiKey: "sk-test")
        #expect(req.url.contains("api.anthropic.com"), Comment(rawValue: req.url))
        #expect(req.provider == "anthropic")
        #expect(req.headers["x-api-key"] == "sk-test", "the key did not reach the request")
        #expect(req.headers["anthropic-version"] != nil, "the version header is missing")
        #expect(!req.model.isEmpty, "no model was chosen")
    }

    @Test("choosing another provider changes the address AND the spelling")
    func providerChangesEverything() async throws {
        // Four providers spell structured output three different ways. This is
        // the whole reason the shaping is not written in Swift.
        let engine = try KhaytEngine()
        let openai = try await engine.aiQuoteRequest(
            settings: Self.settings(provider: "openai"), description: "a bracket",
            materials: Self.shelf, apiKey: "sk-test")
        #expect(openai.url.contains("openai"), Comment(rawValue: openai.url))
        #expect(openai.headers["x-api-key"] == nil,
                "an OpenAI call carried Anthropic's header")
        #expect(openai.headers["authorization"] != nil || openai.headers["Authorization"] != nil,
                Comment(rawValue: "headers were \(openai.headers.keys.sorted())"))
    }

    @Test("no key is a configuration fault, not a network one")
    func noKeyThrows() async throws {
        // `buildRequest` throws rather than returning half a request, and the
        // module says why: a call with no key is something the shop has to see
        // and fix, not something worth retrying three times first.
        let engine = try KhaytEngine()
        var said = ""
        do {
            _ = try await engine.aiQuoteRequest(
                settings: Self.settings(key: ""), description: "a bracket",
                materials: Self.shelf, apiKey: "")
            Issue.record("a request was built with no key")
        } catch {
            said = String(describing: error)
        }
        // The sentence names the KEY, so this cannot pass on a ReferenceError.
        #expect(said.contains("No API key"), Comment(rawValue: "refused with \(said)"))
    }

    @Test("the shop's own materials are named in the prompt")
    func materialsReachTheModel() async throws {
        // So a guess maps to stock the shop actually has, rather than to a
        // filament nobody on the shelf sells.
        let engine = try KhaytEngine()
        let req = try await engine.aiQuoteRequest(
            settings: Self.settings(), description: "a bracket",
            materials: Self.shelf, apiKey: "sk-test")
        guard case .object(let body) = req.body, case .string(let system)? = body["system"] else {
            Issue.record("the request body carries no system prompt"); return
        }
        #expect(system.contains("PETG") && system.contains("PLA"),
                Comment(rawValue: "the prompt names: \(system)"))
        // AND the instruction that keeps money out of the answer.
        #expect(system.uppercased().contains("NEVER RETURN A PRICE"),
                "the model is not told to stay out of pricing")
    }

    // MARK: - Reading one back

    /// What Anthropic sends for a structured answer.
    static func toolUse(_ input: [String: JSONValue]) -> JSONValue {
        .object([
            "model": .string("claude-opus-5"),
            "content": .array([.object([
                "type": .string("tool_use"),
                "name": .string("quote_extract"),
                "input": .object(input),
            ])]),
        ])
    }

    @Test("a good answer comes back as a draft")
    func readsADraft() async throws {
        let engine = try KhaytEngine()
        let read = try await engine.aiQuoteRead(
            settings: Self.settings(),
            response: Self.toolUse(["qty": .number(20), "materialGuess": .string("black PETG"),
                                    "printWeightG": .number(12.5), "printTimeMin": .number(38),
                                    "confidence": .number(0.8)]))
        #expect(read.ok, Comment(rawValue: read.problem ?? "no reason given"))
        guard case .object(let d)? = read.draft else { Issue.record("no draft"); return }
        #expect(d["qty"] == JSONValue.number(20))
    }

    @Test("an answer that is not a draft is a REASON, not an empty form")
    func refusalIsExplained() async throws {
        // A model can refuse, run out of tokens, or answer in prose. Each of
        // those has to reach the shop as a sentence — an empty quote form with
        // no explanation is the one outcome that teaches people the button is
        // broken.
        let engine = try KhaytEngine()
        let read = try await engine.aiQuoteRead(
            settings: Self.settings(),
            response: .object(["stop_reason": .string("max_tokens"),
                               "content": .array([.object(["type": .string("text"),
                                                           "text": .string("I think…")])])]))
        #expect(!read.ok)
        #expect(!(read.problem ?? "").isEmpty, "a refusal arrived with no reason")
    }

    @Test("a draft missing the one required fact is refused")
    func validationBites() async throws {
        // `qty` is the only required field, and a quote for an unstated number
        // of things is not a quote.
        let engine = try KhaytEngine()
        let read = try await engine.aiQuoteRead(
            settings: Self.settings(),
            response: Self.toolUse(["materialGuess": .string("PETG"), "printWeightG": .number(12)]))
        #expect(!read.ok, "a draft with no quantity was accepted")
        #expect((read.problem ?? "").contains("qty"), Comment(rawValue: read.problem ?? ""))
    }

    // MARK: - The governing contract

    @Test("the draft becomes a part, and the part carries NO price")
    func fillsTheFormAndNotThePrice() async throws {
        // "The AI fills the quote FORM; the existing calculator computes the
        // PRICE." A part that arrived with money on it would mean a model's
        // guess had been presented to a customer as a figure.
        let engine = try KhaytEngine()
        let out = try await engine.aiQuoteToPart(
            draft: .object(["qty": .number(20), "materialGuess": .string("black PETG"),
                            "printWeightG": .number(12.5), "printTimeMin": .number(38)]),
            inventory: Self.shelf, defaults: [:], reclaimsTax: false)
        guard case .object(let o) = out, case .object(let part)? = o["part"] else {
            Issue.record("no part came back"); return
        }
        #expect(part["qty"] == JSONValue.number(20))
        #expect(part["printWeight"] == JSONValue.number(12.5))
        for money in ["price", "basePrice", "baseCost", "total", "unitPrice"] {
            #expect(part[money] == nil,
                    Comment(rawValue: "the model's draft arrived carrying \(money)"))
        }
    }

    @Test("the time comes back in HOURS, like every other part in the book")
    func timeIsHours() async throws {
        // THE TRAP THIS PINS, and it was live. The model answers in minutes
        // (`printTimeMin`) and `draftToPart` used to pass them straight into
        // `printTime` — a field that means HOURS on every other part in the
        // codebase: the calculator, the store, the invoice, both editors.
        //
        // It was not visibly wrong only because the single call site remembered
        // to divide. `renderer/build.js` wrote `(part.printTime / 60)`. The Mac
        // was about to become a second caller, and a caller that did not know
        // would have quoted a ninety-minute print as ninety hours.
        let engine = try KhaytEngine()
        let out = try await engine.aiQuoteToPart(
            draft: .object(["qty": .number(1), "printTimeMin": .number(90)]),
            inventory: Self.shelf, defaults: [:], reclaimsTax: false)
        guard case .object(let o) = out, case .object(let part)? = o["part"] else {
            Issue.record("no part"); return
        }
        #expect(Shop.plainNumber(part["printTime"]) == 1.5,
                Comment(rawValue: "90 minutes came back as \(part["printTime"] ?? .null)"))
    }

    @Test("a guessed material is matched to a spool the shop actually has")
    func materialIsMatched() async throws {
        let engine = try KhaytEngine()
        let out = try await engine.aiQuoteToPart(
            draft: .object(["qty": .number(5), "materialGuess": .string("black PETG")]),
            inventory: Self.shelf, defaults: [:], reclaimsTax: false)
        guard case .object(let o) = out, case .object(let part)? = o["part"] else {
            Issue.record("no part"); return
        }
        #expect(part["filamentId"] == JSONValue.string("SP-1"),
                Comment(rawValue: "matched \(part["filamentId"] ?? .null)"))
        #expect(part["spoolCost"] == JSONValue.number(85))
    }

    @Test("a material the shop does not stock is SAID, not silently swapped")
    func unmatchedMaterialIsSurfaced() async throws {
        // Quietly binding the job to whatever spool happened to be first is how
        // a quote comes to be priced against a filament the shop was never
        // going to print it in.
        let engine = try KhaytEngine()
        let out = try await engine.aiQuoteToPart(
            draft: .object(["qty": .number(5), "materialGuess": .string("polycarbonate")]),
            inventory: Self.shelf, defaults: [:], reclaimsTax: false)
        guard case .object(let o) = out else { Issue.record("no answer"); return }
        #expect(o["unmatchedMaterial"] == JSONValue.bool(true))
        guard case .array(let notes)? = o["assumptions"] else {
            Issue.record("no assumptions list"); return
        }
        #expect(notes.contains { Shop.plainString($0)?.contains("polycarbonate") == true },
                "the shop is not told which material failed to match")
    }

    @Test("every inference the model made is carried back for the shop to read")
    func assumptionsSurvive() async throws {
        let engine = try KhaytEngine()
        let out = try await engine.aiQuoteToPart(
            draft: .object(["qty": .number(2), "materialGuess": .string("PLA"),
                            "assumptions": .array([.string("assumed 20% infill"),
                                                   .string("assumed 0.2mm layers")])]),
            inventory: Self.shelf, defaults: [:], reclaimsTax: false)
        guard case .object(let o) = out, case .array(let notes)? = o["assumptions"] else {
            Issue.record("no assumptions"); return
        }
        #expect(notes.count >= 2, "the model's stated assumptions were dropped")
    }

    @Test("a shop that reclaims tax prices the spool net of it")
    func taxReclaimReachesTheBasis() async throws {
        // `draftToPart` asks `KhaytSpoolEdit.netCost`, which is a DIFFERENT
        // bundled module reached through the global — so this also proves the
        // two are loaded in the right order. Read the other way round it would
        // silently fall back to the gross cost and nothing would look wrong.
        let engine = try KhaytEngine()
        let shelf: [JSONValue] = [.object([
            "id": .string("SP-9"), "material": .string("PETG"),
            "cost": .number(115), "vatAmount": .number(15), "spoolWeight": .number(1000),
        ])]
        let gross = try await engine.aiQuoteToPart(
            draft: .object(["qty": .number(1), "materialGuess": .string("PETG")]),
            inventory: shelf, defaults: [:], reclaimsTax: false)
        let net = try await engine.aiQuoteToPart(
            draft: .object(["qty": .number(1), "materialGuess": .string("PETG")]),
            inventory: shelf, defaults: [:], reclaimsTax: true)
        func cost(_ v: JSONValue) -> Double? {
            guard case .object(let o) = v, case .object(let p)? = o["part"] else { return nil }
            return Shop.plainNumber(p["spoolCost"])
        }
        #expect(cost(gross) == 115)
        #expect(cost(net) == 100,
                Comment(rawValue: "net basis came out \(cost(net) ?? -1) — spool-edit may not be loaded"))
    }

    // MARK: - The box is only offered when the shop agreed

    @Test("the drafting box follows the shop's own consent, both ways")
    func theBoxTracksConsent() async throws {
        // The box is an offer to send the shop's words to a vendor. Offering it
        // to a shop that has not switched the feature on is an advertisement on
        // a screen somebody is trying to work in — and worse, it would fail at
        // the wire with a sentence about consent the shop never asked to hear.
        //
        // Read through `aiFeatures`, which is the same rule the wire asks.
        let engine = try KhaytEngine()
        func allowed(_ s: [String: JSONValue]) async throws -> Bool {
            try await engine.aiFeatures(settings: s).first { $0.id == "quote" }?.enabled ?? false
        }
        #expect(try await allowed(Self.settings()), "a consented shop is not offered the box")
        #expect(!(try await allowed(Self.settings(quote: false))),
                "the box is offered for a feature the shop switched off")
        #expect(!(try await allowed(Self.settings(master: false))),
                "the box is offered with AI assist switched off entirely")
    }

    @Test("the \"runs elsewhere\" note is on the features that do, and not on quote")
    func theCaveatCannotOutliveItself() async throws {
        // THE BUG THIS GUARDS is a sentence, not code. The pane carried ONE
        // note over the whole list saying these run in the other app — true
        // when written, false the hour `quote` started working here. A caveat
        // that outlives its limitation is worse than none: it tells a shop a
        // working feature does nothing.
        //
        // So it is per feature now, and this pins both directions.
        #expect(Shop.aiRunsHere("quote"), "quote works here and is still captioned as elsewhere")
        for elsewhere in ["price", "reply", "assistant"] {
            #expect(!Shop.aiRunsHere(elsewhere),
                    Comment(rawValue: "\(elsewhere) claims to run here — does it?"))
        }
        // And every id in the list is a real feature, so a typo cannot quietly
        // drop the note from something that still does not work.
        let engine = try KhaytEngine()
        let known = Set(try await engine.aiFeatures(settings: Self.settings()).map(\.id))
        for id in Shop.aiFeaturesOnThisMac {
            #expect(known.contains(id), Comment(rawValue: "\(id) is not an AI feature"))
        }
    }

    // MARK: - What to do when it fails

    @Test("the two apps agree about which faults are worth retrying")
    func retryPolicyIsShared() async throws {
        let engine = try KhaytEngine()
        // Rate limited and overloaded: transient.
        for status in [429, 529, 500, 503] {
            let p = try await engine.aiRetry(status: status, attempt: 0, retryAfter: nil)
            #expect(p.retry, Comment(rawValue: "\(status) was treated as permanent"))
            #expect(p.afterMs > 0, Comment(rawValue: "\(status) retried with no pause"))
        }
        // A bad key or a bad request will fail identically three times.
        for status in [400, 401, 403, 404] {
            let p = try await engine.aiRetry(status: status, attempt: 0, retryAfter: nil)
            #expect(!p.retry, Comment(rawValue: "\(status) was retried"))
        }
    }

    @Test("the wait grows, and a Retry-After header is honoured")
    func backoffIsHonoured() async throws {
        let engine = try KhaytEngine()
        let first = try await engine.aiRetry(status: 429, attempt: 0, retryAfter: nil)
        let third = try await engine.aiRetry(status: 429, attempt: 2, retryAfter: nil)
        #expect(third.afterMs > first.afterMs, "the backoff does not back off")
        // A provider that says how long to wait is believed.
        let told = try await engine.aiRetry(status: 429, attempt: 0, retryAfter: "5")
        #expect(told.afterMs >= 5000, Comment(rawValue: "asked to wait 5s, waiting \(told.afterMs)ms"))
    }

    @Test("an HTTP fault reads as a sentence, in the other app's words")
    func faultsAreExplained() async throws {
        let engine = try KhaytEngine()
        let unauthorised = try await engine.aiHttpError(status: 401, body: .null)
        #expect(!unauthorised.isEmpty)
        #expect(unauthorised.lowercased().contains("key"),
                Comment(rawValue: "a 401 reads as: \(unauthorised)"))
    }
}

/// That any of it is reachable from the app.
@MainActor
struct AiQuoteWiringTests {

    static func source(_ file: String) throws -> String {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        return try String(contentsOf: dir.appending(path: file), encoding: .utf8)
    }

    @Test("the transport asks the shared rules and decides nothing itself")
    func nothingIsReinvented() throws {
        let client = try Self.source("AiClient.swift")
        for (call, why) in [
            ("engine.aiQuoteRequest(", "the request is shaped somewhere other than the rule"),
            ("engine.aiQuoteRead(", "the reply is parsed somewhere other than the rule"),
            ("engine.aiRetry(", "the Mac has its own opinion about what is worth retrying"),
            ("engine.aiHttpError(", "the Mac writes its own words for an HTTP fault"),
            ("Secrets.open(", "the key is read without being unsealed"),
        ] {
            #expect(client.contains(call), Comment(rawValue: why))
        }
        // No second copy of what a provider's address or headers look like.
        #expect(!client.contains("anthropic.com") && !client.contains("x-api-key"),
                "the transport spells a provider's own details")
    }
}
