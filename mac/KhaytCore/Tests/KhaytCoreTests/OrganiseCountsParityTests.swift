import Foundation
import Testing
@testable import KhaytCore

/// Counting groups and categories in Swift, against the JavaScript it came
/// from (`lib/organise.js counts`).
///
/// The real module is loaded out of `lib/` and both are run on the same
/// records. The records are generated, from a pool of the values a field can
/// really hold and the ones nobody means it to: missing, null, a number, a
/// list, a name that is all spaces, the same name in three spellings.
@MainActor
struct OrganiseCountsParityTests {

    private func js() throws -> JSModule { try JSModule(["organise"]) }

    // MARK: - The pools

    /// Names as a shop types them, and as a shop would never mean to.
    static let names: [String] = [
        "Busts", "busts", "BUSTS", " Busts ", "Busts ", "  busts", "Bu sts", "Bu  sts", "Bu\tsts", "Bu\nsts",
        "Functional parts", "functional  parts", "Functional\u{00A0}parts", "Functional\u{3000}parts",
        "Toys", "toys", "TOYS", "Tóys", "To\u{0301}ys", "Töys",
        "Saudi Kings", "saudi kings", "Saudi Kings — full set",
        "", " ", "   ", "\t", "\n", "\u{FEFF}", "\u{FEFF}Busts", "Busts\u{FEFF}", "\u{2028}Busts\u{2029}",
        "\u{0085}Busts", "Busts\u{0085}", "\u{200B}Busts", "Busts\u{180E}",
        "العائلة المالكة", "العائلة  المالكة", "مجسمات", "أدوات", "ادوات",
        "ΟΔΟΣ", "οδος", "οδοσ", "Σ", "σ", "ς", "ΑΣ ΒΣ", "ας βς", "ΑΣ.", "Σα", "A\u{0301}Σ", "ΑΣ\u{0301}", "ΑΣ\u{0301}Β",
        "İstanbul", "istanbul", "i\u{0307}stanbul", "ISTANBUL", "ıstanbul", "IJSSEL", "Straße", "STRASSE", "straße", "ǅ", "ǆ", "Ǆ",
        "ÉMILE", "émile", "Émile", "ÀÉÎÕÜ", "àéîõü", "ДОМ", "дом", "Дом", "ԱԲԳ", "աբգ",
        "0", "00", "1", "1.5", "-1", "true", "false", "null", "undefined", "NaN", "[object Object]", "1,2",
        "a", "A", "b", "B", "a b", "A B", "a-b", "a_b", "a.b", "a,b", "(a)", "#a", "a1", "a10", "a2", "A1",
        "résumé", "resume", "Resume", "RÉSUMÉ", "zebra", "Zebra", "apple", "Apple", "Banana", "banana", "cherry",
        "😀", "😀 faces", "Faces 😀", "👨‍👩‍👧 family", "🇸🇦", "ｆｕｌｌ", "ＦＵＬＬ", "ß", "ẞ", "ﬁ", "FI", "fi",
        "PLA+", "pla+", "PLA", "PETG / ASA", "petg / asa", "50%", "a\u{0000}b", "tab\there", "quote\"d", "back\\slash",
        String(repeating: "A", count: 59), String(repeating: "A", count: 60), String(repeating: "A", count: 61),
        String(repeating: "a", count: 60), String(repeating: "A", count: 200),
        String(repeating: "A", count: 59) + " B", String(repeating: "A", count: 58) + "  B",
        String(repeating: "A", count: 60) + " B", String(repeating: "A", count: 59) + "\tB",
        String(repeating: " ", count: 70) + "late", String(repeating: "A ", count: 40),
        String(repeating: "ك", count: 61), String(repeating: "é", count: 61), String(repeating: "e\u{0301}", count: 31),
        // An emoji is two UTF-16 units: these end exactly at, just before and
        // across the cut.
        String(repeating: "A", count: 58) + "😀", String(repeating: "A", count: 58) + "😀B",
        String(repeating: "😀", count: 30), String(repeating: "😀", count: 31),
        String(repeating: "A", count: 57) + " 😀",
        String(repeating: "A", count: 59) + "😀", String(repeating: "A", count: 58) + " 😀",
    ]

