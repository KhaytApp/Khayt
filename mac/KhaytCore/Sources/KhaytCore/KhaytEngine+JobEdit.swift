import Foundation

/// Editing a job that already exists, through the shared rules
/// (`lib/order-edit.js`, S1 B2): when its parts may change, the margin it was
/// priced at, and one all-or-nothing edit of the whole job.
///
/// In KhaytCore so the phone's edit route and the Mac's job sheet run the
/// same rule the desktop does. A refusal comes back as a reason code; the
/// app words it.
extension KhaytEngine {

    /// What may be done to a job's parts (`partsLock`).
    public struct PartsLock: Decodable, Sendable, Equatable {
        /// nil when nothing limits it; else `zatca`, `voided`, `credited`,
        /// `cancelled`, `deducted` or `missing`.
        public let code: String?
        public let edit: Bool
        public let addRemove: Bool
        /// A finished job: a part's name and note only.
        public let nameOnly: Bool
        /// In production: the sheet asks whether the price follows the parts.
        public let askPrice: Bool
    }

    public func partsLock(_ order: JSONValue) throws -> PartsLock {
        try runtime.call2("globalThis.KhaytOrderEdit.partsLock(ARG0)", [order], as: PartsLock.self)
    }

    /// The margin the job was priced at, in percent, or nil where it cannot
    /// be said (a typed price, a zero price, no parts): "—, price was typed".
    public func marginOf(_ order: JSONValue) throws -> Double? {
        try runtime.call2("globalThis.KhaytOrderEdit.marginOf(ARG0)", [order], as: Double?.self)
    }

    /// One edit of a whole job, as it came back.
    public struct JobEditResult: Decodable, Sendable {
        public let ok: Bool
        /// Why it was refused: a lock's code, `name_only`, `delivered_part`,
        /// `no_parts`, `paid_exceeds_price`, or `changeCustomer`'s reasons.
        public let reason: String?
        /// The rule that refused: `customer`, `parts` or `price`.
        public let step: String?
        /// False when the record came out as it went in: write nothing.
        public let changed: Bool
        /// The job after the edit; the job as handed in on a refusal.
        public let order: JSONValue
    }

    /// `applyJobEdit`: customer, name, parts, details and a typed price, ALL
    /// OR NOTHING. `fields` names only what is changing (`clientId`,
    /// `project`, `parts`, and anything `applyDetails` understands).
    ///
    /// `keepPrice` is the answer to the question asked in production;
    /// `marginPct` is used only when the job's own margin cannot be read;
    /// `newPartIds` are ids for parts arriving without one. The rule reads the
    /// tax profile and the customer list, so it is handed trimmed settings.
    public func applyJobEdit(order: JSONValue, fields: [String: JSONValue],
                             clients: [JSONValue] = [], settings: [String: JSONValue] = [:],
                             keepPrice: Bool = false, marginPct: Double? = nil,
                             newPartIds: [String] = [], now: Date,
                             editId: String, priceId: String) throws -> JobEditResult {
        try runtime.call2("""
            (function (order, fields, ctx) {
              var o = order;
              var r = globalThis.KhaytOrderEdit.applyJobEdit(o, fields, ctx);
              return { ok: r.ok, reason: r.reason || null, step: r.step || null, changed: !!r.changed, order: o };
            })(ARG0, ARG1, { clients: ARG2, settings: ARG3, keepPrice: ARG4, marginPct: ARG5,
                             ids: ARG6, now: ARG7, id: ARG8, priceId: ARG9 })
            """,
            [order, .object(fields), .array(clients), .object(ruleSettings(settings)), .bool(keepPrice),
             marginPct.map(JSONValue.number) ?? .null, .array(newPartIds.map(JSONValue.string)),
             .number(now.timeIntervalSince1970 * 1000), .string(editId), .string(priceId)],
            as: JobEditResult.self)
    }
}
