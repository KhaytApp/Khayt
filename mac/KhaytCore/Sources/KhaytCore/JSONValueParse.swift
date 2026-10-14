import Foundation

// ── WHY THE BOOK HAS ITS OWN JSON READER ────────────────────────────────
//
// `JSONDecoder` asks `JSONValue.init(from:)` what each value is, and the only
// way a `Decodable` can find out is to try a type and catch the refusal. A
// refusal there is a `DecodingError` carrying the coding path, built for every
// miss, and the shop's book is ten thousand library records of strings and
// objects — so reading a 15 MB book raised millions of errors and took one to
// two and a half seconds, on every load, every scan and every write, on the
// Mac and on the phone.
//
// This reads the same text straight from its bytes, deciding each value by
// its first character, and builds the same `JSONValue`.
//
// ── THE SAME ANSWER, OR NONE AT ALL ─────────────────────────────────────
//
// It is not a second opinion about JSON. Whenever it meets anything outside
// the plain, common shape — a number it cannot read exactly, a lone surrogate,
// a repeated key, invalid UTF-8, a byte-order mark, deep nesting, anything it
// does not recognise — it gives up WITHOUT an answer, and `JSONValue.parse`
// hands the whole text to `JSONDecoder` as before. So a book it can read gets
// the value `JSONDecoder` would have produced, and a book it cannot read gets
// `JSONDecoder` itself, its errors included. `JSONValueParseTests` decodes the
// edge cases both ways and compares them bit for bit.

public extension JSONValue {

