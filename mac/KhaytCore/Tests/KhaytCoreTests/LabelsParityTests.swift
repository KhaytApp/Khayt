import Foundation
import Testing
@testable import KhaytCore

/// The label sheet, against the JavaScript it came from.
///
/// Byte-for-byte, not "renders the same": a rack labelled half from each app
/// has to come out of one holder, and the two sheets are printed through one
/// stylesheet. A missing space is not visible on screen and is visible on a
/// shelf.
@MainActor
struct LabelsParityTests {

    private func js() throws -> JSModule { try JSModule(["labels"]) }

    private func sheet(_ js: JSModule, _ labels: [JSONValue],
                       _ heading: JSONValue) throws -> String {
        let answer = try js.value(
            "globalThis.KhaytLabels.buildLabelSheet(ARG0, { heading: ARG1 })",
            [.array(labels), heading])
        if case .string(let s) = answer { return s }
        return "«not a string: \(answer)»"
    }

    @Test("a real shelf sheet is identical, to the byte")
    func realSheetMatches() throws {
        let js = try js()
        let labels: [JSONValue] = [
            .object(["title": .string("PLA Basic — Black"),
                     "lines": .array([.string("Bambu"), .string("742 g left"), .string("Shelf A3")]),
                     "sub": .string("SP-0001"),
                     "qr": .string("data:image/png;base64,iVBORw0KGgo=")]),
            .object(["title": .string("PETG · Orange"),
                     "lines": .array([.string("Polymaker"), .string("1 kg")]),
                     "qr": .string("data:image/png;base64,AAAA")]),
        ]
        let heading = JSONValue.string("Shelf labels")
        #expect(Labels.sheet(labels, heading: heading) == (try sheet(js, labels, heading)))
    }

    @Test("every character the escape claims to handle is escaped the same way")
    func escapingMatches() throws {
        let js = try js()
        // A title that is an injection attempt, one that is only punctuation,
        // and one that is a shop's own text with an apostrophe in it.
        let nasty = ["<script>alert(1)</script>", "Tom & Jerry's \"big\" <box>",
                     "&<>\"'", "'; DROP TABLE", "«quotes» — em—dash", "🧵 spool",
                     "&amp; already escaped", ""]
        for text in nasty {
            #expect(Labels.esc(.string(text))
                    == (try js.value("globalThis.KhaytLabels.esc(ARG0)", [.string(text)]).asString),
                    Comment(rawValue: "esc(\(text))"))
        }
    }

    @Test("esc coerces the same way for values that are not strings")
    func escapingCoercesTheSame() throws {
        let js = try js()
        var odd: [JSONValue] = [.null, .bool(true), .bool(false), .number(0), .number(-0),
                                .number(1e21), .number(1e-7), .number(0.1 + 0.2),
                                .array([]), .array([.string("a"), .null, .number(2)]),
                                .object([:]), .object(["a": .number(1)])]
        odd += Awkward.numbers.map { JSONValue.number($0) }
        for value in odd {
            let mine = Labels.esc(value)
            let theirs = try js.value("globalThis.KhaytLabels.esc(ARG0)", [value]).asString
            #expect(mine == theirs, Comment(rawValue: "esc of \(value): \(mine) vs \(theirs ?? "nil")"))
        }
    }

    /// ── ONE PLACE THE PORT DELIBERATELY DOES NOT AGREE ────────────────────
    ///
    /// A label entry that is a bare STRING picks up `String.prototype.sub` —
    /// the legacy `<sub>` helper every JavaScript string has — and a function
    /// is truthy, so the original prints
    /// `<div class="lbl-sub">function sub() { [native code] }</div>` onto the
    /// label. That is a wart of prototype lookup, not a rule, and it is the
    /// same shape as the `hasOwnProperty` guard `order-progress` needed.
    ///
    /// The Swift port reads fields off a dictionary, which has no prototype,
    /// so it prints no sub-line. That is the answer a shop wants. The test
    /// pins the difference so it is a decision on the record rather than a
    /// disagreement nobody noticed.
    @Test("a string entry prints no sub-line here, where JavaScript printed its own method")
    func stringEntryDropsThePrototypeWart() throws {
        let js = try js()
        let labels: [JSONValue] = [.string("not a label")]
        let mine = Labels.sheet(labels, heading: .string(""))
        #expect(!mine.contains("lbl-sub"), "the port must not print a sub-line for a bare string")
        #expect(!mine.contains("native code"))
        let theirs = try sheet(js, labels, .string(""))
        #expect(theirs.contains("native code"),
                "if the original stopped doing this, the port no longer differs and this test can go")
        // Everything else about the card is the same; only the sub-line
        // differs — and the function's own printed source is the engine's
        // business, so it is cut out by position rather than by spelling.
        var stripped = theirs
        if let open = stripped.range(of: "<div class=\"lbl-sub\">"),
           let close = stripped.range(of: "</div>", range: open.upperBound..<stripped.endIndex) {
            stripped.removeSubrange(open.lowerBound..<close.upperBound)
        }
        #expect(mine == stripped, "the cards differ by more than the sub-line")
    }

    @Test("a blank line is dropped and a zero is not")
    func blankLinesMatch() throws {
        let js = try js()
        // `0` and `false` print; a string of spaces does not. Getting this
        // backwards would drop "0 g left" off every empty spool's label.
        let labels: [JSONValue] = [.object(["title": .string("t"), "lines": .array([
            .string(""), .string("   "), .string("\t\n"), .number(0), .bool(false),
            .null, .string("kept"), .array([]), .object([:]), .string(" padded "),
        ])])]
        #expect(Labels.sheet(labels, heading: .string("")) == (try sheet(js, labels, .string(""))))
    }

    @Test("an empty heading prints no heading, and so does a falsy one")
    func headingMatches() throws {
        let js = try js()
        let labels: [JSONValue] = [.object(["title": .string("t")])]
        for heading in [JSONValue.string(""), .null, .bool(false), .number(0),
                        .string("0"), .string("Shelf"), .number(7), .bool(true)] {
            #expect(Labels.sheet(labels, heading: heading) == (try sheet(js, labels, heading)),
                    Comment(rawValue: "heading \(heading)"))
        }
    }

    @Test("a label missing every field, and entries that are not labels at all")
    func degenerateLabelsMatch() throws {
        let js = try js()
        let cases: [[JSONValue]] = [
            [],
            [.object([:])],
            [.null, .object(["title": .string("kept")]), .bool(false), .number(0), .string("")],
            [.number(3), .array([])],
            [.object(["title": .null, "lines": .null, "qr": .null, "sub": .null])],
            [.object(["lines": .string("not an array")])],
            [.object(["qr": .string(""), "sub": .string("")])],
            [.object(["qr": .bool(true), "sub": .number(5), "title": .array([.string("a")])])],
        ]
        for labels in cases {
            #expect(Labels.sheet(labels, heading: .string("H")) == (try sheet(js, labels, .string("H"))),
                    Comment(rawValue: "labels \(labels)"))
        }
    }
}

extension JSONValue {
    /// The string inside, or nil — for reading a parity answer back.
    var asString: String? { if case .string(let s) = self { return s }; return nil }
}
