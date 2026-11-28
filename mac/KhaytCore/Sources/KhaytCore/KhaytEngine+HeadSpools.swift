import Foundation

/// One spool, one head (`lib/head-spools.js`): linking a spool to a head takes
/// it out of every other head, on this machine and on every other one.
///
/// In KhaytCore because the phone shows heads too, and the rule is the
/// desktop's and the Mac's alike: a spool linked to two heads at once (Baby
/// U1, Nov 27 2026) came from two apps each writing `headSpools[head]` and
/// nothing else.
extension KhaytEngine {

    public struct HeadLinkResult: Decodable, Sendable, Equatable {
        public struct Moved: Decodable, Sendable, Equatable {
            public let machineId: String
            public let head: String
        }
        /// Every machine; only those in `changed` differ from what was given.
        public let machines: [JSONValue]
        /// The heads the spool was taken out of.
        public let moved: [Moved]
        public let changed: [String]
        /// "bad-head", "no-spool" or "no-machine"; nothing changed.
        public let error: String?
    }

    /// Put a spool in a head (counted from zero) and out of every other head.
    public func headSpoolsLink(machines: [JSONValue], machineId: String, head: Int, spoolId: String) throws -> HeadLinkResult {
        try runtime.call2("KhaytHeadSpools.link(ARG0, ARG1, ARG2, ARG3)",
                          [.array(machines), .string(machineId), .number(Double(head)), .string(spoolId)],
                          as: HeadLinkResult.self)
    }

    /// Take whatever is in a head out of it.
    public func headSpoolsUnlink(machines: [JSONValue], machineId: String, head: Int) throws -> HeadLinkResult {
        try runtime.call2("KhaytHeadSpools.unlink(ARG0, ARG1, ARG2)",
                          [.array(machines), .string(machineId), .number(Double(head))],
                          as: HeadLinkResult.self)
    }

    /// "linked", "not-in-printer" (linked, and the printer answered that the
    /// head is empty: kept, and said) or "none".
    public func headSpoolsShown(linked: String?, reportsEmpty: Bool?) throws -> String {
        try runtime.call2("KhaytHeadSpools.shown(ARG0, ARG1)",
                          [linked.map(JSONValue.string) ?? .null, reportsEmpty.map(JSONValue.bool) ?? .null],
                          as: String.self)
    }
}
