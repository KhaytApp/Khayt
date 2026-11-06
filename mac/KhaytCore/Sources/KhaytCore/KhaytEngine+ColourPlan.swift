import Foundation

/// The multicolour print planner and MakerRun's vocabularies, on the shop's
/// engine. Every answer is a shared module's — `lib/color-plan.js` and
/// `lib/makerrun-terms.js`, the files the desktop's planner modal and Bed
/// Ready's publish form run — so the Mac cannot start a colour on a different
/// spool, or offer a different licence, than the other app.
extension KhaytEngine {

    // MARK: - Colour plan

    /// One row of a plan, in the book's own field names (`rec.colorPlan`
    /// holds `hex`, `filamentId` and `grams`; `label` is the screen's).
    public struct ColourPlanRow: Codable, Sendable, Hashable {
        public var hex: String
        public var label: String
        public var grams: Double
        public var filamentId: String
        public init(hex: String, label: String, grams: Double, filamentId: String) {
            self.hex = hex; self.label = label; self.grams = grams; self.filamentId = filamentId
        }
    }

    /// What a plan comes to: per-row cost and colour distance, the totals,
    /// and the AMS slot map.
    public struct ColourPlanSummary: Decodable, Sendable, Equatable {
        public struct Row: Decodable, Sendable, Equatable {
            public let hex: String
            public let filamentId: String
            public let grams: Double
            /// Nil when the row has no spool.
            public let cost: Double?
            public let deltaE: Double?
        }
        public let rows: [Row]
        public let totalGrams: Double
        public let totalCost: Double
        /// One slot per distinct spool with grams, in colour order.
        public let slots: [String]
        /// Spools past one AMS set, swapped in by hand.
        public let overflow: Int
    }

    /// The plan the planner opens on: each colour keeps the spool the shop
    /// chose last time while it is still on the shelf, else the nearest
    /// colour (CIEDE2000). `colours` is the record's `colors`, `saved` its
    /// `colorPlan`, `inventory` the book's spools as stored.
    public func initialColourPlan(colours: [JSONValue], saved: [JSONValue],
                                  inventory: [JSONValue]) throws -> [ColourPlanRow] {
        try runtime.call2("""
            (function (colours, saved, inv) {
              const cands = KhaytColorPlan.colouredFilaments(inv);
              return KhaytColorPlan.initialPlan(colours, saved, cands);
            })(ARG0, ARG1, ARG2)
            """, [.array(colours), .array(saved), .array(inventory)], as: [ColourPlanRow].self)
    }

    public func summariseColourPlan(_ plan: [ColourPlanRow], inventory: [JSONValue]) throws -> ColourPlanSummary {
        let rows = try JSONValue.decode(JSONValue.self, from: JSONEncoder().encode(plan))
        return try runtime.call2("""
            (function (plan, inv) {
              const s = KhaytColorPlan.summarise(plan, KhaytColorPlan.colouredFilaments(inv));
              return { rows: s.rows, totalGrams: s.totalGrams, totalCost: s.totalCost,
                       slots: s.slots, overflow: s.overflow };
            })(ARG0, ARG1)
            """, [rows, .array(inventory)], as: ColourPlanSummary.self)
    }

    /// "good", "ok", "far" or "" — the planner's three bands of closeness.
    public func colourCloseness(_ deltaE: Double?) throws -> String {
        guard let deltaE, deltaE.isFinite else { return "" }
        return try runtime.call2("KhaytColorPlan.closeness(ARG0)", [.number(deltaE)], as: String.self)
    }

    /// How many filaments one AMS set holds — the module's figure.
    public func amsSlots() throws -> Int {
        try runtime.call2("KhaytColorPlan.AMS_SLOTS", [], as: Int.self)
    }

    // MARK: - MakerRun vocabularies

    public struct MakerRunTerms: Decodable, Sendable, Equatable {
        public struct Category: Decodable, Sendable, Equatable, Hashable {
            public let value: String
            public let label: String
        }
        public let categories: [Category]
        public let materials: [String]
        public let licences: [String]
    }

    public func makerRunTerms() throws -> MakerRunTerms {
        try runtime.call2("""
            ({ categories: BedReadyMakerRunTerms.CATEGORIES, materials: BedReadyMakerRunTerms.MATERIALS,
               licences: BedReadyMakerRunTerms.LICENCES })
            """, [], as: MakerRunTerms.self)
    }

    /// A MakerRun licence string → the record's licence id, or nil when it
    /// cannot be read with certainty.
    public func recordLicence(fromMakerRun licence: String?) throws -> String? {
        try runtime.call2("BedReadyMakerRunTerms.toRecordLicence(ARG0)",
                          [licence.map(JSONValue.string) ?? .null], as: String?.self)
    }

    /// A record licence id → the MakerRun string to publish under, or nil.
    public func makerRunLicence(fromRecord id: String?) throws -> String? {
        try runtime.call2("BedReadyMakerRunTerms.toMakerRunLicence(ARG0)",
                          [id.map(JSONValue.string) ?? .null], as: String?.self)
    }

    /// May a print be sold under this licence? true, false, or nil for "read it".
    public func commercialUse(_ licence: String?) throws -> Bool? {
        try runtime.call2("BedReadyMakerRunTerms.commercialUse(ARG0)",
                          [licence.map(JSONValue.string) ?? .null], as: Bool?.self)
    }
}
