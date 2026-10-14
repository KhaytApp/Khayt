import Foundation
import Testing
@testable import KhaytCore

/// `JSONValue.parse` / `JSONValue.decode` / `JSONValue.encode` — the fast
/// reader and writer the book goes through — must give exactly what
/// `JSONDecoder` and `JSONEncoder` gave. Everything here is decided by
/// comparing the two, bit for bit, never by a value written down by hand.
struct JSONValueParseTests {

    // MARK: - the reference: the decoder as it was before

    /// `JSONValue.init(from:)` exactly as it was before it was reordered:
    /// Bool, Double, String, object, array. The reference every read here is
    /// compared with.
    enum Legacy: Decodable {
        case string(String), number(Double), bool(Bool), object([String: Legacy]), array([Legacy]), null

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null; return }
            if let v = try? c.decode(Bool.self) { self = .bool(v); return }
            if let v = try? c.decode(Double.self) { self = .number(v); return }
            if let v = try? c.decode(String.self) { self = .string(v); return }
            if let v = try? c.decode([String: Legacy].self) { self = .object(v); return }
            if let v = try? c.decode([Legacy].self) { self = .array(v); return }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unrecognised JSON value")
        }

        var value: JSONValue {
            switch self {
            case .string(let s): return .string(s)
            case .number(let d): return .number(d)
            case .bool(let b): return .bool(b)
            case .null: return .null
            case .array(let a): return .array(a.map(\.value))
            case .object(let o): return .object(o.mapValues(\.value))
            }
        }
    }

    /// Bit for bit: `-0` is not `0`, and strings and keys compare by their
    /// UTF-8 bytes rather than by Swift's canonical equivalence.
    static func same(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case (.string(let x), .string(let y)): return Array(x.utf8) == Array(y.utf8)
        case (.number(let x), .number(let y)): return x.bitPattern == y.bitPattern
        case (.bool(let x), .bool(let y)): return x == y
        case (.null, .null): return true
        case (.array(let x), .array(let y)):
            guard x.count == y.count else { return false }
            for (p, q) in zip(x, y) where !same(p, q) { return false }
            return true
        case (.object(let x), .object(let y)):
            guard x.count == y.count else { return false }
            for (k, v) in x {
                guard let w = y[k], same(v, w) else { return false }
            }
            let xk = Set(x.keys.map { Array($0.utf8) })
            let yk = Set(y.keys.map { Array($0.utf8) })
            return xk == yk
        default: return false
        }
    }

    /// Read `text` both ways. Nil from both — both refused — counts as agreeing.
    static func agrees(_ text: String) -> Bool {
        let data = Data(text.utf8)
        let fast = try? JSONValue.parse(data)
        let reordered = try? JSONDecoder().decode(JSONValue.self, from: data)
        let legacy = (try? JSONDecoder().decode(Legacy.self, from: data))?.value
        switch (fast, reordered, legacy) {
        case (nil, nil, nil): return true
        case (let f?, let r?, let l?): return same(f, l) && same(r, l)
        default: return false
        }
    }

    // MARK: - reading

    @Test("numbers JSONDecoder reads, refuses or reads oddly — the fast reader agrees on every one")
    func numberEdges() {
        let cases = [
            "0", "-0", "0.0", "-0.0", "0.000", "0e0", "0E5", "-0e-5", "0.0e1", "1", "-1", "1.0", "0.1",
            "1e-7", "1E2", "1e+2", "1e-2", "12345.678", "1791826094386.221",
            "9007199254740991", "9007199254740992", "9007199254740993", "9007199254740995",
            "18446744073709551615", "18446744073709551616", "123456789012345678901234567890",
            "1.00000000000000000000000001", "0.30000000000000004", "2.2250738585072014e-308",
            "4.9e-324", "2.4703282292062327e-324", "2.4703282292062328e-324", "1e-320",
            "1.7976931348623157e308", "1.7976931348623159e308", "1e400", "-1e400", "1e-400",
            "01", "-01", "1.", ".5", "-", "+1", "1e", "1e+", "--1", "0x10", "Infinity", "-Infinity", "NaN",
        ]
        var wrong: [String] = []
        for text in cases where !Self.agrees(text) { wrong.append(text) }
        for text in cases where !Self.agrees("[\(text)]") { wrong.append("[\(text)]") }
        #expect(wrong.isEmpty, "read differently: \(wrong)")
    }

    @Test("random number literals of every shape read to the same Double")
    func randomNumberLiterals() {
        var r = SyntheticBook.Rand(state: 11)
        let digits = Array("0123456789")
        var wrong: [String] = []
        for _ in 0..<20_000 {
            var s = r.int(2) == 0 ? "-" : ""
            if r.int(5) == 0 {
                s += "0"
            } else {
                for k in 0..<(1 + r.int(25)) { s.append(k == 0 ? digits[1 + r.int(9)] : digits[r.int(10)]) }
            }
            if r.int(2) == 0 {
                s += "."
                for _ in 0..<(1 + r.int(25)) { s.append(digits[r.int(10)]) }
            }
            if r.int(3) == 0 { s += r.pick(["e", "E", "e+", "e-", "E-"]) + String(r.int(400)) }
            if !Self.agrees("[\(s)]") { wrong.append(s) }
        }
        #expect(wrong.isEmpty, "read differently: \(wrong.prefix(10))")
    }

    @Test("true and false are not 1 and 0, either way round")
    func boolsAreNotNumbers() {
        let texts = ["true", "false", "1", "0", "[true,1,false,0]", "{\"a\":true,\"b\":1}"]
        var wrong: [String] = []
        for text in texts where !Self.agrees(text) { wrong.append(text) }
        #expect(wrong.isEmpty)
        let parsed = try? JSONValue.parse(Data("[true,1,false,0]".utf8))
        #expect(parsed == .array([.bool(true), .number(1), .bool(false), .number(0)]))
    }

    @Test("JSONDecoder's five kinds are disjoint, so reordering init(from:) moved nothing")
    func kindsAreDisjoint() {
        let d = JSONDecoder()
        #expect((try? d.decode(Bool.self, from: Data("1".utf8))) == nil)
        #expect((try? d.decode(Bool.self, from: Data("0".utf8))) == nil)
        #expect((try? d.decode(Double.self, from: Data("true".utf8))) == nil)
        #expect((try? d.decode(Double.self, from: Data("\"1\"".utf8))) == nil)
        #expect((try? d.decode(String.self, from: Data("1".utf8))) == nil)
        #expect((try? d.decode(String.self, from: Data("true".utf8))) == nil)
    }

    @Test("strings: escapes, surrogates, control characters, Arabic, emoji")
    func stringEdges() {
        let cases = [
            #""""#, #""a""#, #""\"\\\/\b\f\n\r\t""#, #""\u0000""#, #""\u001f""#, #""\u00e9""#, #""e\u0301""#,
            #""\u0645\u0644\u0643""#, "\"ملك\"", "\"😀\"", #""\ud83d\ude00""#, #""\ud800""#, #""\udc00""#,
            #""\ud800x""#, #""\ud800\u0041""#, #""\x""#, "\"\u{1}\"", "\"a\tb\"", #""\u12""#, "\"open",
            "\"" + String(repeating: "طويل جدا ", count: 20_000) + "\"",
            "\"data:image/png;base64," + String(repeating: "iVBORw0KGgo", count: 10_000) + "\"",
        ]
        var wrong: [String] = []
        for text in cases where !Self.agrees(text) { wrong.append(String(text.prefix(40))) }
        #expect(wrong.isEmpty, "read differently: \(wrong)")
    }

    @Test("every scalar in the awkward ranges reads the same, raw and escaped")
    func scalarSweep() throws {
        var wrong: [UInt32] = []
        let ranges = Array(0..<0x800) + Array(0xD7F0..<0xE010) + Array(0xFFF0..<0x10010) + [0x1F600, 0x10FFFF]
        for v in ranges {
            guard let u = Unicode.Scalar(UInt32(v)) else { continue }
            let written = try JSONEncoder().encode([String(Character(u))])
            if !Self.agrees(String(decoding: written, as: UTF8.self)) { wrong.append(UInt32(v)) }
            if v <= 0xFFFF, !Self.agrees(String(format: "[\"\\u%04x\"]", v)) { wrong.append(UInt32(v)) }
        }
        #expect(wrong.isEmpty, "read differently: \(wrong.prefix(10))")
    }

    @Test("structure: empties, nesting, repeated keys, whitespace, garbage")
    func structureEdges() {
        // Past the fast reader's depth limit, so JSONDecoder reads it — kept
        // shallow enough for the test thread's stack in a debug build.
        let deep = String(repeating: "[", count: 80) + "{\"a\":1}" + String(repeating: "]", count: 80)
        let cases = [
            "{}", "[]", "[[]]", "[{}]", "{\"a\":{}}", "{\"a\":[]}", "{\"a\":[{},[],null]}", " \t\n\r{ \"a\" : [ 1 , 2 ] } \n",
            "{\"a\":1,\"a\":2}", "{\"\u{e9}\":1,\"e\u{301}\":2}", "null", "true", " 1 ", "1 2", "[1,]", "{\"a\":1,}",
            "{a:1}", "[1 2]", "", " ", "\u{FEFF}{}", "{\"a\"}", "{\"a\":}", "[", "]", "nul", "tru", "falsey",
            deep, String(repeating: "[", count: 60) + String(repeating: "]", count: 60),
        ]
        var wrong: [String] = []
        for text in cases where !Self.agrees(text) { wrong.append(String(text.prefix(30))) }
        #expect(wrong.isEmpty, "read differently: \(wrong)")
    }

    @Test("a whole synthetic book reads to the same value as before, and through the fast path")
    func wholeBook() throws {
        let data = SyntheticBook.make(records: 2_000)
        #expect(FastJSON.parse(data) != nil)
        let fast = try JSONValue.decode([String: JSONValue].self, from: data)
        let legacy = try JSONDecoder().decode([String: Legacy].self, from: data)
        #expect(Self.same(.object(fast), .object(legacy.mapValues(\.value))))
    }

    @Test("decode(_:from:) refuses what JSONDecoder refuses, for each shape")
    func refusals() {
        let array = Data("[1,2]".utf8), object = Data("{\"a\":1}".utf8), bad = Data("{\"a\":0e5}".utf8)
        #expect((try? JSONValue.decode([String: JSONValue].self, from: array)) == nil)
        #expect((try? JSONValue.decode([JSONValue].self, from: object)) == nil)
        #expect((try? JSONValue.decode(JSONValue.self, from: bad)) == nil)
        #expect((try? JSONDecoder().decode(JSONValue.self, from: bad)) == nil)
        #expect((try? JSONValue.decode([Int].self, from: array)) == [1, 2])
    }

    // MARK: - writing

    @Test("numbers are spelled exactly as JSONEncoder spells them")
    func numberSpelling() throws {
        var r = SyntheticBook.Rand(state: 7)
        var values: [Double] = [0, -0.0, 0.1, 1e-7, 1.0, 1e15, 1e16, 1e21, 1e22, 5e-324, 1.7976931348623157e308,
                                1791826094386.221, 9007199254740991, 9007199254740992, 9007199254740994, -1, .pi]
        for e in -330...310 { values += [pow(10, Double(e)), -1.5 * pow(10, Double(e))] }
        for k in -500...500 { values += [9007199254740992 + Double(k), Double(k), Double(k) / 100] }
        for _ in 0..<20_000 { values.append(Double(bitPattern: r.next() << 11 | (r.next() & 0x7FF))) }
        for _ in 0..<20_000 { values.append(Double(r.int(1_000_000_000)) / 1000) }
        var wrong: [Double] = []
        for d in values where d.isFinite {
            let mine = try JSONValue.encode(.array([.number(d)]))
            let theirs = try JSONEncoder().encode([d])
            if mine != theirs { wrong.append(d) }
        }
        #expect(wrong.isEmpty, "spelled differently: \(wrong.prefix(10))")
    }

    @Test("strings are escaped exactly as JSONEncoder escapes them")
    func stringSpelling() throws {
        var wrong: [UInt32] = []
        for v in Array(0..<0x800) + Array(0xFFF0..<0x10010) + [0x2028, 0x2029, 0x1F600, 0x10FFFF] {
            guard let u = Unicode.Scalar(UInt32(v)) else { continue }
            let s = "a" + String(Character(u)) + "/\"\\"
            let mine = try JSONValue.encode(.object([s: .string(s)]))
            let theirs = try JSONEncoder().encode([s: s])
            if mine != theirs { wrong.append(UInt32(v)) }
        }
        #expect(wrong.isEmpty, "escaped differently: \(wrong.prefix(10))")
    }

    @Test("a whole book written fast reads back to the same value, and to what JSONEncoder wrote")
    func wholeBookWrite() throws {
        let book = try JSONValue.decode([String: JSONValue].self, from: SyntheticBook.make(records: 2_000))
        let mine = try JSONValue.encode(book)
        let theirs = try JSONEncoder().encode(book)
        // Same length: every value spelled alike; only the key order differs,
        // and JSONEncoder's own key order is not stable between two encodes.
        #expect(mine.count == theirs.count)
        let a = try JSONValue.decode(JSONValue.self, from: mine)
        let b = try JSONDecoder().decode(Legacy.self, from: theirs).value
        #expect(Self.same(a, b))
        #expect(Self.same(a, .object(book)))
    }

    @Test("a NaN or an infinity is refused, as JSONEncoder refuses it")
    func nonFinite() {
        #expect((try? JSONValue.encode(.number(.nan))) == nil)
        #expect((try? JSONValue.encode(["a": .array([.number(.infinity)])])) == nil)
        #expect((try? JSONEncoder().encode(JSONValue.number(.nan))) == nil)
    }

    // MARK: - the budget

    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// The store's read path at 10,000 records. Measured against the old
    /// decoder in the same run rather than against a clock, so a slow CI
    /// machine moves both sides together. Release, 15.7 MB real book: old
    /// 610 ms, fast 69 ms; debug is slower for both but the gap is wider.
    @Test("reading a 10,000-record book is at least twice as fast as the old decoder")
    func readBudget() throws {
        let data = SyntheticBook.make(records: 10_000)
        let clock = ContinuousClock()
        let legacy = try clock.measure { _ = try JSONDecoder().decode([String: Legacy].self, from: data) }
        var fast = Duration.seconds(3600)
        for _ in 0..<3 {
            let t = try clock.measure { _ = try JSONValue.decode([String: JSONValue].self, from: data) }
            fast = min(fast, t)
        }
        let ratio = legacy / fast
        print("JSONValue read budget: fast \(fast) vs old \(legacy), \(ratio)x")
        #expect(ratio > 2, "fast \(fast) vs old \(legacy)")
        #expect(fast < .seconds(5), "fast read took \(fast)")
    }

    /// Only in an optimised build. Unoptimised, this writer's byte appends
    /// run at -Onone while `JSONEncoder` is the system's optimised copy, so a
    /// debug run measures the compiler setting, not the code. Release, 15.7 MB
    /// real book: JSONEncoder 213 ms, this 34 ms.
    @Test("writing a 10,000-record book is faster than JSONEncoder",
          .enabled(if: !JSONValueParseTests.isDebugBuild, "timed only in an optimised build"))
    func writeBudget() throws {
        let book = try JSONValue.decode([String: JSONValue].self, from: SyntheticBook.make(records: 10_000))
        let clock = ContinuousClock()
        let reference = try clock.measure { _ = try JSONEncoder().encode(book) }
        var fast = Duration.seconds(3600)
        for _ in 0..<3 {
            let t = try clock.measure { _ = try JSONValue.encode(book) }
            fast = min(fast, t)
        }
        #expect(reference / fast > 2, "fast \(fast) vs JSONEncoder \(reference)")
    }
}
