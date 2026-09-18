import Foundation
import Testing
@testable import KhaytCore

/// Keeping a shop's tags to one spelling, against the JavaScript it came from.
///
/// Everything here turns on case folding and on WHICH spelling survives, so
/// the cases are mostly the same word written several ways.
@MainActor
struct TagsParityTests {

    private func js() throws -> JSModule { try JSModule(["tags"]) }

    private func strings(_ v: JSONValue) -> [String] {
        guard case .array(let rows) = v else { return ["<not an array>"] }
        return rows.map { if case .string(let s) = $0 { return s } else { return "<not a string>" } }
    }

    // MARK: - normaliseTags

    private func checkNormalise(_ raw: JSONValue, _ known: [JSONValue],
                                _ what: String, _ js: JSModule) throws {
        let mine = Tags.normalise(raw, known: known)
        let theirs = strings(try js.value("KhaytTags.normaliseTags(ARG0, ARG1)",
                                          [raw, .array(known)]))
        #expect(mine == theirs, Comment(rawValue: "\(what)\n  swift \(mine)\n  js    \(theirs)"))
    }

    @Test("a tag the shop already uses adopts its spelling")
    func adoptsSpelling() throws {
        let js = try js()
        let known: [JSONValue] = [.string("Resin"), .string("PLA+"), .string("  Miniatures ")]
        for typed in ["resin", "RESIN", " resin ", "Resin", "pla+", "miniatures",
                      "resin, pla+", "resin,resin,Resin", "resin , , pla+ ,",
                      "", "   ", ",", ",,,", "new tag", "New Tag, resin"] {
            try checkNormalise(.string(typed), known, typed.debugDescription, js)
        }
    }

    @Test("the first spelling the shop uses wins, whatever order they arrive in")
    func firstKnownWins() throws {
        let js = try js()
        try checkNormalise(.string("resin"),
                           [.string("Resin"), .string("RESIN"), .string("resin")], "Resin first", js)
        try checkNormalise(.string("resin"),
                           [.string("RESIN"), .string("Resin")], "RESIN first", js)
        // An empty or blank known tag is skipped rather than claiming the key.
        try checkNormalise(.string("resin"),
                           [.string(""), .string("  "), .string("Resin")], "blanks first", js)
    }

    @Test("an array in, and rows that are not strings")
    func arrayInput() throws {
        let js = try js()
        try checkNormalise(.array([.string("resin"), .string(" PLA "), .string("resin")]),
                           [.string("Resin")], "an array", js)
        try checkNormalise(.array([.null, .string(""), .number(3), .bool(true),
                                   .string("resin"), .number(0), .bool(false)]),
                           [.string("Resin"), .number(3)], "a mixed array", js)
        try checkNormalise(.array([]), [], "an empty array", js)
        try checkNormalise(.null, [.string("Resin")], "null", js)
        try checkNormalise(.number(7), [], "a number", js)
        try checkNormalise(.bool(true), [], "a boolean", js)
    }

    @Test("nothing is imposed on a tag the shop has not used before")
    func keepsWhatWasTyped() throws {
        // The rule normalises COLLISIONS; it does not lower-case a shop's
        // "ABS" into "abs".
        #expect(Tags.normalise("ABS, PLA+", known: []) == ["ABS", "PLA+"])
        #expect(Tags.normalise("abs", known: ["ABS"]) == ["ABS"])
    }

    // MARK: - tagCounts

    private func checkCounts(_ records: [JSONValue], _ what: String, _ js: JSModule) throws {
        let mine = Tags.counts(records)
        let v = try js.value("KhaytTags.tagCounts(ARG0)", [.array(records)])
        guard case .array(let rows) = v else { Issue.record("not an array"); return }
        let theirs: [Tags.Count] = rows.map { row in
            guard case .array(let pair) = row, pair.count == 2,
                  case .string(let label) = pair[0], case .number(let n) = pair[1]
            else { return .init(label: "<bad row>", count: -1) }
            return .init(label: label, count: Int(n))
        }
        #expect(mine == theirs, Comment(rawValue: "\(what)\n  swift \(mine)\n  js    \(theirs)"))
    }

