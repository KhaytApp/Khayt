import Foundation

/// Can this model start on that machine — the spools AND the bed, together.
///
/// ── TWO RULES THAT NEVER MET ──────────────────────────────────────────────
///
/// "Ready" was answered from the spools alone (`readyToPrint`: the colours the
/// file needs are loaded) and "Fits" from the bed alone (`PrintFit`). The
/// library inspector drew both, one above the other, and a model too big for
/// every machine the shop owns read "Too big for every machine you have" over
/// "Snapmaker U1 — Ready to start" (library audit, Oct 2026). A print that
/// does not go on the bed is not ready on that machine, whatever is loaded.
///
/// So the two are asked HERE, once, and every screen that says "ready" — the
/// inspector's summary, its filament rows, the Ready-on chip's count — reads
/// this answer.
///
/// ── UNKNOWN IS NOT A REFUSAL ──────────────────────────────────────────────
///
/// A model with no measured mesh, or a machine with no bed recorded, is NOT a
/// model that does not fit (`PrintFit.Verdict.known`). Spool readiness then
/// stands on its own, exactly as before this rule existed.
public enum ModelReadiness {

    public enum State: String, Sendable, Equatable, CaseIterable {
        /// The spools it needs are loaded and it goes on the bed.
        case ready
        /// Loaded, and it goes on the bed turned a quarter turn.
        case readyTurned
        /// It goes on the bed, but a spool has to change first.
        case needsSwap
        /// It goes on the bed; the machine does not say what it has loaded.
        case fits
        /// It goes on the bed turned; nothing known about the spools.
        case fitsTurned
        /// It does not go on this bed, either way round.
        case tooBig
    }

    /// The answer for one model on one machine, or nil when nothing at all is
    /// known (no bed, no mesh and no spools reported).
    ///
    /// - Parameters:
    ///   - bounds: the model's `{x, y, z}` in millimetres, or nil.
    ///   - bed: the machine's `bed` record, or nil.
    ///   - spoolsReady: what the spool rule said — nil when the machine does
    ///     not report or record what it has loaded.
    public static func state(bounds: JSONValue?, bed: JSONValue?, spoolsReady: Bool?) -> State? {
        let fit = PrintFit.check(bounds: bounds, bed: bed)
        // Turned only helps when the height fits too (`PrintFit.bestFit`).
        let turned = fit.known && !fit.ok && fit.rotated && !fit.height
        if fit.known && !fit.ok && !turned { return .tooBig }
        switch spoolsReady {
        case true?: return turned ? .readyTurned : .ready
        case false?: return .needsSwap
        case nil: return fit.known ? (turned ? .fitsTurned : .fits) : nil
        }
    }

    /// True only when it can start now: loaded AND on the bed.
    public static func canStart(_ state: State?) -> Bool {
        state == .ready || state == .readyTurned
    }

    /// `{x, y, z}` from a measured box, for the rule above.
    public static func bounds(x: Double, y: Double, z: Double) -> JSONValue {
        .object(["x": .number(x), "y": .number(y), "z": .number(z)])
    }
}

/// What a sale keeps, as a share of the price — and whether it is below the
/// floor the shop set (`settings.minMarginPct`, the calculator's own warning).
///
/// The calculator says "margin" the same way: (price − cost) ÷ price, so a
/// figure here and the one on a quote for the same model agree.
public enum ModelMargin {

    /// The margin on price, 0…1 (negative when sold at a loss); nil when
    /// there is no price to divide by.
    public static func onPrice(price: Double, cost: Double) -> Double? {
        guard price.isFinite, cost.isFinite, price > 0 else { return nil }
        return (price - cost) / price
    }

    /// Below the shop's floor. No floor set (0 or absent) never warns: the
    /// calculator's own rule is `minPct > 0 && actual < minPct`.
    public static func belowFloor(_ margin: Double?, floorPct: Double?) -> Bool {
        guard let margin, let floorPct, floorPct.isFinite, floorPct > 0 else { return false }
        return margin * 100 < floorPct
    }
}
