import Foundation

/// Printers a scan found, remembered for a while (`lib/found-printers.js`).
/// The rule is the shared one: what counts as the same printer, the three-day
/// expiry and the cap of forty are not written again here.
extension KhaytEngine {

    /// The list after a scan: what was remembered plus what this scan saw.
    /// `source` is `mdns`, `sdcp` or `sweep`. Never changes `list`.
    public func rememberFound(list: JSONValue, found: [JSONValue], nowMs: Double, source: String) throws -> [JSONValue] {
        try runtime.call2("KhaytFoundPrinters.remember(ARG0, ARG1, ARG2, { source: ARG3 })",
                          [list, .array(found), .number(nowMs), .string(source)], as: [JSONValue].self)
    }

    /// What is still inside the expiry, most recently seen first.
    public func recentFound(list: JSONValue, nowMs: Double) throws -> [JSONValue] {
        try runtime.call2("KhaytFoundPrinters.recent(ARG0, ARG1, {})", [list, .number(nowMs)], as: [JSONValue].self)
    }

    /// What a picker shows: this scan's printers (`seenNow: true`), then the
    /// remembered ones this scan did not see (`seenNow: false`, `lastSeen`).
    public func foundForScan(list: JSONValue, scanned: [JSONValue], nowMs: Double) throws -> [JSONValue] {
        try runtime.call2("KhaytFoundPrinters.forScan(ARG0, ARG1, ARG2, {})",
                          [list, .array(scanned), .number(nowMs)], as: [JSONValue].self)
    }
}
