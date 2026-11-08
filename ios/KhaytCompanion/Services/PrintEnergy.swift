import Foundation
import KhaytCore

/**
 * What a print drew from the wall, on the phone: `lib/print-energy.js`
 * `energyWhOf`, `tariffOf`, `estimatedPowerCost` and `actualPowerCost`, and
 * `lib/print-rates.js` `shopTariff`, in Swift.
 *
 * The desktop (#2293) and the Mac write `actualEnergyWh` and `actualEnergy`
 * (`{ source: 'plug', coveredS, spanS, coverage, samples, gaps, at }`) onto
 * a FINISHED job a metering smart plug watched. The phone only reads them.
 *
 * `PrintEnergyParityTests` runs the real JavaScript in JavaScriptCore against
 * this file. Values are read as the JavaScript reads them: `Number(v)`, so
 * `null` and `""` are 0 and a numeric string is its number (`JSRead`).
 *
 * ── ONE PLACE THE JAVASCRIPT THROWS ──────────────────────────────────────
 *
 * `tariffOf` reads `p.elecRate` after `num(p && p.elecRate)` let a `null`
 * part through as 0, so a job whose `parts` holds a `null` throws. Here that
 * is `nil` from `tariffOf` and `actualPowerCost`: the page shows no cost
 * rather than one the shop's own rule would not give.
 */
enum EnergyRules {

    /// Below this share of the print metered, a reading is not used.
    static let minCoverage = 0.8
    /// `MAX_ELEC_RATE` in `lib/print-rates.js`.
    static let maxElecRate = 10_000.0

    /// `num`: `Number(v)` when finite, else nil. `null` is 0.
    static func num(_ v: JSONValue?) -> Double? {
        let n = JSRead.toNumber(v)
        return n.isFinite ? n : nil
    }

    /// `pos`: a number above zero, else nil.
    static func pos(_ v: JSONValue?) -> Double? {
        guard let n = num(v), n > 0 else { return nil }
        return n
    }

    /// `round(v, dp)`: `Math.round(v × 10^dp) / 10^dp`.
    static func round(_ v: Double, _ dp: Int) -> Double {
        let f = pow(10.0, Double(dp))
        return JSRead.round(v * f) / f
    }

    /// `energyWhOf`: the Wh a record measured, or nil — nil when none was,
    /// and nil when less than `minCoverage` of the print was. Above it, scaled
    /// to the whole span. A reading with no coverage is taken as it stands.
    static func energyWhOf(_ record: [String: JSONValue], minCoverage: Double? = nil) -> Double? {
        guard let wh = pos(record["actualEnergyWh"] != nil ? record["actualEnergyWh"] : record["energyWh"]) else {
            return nil
        }
        let meta: JSONValue? = JSRead.truthy(record["actualEnergy"]) ? record["actualEnergy"]
            : (JSRead.truthy(record["energy"]) ? record["energy"] : nil)
        var coverage: JSONValue?
        if case .object(let m)? = meta { coverage = m["coverage"] }
        let minCov = minCoverage.flatMap { $0 > 0 && $0.isFinite ? $0 : nil } ?? Self.minCoverage
        guard let cov = num(coverage) else { return wh }
        if cov < minCov { return nil }
        return round(wh / min(1, cov), 1)
    }

    private static func parts(_ order: [String: JSONValue]) -> [JSONValue] {
        if case .array(let p)? = order["parts"] { return p }
        return []
    }

    /// The first part that settles the tariff, as `tariffOf` walks them.
    private enum PartTariff { case said(Double), thrown, none }

    private static func partWalk(_ order: [String: JSONValue]) -> PartTariff {
        for p in parts(order) {
            switch p {
            case .null:
                return .thrown
            case .object(let part):
                let raw = part["elecRate"]
                if let r = num(raw), r >= 0, raw != .string(""), raw != .null { return .said(r) }
            default:
                // `false`, `0` and `""` read as 0 and have no `elecRate` to
                // refuse it: the JavaScript returns 0. Anything else is skipped.
                if !JSRead.truthy(p) { return .said(0) }
            }
        }
        return .none
    }

    /// `tariffOf`: the job's parts' own tariff, else the resolved rate, else
    /// 0. Nil where the JavaScript throws (a `null` part reached first).
    static func tariffOf(_ order: [String: JSONValue], rates: [String: JSONValue]) -> Double? {
        switch partWalk(order) {
        case .said(let r): return r
        case .thrown: return nil
        case .none:
            if let r = num(rates["elecRate"]), r >= 0 { return r }
            return 0
        }
    }