    private func rec(_ tags: JSONValue...) -> JSONValue {
        .object(["tags": .array(tags)])
    }

    @Test("a drifted library folds to one chip with the real count")
    func countsFold() throws {
        let js = try js()
        try checkCounts([rec(.string("resin")), rec(.string("Resin")), rec(.string("RESIN")),
                         rec(.string("resin"), .string("pla")), rec(.string("PLA"))],
                        "a drifted shop", js)
    }

    @Test("the spelling shown is the one used most, and the first wins a tie")
    func mostUsedSpellingWins() throws {
        let js = try js()
        try checkCounts([rec(.string("Resin")), rec(.string("resin")), rec(.string("resin"))],
                        "resin ahead", js)
        try checkCounts([rec(.string("Resin")), rec(.string("resin"))], "a tie", js)
        try checkCounts([rec(.string("resin")), rec(.string("Resin"))], "a tie the other way", js)
    }

    @Test("one record naming a tag twice counts once for it")
    func onePerRecord() throws {
        let js = try js()
        try checkCounts([rec(.string("resin"), .string("Resin"), .string("RESIN")),
                         rec(.string("resin"))], "twice on one record", js)
    }

    @Test("equal counts sort by name the way a person reads them")
    func tiesSortByName() throws {
        // `localeCompare`, so "apple" comes before "Banana" — comparing code
        // points would put every capital first.
        let js = try js()
        try checkCounts([rec(.string("Banana")), rec(.string("apple")),
                         rec(.string("Cherry"))], "three ones", js)
        try checkCounts([rec(.string("زهرة")), rec(.string("apple")),
                         rec(.string("Émile"))], "mixed scripts", js)
    }

    @Test("records and tags that are not what they should be")
    func degenerateRecords() throws {
        let js = try js()
        try checkCounts([.null, .string("x"), .number(1), .bool(true), .array([]),
                         .object([:]), .object(["tags": .null]),
                         .object(["tags": .array([])]),
                         rec(.string(""), .string("  "), .null, .number(3), .bool(true)),
                         rec(.string("resin"))], "a mess", js)
        try checkCounts([], "nothing at all", js)
    }

    @Test("tags saved as a string are read letter by letter, as the other app reads them")
    func stringTagsIterate() throws {
        // Not a good answer — but it is the answer already in any book the
        // other app wrote, so the two must agree about it.
        let js = try js()
        try checkCounts([.object(["tags": .string("abc")]),
                         .object(["tags": .string("ab")])], "a string of tags", js)
    }

    // MARK: - hasTag

    @Test("a record carries a tag whatever either side's spelling")
    func hasTagMatches() throws {
        let js = try js()
        let records: [JSONValue] = [rec(.string("Resin"), .string("mini")),
                                    rec(), .object([:]), .null,
                                    rec(.number(3)), rec(.string(" resin "))]
        for record in records {
            for tag in ["resin", "RESIN", " Resin ", "mini", "", "  ", "3", "nope"] {
                let mine = Tags.has(record, tag: .string(tag))
                let theirs = try js.value("KhaytTags.hasTag(ARG0, ARG1)", [record, .string(tag)])
                #expect(.bool(mine) == theirs,
                        Comment(rawValue: "\(tag.debugDescription) on \(record)"))
            }
        }
    }

    @Test("the key is the same string on both sides")
    func keyMatches() throws {
        let js = try js()
        for raw: JSONValue in [.string("Resin"), .string("  RESIN  "), .string(""),
                               .string("PLA+"), .null, .number(3), .bool(true),
                               .string("زهرة"), .string("Émile"), .array([]),
                               .object([:])] {
            let theirs = try js.value("KhaytTags.tagKey(ARG0)", [raw])
            #expect(.string(Tags.key(raw)) == theirs, Comment(rawValue: "\(raw)"))
        }
    }
}
