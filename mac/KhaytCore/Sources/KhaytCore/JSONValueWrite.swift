import Foundation

public extension JSONValue {

    /// `JSONEncoder().encode(value)` with the default settings — the same
    /// bytes — written straight from the value instead of through the
    /// `Encoder` machinery.
    static func encode(_ value: JSONValue) throws -> Data {
        if let bytes = FastJSONWriter.write(value) { return bytes }
        return try JSONEncoder().encode(value)
    }

    /// The same, for a whole book.
    static func encode(_ object: [String: JSONValue]) throws -> Data {
        if let bytes = FastJSONWriter.write(object) { return bytes }
        return try JSONEncoder().encode(object)
    }
}

enum FastJSONWriter {

    static func write(_ value: JSONValue) -> Data? {
        var w = Writer()
        guard w.value(value) else { return nil }
        return Data(w.out)
    }

    static func write(_ object: [String: JSONValue]) -> Data? {
        var w = Writer()
        guard w.object(object) else { return nil }
        return Data(w.out)
    }

    struct Writer {
        var out: [UInt8] = []

        init() { out.reserveCapacity(1 << 16) }

        /// False when the value cannot be written as JSON — a NaN or an
        /// infinity — so the caller can let `JSONEncoder` refuse it in its
        /// own words.
        mutating func value(_ v: JSONValue) -> Bool {
            switch v {
            case .string(let s): string(s)
            case .number(let d): return number(d)
            case .bool(let b): b ? ascii("true") : ascii("false")
            case .null: ascii("null")
            case .object(let o): return object(o)
            case .array(let a):
                out.append(UInt8(ascii: "["))
                var first = true
                for e in a {
                    if !first { out.append(UInt8(ascii: ",")) }
                    first = false
                    guard value(e) else { return false }
                }
                out.append(UInt8(ascii: "]"))
            }
            return true
        }

        mutating func object(_ o: [String: JSONValue]) -> Bool {
            out.append(UInt8(ascii: "{"))
            var first = true
            for (k, v) in o {
                if !first { out.append(UInt8(ascii: ",")) }
                first = false
                string(k)
                out.append(UInt8(ascii: ":"))
                guard value(v) else { return false }
            }
            out.append(UInt8(ascii: "}"))
            return true
        }

        @inline(__always)
        mutating func ascii(_ s: StaticString) {
            out.append(contentsOf: UnsafeBufferPointer(start: s.utf8Start, count: s.utf8CodeUnitCount))
        }

        static let hex: [UInt8] = Array("0123456789abcdef".utf8)

        /// As `JSONEncoder` spells a string: `"` `\` and `/` escaped, the
        /// control characters as `\b \t \n \f \r` or `\u00XX`, and everything
        /// else — Arabic, emoji — as its own UTF-8.
        mutating func string(_ s: String) {
            out.append(UInt8(ascii: "\""))
            var s = s
            s.withUTF8 { bytes in
                var runStart = 0
                for (i, c) in bytes.enumerated() {
                    let escape: UInt8
                    switch c {
                    case UInt8(ascii: "\""): escape = UInt8(ascii: "\"")
                    case UInt8(ascii: "\\"): escape = UInt8(ascii: "\\")
                    case UInt8(ascii: "/"): escape = UInt8(ascii: "/")
                    case 0x08: escape = UInt8(ascii: "b")
                    case 0x09: escape = UInt8(ascii: "t")
                    case 0x0A: escape = UInt8(ascii: "n")
                    case 0x0C: escape = UInt8(ascii: "f")
                    case 0x0D: escape = UInt8(ascii: "r")
                    case 0x00..<0x20: escape = UInt8(ascii: "u")
                    default: continue
                    }
                    if runStart < i { out.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[runStart..<i])) }
                    out.append(UInt8(ascii: "\\"))
                    out.append(escape)
                    if escape == UInt8(ascii: "u") {
                        out.append(contentsOf: [UInt8(ascii: "0"), UInt8(ascii: "0"),
                                                Self.hex[Int(c >> 4)], Self.hex[Int(c & 0xF)]])
                    }
                    runStart = i + 1
                }
                if runStart < bytes.count {
                    out.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[runStart...]))
                }
            }
            out.append(UInt8(ascii: "\""))
        }

        /// As `JSONEncoder` spells a `Double`: Swift's own shortest
        /// round-tripping `description`, less a trailing `.0`.
        mutating func number(_ d: Double) -> Bool {
            guard d.isFinite else { return false }
            // Whole numbers below 2^53 are what a book is mostly made of, and
            // `description` spells them as plain digits — so does Int64. From
            // 2^53 up it switches to `9.007199254740992e+15`, so those go the
            // long way.
            if d == d.rounded(.towardZero), abs(d) < 9_007_199_254_740_992 {
                if d == 0 {
                    if d.sign == .minus { ascii("-0") } else { out.append(UInt8(ascii: "0")) }
                    return true
                }
                var n = Int64(d)
                if n < 0 { out.append(UInt8(ascii: "-")); n = -n }
                var digits: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                             UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
                    (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
                var count = 0
                withUnsafeMutableBytes(of: &digits) { buf in
                    while n > 0 {
                        buf[15 - count] = UInt8(n % 10) + 0x30
                        n /= 10
                        count += 1
                    }
                    out.append(contentsOf: buf[(16 - count)...])
                }
                return true
            }
            var text = d.description
            if text.hasSuffix(".0") { text.removeLast(2) }
            out.append(contentsOf: text.utf8)
            return true
        }
    }
}