    /// What a field can hold that is not a name.
    static let oddValues: [JSONValue] = [
        .null, .bool(true), .bool(false), .number(0), .number(-0.0), .number(1), .number(-1), .number(1.5),
        .number(1e21), .number(1e-7), .number(123_456_789.987), .number(0.1 + 0.2),
        .array([]), .array([.string("Busts")]), .array([.string("Busts"), .string("Toys")]),
        .array([.null, .string("a"), .null]), .array([.number(1), .array([.number(2), .number(3)])]),
        .array([.object([:])]), .object([:]), .object(["category": .string("Busts")]),
        .object(["toString": .string("Busts")]),
    ]

    static var values: [JSONValue] { names.map(JSONValue.string) + oddValues }

    /// Rows that are not records at all.
    static let notRecords: [JSONValue] = [
        .null, .bool(true), .bool(false), .number(0), .number(-0.0), .number(1), .number(42.5),
        .string(""), .string("Busts"), .string(" "), .array([]), .array([.string("Busts")]),
        .array([.object(["category": .string("Busts")])]),
    ]

    /// A small generator with a fixed seed: the same records on every run and
    /// every machine, so a failure can be found again.
    struct Dice {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
        mutating func pick<T>(_ from: [T]) -> T { from[below(from.count)] }
    }

    static func record(_ dice: inout Dice, from pool: [JSONValue]) -> JSONValue {
        if dice.below(12) == 0 { return dice.pick(notRecords) }
        var r: [String: JSONValue] = ["id": .string("r\(dice.below(10_000))"), "name": .string("a model")]
        // Each field: usually there, sometimes missing.
        if dice.below(5) != 0 { r["category"] = dice.pick(pool) }
        if dice.below(3) != 0 { r["group"] = dice.pick(pool) }
        if dice.below(3) == 0 { r["folder"] = dice.pick(pool) }
        return .object(r)
    }

    // MARK: - Comparing

    private func rows(_ v: JSONValue) -> [Organise.Count] {
        guard case .array(let rows) = v else { return [.init(label: "<not an array>", count: -1)] }
        return rows.map { row in
            guard case .array(let pair) = row, pair.count == 2,
                  case .string(let label) = pair[0], case .number(let n) = pair[1]
            else { return .init(label: "<bad row>", count: -1) }
            return .init(label: label, count: Int(n))
        }
    }

    /// Labels compared unit for unit: Swift's `==` calls "é" and "e" + accent
    /// the same string and JavaScript does not.
    private func same(_ a: [Organise.Count], _ b: [Organise.Count]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy {
            $0.count == $1.count && Array($0.label.utf16) == Array($1.label.utf16)
        }
    }

    /// The same rows with the same counts, most-used first, but two names
    /// with EQUAL counts may stand in either order.
    ///
    /// That last order is a collation: `localeCompare` in JavaScript,
    /// `localizedCompare` here, as in `Tags.counts`. They are two libraries'
    /// readings of one standard and they agree on the names a shop types
    /// (`tiesSortByName` holds them to that, strictly). On names nobody
    /// types they can part: a lone "ς" sorts after "Σ" there and before it
    /// here. So the generated libraries, which are full of such names, are
    /// held to everything except that.
    private func sameButForTies(_ a: [Organise.Count], _ b: [Organise.Count]) -> Bool {
        guard a.count == b.count, a.map(\.count) == b.map(\.count) else { return false }
        func bag(_ rows: [Organise.Count]) -> [String] {
            rows.map { "\($0.count)|" + $0.label.utf16.map { String($0, radix: 16) }.joined(separator: ".") }.sorted()
        }
        return bag(a) == bag(b)
    }

    private func show(_ rows: [Organise.Count]) -> String {
        rows.map { "\($0.label.debugDescription)×\($0.count)" }.joined(separator: ", ")
    }

