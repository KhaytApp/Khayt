import Foundation

/// Which lot a draw came from, as `lib/order-deduction.js` stamps it.
extension KhaytEngine {

    /// `KhaytOrderDeduction.lotStamp(spool)`: `{lot?, poId?}` — the spool's
    /// trimmed lot when it has one and the purchase order it was last received
    /// against. Asked of the shared rule rather than re-written, so a draw this
    /// app writes (the spool switch) carries the same stamp as every draw the
    /// deduction itself writes, and a recall (`lib/lot-trace.js`) reads it the
    /// same way.
    public func lotStamp(_ spool: JSONValue) throws -> [String: JSONValue] {
        try runtime.call2("KhaytOrderDeduction.lotStamp(ARG0)", [spool], as: [String: JSONValue].self)
    }
}
