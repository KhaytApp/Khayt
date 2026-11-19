import Foundation
import KhaytCore

/// Price a job again from its parts (Turki, Nov 19: "no way to recalculate a
/// price"; Figma Mac file p.19).
///
/// Once a price was kept as a typed one (typed in "Or set the price", kept on
/// a seen quote, or kept by the rule for a price its parts do not explain) the
/// markup could not be edited and clearing the price field sent nothing: there
/// was no way back to the arithmetic. The shared rule (`lib/order-edit.js`
/// `applyJobEdit { reprice }`, #2576) prices the job exactly as `newOrder`
/// would from its parts at a markup, drops the typed price and logs the
/// change, under the same locks as any price edit: a frozen job is refused,
/// the price may not go below what was paid, and a price the customer has
/// seen, or an issued proforma above the new price, is asked about first.
extension Shop {

    /// What a reprice would do, or why it cannot.
    enum RepriceAnswer: Equatable {
        /// The job as it would be saved, its price before and after, and the
        /// markup the rule used.
        case ready(order: JSONValue, was: Double, now: Double, markup: Double?)
        /// Needs the shop's yes first: `ask_price` (the customer has seen the
        /// price) or `milestones_issued` (a sent proforma asks for more).
        case ask(String)
        /// Refused, in the shop's words.
        case refused(String)
    }

    /// The rule's answer for this job, on a copy; nothing is written.
    nonisolated static func repriced(_ order: JSONValue, marginPct: Double?, priceSeenOk: Bool,
                                     milestonesOk: Bool, clients: [JSONValue],
                                     settings: [String: JSONValue], overheadPerHour: Double?,
                                     engine: KhaytEngine, refusals: [String: String]) async -> RepriceAnswer {
        let req: JSONValue = .object(marginPct.map { ["marginPct": .number($0)] } ?? [:])
        guard let r = try? await engine.applyJobEdit(
            order: order, fields: ["reprice": req], clients: clients, settings: settings,
            priceSeenOk: priceSeenOk, milestonesOk: milestonesOk, overheadPerHour: overheadPerHour,
            now: Date(), editId: uid("edit"), priceId: uid("edit")) else {
            return .refused(refusals["unknown"] ?? "")
        }
        guard r.ok else {
            let code = r.reason ?? "unknown"
            if code == "ask_price" || code == "milestones_issued" { return .ask(code) }
            return .refused(refusals["price." + code] ?? refusals[code] ?? refusals["unknown"] ?? code)
        }
        let was = plainNumber(asObject(order)?["price"]) ?? 0
        let now = plainNumber(asObject(r.order)?["price"]) ?? was
        return .ready(order: r.changed ? r.order : order, was: was, now: now, markup: r.marginPct)
    }

    /// What the sheet sends for the questions answered so far. Both yeses go
    /// together: the rule asks the seen price before a sent proforma, so a
    /// save that carried only the latest yes was asked the first again.
    nonisolated static func repriceYeses(_ answered: Set<String>) -> (priceSeen: Bool, milestones: Bool) {
        (answered.contains("ask_price"), answered.contains("milestones_issued"))
    }

    /// The repriced job's cost in the JOB's currency. `lib/order-money.js
    /// jobCost` is in the shop's currency; a USD job taken at 3.75 shows its
    /// SAR cost divided by its own rate, as the job page does.
    nonisolated static func repriceCost(_ order: JSONValue, engine: KhaytEngine) async -> Double? {
        guard let shopCost = try? await engine.jobCost(order) else { return nil }
        let fx: Double = { if case .number(let r)? = asObject(order)?["fxRate"], r > 0 { return r }; return 1 }()
        return inJobCurrency(shopCost, fxRate: fx)
    }

    /// The refusals a reprice can say: the price lock's and the parts rule's.
    static func repriceRefusalWords(_ words: Words) -> [String: String] {
        jobSaveRefusalWords(words)
    }

    /// The preview the sheet shows, as if the shop had said yes to every
    /// question: the questions are asked on Save.
    func previewReprice(_ id: Order.ID, marginPct: Double?) async -> RepriceAnswer? {
        guard let engine, let row = orderRow(id) else { return nil }
        return await Self.repriced(row, marginPct: marginPct, priceSeenOk: true, milestonesOk: true,
                                   clients: clientRows, settings: settingsDict, overheadPerHour: Self.repriceOverhead,
                                   engine: engine, refusals: Self.repriceRefusalWords(words))
    }

    /// The overhead a reprice charges: nil, the JOB's own rate (`order-edit.js`
    /// reads it off the job), never the shop's rate today. Passing the shop's
    /// gave an online or shelf job priced without overhead a share of it on
    /// Recalculate (release data review). If a shop ever opts in to
    /// re-charging overhead, this is where it is decided.
    nonisolated static let repriceOverhead: Double? = nil

    /// Reprice the job, inside the write, on the book as it is on disk.
    /// Returns the rule's answer: `.ready` when it was written, `.ask` when the
    /// shop must say yes first (nothing written), `.refused` with the reason.
    @discardableResult
    func reprice(_ id: Order.ID, marginPct: Double?, priceSeenOk: Bool,
                 milestonesOk: Bool) async -> RepriceAnswer? {
        guard permitted("orders", "edit") else { return nil }
        let refusals = Self.repriceRefusalWords(words)
        let overhead = Self.repriceOverhead
        var answer: RepriceAnswer?
        let wrote = await writeToOneOrder(id, named: words.callIt("mac.rc_title"), as: .person("orders", "edit")) { order, engine, root in
            let a = await Self.repriced(order, marginPct: marginPct, priceSeenOk: priceSeenOk,
                                        milestonesOk: milestonesOk, clients: Self.rows(root, "clients"),
                                        settings: Self.settings(root), overheadPerHour: overhead,
                                        engine: engine, refusals: refusals)
            answer = a
            switch a {
            case .ready(let out, _, _, _): return OneOrderEdit(order: out)
            case .ask, .refused: return OneOrderEdit(order: order)
            }
        }
        if !wrote, answer == nil { return nil }
        return answer
    }
}
