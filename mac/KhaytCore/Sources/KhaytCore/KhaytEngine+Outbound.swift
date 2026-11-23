import Foundation

/// `lib/outbound.js` through the engine, as the fixtures call it: for the
/// parity test, and for a screen that already holds the engine. A call site
/// asks `OutboundGate.shared`, which runs the same file.
extension KhaytEngine {

    /// `allowed(settings, purpose, ctx)` exactly as given: any settings (null
    /// for a book not read yet), any purpose text, any context.
    public func outboundAllowed(settings: JSONValue, purpose: JSONValue, ctx: JSONValue) throws -> JSONValue {
        try runtime.call2("KhaytOutbound.allowed(ARG0, ARG1, ARG2 === null ? undefined : ARG2)", [ruleSettings(settings), purpose, ctx], as: JSONValue.self)
    }

    /// The SHOP's switch as a device with no copy of the book needs it:
    /// `{offline, keep}`, both read by the rule (a malformed `network` is
    /// offline with nothing kept; `keep` holds only real purpose ids, never
    /// `lan`). This computer's own switch is not part of it.
    public func outboundShopSwitch(settings: JSONValue) throws -> JSONValue {
        try runtime.call2("({ offline: KhaytOutbound.isOffline(ARG0, {}), keep: KhaytOutbound.keptOf(ARG0) })",
                          [ruleSettings(settings)], as: JSONValue.self)
    }

    public func outboundPurposes() throws -> [String] {
        try runtime.call2("KhaytOutbound.PURPOSES", [], as: [String].self)
    }

    public func outboundReasons() throws -> [String] {
        try runtime.call2("KhaytOutbound.REASONS", [], as: [String].self)
    }

    /// A new change's stamp, MONOTONIC (Dev Hub, Nov 22; `lib/network-switch.js`
    /// `stampAfter`, the same rule on the desktop): this computer's clock, or
    /// one millisecond after the newest stamp it has seen, whichever is
    /// later. Another computer whose clock runs a few minutes ahead publishes
    /// a value stamped in this computer's future; a change made here "now"
    /// would be stamped before it, refused by the server as stale, and never
    /// win. `seen` entries that are not strict stamps are ignored.
    public func networkSwitchStampAfter(now: Date, seen: [String?]) throws -> String {
        let said = try runtime.call2("(KhaytNetworkSwitch.stampAfter(ARG0, ARG1) || '')",
                                     [.number((now.timeIntervalSince1970 * 1000).rounded(.down)),
                                      .array(seen.map { $0.map(JSONValue.string) ?? .null })], as: String.self)
        guard !said.isEmpty else { throw CocoaError(.coderInvalidValue) }
        return said
    }

    /// One millisecond before a stamp (`justBefore`): "at or after" asked of a strict "newer".
    public func networkSwitchJustBefore(_ stamp: String) throws -> String? {
        let said = try runtime.call2("(KhaytNetworkSwitch.justBefore(ARG0) || '')", [.string(stamp)], as: String.self)
        return said.isEmpty ? nil : said
    }
}
