import Foundation
import Testing
@testable import KhaytCore

/// Differential fuzz of the book's reader and writer against `JSONDecoder` /
/// `JSONEncoder` — the decoder as it was before (`JSONValueParseTests.Legacy`).
///
/// Bounded for CI. For a long local run set `KHAYT_JSON_FUZZ=<iterations>`
/// (and optionally `KHAYT_JSON_FUZZ_SEED`); every failure prints the input.
struct JSONValueFuzzTests {

    static var iterations: Int {
        Int(ProcessInfo.processInfo.environment["KHAYT_JSON_FUZZ"] ?? "") ?? 3_000
    }
    static var seed: UInt64 {
        UInt64(ProcessInfo.processInfo.environment["KHAYT_JSON_FUZZ_SEED"] ?? "") ?? 0x5EED_1861
    }

    typealias Rand = SyntheticBook.Rand

    // MARK: - generators

    /// Characters chosen to hit every branch of the string reader and writer.
    static let scalars: [String] = [
        "a", "Z", "0", " ", "\"", "\\", "/", "\u{08}", "\u{09}", "\u{0A}", "\u{0C}", "\u{0D}", "\u{00}",
        "\u{01}", "\u{1F}", "\u{7F}", "\u{80}", "\u{FF}", "é", "e\u{301}", "\u{2028}", "\u{2029}",
        "\u{FEFF}", "\u{FFFE}", "\u{FFFF}", "ملك", "😀", "\u{10FFFF}", "\u{1F1F8}\u{1F1E6}", "\u{D7FF}", "\u{E000}",
    ]

    /// A string spelled in JSON, valid or not, as raw text and escapes mixed.
    static func stringLiteral(_ r: inout Rand) -> String {
        var s = "\""
        for _ in 0..<r.int(8) {
            switch r.int(10) {
            case 0: s += "\\" + r.pick(["\"", "\\", "/", "b", "f", "n", "r", "t"])
            case 1: s += String(format: "\\u%04X", r.pick([0, 1, 0x1F, 0x20, 0x22, 0x2F, 0x5C, 0x7F, 0x80, 0xE9, 0x301,
                                                             0x2028, 0xD7FF, 0xE000, 0xFEFF, 0xFFFE, 0xFFFF, r.int(0x10000)]))
            case 2: // a surrogate pair, sometimes broken
                let hi = 0xD800 + r.int(0x400), lo = 0xDC00 + r.int(0x400)
                switch r.int(5) {
                case 0: s += String(format: "\\u%04x", hi)
                case 1: s += String(format: "\\u%04x", lo)
                case 2: s += String(format: "\\u%04x\\u%04x", lo, hi)
                case 3: s += String(format: "\\u%04x\\u%04x", hi, hi)
                default: s += String(format: "\\u%04x\\u%04x", hi, lo)
                }
            default:
                s += r.pick(scalars)
            }
        }
        return s + "\""
    }

    static func numberLiteral(_ r: inout Rand) -> String {
        let digits = Array("0123456789")
        switch r.int(6) {
        case 0:
            return r.pick(["0", "-0", "0.0", "-0.0", "0e0", "-0E-0", "1E5", "1e22", "1e23", "-1e22", "9007199254740993",
                           "9007199254740992", "18014398509481985", "5e-324", "4e-324", "2e-324", "1e-400",
                           "1.7976931348623157e308", "1.8e308", "01", "-", "1.", ".1", "1e", "+1", "00", "-00",
                           "0.30000000000000004", "123456789012345678e-5", "1234567890123456789",
                           "12345678901234567890", "0.000001", "1e-7", "100000000000000000000000",
                           "4.35", "2.675", "1.0000000000000002", "8.98846567431158e307",
                           "4503599627370497.5", "9007199254740993e-22", "1e+0", "1e-0", "1e00001"])
        case 1:
            // Doubles as JSONEncoder spells them: the spelling round-trips.
            let d = Double(bitPattern: r.next() << 11 | r.next() & 0x7FF)
            return d.isFinite ? "\(d)" : "1"
        default:
            var s = r.int(3) == 0 ? "-" : ""
            if r.int(5) == 0 { s += "0" } else {
                for k in 0..<(1 + r.int(22)) { s.append(k == 0 ? digits[1 + r.int(9)] : digits[r.int(10)]) }
            }
            if r.int(2) == 0 { s += "."; for _ in 0..<(1 + r.int(22)) { s.append(digits[r.int(10)]) } }
            if r.int(3) == 0 { s += r.pick(["e", "E", "e+", "e-", "E+"]) + String(r.int(r.int(2) == 0 ? 30 : 400)) }
            return s
        }
    }

