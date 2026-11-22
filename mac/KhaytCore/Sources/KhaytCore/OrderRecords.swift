import Foundation

// What the shared order rules hand back for the order editor, its history,
// voids, credit notes, RMAs and the job intake waiting list. Plain values:
// the rules are `lib/order-edit.js`, `lib/invoice-reversal.js`,
// `lib/reprint.js` and `lib/intake-queue.js`, run through `KhaytEngine`.

/// One edit in a job's `editHistory`, as `editLog` reads it.
public struct OrderEditEntry: Decodable, Sendable, Equatable, Identifiable {
    public struct Field: Decodable, Sendable, Equatable {
        public let field: String
        public let from: String
        public let to: String
    }
    public let id: String?
    public let at: String?
    public let fields: [Field]

    /// Stable enough for a list: the entry's own id, else its time and fields.
    public var listId: String { id ?? ((at ?? "") + fields.map(\.field).joined(separator: ",")) }
}

/// A job's way through the stages (`timeline`).
public struct OrderTimeline: Decodable, Sendable, Equatable {
    public struct Step: Decodable, Sendable, Equatable {
        public let status: String
        public let at: String
        /// How long the job sat in this stage, in milliseconds — up to the
        /// next step, or to now for the stage it is in.
        public let ms: Double
        public let current: Bool
        public let note: String?
    }
    public let steps: [Step]
    public let totalMs: Double
}

/// A void's answer: the job as it now stands, and the waste row to book.
public struct InvoiceVoided: Decodable, Sendable {
    public let ok: Bool
    public let error: String?
    public let order: JSONValue
    public let waste: JSONValue?
}

/// What a void would book as waste.
public struct VoidMaterial: Decodable, Sendable, Equatable {
    public let weight: Double
    public let material: String
    public let loggable: Bool
}

/// A credit note's answer: the job, and the note pushed onto `creditNotes`.
public struct CreditIssued: Decodable, Sendable {
    public let ok: Bool
    public let error: String?
    public let order: JSONValue
    public let note: JSONValue?
}

/// An RMA recorded on a job, and what a linked reprint should cost.
public struct RmaOpened: Decodable, Sendable {
    public let order: JSONValue
    /// `shop` or `billable` when the resolution is a reprint, else nil.
    public let reprintCost: String?
}

/// The intake funnel's figures.
public struct IntakeFunnel: Decodable, Sendable, Equatable {
    public let total: Int
    public let active: Int
    public let converted: Int
    public let declined: Int
    public let convertedPct: Double
    public let pipeline: Double
}

/// An enquiry saved, or why not (`project_required`, `gone`).
public struct IntakeSaved: Decodable, Sendable {
    public let ok: Bool
    public let error: String?
    public let list: [JSONValue]?
    public let item: JSONValue?
}

/// An enquiry turned into work: both lists afterwards, the customer it is
/// for (and the record to add when there was none), and the job's note.
public struct IntakePromoted: Decodable, Sendable {
    public let list: [JSONValue]
    public let history: [JSONValue]
    public let item: JSONValue
    public let clientId: String?
    public let createdClient: JSONValue?
    public let note: String
}
