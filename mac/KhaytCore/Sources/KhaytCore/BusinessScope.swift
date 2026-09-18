import Foundation

/// Prints that happened, but were not business — ported to Swift.
///
/// A workshop prints things that are not jobs: a calibration cube, a bracket
/// for its own shelf, a gift, a test of a new filament. They ran on the machine
/// and used the material, and counting them as trade makes a shop's own numbers
/// lie to it — an average order value dragged down by a run of free test prints
/// is worse than no average at all.
///
/// ── WHAT THE FLAG DOES, AND WHAT IT DELIBERATELY DOES NOT ─────────────────
///
/// Scoped to MONEY AND TRADE COUNTS and nothing else, because the print was
/// real:
///
///   * **OUT** of revenue, order counts and reports. That is the whole point.
///   * **IN** for nozzle wear. A personal print wears a nozzle exactly as much
///     as a paid one — the abrasive filament does not know who it was for —
///     and a wear counter that ignored half a machine's work would warn late,
///     in the direction that ruins parts.
///   * **IN** for capacity and lead time. The machine is occupied either way,
///     so a promise made to a customer has to account for it.
///   * **IN** for the catalogue. A part printed for the shop's own use can
///     still be something the shop sells.
///
/// PORTED AND STILL BUNDLED: `order-money`, `kpi-rows` and `top-lists` all
/// read `KhaytBusinessScope` at run time. It leaves when they do.
public enum BusinessScope {

    /// Does this order count as trade?
    ///
    /// Deliberately not "is it valid" — a non-business print is a real record
    /// with real material behind it. This answers one question: should the
    /// money and the count appear in what the shop reports as its business.
    ///
    /// `!== true` and not "is falsy": only the literal `true` excludes a job,
    /// so a `nonBusiness` of `"no"` or `0` left behind by some other tool does
    /// not quietly drop a real sale out of the revenue.
    public static func countsForBusiness(_ order: JSONValue?) -> Bool {
        guard JSSemantics.truthy(order), case .object(let o)? = order else {
            // `!!order` — a truthy non-object has no `nonBusiness` to read, so
            // it counts. A falsy one does not.
            return JSSemantics.truthy(order)
        }
        return o["nonBusiness"] != .bool(true)
    }

    /// Has this order been REPLACED by the orders it was split into?
    ///
    /// Splitting a job across machines creates one sub-order per machine, each
    /// carrying a proportional share of the price, and leaves the parent behind
    /// with `status: 'split'` and its FULL PRICE INTACT. Nothing excluded the
    /// parent from the money, so a SAR 3,000 job split in two showed SAR 3,000
    /// owed on the parent PLUS SAR 3,000 across the children — measured at
    /// 5,000 owed against 2,000 actually owed.
    ///
    /// A superseded parent is not a debt and not a sale; it is a record of what
    /// the children came from.
    public static func isSuperseded(_ order: JSONValue?) -> Bool {
        guard case .object(let o)? = order, case .string("split")? = o["status"],
              case .array(let into)? = o["splitInto"] else { return false }
        return !into.isEmpty
    }

    /// The trade subset of a queue, for the aggregations that report money.
    public static func businessOrders(_ orders: [JSONValue]) -> [JSONValue] {
        orders.filter(countsForBusiness)
    }
}