    static func space(_ r: inout Rand) -> String {
        r.int(4) != 0 ? "" : r.pick([" ", "\n", "\r\n", "\t", "  \n\t", "\u{0C}", "\u{0B}", "\u{A0}"])
    }

    /// JSON text, valid most of the time, built from the generators above.
    static func text(_ r: inout Rand, depth: Int = 0) -> String {
        let pick = depth > 5 ? r.int(5) : r.int(8)
        switch pick {
        case 0: return stringLiteral(&r)
        case 1: return numberLiteral(&r)
        case 2: return r.pick(["true", "false", "null"])
        case 3: return stringLiteral(&r)
        case 4: return numberLiteral(&r)
        case 5, 6:
            var parts: [String] = []
            for _ in 0..<r.int(5) {
                // Keys that collide: plain repeats, NFC against NFD.
                let key = r.int(4) == 0 ? r.pick(["\"a\"", "\"é\"", "\"e\u{301}\"", "\"\\u00e9\"", "\"\""])
                    : stringLiteral(&r)
                parts.append(space(&r) + key + space(&r) + ":" + space(&r) + text(&r, depth: depth + 1) + space(&r))
            }
            return "{" + parts.joined(separator: ",") + (r.int(30) == 0 ? ",}" : "}")
        default:
            var parts: [String] = []
            for _ in 0..<r.int(5) { parts.append(space(&r) + text(&r, depth: depth + 1) + space(&r)) }
            return "[" + parts.joined(separator: ",") + (r.int(30) == 0 ? ",]" : "]")
        }
    }

    /// A mutation of valid JSON: a byte changed, inserted, removed, or the
    /// text cut short.
    static func mutate(_ bytes: [UInt8], _ r: inout Rand) -> [UInt8] {
        var b = bytes
        let interesting: [UInt8] = [0x00, 0x09, 0x0A, 0x0D, 0x20, 0x22, 0x2C, 0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x3A,
                                    0x45, 0x5B, 0x5C, 0x5D, 0x65, 0x75, 0x7B, 0x7D, 0x7F, 0x80, 0xBF, 0xC0, 0xC1,
                                    0xC3, 0xE0, 0xED, 0xEF, 0xF0, 0xF4, 0xF5, 0xFE, 0xFF]
        for _ in 0..<(1 + r.int(3)) {
            switch r.int(5) {
            case 0 where !b.isEmpty: b[r.int(b.count)] = r.pick(interesting)
            case 1: b.insert(r.pick(interesting), at: r.int(b.count + 1))
            case 2 where !b.isEmpty: b.remove(at: r.int(b.count))
            case 3 where !b.isEmpty: b = Array(b.prefix(r.int(b.count)))
            case 4 where !b.isEmpty: b[r.int(b.count)] = UInt8(truncatingIfNeeded: r.next())
            default: break
            }
        }
        return b
    }

    /// A random value for the writer — every number finite.
    static func value(_ r: inout Rand, depth: Int = 0) -> JSONValue {
        switch depth > 4 ? r.int(4) : r.int(6) {
        case 0:
            var s = ""
            for _ in 0..<r.int(6) {
                if r.int(4) == 0, let u = Unicode.Scalar(UInt32(r.int(0x110000))) { s.unicodeScalars.append(u) }
                else { s += r.pick(scalars) }
            }
            return .string(s)
        case 1:
            switch r.int(4) {
            case 0: return .number(Double(r.int(2_000_000)) - 1_000_000)
            case 1: return .number(r.pick([0, -0.0, 1e-7, 1e16, 9007199254740992, 9007199254740993, -9007199254740991,
                                           1e21, 1e22, 1e23, 5e-324, .greatestFiniteMagnitude, 0.1, 1.5, 123456.789]))
            default:
                let d = Double(bitPattern: r.next() << 11 | r.next() & 0x7FF)
                return .number(d.isFinite ? d : 0)
            }
        case 2: return r.int(3) == 0 ? .null : .bool(r.int(2) == 0)
        case 3: return .string(r.pick(["", "/", "a/b", "\\", "\"", "\u{7F}", "\u{2028}"]))
        case 4:
            var o: [String: JSONValue] = [:]
            for _ in 0..<r.int(5) {
                guard case .string(let k) = value(&r, depth: 99) else { continue }
                o[k] = value(&r, depth: depth + 1)
            }
            return .object(o)
        default:
            return .array((0..<r.int(5)).map { _ in value(&r, depth: depth + 1) })
        }
    }

    // MARK: - the comparison

