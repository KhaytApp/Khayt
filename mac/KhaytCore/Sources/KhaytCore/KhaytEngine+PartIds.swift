import Foundation

/// The id a part without one is owed: `lib/part-ids.js`.
///
/// ── WHY THE RULE AND NOT SWIFT ───────────────────────────────────────────
///
/// Two computers that give the same book's parts their ids must write the
/// same ids, or sync sees two edits where there was one. The id is a hash of
/// the part's JSON, so it depends on exactly how a number and a key order are
/// written, and the desktop writes them with V8. Running the same file here
/// (JavaScriptCore) is what keeps the two in step; `PartIdsParityTests` holds
/// this copy to the vectors the desktop's test pins.
extension KhaytEngine {

    /// `printLog` with every id-less part given its id, and what was given.
    public struct PartIds: Decodable, Sendable {
        public let orders: [JSONValue]
        public let given: [Given]

        public struct Given: Decodable, Sendable, Equatable {
            public let orderId: String
            public let index: Int
            public let id: String
        }
    }

    public func assignPartIds(_ orders: [JSONValue]) throws -> PartIds {
        try runtime.call2("""
            (function (orders) {
              var given = KhaytPartIds.assignPartIds(orders);
              return { orders: orders, given: given };
            })(ARG0)
            """, [.array(orders)], as: PartIds.self)
    }

    /// One id, for the parity test.
    public func partIdFor(orderId: String, index: Int, part: JSONValue) throws -> String {
        try runtime.call2("KhaytPartIds.partIdFor(ARG0, ARG1, ARG2)",
                          [.string(orderId), .number(Double(index)), part], as: String.self)
    }

    /// The text the id hashes, for the parity test.
    public func partIdText(orderId: String, index: Int, part: JSONValue) throws -> String {
        try runtime.call2("KhaytPartIds.idText(ARG0, ARG1, ARG2)",
                          [.string(orderId), .number(Double(index)), part], as: String.self)
    }

    /// True when any job holds a part without an id. Swift, and cheap, so a
    /// reload of a large book asks the rule nothing when nothing is missing
    /// (which, once the ids are written, is every reload).
    public static func hasPartsWithoutIds(_ orders: [JSONValue]) -> Bool {
        for case .object(let o) in orders {
            guard case .array(let parts)? = o["parts"] else { continue }
            for case .object(let p) in parts {
                if case .string(let id)? = p["id"], !id.isEmpty { continue }
                return true
            }
        }
        return false
    }
}
