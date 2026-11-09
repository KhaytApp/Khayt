import Foundation
import Testing
@testable import KhaytCore

/// When Settings shows one invoice prefix and when two, and what a save writes,
/// against `lib/number-prefixes.js` — the desktop calls the JavaScript, the Mac
/// and the phone this port, and a shop must see the same fields on each.
@MainActor
struct NumberPrefixesParityTests {

    private func js() throws -> JSModule { try JSModule(["number-prefixes"]) }

    /// Values a stored prefix can hold, including the ways of saying nothing.
    private let stored: [JSONValue?] = [
        nil, .null, .number(7), .bool(true), .string(""), .string("  "), .string("INV"), .string(" INV "),
        .string("inv"), .string("ATH"), .string("ABCDEFGHIJKLMN"), .string("\u{0627}\u{062B}\u{0631}"),
        .string("ABCDEFGHI\u{1F600}"), .string("\tQ\n"),
    ]

    private func theirs(_ js: JSModule, _ settings: [String: JSONValue]) throws -> NumberPrefixes.View {
        guard case .object(let o) = try js.value("KhaytNumberPrefixes.prefixView(ARG0)", [.object(settings)]) else {
            Issue.record("not an object"); throw CancellationError()
        }
        if case .string(let s)? = o["shared"] { return .shared(s) }
        guard case .string(let j)? = o["job"], case .string(let t)? = o["taxInvoice"] else {
            Issue.record("neither shared nor split: \(o)"); throw CancellationError()
        }
        return .split(job: j, taxInvoice: t)
    }

    @Test("one field or two, for every pair of stored prefixes")
    func viewMatches() throws {
        let js = try js()
        for a in stored {
            for b in stored {
                var s: [String: JSONValue] = [:]
                if let a { s["invPrefix"] = a }
                if let b { s["invNumPrefix"] = b }
                #expect(NumberPrefixes.view(s) == (try theirs(js, s)),
                        Comment(rawValue: "\(String(describing: a)) / \(String(describing: b))"))
            }
        }
    }

    @Test("what a save writes, shared and split")
    func patchMatches() throws {
        let js = try js()
        let typed = ["", "  ", "INV", " ATH ", "ABCDEFGHIJKLMN", "ABCDEFGHI\u{1F600}", "ABCDEFGH\u{1F600}Z",
                     "\u{0627}\u{062B}\u{0631}", "x\ny"]
        for t in typed {
            let mine = NumberPrefixes.patch(shared: t)
            let theirs = try js.value("KhaytNumberPrefixes.prefixPatch({shared: ARG0})", [.string(t)])
            #expect(JSONValue.object(mine) == theirs, Comment(rawValue: t.debugDescription))
            for u in typed {
                let split = NumberPrefixes.patch(job: t, taxInvoice: u)
                let theirSplit = try js.value("KhaytNumberPrefixes.prefixPatch({job: ARG0, taxInvoice: ARG1})",
                                              [.string(t), .string(u)])
                #expect(JSONValue.object(split) == theirSplit, Comment(rawValue: "\(t.debugDescription) / \(u.debugDescription)"))
            }
        }
        #expect(NumberPrefixes.patch(job: "ATH", taxInvoice: nil) == ["invPrefix": .string("ATH")])
        #expect(NumberPrefixes.patch(job: nil, taxInvoice: nil).isEmpty)
    }

    @Test("the limits are the module's")
    func limits() throws {
        let js = try js()
        #expect(try js.int("KhaytNumberPrefixes.MAX") == NumberPrefixes.max)
        #expect(try js.value("KhaytNumberPrefixes.DEFAULT") == .string(NumberPrefixes.fallback))
    }
}
