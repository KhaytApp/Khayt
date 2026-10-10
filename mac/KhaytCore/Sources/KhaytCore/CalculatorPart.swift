import Foundation

/// The part the shared cost model is handed, built from what a calculator
/// screen holds: the filament lines, the purge, the hours, the pieces.
///
/// ── WHY IT IS HERE AND NOT IN A SCREEN ────────────────────────────────────
///
/// It was written twice: `Shop.costInput` and `CalculatorModel.costInput` on
/// the Mac, and the iPhone's calculator was about to be the third. The cost
/// model itself (`lib/calculator-cost.js`) is already one copy; the shape of
/// what it is handed — purge shared across colours by weight, a spool's price
/// per gram, consumables carrying their own unit cost — is just as much a rule,
/// and two copies of it would quote the same print differently on two devices.
/// Both apps adapt their own spool and consumable types to the small values
/// below and call this.
public enum CalculatorPart {

    /// A spool, as far as costing needs one.
    public struct Spool: Sendable, Equatable {
        public let id: String
        public let material: String
        public let cost: Double?
        /// What the full spool weighed — what `cost` bought.
        public let spoolWeight: Double?
        public let color: String?

        public init(id: String, material: String, cost: Double?, spoolWeight: Double?, color: String?) {
            self.id = id; self.material = material; self.cost = cost
            self.spoolWeight = spoolWeight; self.color = color
        }
    }

    /// One filament line: a spool and the grams printed from it.
    public struct Line: Sendable, Equatable {
        public let spool: Spool?
        public let grams: Double
        /// The colour the model asked for, when the line came from a file.
        public let hex: String?

        public init(spool: Spool?, grams: Double, hex: String? = nil) {
            self.spool = spool; self.grams = grams; self.hex = hex
        }
    }

    /// A consumable on the shelf, as far as costing needs one.
    public struct ShelfItem: Sendable, Equatable {
        public let id: String
        public let name: String?
        public let cost: Double?

        public init(id: String, name: String?, cost: Double?) {
            self.id = id; self.name = name; self.cost = cost
        }
    }

    /// One spool, one weight. `extra` is the part as the book holds it — its
    /// own labour, power, wear and failure figures beat the machine's defaults
    /// inside `costPart` — and the four measured fields are written over it.
    public static func single(spool: Spool?, grams: Double, hours: Double, qty: Int,
                              extra: [String: JSONValue] = [:]) -> JSONValue {
        var part = extra
        part["printWeight"] = .number(max(0, grams))
        part["printTime"] = .number(max(0, hours))
        part["qty"] = .number(Double(max(1, qty)))
        if let spool {
            part["filamentId"] = .string(spool.id)
            part["material"] = .string(spool.material)
            part["spoolCost"] = .number(spool.cost ?? 0)
            // At least one gram: the cost model divides by this.
            part["spoolWeight"] = .number(max(1, spool.spoolWeight ?? 1000))
        }
        return .object(part)
    }

    /// The whole calculator: one line or several, the purge, the pieces.
    ///
    /// Several colours make one part with `colours` and a pre-summed
    /// `spoolCost`/`spoolWeight` (the shape `lib/calculator-cost.js` prices).
    /// Purge is shared across the colours by weight, so each spool carries its
    /// share. With one colour the purge is that spool's, charged as support is.
    public static func input(lines: [Line], purge: Double, hours: Double, qty: Int,
                             pieces: [JSONValue] = [], extra: [String: JSONValue] = [:]) -> JSONValue {
        let used = lines.filter { $0.grams > 0 }
        var part: [String: JSONValue]
        if used.count > 1 {
            let printed = used.reduce(0) { $0 + $1.grams }
            var colours: [JSONValue] = []
            var totalCost = 0.0, totalGrams = 0.0
            var materials: [String] = []
            var dominant: (id: String, grams: Double)?
            for line in used {
                let g = line.grams + (printed > 0 ? purge * line.grams / printed : 0)
                let s = line.spool
                let perGram = s.map { ($0.cost ?? 0) / max(1, $0.spoolWeight ?? 1000) } ?? 0
                var c: [String: JSONValue] = ["grams": .number(g), "cost": .number(perGram * g)]
                if let s {
                    c["filamentId"] = .string(s.id)
                    c["material"] = .string(s.material)
                    if !materials.contains(s.material) { materials.append(s.material) }
                    if g > (dominant?.grams ?? -1) { dominant = (s.id, g) }
                }
                if let hex = line.hex ?? s?.color, !hex.isEmpty { c["hex"] = .string(hex) }
                colours.append(.object(c))
                totalCost += perGram * g
                totalGrams += g
            }
            part = extra
            part["colours"] = .array(colours)
            part["printWeight"] = .number(totalGrams)
            part["spoolCost"] = .number(totalCost)
            part["spoolWeight"] = .number(max(1, totalGrams))
            part["printTime"] = .number(max(0, hours))
            part["qty"] = .number(Double(max(1, qty)))
            if let dominant { part["filamentId"] = .string(dominant.id) }
            if !materials.isEmpty { part["material"] = .string(materials.joined(separator: " + ")) }
            if purge > 0 { part["purgeGrams"] = .number(purge) }
        } else {
            let line = used.first ?? lines.first
            var withPurge = extra
            if purge > 0 { withPurge["supportWeight"] = .number(purge) }
            guard case .object(let o) = single(spool: line?.spool, grams: line?.grams ?? 0,
                                               hours: hours, qty: qty, extra: withPurge)
            else { return .object([:]) }
            part = o
        }
        if !pieces.isEmpty { part["consumables"] = .array(pieces) }
        return .object(part)
    }

    /// Consumable lines as a part records them. `unitCost` is written beside
    /// the id so a host without the shelf in reach still costs the magnet at
    /// what it cost, never at nothing; `name` so the other app can show it.
    /// Finite and at most 9,999: `.number(inf)` makes JSONEncoder throw, and
    /// the whole book write with it.
    public static func consumableRows(_ uses: [(id: String, qty: Double)], shelf: [ShelfItem]) -> [JSONValue] {
        uses.compactMap { use in
            guard !use.id.isEmpty, use.qty.isFinite, use.qty > 0 else { return nil }
            var row: [String: JSONValue] = ["consumableId": .string(use.id),
                                            "qty": .number(Swift.min(9999, use.qty))]
            if let item = shelf.first(where: { $0.id == use.id }) {
                let cost = item.cost ?? 0
                row["unitCost"] = .number(cost.isFinite ? max(0, cost) : 0)
                if let name = item.name, !name.isEmpty { row["name"] = .string(name) }
            }
            return .object(row)
        }
    }

    /// What `lib/pricing.js` `quoteTotal` is handed for a calculator's price:
    /// the cost, the margin, the discount, and the shop's own rush percentage
    /// (`settings.rushFeePct`, or Khayt's default of twenty-five).
    public static func quoteInput(baseCost: Double, margin: Double, discountPct: Double,
                                  shippingCost: Double = 0, rush: Bool, agreedAmount: Double = 0,
                                  settings: [String: JSONValue]) -> [String: JSONValue] {
        var input: [String: JSONValue] = [
            "baseCost": .number(baseCost), "qty": .number(1),
            "margin": .number(margin), "discountPct": .number(discountPct),
            "shippingCost": .number(shippingCost),
            "rushEnabled": .bool(rush), "business": .bool(true),
            "agreedAmount": .number(agreedAmount),
        ]
        if rush {
            var pct = 25.0
            if case .number(let own)? = settings["rushFeePct"] { pct = own }
            input["rushPct"] = .number(pct)
        }
        return input
    }
}