    /// nil when the fast path agrees with the old decoder on `data`; a
    /// description of the difference otherwise.
    static func disagreement(_ data: Data) -> String? {
        let legacy = (try? JSONDecoder().decode(JSONValueParseTests.Legacy.self, from: data))?.value
        let fast = FastJSON.parse(data)
        let parsed = try? JSONValue.parse(data)
        if let fast {
            guard let legacy else { return "fast read what JSONDecoder refuses" }
            if !JSONValueParseTests.same(fast, legacy) { return "fast \(fast) vs legacy \(legacy)" }
        }
        switch (parsed, legacy) {
        case (nil, nil): return nil
        case (let p?, let l?): return JSONValueParseTests.same(p, l) ? nil : "parse \(p) vs legacy \(l)"
        default: return "parse \(String(describing: parsed)) vs legacy \(String(describing: legacy))"
        }
    }

    static func show(_ data: Data) -> String {
        String(data: data, encoding: .utf8).map { $0.debugDescription } ?? data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - tests

    @Test("fuzz: generated JSON, valid and not, reads as JSONDecoder reads it")
    func generated() {
        var r = Rand(state: Self.seed)
        var wrong: [String] = []
        var fastHits = 0
        for _ in 0..<Self.iterations {
            let data = Data((Self.space(&r) + Self.text(&r) + Self.space(&r)).utf8)
            if FastJSON.parse(data) != nil { fastHits += 1 }
            if let why = Self.disagreement(data) { wrong.append("\(Self.show(data)): \(why)") }
            if wrong.count > 10 { break }
        }
        #expect(wrong.isEmpty, "\(wrong)")
        // The fuzz must exercise the fast path, not only the fallback.
        #expect(fastHits > Self.iterations / 5, "fast path taken \(fastHits) times")
    }

    @Test("fuzz: mutations of valid JSON read as JSONDecoder reads them")
    func mutated() throws {
        var r = Rand(state: Self.seed &+ 1)
        var wrong: [String] = []
        for _ in 0..<Self.iterations {
            let base = try JSONValue.encode(Self.value(&r))
            let data = Data(Self.mutate(Array(base), &r))
            if let why = Self.disagreement(data) { wrong.append("\(Self.show(data)): \(why)") }
            if wrong.count > 10 { break }
        }
        #expect(wrong.isEmpty, "\(wrong)")
    }

    @Test("fuzz: random bytes read as JSONDecoder reads them")
    func randomBytes() {
        var r = Rand(state: Self.seed &+ 2)
        let alphabet = Array("{}[],:\"\\0123456789-+.eEtrufalsn \n\u{7}".utf8) + [0xC3, 0xA9, 0xFF, 0x00]
        var wrong: [String] = []
        for _ in 0..<Self.iterations {
            let bytes = (0..<r.int(24)).map { _ in r.pick(alphabet) }
            let data = Data(bytes)
            if let why = Self.disagreement(data) { wrong.append("\(Self.show(data)): \(why)") }
            if wrong.count > 10 { break }
        }
        #expect(wrong.isEmpty, "\(wrong)")
    }

    @Test("fuzz: the writer spells what JSONEncoder spells, and reads back to the same value")
    func writer() throws {
        var r = Rand(state: Self.seed &+ 3)
        var wrong: [String] = []
        for _ in 0..<Self.iterations {
            let v = Self.value(&r)
            let fast = try JSONValue.encode(v)
            let slow = try JSONEncoder().encode(v)
            // Same length (key order aside, the spelling is the same).
            if fast.count != slow.count { wrong.append("length \(Self.show(fast)) vs \(Self.show(slow))") }
            // Scalars have no key order: byte for byte.
            switch v {
            case .object, .array: break
            default: if fast != slow { wrong.append("\(Self.show(fast)) vs \(Self.show(slow))") }
            }
            let back = try JSONDecoder().decode(JSONValueParseTests.Legacy.self, from: fast).value
            if !JSONValueParseTests.same(back, v) { wrong.append("round trip \(v) -> \(Self.show(fast))") }
            if wrong.count > 10 { break }
        }
        #expect(wrong.isEmpty, "\(wrong)")
    }

    @Test("nesting past the fast reader's limit reads as JSONDecoder reads it")
    func deepNesting() {
        for depth in [63, 64, 65, 66, 200] {
            for (open, close) in [("[", "]"), ("{\"k\":", "}")] {
                let text = String(repeating: open, count: depth) + "1" + String(repeating: close, count: depth)
                #expect(Self.disagreement(Data(text.utf8)) == nil, "depth \(depth) \(open)")
            }
        }
    }
}
