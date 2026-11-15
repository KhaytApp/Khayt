import Foundation

/// What a New Job screen shows while the job is typed, from the rule the job
/// is saved by: `lib/order-new.js previewTotal` and `canTake`.
///
/// ── WHY THE SCREEN ASKS THE RULE ──────────────────────────────────────────
///
/// The Mac used to build its own input for `KhaytPricing.quoteTotal` (the
/// costed base, the agreed amount, the hours the overhead is charged on) and
/// `newOrder` built another on save. Two builders agree until one of them
/// learns something: a customer kept in another currency was previewed in the
/// shop's and saved in theirs. `previewTotal` prices through the same code
/// `newOrder` does, so the figure on the sheet is the figure in the book, and
/// the desktop shows the same one for the same input.
extension KhaytEngine {

    public struct NewOrderPreview: Decodable, Sendable, Equatable {
        /// The price the job would be recorded at, in `currency`.
        public let total: Double
        /// The job's currency when it is not simply the shop's: the customer's,
        /// when they are kept in one with a rate on file. ABSENT for a job in
        /// the shop's own currency, as `newOrder` leaves `currency` off it.
        public let currency: String?
        /// `quoteTotal`'s whole answer, for the lines under the total.
        public let quote: QuoteTotal
    }

    /// `input` exactly as `newOrder` takes it. Pure: no number is allocated,
    /// no counter in `settings` moves and no token is needed.
    public func previewNewOrder(_ input: [String: JSONValue], settings: [String: JSONValue],
                                consumables: [JSONValue] = [],
                                clients: [JSONValue] = []) throws -> NewOrderPreview {
        try runtime.call2(
            "KhaytOrderNew.previewTotal(ARG0, { settings: ARG1, consumables: ARG2, clients: ARG3 })",
            [.object(input), .object(settings), .array(consumables), .array(clients)],
            as: NewOrderPreview.self)
    }

    public struct CanTake: Decodable, Sendable, Equatable {
        public let ok: Bool
        /// `no_parts` when the cart is empty.
        public let reason: String?
    }

    /// Whether a new job can be taken, or saved as a quote, as it stands.
    public func canTakeNewOrder(_ input: [String: JSONValue]) throws -> CanTake {
        try runtime.call2("KhaytOrderNew.canTake(ARG0)", [.object(input)], as: CanTake.self)
    }
}
