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

    public func outboundPurposes() throws -> [String] {
        try runtime.call2("KhaytOutbound.PURPOSES", [], as: [String].self)
    }

    public func outboundReasons() throws -> [String] {
        try runtime.call2("KhaytOutbound.REASONS", [], as: [String].self)
    }
}
