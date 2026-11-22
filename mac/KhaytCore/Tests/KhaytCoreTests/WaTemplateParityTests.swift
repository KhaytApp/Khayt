import Foundation
import Testing
@testable import KhaytCore

/// Filling a saved message, against the JavaScript it came from.
///
/// This one goes to a real customer. A placeholder the port does not know
/// prints as `{{due}}` in somebody's WhatsApp, in the shop's name — so the
/// comparison covers every placeholder, every blank, and the values that break
/// a naive implementation.
@MainActor
struct WaTemplateParityTests {

    private func js() throws -> JSModule { try JSModule(["wa-template"]) }

    private func theirs(_ js: JSModule, _ body: JSONValue,
                        _ values: [String: String]) throws -> String {
        let answer = try js.value("globalThis.KhaytWaTemplate.fillTemplate(ARG0, ARG1)",
                                  [body, .object(values.mapValues(JSONValue.string))])
        if case .string(let s) = answer { return s }
        return "«not a string: \(answer)»"
    }

    private func check(_ body: String, _ values: [String: String],
                       _ what: String, _ js: JSModule) throws {
        #expect(WaTemplate.fill(body, values: values) == (try theirs(js, .string(body), values)),
                Comment(rawValue: what))
    }

    @Test("the shipped templates fill identically")
    func shippedTemplatesMatch() throws {
        let js = try js()
        let values = ["client": "ليلى", "id": "O-7", "price": "250.00",
                      "currency": "SAR", "due": "2026-09-30", "status": "Ready"]
        for body in [
            "Hi {{client}}, your order {{id}} is ready! Total: {{price}} {{currency}}. Please arrange pickup or delivery. Thank you!",
            "Hi {{client}}, we've received order {{id}} and it's now in our production queue. We'll notify you when it's ready.",
            "Hi {{client}}, gentle reminder: payment of {{price}} {{currency}} is outstanding for order {{id}}. Thank you!",
        ] {
            try check(body, values, "a shipped template", js)
            // And the customer never sees a brace.
            #expect(!WaTemplate.fill(body, values: values).contains("{{"))
        }
    }

    @Test("every blank agrees, including the two that are not empty")
    func blanksMatch() throws {
        let js = try js()
        let body = "[{{client}}][{{id}}][{{price}}][{{currency}}][{{due}}][{{status}}]"
        try check(body, [:], "nothing supplied", js)
        try check(body, ["client": "", "id": "", "price": "", "currency": "",
                         "due": "", "status": ""], "every value empty", js)
        for key in WaTemplate.placeholders {
            try check(body, [key: "X"], "only \(key) supplied", js)
        }
        // Said outright, because agreeing on the wrong mark is still wrong.
        #expect(WaTemplate.fill("{{client}}", values: [:]) == "...")
        #expect(WaTemplate.fill("{{due}}", values: [:]) == "—")
        #expect(WaTemplate.fill("{{price}}", values: [:]) == "")
    }

    @Test("a value that would rewrite the message around it is inserted literally")
    func replacementPatternsMatch() throws {
        let js = try js()
        // `$&` is "the whole match" and `$'` is "everything after it" in a
        // string replacement. A shop's customer list is not a safe source of
        // replacement patterns.
        for value in ["$&", "$'", "$`", "$$", "$1", "\\n", "\\", "%s", "{{", "}}"] {
            try check("a{{client}}b", ["client": value], "client = \(value)", js)
        }
    }

    @Test("a value that is itself a placeholder is not filled again")
    func noSecondPass() throws {
        let js = try js()
        try check("{{client}} {{price}}", ["client": "{{price}}", "price": "99"],
                  "a customer named {{price}}", js)
        try check("{{client}}", ["client": "{{client}}"], "a self-reference", js)
        // Said outright: the answer must be the literal, not the price.
        #expect(WaTemplate.fill("{{client}} {{price}}",
                                values: ["client": "{{price}}", "price": "99"]) == "{{price}} 99")
    }

    @Test("braces that are not placeholders are left where they are")
    func strayBracesMatch() throws {
        let js = try js()
        for body in ["{{nope}}", "{{}}", "{{", "}}", "{ {client} }", "{{client",
                     "{{{client}}}", "{{client}}}}", "{{CLIENT}}", "{{ client }}",
                     "a{{b{{client}}c}}d", "", "no placeholders at all"] {
            try check(body, ["client": "Layla", "price": "9"], "body \(body)", js)
        }
    }

    @Test("a placeholder used twice is filled twice, and order does not matter")
    func repeatsMatch() throws {
        let js = try js()
        try check("{{id}} {{id}} {{id}}", ["id": "O-1"], "three times", js)
        try check("{{status}}{{due}}{{currency}}{{price}}{{id}}{{client}}",
                  ["client": "A", "id": "B", "price": "C", "currency": "D",
                   "due": "E", "status": "F"], "reversed order", js)
    }

    @Test("a template that is not a string does not throw on either side")
    func oddBodiesMatch() throws {
        let js = try js()
        for body in [JSONValue.null, .number(42), .bool(false), .bool(true),
                     .array([]), .object([:]), .string("")] {
            let text: String? = { if case .string(let s) = body { return s } else { return nil } }()
            // Swift's signature takes `String?`, so a non-string arrives as the
            // absence it is; the JavaScript coerces. Both must produce the same
            // thing for the case that actually happens — a missing template.
            if case .null = body {
                #expect(WaTemplate.fill(text, values: [:]) == (try theirs(js, body, [:])))
            }
            #expect(WaTemplate.fill(text, values: [:]).contains("{{") == false)
        }
    }

    @Test("the placeholder list and the blanks are the same on both sides")
    func listsMatch() throws {
        let js = try js()
        #expect(WaTemplate.placeholders
                == (try js.strings("globalThis.KhaytWaTemplate.PLACEHOLDERS")))
        guard case .object(let blanks) = try js.value("globalThis.KhaytWaTemplate.BLANKS") else {
            Issue.record("BLANKS did not come back as an object"); return
        }
        let theirs = blanks.compactMapValues { value -> String? in
            if case .string(let s) = value { return s }; return nil
        }
        #expect(WaTemplate.blanks == theirs,
                Comment(rawValue: "\(WaTemplate.blanks) vs \(theirs)"))
    }

    @Test("usesPlaceholder agrees")
    func usesMatches() throws {
        let js = try js()
        for body in ["a {{due}} b", "a {{price}} b", "", "{{DUE}}", "{{due"] {
            for key in WaTemplate.placeholders {
                let mine = WaTemplate.uses(body, key)
                let theirs = try js.bool("globalThis.KhaytWaTemplate.usesPlaceholder(ARG0, ARG1)",
                                         [.string(body), .string(key)])
                #expect(mine == theirs, Comment(rawValue: "\(body) uses \(key)"))
            }
        }
    }
}
