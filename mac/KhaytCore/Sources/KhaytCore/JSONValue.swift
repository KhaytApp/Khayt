import Foundation

/// A JSON value, for the settings and option bags the JS side takes.
///
/// Khayt's store is one loosely-typed JSON document and several of these
/// functions accept "whatever settings the shop has". Modelling that as a
/// closed Swift struct would mean this file has to change every time a setting
/// is added — and a setting it did not know about would be dropped on the way
/// through, which is exactly how `printerCompletions` came to be deleted on
/// every save.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unrecognised JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v):   try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v):  try c.encode(v)
        case .null:          try c.encodeNil()
        }
    }
}

public extension JSONValue {
    static func from(_ any: Any) -> JSONValue {
        switch any {
        case let v as String: return .string(v)
        case let v as Bool:   return .bool(v)
        case let v as Int:    return .number(Double(v))
        case let v as Double: return .number(v)
        case let v as [String: Any]: return .object(v.mapValues(JSONValue.from))
        case let v as [Any]:  return .array(v.map(JSONValue.from))
        default: return .null
        }
    }
}

/// Synthesised: every case holds a `Hashable`. Here so a record that keeps
/// the fields it does not understand as `[String: JSONValue]` — a customer's
/// price list, say — can still be a value a `Table` selects or a `ForEach`
/// walks.
extension JSONValue: Hashable {}
