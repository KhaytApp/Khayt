import Foundation

/// Does this JSON text name the same key twice in one object?
///
/// JSON allows it and readers disagree about it: JavaScript's `JSON.parse`
/// keeps the LAST value, `JSONDecoder` the FIRST. Where one reader judges a
/// request and another acts on it, `{"price":999,"price":null}` is no price to
/// the judge and 999 to the actor (Nov 26 security review, MED-1). A body that
/// does this is not read at all.
///
/// Keys are compared after their escapes are read (`"price"` is
/// `"price"`), as `String`s, which also counts two spellings Unicode calls the
/// same: stricter than either reader, never looser. Text that is not JSON is
/// answered `false`: whether it parses is the reader's question, not this one.
public enum JSONRepeatedKeys {

    /// LINEAR in the size of the text, whatever is in it: a signed device
    /// may send several megabytes (an expense with its receipt), and this runs
    /// on the LAN server's thread before any rule does. Each object's keys are
    /// a set mutated in place (never copied per key), and a key's escapes are
    /// read here, not by `JSONDecoder`, which would cost far more per key.
    /// `ReleaseReviewNov26Tests` times it at 8 MB.
    ///
    /// Only a body that STARTS like JSON (`{` or `[`, after spaces) is looked
    /// at. A photo or any other binary body is not JSON, and its bytes could
    /// otherwise happen to read as a repeated key.
    public static func found(in data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            let bytes = raw.bindMemory(to: UInt8.self)
            let n = bytes.count
            var i = 0
            while i < n, bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D || bytes[i] == 0x09 { i += 1 }
            guard i < n, bytes[i] == UInt8(ascii: "{") || bytes[i] == UInt8(ascii: "[") else { return false }
            // One entry per open container (true: an object); the open objects' key sets, innermost last.
            var isObject: [Bool] = []
            var keys: [Set<String>] = []
            var expectingKey = false
            while i < n {
                let c = bytes[i]
                switch c {
                case UInt8(ascii: "{"):
                    isObject.append(true); keys.append(Set<String>()); expectingKey = true; i += 1
                case UInt8(ascii: "["):
                    isObject.append(false); expectingKey = false; i += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    if let last = isObject.popLast(), last, !keys.isEmpty { keys.removeLast() }
                    expectingKey = false; i += 1
                case UInt8(ascii: ","):
                    expectingKey = isObject.last == true; i += 1
                case UInt8(ascii: "\""):
                    // The string's end, and whether it holds an escape.
                    var j = i + 1, escaped = false, closed = false
                    while j < n {
                        let b = bytes[j]
                        if b == UInt8(ascii: "\\") { escaped = true; j += 2; continue }
                        if b == UInt8(ascii: "\"") { closed = true; break }
                        j += 1
                    }
                    guard closed else { return false }
                    if expectingKey, !keys.isEmpty {
                        let inner = UnsafeBufferPointer(rebasing: bytes[(i + 1)..<j])
                        guard let key = escaped ? unescape(inner) : String(decoding: inner, as: UTF8.self) else { return false }
                        if !keys[keys.count - 1].insert(key).inserted { return true }
                        expectingKey = false
                    }
                    i = j + 1
                default:
                    i += 1
                }
            }
            return false
        }
    }

    /// A key's text with its escapes read, as JSON defines them; nil for an
    /// escape JSON does not have (then the text is not JSON, and not this
    /// check's question).
    static func unescape(_ s: UnsafeBufferPointer<UInt8>) -> String? {
        var out: [UInt16] = []
        out.reserveCapacity(s.count)
        var plain: [UInt8] = []
        func flush() {
            if !plain.isEmpty { out.append(contentsOf: String(decoding: plain, as: UTF8.self).utf16); plain.removeAll(keepingCapacity: true) }
        }
        func hex(_ k: Int) -> UInt16? {
            guard k + 4 <= s.count else { return nil }
            var v: UInt16 = 0
            for m in k..<(k + 4) {
                let d = s[m]
                let x: UInt8
                switch d {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): x = d - UInt8(ascii: "0")
                case UInt8(ascii: "a")...UInt8(ascii: "f"): x = d - UInt8(ascii: "a") + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"): x = d - UInt8(ascii: "A") + 10
                default: return nil
                }
                v = v << 4 | UInt16(x)
            }
            return v
        }
        var k = 0
        while k < s.count {
            let b = s[k]
            guard b == UInt8(ascii: "\\") else { plain.append(b); k += 1; continue }
            guard k + 1 < s.count else { return nil }
            flush()
            switch s[k + 1] {
            case UInt8(ascii: "\""): out.append(0x22)
            case UInt8(ascii: "\\"): out.append(0x5C)
            case UInt8(ascii: "/"): out.append(0x2F)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                guard let v = hex(k + 2) else { return nil }
                out.append(v); k += 6; continue
            default: return nil
            }
            k += 2
        }
        flush()
        // A lone surrogate reads as U+FFFD, so two different ones read as the
        // same key: stricter than either reader, never looser.
        return String(decoding: out, as: UTF16.self)
    }
}