    /// Both counts of the same records, by both fields. When the JavaScript
    /// throws, or its answer cannot be read back, the port must throw too.
    private func check(_ records: [JSONValue], _ what: String, _ js: JSModule,
                       tiesInAnyOrder: Bool = false) throws {
        for field in Organise.Field.allCases {
            let mine = try? Organise.counts(records, field: field)
            let theirs = (try? js.value("KhaytOrganise.counts(ARG0, ARG1)",
                                        [.array(records), .string(field.rawValue)])).map(rows)
            guard let mine, let theirs else {
                #expect((mine == nil) == (theirs == nil), Comment(rawValue:
                    "\(what), \(field.rawValue): swift \(mine == nil ? "threw" : "answered"), "
                    + "js \(theirs == nil ? "threw" : "answered")"))
                continue
            }
            #expect(tiesInAnyOrder ? sameButForTies(mine, theirs) : same(mine, theirs),
                    Comment(rawValue: "\(what), \(field.rawValue)\n  swift \(show(mine))\n  js    \(show(theirs))"))
        }
    }

    /// One read, both ways: the same text, or both refuse.
    private func checkRead(_ mine: String?, _ expression: String, _ arg: JSONValue,
                           _ js: JSModule) {
        let theirs = try? js.value(expression, [arg])
        guard let mine, case .string(let s)? = theirs else {
            #expect((mine == nil) == (theirs == nil), Comment(rawValue:
                "\(expression) on \(arg): swift \(mine == nil ? "threw" : "answered"), js \(theirs == nil ? "threw" : "answered")"))
            return
        }
        #expect(Array(mine.utf16) == Array(s.utf16),
                Comment(rawValue: "\(expression) on \(arg)\n  swift \(mine.debugDescription)\n  js    \(s.debugDescription)"))
    }

    // MARK: - The reads

    @Test("every value a field can hold reads as the same name")
    func oneValueAtATime() throws {
        let js = try js()
        for value in Self.values {
            checkRead(try? Organise.normalise(value), "KhaytOrganise.normalise(ARG0)", value, js)
            for record in [JSONValue.object(["category": value]), .object(["group": value]),
                           .object(["folder": value]), .object(["folder": value, "group": .string("Other")]),
                           .object(["group": value, "folder": .string("")]),
                           .object(["group": value, "folder": .null]),
                           .object(["group": value, "folder": .number(3)])] {
                checkRead(try? Organise.categoryOf(record), "KhaytOrganise.categoryOf(ARG0)", record, js)
                checkRead(try? Organise.groupOf(record), "KhaytOrganise.groupOf(ARG0)", record, js)
            }
        }
    }

    @Test("a row that is not a record reads the way the other app reads it")
    func notARecord() throws {
        // `rec && rec.category` hands a falsy row on as itself, so the number
        // 0 in a list of models is filed under "0". Odd, and copied.
        let js = try js()
        for row in Self.notRecords {
            checkRead(try? Organise.categoryOf(row), "KhaytOrganise.categoryOf(ARG0)", row, js)
            checkRead(try? Organise.groupOf(row), "KhaytOrganise.groupOf(ARG0)", row, js)
        }
        #expect(try Organise.categoryOf(.number(0)) == "0")
        #expect(try Organise.categoryOf(.bool(false)) == "false")
        #expect(try Organise.categoryOf(.number(5)) == "")
        try check(Self.notRecords, "rows that are not records", js)
    }

    @Test("a name the JavaScript cannot turn into text stops the whole count, there and here")
    func notText() throws {
        // `String({toString: 'x'})` is a TypeError: nothing from JSON is a
        // function, so the object has a `toString` that cannot be called. The
        // old call threw, its callers showed no chips, and the port does the
        // same rather than quietly counting what the other app cannot.
        let js = try js()
        let bad: [JSONValue] = [.object(["toString": .string("Busts")]), .object(["toString": .null]),
                                .array([.string("a"), .object(["toString": .number(1)])]),
                                .array([.array([.object(["toString": .bool(true)])])])]
        let fine: [JSONValue] = [.object(["valueOf": .string("Busts")]), .object(["tostring": .string("x")]),
                                 .array([.object(["valueOf": .number(1)])])]
        for value in bad + fine {
            checkRead(try? Organise.normalise(value), "KhaytOrganise.normalise(ARG0)", value, js)
            try check([.object(["category": .string("Busts")]), .object(["category": value, "group": value]),
                       .object(["category": .string("Toys")])], "a name that is \(value)", js)
        }
        for value in bad {
            #expect(throws: Organise.Unreadable.notText) { try Organise.normalise(value) }
            #expect(throws: Organise.Unreadable.notText) {
                try Organise.counts([.object(["category": value])], field: .category)
            }
        }
        for value in fine { #expect(try Organise.normalise(value) == "[object Object]") }
    }

    @Test("two spellings are one name exactly when the other app says so")
    func keysMatch() throws {
        let js = try js()
        // Every name in the pool, and every letter of the scripts a shop's
        // names are written in: Latin and its extensions, Greek, Cyrillic,
        // Armenian, Arabic, the punctuation and the spaces.
        var texts = Self.names
        for range in [0x0020...0x024F, 0x0370...0x058F, 0x0600...0x06FF, 0x1E00...0x1FFF,
                      0x2000...0x206F, 0x2C60...0x2C7F, 0xFF00...0xFF5E] {
            for v in range {
                guard let u = Unicode.Scalar(v) else { continue }
                texts.append(String(u))
                texts.append("a" + String(u) + "b")
                texts.append("Α" + String(u))
            }
        }
        let theirs = try js.value("ARG0.map(KhaytOrganise.nameKey)", [.array(texts.map(JSONValue.string))])
        guard case .array(let keys) = theirs, keys.count == texts.count else { Issue.record("no keys"); return }
        var wrong: [String] = []
        for (text, key) in zip(texts, keys) {
            guard case .string(let k) = key else { continue }
            let mine = Organise.key(text)
            if Array(mine.utf16) != Array(k.utf16) {
                wrong.append("\(text.unicodeScalars.map { String($0.value, radix: 16) }): swift \(mine.debugDescription) js \(k.debugDescription)")
            }
        }
        #expect(wrong.isEmpty, Comment(rawValue: "\(wrong.count) keys differ:\n" + wrong.prefix(40).joined(separator: "\n")))
    }

    // MARK: - The counts

    @Test("a drifted library folds to one chip with the real count")
    func folds() throws {
        let js = try js()
        let cat: (String) -> JSONValue = { .object(["category": .string($0), "group": .string($0)]) }
        try check([cat("Busts"), cat("busts"), cat("BUSTS"), cat(" Busts "), cat("Toys")], "a drifted shop", js)
        // The spelling used most is the label; the first seen wins a tie.
        try check([cat("Busts"), cat("busts"), cat("busts")], "busts ahead", js)
        try check([cat("Busts"), cat("busts")], "a tie", js)
        try check([cat("busts"), cat("Busts")], "a tie the other way", js)
        try check([cat("Toys"), cat("busts"), cat("Busts"), cat("toys"), cat("TOYS"), cat("BUSTS")], "two ties", js)
        try check([], "nothing at all", js)
        try check([.object([:]), .object(["category": .string("")]), .object(["category": .null])], "nothing filed", js)
        #expect(try Organise.counts([cat("Busts"), cat("busts"), cat("busts"), cat("Toys")], field: .category)
                == [.init(label: "busts", count: 3), .init(label: "Toys", count: 1)])
    }

    @Test("folder wins over group, even when it is empty")
    func folderWins() throws {
        let js = try js()
        let records: [JSONValue] = [
            .object(["group": .string("Dental"), "folder": .string("Saudi Kings")]),
            .object(["group": .string("Saudi Kings"), "folder": .string("")]),
            .object(["group": .string("Dental")]),
            .object(["folder": .string("saudi kings")]),
            .object(["group": .string("Dental"), "folder": .null]),
            .object(["group": .string("Dental"), "folder": .number(1)]),
            .object(["group": .string("Dental"), "folder": .array([.string("Saudi Kings")])]),
        ]
        try check(records, "two machines, one on an older build", js)
        #expect(try Organise.counts(records, field: .group)
                == [.init(label: "Dental", count: 4), .init(label: "Saudi Kings", count: 2)])
    }

    @Test("equal counts sort by name the way the other app sorts them")
    func tiesSortByName() throws {
        // Strict: the same order, name for name. On the names a shop types.
        let js = try js()
        let one: (String) -> JSONValue = { .object(["category": .string($0)]) }
        try check(["Banana", "apple", "Cherry"].map(one), "three ones", js)
        try check(["زهرة", "apple", "Émile", "مجسمات", "Zebra", "a10", "a2", "(a)", "#a", "50%"].map(one), "mixed scripts", js)
        let typed = ["Busts", "Functional parts", "Toys", "Tóys", "Töys", "Saudi Kings", "Saudi Kings — full set",
                     "العائلة المالكة", "مجسمات", "أدوات", "ادوات", "ÉMILE", "ДОМ", "résumé", "resume",
                     "zebra", "apple", "Banana", "cherry", "0", "00", "1", "1.5", "-1", "a", "b", "a b", "a-b",
                     "a_b", "a.b", "a,b", "a1", "a10", "a2", "PLA+", "PLA", "PETG / ASA", "50%", "Straße",
                     "İstanbul", "istanbul", "ıstanbul", "true", "false", "null", "[object Object]"]
        try check(typed.map(one), "every typed name once", js)
        try check(typed.reversed().map(one), "every typed name once, backwards", js)
        // Everything else in the pool, once each: the same rows, ties in any order.
        var seen: Set<String> = []
        let distinct = Self.names.filter { name in
            guard let n = try? Organise.normalise(.string(name)) else { return false }
            let k = Organise.key(n)
            return !k.isEmpty && seen.insert(k).inserted
        }
        try check(distinct.map(one), "every name once", js, tiesInAnyOrder: true)
    }

    @Test("generated libraries, hundreds of them")
    func generated() throws {
        let js = try js()
        var dice = Dice(state: 0x4B48_4159_54)
        // A few names used a lot (a real library), then everything at once.
        let plain: [JSONValue] = ["Busts", "busts", "Toys", "Functional parts", "العائلة المالكة", "Saudi Kings",
                                  "saudi kings", "", " Busts "].map(JSONValue.string) + [.null]
        for n in 0..<120 {
            let size = [0, 1, 2, 3, 7, 30, 150][n % 7]
            let records = (0..<size).map { _ in Self.record(&dice, from: plain) }
            try check(records, "plain library \(n)", js)
        }
        for n in 0..<240 {
            let size = [1, 2, 5, 12, 40, 90][n % 6]
            let records = (0..<size).map { _ in Self.record(&dice, from: Self.values) }
            try check(records, "odd library \(n)", js, tiesInAnyOrder: true)
        }
    }

    @Test("a library of thousands, as a real shop's is")
    func large() throws {
        let js = try js()
        var dice = Dice(state: 14_695)
        let pool = (0..<40).map { JSONValue.string("Category \($0)") }
            + ["category 3", "CATEGORY 3", " Category 7"].map(JSONValue.string) + [.null, .string("")]
        let records = (0..<6_000).map { _ in Self.record(&dice, from: pool) }
        try check(records, "six thousand models", js)
    }

    // MARK: - Half a character

    @Test("a name cut through the middle of an emoji stops the count, as it did")
    func halfACharacter() throws {
        // `slice(0, 60)` counts UTF-16 units and an emoji is two, so a name
        // whose 60th unit is the first half of one is cut through it.
        let js = try js()
        let cut = String(repeating: "A", count: 59) + "😀"
        #expect(try js.int("KhaytOrganise.normalise(ARG0).length", [.string(cut)]) == 60)
        #expect(try js.int("KhaytOrganise.normalise(ARG0).charCodeAt(59)", [.string(cut)]) == 0xD83D,
                "the JavaScript keeps the first half of the pair")
        // Half a character does not survive the trip back: the answer is
        // JSON, and JSON with a lone surrogate in it is not read. So the old
        // call failed for the whole library, and the port fails the same way.
        let record = JSONValue.object(["category": .string(cut)])
        #expect((try? js.value("KhaytOrganise.counts(ARG0, 'category')", [.array([record])])) == nil)
        #expect(throws: Organise.Unreadable.halfCharacter) { try Organise.normalise(.string(cut)) }
        #expect(throws: Organise.Unreadable.halfCharacter) {
            try Organise.counts([.object(["category": .string("Busts")]), record], field: .category)
        }
        #expect(throws: Organise.Unreadable.halfCharacter) {
            try Organise.normalise(.string(String(repeating: "A", count: 58) + " 😀"))
        }
        // One unit earlier and the emoji fits whole.
        let fits = String(repeating: "A", count: 58) + "😀"
        #expect(try Organise.normalise(.string(fits + "B")) == fits)
        try check([record, .object(["category": .string("Busts")])], "a name cut in half", js)
    }

    // MARK: - The engine asks Swift

    @Test("the engine no longer hands the library to JavaScript to count it")
    func engineCountsNatively() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytCore/KhaytEngine.swift"), encoding: .utf8)
        #expect(!source.contains("\"KhaytOrganise\", \"counts\""),
                "the counts went back across the bridge: 24 MB per call on a large library")
        #expect(source.contains("Organise.counts(records, field: .category)"))
    }
}
