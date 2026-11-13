import Foundation

/// What a shop in Simple mode gets of one surface.
///
/// ── WHY THIS IS A BRIDGE AND NOT A TABLE ──────────────────────────────────
///
/// Simple and Professional are one decision for the Mac, the iPhone and the
/// desktop: `lib/feature-tiers.js` `SIMPLE_MAP`, one row per surface, agreed
/// in Nov 2026 after three reviews found each app hiding a different set of
/// things. A second copy of that table in Swift is how the apps come to
/// disagree again, so the table stays in the rule and this asks it.
///
/// `featureEnabled(_:mode:)` is the older question (the five gates). This is
/// the fuller one: not only "is it there" but "is it there in its smaller
/// form", which is most of what Simple is.
extension KhaytEngine {

    /// What a surface looks like for a shop, with its mode taken into account.
    public enum SimpleSurface: String, Sendable, Equatable {
        /// As Professional has it: the shop is Professional, or the row is the
        /// same in both modes (`show`).
        case full
        /// The smaller form the row describes (`reduced`).
        case reduced
        /// Not in Simple: it is not listed, and a link to it says it is part
        /// of Professional with a way to switch (`pro`).
        case professionalOnly
    }

    /// The map's own answer for one row, whatever the shop's mode:
    /// `"show"`, `"reduced"`, `"pro"`, or nil when the map has no such row.
    public func simpleDecision(_ key: String) throws -> String? {
        try runtime.call2("""
            (function (key) {
              var d = globalThis.KhaytTiers.simpleDecision(key);
              return d === undefined ? null : d;
            })(ARG0)
            """, [.string(key)], as: String?.self)
    }

    /// What this shop gets of a surface, or nil when the map has no such row.
    ///
    /// The mode is read the way `featureEnabled` reads it, and for the same
    /// reasons: an absent mode is Professional (a book from before modes
    /// existed, and a phone with no book yet), and `enthusiast` is Simple
    /// (Bed Ready's old hobbyist value, which Khayt never offers).
    ///
    /// nil is deliberately not `.full`: a key nobody recognises is a typing
    /// mistake or a row that was renamed, and showing everything for it would
    /// hide that. A caller decides what an unknown surface does.
    public func simpleSurface(_ key: String, mode: String?) throws -> SimpleSurface? {
        guard let decision = try simpleDecision(key) else { return nil }
        guard Self.isSimple(mode) else { return .full }
        switch decision {
        case "reduced": return .reduced
        case "pro": return .professionalOnly
        default: return .full
        }
    }

    /// Every row's key, in the map's order, so a test can hold an app to
    /// asking only about rows that exist.
    public func simpleSurfaceKeys() throws -> [String] {
        try runtime.call2("globalThis.KhaytTiers.SIMPLE_MAP.map(function (r) { return r.key; })", [], as: [String].self)
    }

    /// Is this mode Simple? `simple`, or Bed Ready's `enthusiast`. Anything
    /// else, and no mode at all, is Professional.
    public nonisolated static func isSimple(_ mode: String?) -> Bool {
        mode == "simple" || mode == "enthusiast"
    }
}

/// Simple's board: four columns instead of eight, asked of the shared rule.
///
/// `lib/order-status.js` `simpleStageOf` and `simpleColumnJobs` (desktop
/// #2428) say which of Quote, Queued, Printing and Ready a job is filed under,
/// the finer stage it is really at (shown as a note on the card), whether a
/// job on hold had already started printing, and the newest 120 of Ready.
/// The iPhone carried a Swift copy of the table until this; the Mac and the
/// phone ask the engine instead, so the three apps file a job the same way.
extension KhaytEngine {

    /// Where Simple files one job.
    public struct SimpleStage: Decodable, Sendable, Equatable {
        /// `quote` | `queued` | `printing` | `ready`.
        public let column: String
        /// The finer stage shown on the card (`on_hold`, `post`, `qc`,
        /// `shipped`, `delivered`), or nil.
        public let note: String?
        /// The job's own stage, so a card can still offer its own actions.
        public let stage: String
        /// On hold only: the job had started printing before it was held.
        public let midPrint: Bool?

        public init(column: String, note: String?, stage: String, midPrint: Bool?) {
            self.column = column; self.note = note; self.stage = stage; self.midPrint = midPrint
        }
    }

    /// The four columns, in order.
    public func simpleColumns() throws -> [String] {
        try runtime.call2("globalThis.KhaytOrderStatus.SIMPLE_COLUMNS", [], as: [String].self)
    }

    /// Where Simple files this job, or nil when it is not on the board
    /// (cancelled, failed, an unknown status), as in Professional.
    public func simpleStage(of order: JSONValue) throws -> SimpleStage? {
        try runtime.call2("globalThis.KhaytOrderStatus.simpleStageOf(ARG0)", [order], as: SimpleStage?.self)
    }

    /// The jobs one column shows, in the rule's order, as indexes into
    /// `orders`, and how many Ready leaves out (only Ready is cut, newest
    /// first). Indexes rather than records, so a caller keeps its own models.
    public func simpleColumn(_ column: String, orders: [JSONValue], cap: Int? = nil) throws -> (indexes: [Int], more: Int) {
        struct Answer: Decodable { let indexes: [Int]; let more: Int }
        let a = try runtime.call2("""
            (function (orders, column, cap) {
              var tagged = orders.map(function (o, i) {
                var c = Object.assign({}, o); Object.defineProperty(c, '__i', { value: i, enumerable: false }); return c;
              });
              var r = globalThis.KhaytOrderStatus.simpleColumnJobs(tagged, column, cap === null ? undefined : { cap: cap });
              return { indexes: r.jobs.map(function (o) { return o.__i; }), more: r.more };
            })(ARG0, ARG1, ARG2)
            """, [.array(orders), .string(column), cap.map { .number(Double($0)) } ?? .null], as: Answer.self)
        return (a.indexes, a.more)
    }
}
