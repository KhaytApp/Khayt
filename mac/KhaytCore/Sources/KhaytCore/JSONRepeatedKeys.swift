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

    public static func found(in data: Data) -> Bool {
        let bytes = [UInt8](data)
        var i = 0
        // One entry per open container: the keys seen so far for an object,
        // nil for an array.
        var stack: [Set<String>?] = []
        var expectingKey = false

        func skipString() -> Int? {
            // `i` is at the opening quote. Returns the index just past the closing one.
            var j = i + 1
            while j < bytes.count {
                switch bytes[j] {
                case UInt8(ascii: "\\"): j += 2
                case UInt8(ascii: "\""): return j + 1
                default: j += 1
                }
            }
            return nil
        }

        while i < bytes.count {
            let c = bytes[i]
            switch c {
            case UInt8(ascii: "{"):
                stack.append(Set<String>()); expectingKey = true; i += 1
            case UInt8(ascii: "["):
                stack.append(nil); expectingKey = false; i += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                if !stack.isEmpty { stack.removeLast() }
                expectingKey = false; i += 1
            case UInt8(ascii: ","):
                // After a comma inside an object, a key comes next.
                if let top = stack.last, top != nil { expectingKey = true }
                i += 1
            case UInt8(ascii: "\""):
                guard let end = skipString() else { return false }
                if expectingKey, var keys = stack.last ?? nil {
                    guard let key = try? JSONDecoder().decode(String.self, from: Data(bytes[i..<end])) else { return false }
                    if !keys.insert(key).inserted { return true }
                    stack[stack.count - 1] = keys
                    expectingKey = false
                }
                i = end
            default:
                i += 1
            }
        }
        return false
    }
}