    /// The tariff the job's own parts carry, or nil when none does.
    static func partTariff(_ order: [String: JSONValue]) -> Double? {
        if case .said(let r) = partWalk(order) { return r }
        return nil
    }

    /// `estimatedPowerCost`: hours × watts × tariff × failure allowance × qty,
    /// each part's own figure first, else the rates'.
    static func estimatedPowerCost(_ order: [String: JSONValue], rates: [String: JSONValue]) -> Double {
        var total = 0.0
        for p in parts(order) {
            guard JSRead.truthy(p) else { continue }
            var part: [String: JSONValue] = [:]
            if case .object(let o) = p { part = o }
            func pick(_ k: String) -> Double {
                if let v = num(part[k]), part[k] != .string(""), part[k] != .null { return v }
                return num(rates[k]) ?? 0
            }
            let hours = max(0, num(part["printTime"]) ?? 0)
            let watts = max(0, pick("powerDraw"))
            let tariff = max(0, pick("elecRate"))
            let fr = max(0, pick("failureRate"))
            let qty = max(1, num(part["qty"]).flatMap { $0 == 0 ? nil : $0 } ?? 1)
            total += hours * (watts / 1000) * tariff * (1 + fr / 100) * qty
        }
        return total
    }

    struct PowerCost: Equatable {
        let cost: Double
        let measured: Bool
        let wh: Double?
        let estimated: Double
    }

    /// `actualPowerCost`: measured energy × the job's tariff when a plug
    /// metered enough of it; else hours × the rates' wattage × the tariff.
    static func actualPowerCost(_ order: [String: JSONValue], rates: [String: JSONValue]) -> PowerCost? {
        guard let tariff = tariffOf(order, rates: rates) else { return nil }
        let estimated = estimatedPowerCost(order, rates: rates)
        if let wh = energyWhOf(order) {
            return PowerCost(cost: (wh / 1000) * tariff, measured: true, wh: wh, estimated: estimated)
        }
        let hours = pos(order["actualPrintTime"]) ?? pos(order["printTime"]) ?? 0
        let watts = max(0, num(rates["powerDraw"]) ?? 0)
        return PowerCost(cost: hours * (watts / 1000) * tariff, measured: false, wh: nil, estimated: estimated)
    }

    /// `KhaytPrintRates.shopTariff`: what a kWh costs this shop, or nil when
    /// it has not said (absent, blank, negative, not a number). Clamped.
    static func shopTariff(_ settings: [String: JSONValue]) -> Double? {
        let v: Double
        switch settings["elecRate"] {
        case .number(let n)?: v = n
        case .string(let s)?:
            if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            v = JSRead.number(in: s)
        default: return nil
        }
        guard v.isFinite, v >= 0 else { return nil }
        return min(v, maxElecRate)
    }
}

/// What a finished job's page shows about the electricity it drew.
struct JobEnergy: Equatable {
    /// Measured energy, in kWh (`energyWhOf` ÷ 1000).
    let kWh: Double
    /// The power cost at the job's tariff, in the shop's currency — nil when
    /// neither the job nor the shop has a tariff.
    let cost: Double?
    let currency: String?

    /// From the job's record and the shop's settings. Nil when there is no
    /// reading, or `energyWhOf` refuses it — the page then shows nothing.
    static func of(order: [String: JSONValue], settings: [String: JSONValue]) -> JobEnergy? {
        guard let wh = EnergyRules.energyWhOf(order) else { return nil }
        var currency: String?
        if case .string(let c)? = settings["currency"], !c.trimmingCharacters(in: .whitespaces).isEmpty { currency = c }
        let shop = EnergyRules.shopTariff(settings)
        var cost: Double?
        if EnergyRules.partTariff(order) != nil || shop != nil {
            let rates: [String: JSONValue] = shop.map { ["elecRate": .number($0)] } ?? [:]
            cost = EnergyRules.actualPowerCost(order, rates: rates)?.cost
        }
        return JobEnergy(kWh: wh / 1000, cost: cost, currency: currency)
    }

    /// The job out of a book, by id.
    static func of(store: [String: JSONValue], orderId: String) -> JobEnergy? {
        var settings: [String: JSONValue] = [:]
        if case .object(let s)? = store["settings"] { settings = s }
        for case .object(let o) in JSRead.rows(store, "printLog") where o["id"] == .string(orderId) {
            return of(order: o, settings: settings)
        }
        return nil
    }
}
