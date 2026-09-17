import Foundation

/// JavaScript's own arithmetic and number-printing, in Swift.
///
/// ── WHY THIS EXISTS BEFORE ANY PORTED MODULE DOES ─────────────────────────
///
/// Khayt's rules were written in JavaScript and their output is compared
/// against records the other app wrote. Porting one to Swift means reproducing
/// not just what it decides but how it SPELLS the answer, and the two languages
/// disagree in ways that look like nothing until a key stops matching:
///
///   `Math.round` in JavaScript rounds a half UP, toward positive infinity, so
///   `Math.round(-0.5)` is `-0`. Swift's `rounded()` rounds a half AWAY FROM
///   ZERO, so the same call is `-1`. Every rounded figure in the codebase goes
///   through that function.
///
///   A whole number prints as `1` in JavaScript and `1.0` in Swift. A geometry
///   key is three numbers joined by punctuation, so that one character is the
///   difference between two apps agreeing that a model is the same model and
///   silently disagreeing for ever.
///
/// Nothing here is a judgement about which behaviour is better. It is the
/// behaviour the book already holds, and a port that "fixes" it would be a port
/// that invalidates every record written before it.
public enum JSSemantics {

    /// `Math.round` — a half goes UP, toward positive infinity.
    ///
    /// Not `rounded()`, which takes a half away from zero and therefore
    /// disagrees on every negative half.
    public static func round(_ x: Double) -> Double {
        guard x.isFinite else { return x }
        return (x + 0.5).rounded(.down)
    }

    /// `Number(value)` — JavaScript's coercion, not Swift's parsing.
    ///
    /// The differences that bite: an empty or blank string is `0` rather than
    /// a failure, `null` is `0`, a missing property is `NaN`, and a boolean is
    /// `1` or `0`. A rule that reads `Number(g.triangleCount)` gets all of
    /// that, so a port that only accepts a JSON number silently changes what
    /// the rule accepts.
    public static func number(_ value: JSONValue?) -> Double {
        guard let value else { return .nan }
        switch value {
        case .number(let n): return n
        case .bool(let b): return b ? 1 : 0
        case .null: return 0
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return 0 }
            if t.hasPrefix("0x") || t.hasPrefix("0X") {
                // `.map(Double.init)` here resolved to `Double(bitPattern:)`,
                // so `"0x10"` came back as 8e-323 instead of 16 — a denormal
                // that rounds to zero and looks like a perfectly ordinary
                // dimension. The parity harness caught it; nothing else would
                // have. The closure spells out which initialiser is meant.
                guard let bits = UInt64(t.dropFirst(2), radix: 16) else { return .nan }
                return Double(bits)
            }
            if t == "Infinity" || t == "+Infinity" { return .infinity }
            if t == "-Infinity" { return -.infinity }
            // Swift's Double() accepts "nan", "inf" and hex floats, which
            // JavaScript's Number() does not.
            guard t.rangeOfCharacter(from: CharacterSet(charactersIn: "xXnN")) == nil
                    || t.lowercased().hasPrefix("e") else { return .nan }
            return Double(t) ?? .nan
        // ToPrimitive, which for an array is `join(",")` — so an EMPTY array
        // is `""` and therefore `0`, a single-element one is that element, and
        // anything longer is a string with a comma in it and therefore NaN.
        // An object is "[object Object]" and never a number. Guessed NaN for
        // all of them at first; the harness produced `Number([]) === 0`.
        case .array(let items):
            if items.isEmpty { return 0 }
            if items.count == 1 { return number(items[0]) }
            return .nan
        case .object: return .nan
        }
    }

    /// `String(number)` — how JavaScript prints a Double.
    ///
    /// ── NOT `description`, AND THE HARNESS SAID SO FIRST ──────────────────
    ///
    /// Swift's `description` is already the shortest form that round-trips,
    /// which is what ECMAScript asks for — but it chooses notation by its own
    /// rules. `1e-6` prints as `1e-06` in Swift and `0.000001` in JavaScript,
    /// and a whole number prints as `1.0` against `1`. A geometry key is three
    /// numbers joined by punctuation, so either difference is two apps
    /// disagreeing for ever about whether a model is the same model.
    ///
    /// The parity harness found the first of those on its first run, which is
    /// the argument for the harness in one line.
    ///
    /// So: take the shortest digits Swift produces, and place the decimal point
    /// where ECMAScript places it — positional for 1e-6 ≤ |n| < 1e21, and the
    /// `e+21` form outside that.
    public static func string(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d == 0 { return "0" }                 // covers -0, which prints as "0"
        if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }

        let negative = d < 0
        let (digits, pointAt) = shortest(abs(d))
        let k = digits.count
        let n = pointAt
        var out: String

        if k <= n && n <= 21 {
            // 123 → "123", with any trailing zeros the exponent implies.
            out = digits + String(repeating: "0", count: n - k)
        } else if 0 < n && n <= 21 {
            // 1.25 → digits "125", point after 1.
            let i = digits.index(digits.startIndex, offsetBy: n)
            out = String(digits[..<i]) + "." + String(digits[i...])
        } else if -6 < n && n <= 0 {
            // 0.000001 → "0." then the zeros the exponent implies.
            out = "0." + String(repeating: "0", count: -n) + digits
        } else {
            // Outside the positional range, the e+21 / e-7 form.
            let e = n - 1
            let mantissa = k == 1 ? digits
                : String(digits.first!) + "." + String(digits.dropFirst())
            out = "\(mantissa)e\(e >= 0 ? "+" : "-")\(abs(e))"
        }
        return negative ? "-" + out : out
    }

    /// The shortest digits that round-trip, and where the decimal point goes.
    ///
    /// Returned as ECMAScript frames it: a digit string `s` of length `k`, and
    /// an `n` such that the value is `s × 10^(n−k)`. Swift's own `description`
    /// is the source of the digits, because it is already the shortest form
    /// that reads back as the same Double — only its NOTATION differs.
    private static func shortest(_ magnitude: Double) -> (digits: String, pointAt: Int) {
        let text = magnitude.description          // "1.5", "1e-06", "1.1429459e+06"
        var mantissa = text
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = String(text[text.startIndex..<e])
            exponent = Int(text[text.index(after: e)...].replacingOccurrences(of: "+", with: "")) ?? 0
        }
        var whole = mantissa, fraction = ""
        if let dot = mantissa.firstIndex(of: ".") {
            whole = String(mantissa[mantissa.startIndex..<dot])
            fraction = String(mantissa[mantissa.index(after: dot)...])
        }
        var digits = whole + fraction
        // `n` counts the digits before the point once the exponent is applied.
        var pointAt = whole.count + exponent
        // Leading zeros are not significant and shift the point.
        while digits.count > 1 && digits.hasPrefix("0") {
            digits.removeFirst()
            pointAt -= 1
        }
        // Nor are trailing ones, which only pad.
        while digits.count > 1 && digits.hasSuffix("0") { digits.removeLast() }
        if digits == "0" { return ("0", 1) }
        return (digits, pointAt)
    }
}