    /// Read JSON text — the same value `JSONDecoder().decode(JSONValue.self,
    /// from:)` gives, and the same error when there is one, only without the
    /// cost of a thrown error per value.
    static func parse(_ data: Data) throws -> JSONValue {
        if let value = FastJSON.parse(data) { return value }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// `JSONDecoder().decode(type, from: data)`, through the fast reader when
    /// `type` is one of the three shapes a `JSONValue` document comes in —
    /// `JSONValue`, `[String: JSONValue]` or `[JSONValue]` — and straight to
    /// `JSONDecoder` for anything else.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        if T.self == JSONValue.self, let value = FastJSON.parse(data) {
            return value as! T
        }
        if T.self == [String: JSONValue].self, case .object(let object)? = FastJSON.parse(data) {
            return object as! T
        }
        if T.self == [JSONValue].self, case .array(let array)? = FastJSON.parse(data) {
            return array as! T
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// The reader. `parse` returns nil — never a guess — for anything it is not
/// certain `JSONDecoder` would read to exactly the value it would build.
enum FastJSON {

    static func parse(_ data: Data) -> JSONValue? {
        data.withUnsafeBytes { raw -> JSONValue? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count > 0 else {
                return nil
            }
            var reader = Reader(base: base, end: raw.count)
            do {
                let value = try reader.value()
                reader.skipSpace()
                guard reader.i == reader.end else { return nil }
                return value
            } catch {
                return nil
            }
        }
    }

    struct GiveUp: Error {}

    /// A book is a handful of levels deep. Anything deeper than this is read
    /// by `JSONDecoder`, as before — so this reader's recursion stays small on
    /// a background thread's 512 KB stack, and the nesting limit, and the
    /// answer past it, remain `JSONDecoder`'s own.
    static let maxDepth = 64

    struct Reader {
        let base: UnsafePointer<UInt8>
        let end: Int
        var i = 0
        var depth = 0
        /// Reused across escaped strings so each one does not allocate.
        var scratch: [UInt8] = []

        init(base: UnsafePointer<UInt8>, end: Int) {
            self.base = base
            self.end = end
        }

        @inline(__always)
        mutating func skipSpace() {
            while i < end {
                switch base[i] {
                case 0x20, 0x0A, 0x0D, 0x09: i += 1
                default: return
                }
            }
        }

        mutating func value() throws(GiveUp) -> JSONValue {
            skipSpace()
            guard i < end else { throw GiveUp() }
            switch base[i] {
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try number())
            default: throw GiveUp()
            }
        }

        mutating func literal(_ word: StaticString) throws(GiveUp) {
            let n = word.utf8CodeUnitCount
            guard end - i >= n else { throw GiveUp() }
            let w = word.utf8Start
            for k in 0..<n where base[i + k] != w[k] { throw GiveUp() }
            i += n
        }

        mutating func object() throws(GiveUp) -> JSONValue {
            depth += 1
            guard depth <= FastJSON.maxDepth else { throw GiveUp() }
            i += 1
            var out: [String: JSONValue] = [:]
            skipSpace()
            if i < end, base[i] == UInt8(ascii: "}") {
                i += 1; depth -= 1
                return .object(out)
            }
            while true {
                skipSpace()
                guard i < end, base[i] == UInt8(ascii: "\"") else { throw GiveUp() }
                let key = try string()
                skipSpace()
                guard i < end, base[i] == UInt8(ascii: ":") else { throw GiveUp() }
                i += 1
                let v = try value()
                // A repeated key — or two spellings Swift calls the same
                // string, like a precomposed and a decomposed "é". Which one
                // survives is `JSONDecoder`'s business, so it is asked.
                if out.updateValue(v, forKey: key) != nil { throw GiveUp() }
                skipSpace()
                guard i < end else { throw GiveUp() }
                if base[i] == UInt8(ascii: ",") { i += 1; continue }
                if base[i] == UInt8(ascii: "}") { i += 1; break }
                throw GiveUp()
            }
            depth -= 1
            return .object(out)
        }

        mutating func array() throws(GiveUp) -> JSONValue {
            depth += 1
            guard depth <= FastJSON.maxDepth else { throw GiveUp() }
            i += 1
            var out: [JSONValue] = []
            skipSpace()
            if i < end, base[i] == UInt8(ascii: "]") {
                i += 1; depth -= 1
                return .array(out)
            }
            while true {
                out.append(try value())
                skipSpace()
                guard i < end else { throw GiveUp() }
                if base[i] == UInt8(ascii: ",") { i += 1; continue }
                if base[i] == UInt8(ascii: "]") { i += 1; break }
                throw GiveUp()
            }
            depth -= 1
            return .array(out)
        }

        /// A string, from its opening quote. Escapes are decoded; anything
        /// that is not plainly valid — a raw control character, invalid UTF-8,
        /// a surrogate without its partner — gives up.
        mutating func string() throws(GiveUp) -> String {
            i += 1
            let start = i
            while i < end {
                let c = base[i]
                if c == UInt8(ascii: "\"") {
                    let bytes = UnsafeBufferPointer(start: base + start, count: i - start)
                    i += 1
                    guard let s = String(validating: bytes, as: UTF8.self) else { throw GiveUp() }
                    return s
                }
                if c == UInt8(ascii: "\\") { return try escapedString(from: start) }
                if c < 0x20 { throw GiveUp() }
                i += 1
            }
            throw GiveUp()
        }

        mutating func escapedString(from start: Int) throws(GiveUp) -> String {
            scratch.removeAll(keepingCapacity: true)
            scratch.append(contentsOf: UnsafeBufferPointer(start: base + start, count: i - start))
            while i < end {
                let c = base[i]
                if c == UInt8(ascii: "\"") {
                    i += 1
                    guard let s = String(validating: scratch, as: UTF8.self) else { throw GiveUp() }
                    return s
                }
                if c < 0x20 { throw GiveUp() }
                if c != UInt8(ascii: "\\") { scratch.append(c); i += 1; continue }
                i += 1
                guard i < end else { throw GiveUp() }
                let e = base[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""): scratch.append(0x22)
                case UInt8(ascii: "\\"): scratch.append(0x5C)
                case UInt8(ascii: "/"): scratch.append(0x2F)
                case UInt8(ascii: "b"): scratch.append(0x08)
                case UInt8(ascii: "f"): scratch.append(0x0C)
                case UInt8(ascii: "n"): scratch.append(0x0A)
                case UInt8(ascii: "r"): scratch.append(0x0D)
                case UInt8(ascii: "t"): scratch.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try hex4()
                    if scalar >= 0xD800 && scalar <= 0xDBFF {
                        // A high surrogate must be followed by its low half.
                        guard end - i >= 6, base[i] == UInt8(ascii: "\\"), base[i + 1] == UInt8(ascii: "u") else {
                            throw GiveUp()
                        }
                        i += 2
                        let low = try hex4()
                        guard low >= 0xDC00 && low <= 0xDFFF else { throw GiveUp() }
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    } else if scalar >= 0xDC00 && scalar <= 0xDFFF {
                        throw GiveUp()
                    }
                    guard let u = Unicode.Scalar(scalar) else { throw GiveUp() }
                    scratch.append(contentsOf: UTF8.encode(u)!)
                default:
                    throw GiveUp()
                }
            }
            throw GiveUp()
        }

        mutating func hex4() throws(GiveUp) -> UInt32 {
            guard end - i >= 4 else { throw GiveUp() }
            var v: UInt32 = 0
            for _ in 0..<4 {
                let c = base[i]
                let d: UInt32
                switch c {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): d = UInt32(c - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): d = UInt32(c - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"): d = UInt32(c - UInt8(ascii: "A") + 10)
                default: throw GiveUp()
                }
                v = v << 4 | d
                i += 1
            }
            return v
        }

        /// Powers of ten a `Double` holds exactly.
        static let exact: [Double] = [1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11,
                                      1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22]

        /// A number, strictly by JSON's grammar.
        ///
        /// When its digits fit in 53 bits and its power of ten is one a
        /// `Double` holds exactly, one multiply or divide gives the correctly
        /// rounded value (Clinger's fast path) — the value `strtod` gives. Any
        /// other number is handed to Swift's own correctly rounded parser. A
        /// result of zero or infinity from digits that are not all zeros gives
        /// up: `JSONDecoder` refuses those, and so must this.
        mutating func number() throws(GiveUp) -> Double {
            let start = i
            var negative = false
            if base[i] == UInt8(ascii: "-") { negative = true; i += 1 }
            guard i < end else { throw GiveUp() }

            var mantissa: UInt64 = 0
            var digits = 0          // significant digits gathered into mantissa
            var overflow = false    // more significant digits than mantissa holds
            var allZero = true

            @inline(__always) func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

            // Integer part: "0", or a non-zero digit and more.
            if base[i] == UInt8(ascii: "0") {
                i += 1
                if i < end, isDigit(base[i]) { throw GiveUp() }
            } else if isDigit(base[i]) {
                while i < end, isDigit(base[i]) {
                    let d = UInt64(base[i] - 0x30)
                    if d != 0 { allZero = false }
                    if digits < 19 { mantissa = mantissa * 10 + d; if mantissa != 0 { digits += 1 } }
                    else { overflow = true }
                    i += 1
                }
            } else {
                throw GiveUp()
            }

            var fraction = 0
            if i < end, base[i] == UInt8(ascii: ".") {
                i += 1
                guard i < end, isDigit(base[i]) else { throw GiveUp() }
                while i < end, isDigit(base[i]) {
                    let d = UInt64(base[i] - 0x30)
                    if d != 0 { allZero = false }
                    if digits < 19 {
                        mantissa = mantissa * 10 + d
                        if mantissa != 0 { digits += 1 }
                        fraction += 1
                    } else {
                        overflow = true
                    }
                    i += 1
                }
            }

            var hasExponent = false
            var exponent = 0
            if i < end, base[i] == UInt8(ascii: "e") || base[i] == UInt8(ascii: "E") {
                hasExponent = true
                i += 1
                var expNegative = false
                if i < end, base[i] == UInt8(ascii: "+") || base[i] == UInt8(ascii: "-") {
                    expNegative = base[i] == UInt8(ascii: "-")
                    i += 1
                }
                guard i < end, isDigit(base[i]) else { throw GiveUp() }
                while i < end, isDigit(base[i]) {
                    if exponent < 100_000 { exponent = exponent * 10 + Int(base[i] - 0x30) }
                    i += 1
                }
                if expNegative { exponent = -exponent }
            }

            if allZero {
                // "0", "-0", "0.0", "-0.000": a true zero, sign kept, which is
                // what JSONDecoder reads them as. A zero with an exponent is a
                // case JSONDecoder has its own opinion about — let it say.
                guard !hasExponent else { throw GiveUp() }
                return negative ? -0.0 : 0.0
            }

            if !overflow {
                let power = exponent - fraction
                if mantissa <= (1 << 53), power >= -22, power <= 22 {
                    var v = Double(mantissa)
                    v = power < 0 ? v / Self.exact[-power] : v * Self.exact[power]
                    return negative ? -v : v
                }
            }

            // Everything else: the literal, exactly as written, through the
            // standard library's correctly rounded conversion.
            let text = String(decoding: UnsafeBufferPointer(start: base + start, count: i - start), as: UTF8.self)
            guard let v = Double(text), v.isFinite, v != 0 else { throw GiveUp() }
            return v
        }
    }
}
