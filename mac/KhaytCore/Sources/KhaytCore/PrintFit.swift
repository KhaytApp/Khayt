import Foundation

/// Will this model go on that bed?
///
/// ── WHY IT IS ITS OWN RULE ────────────────────────────────────────────────
///
/// The decision lived inside `mf-convert.js`, which is built on Node's zlib and
/// cannot be loaded anywhere but a main process. So the one question a maker
/// asks about a model before anything else — will it even fit on my printer —
/// could only be answered DURING a conversion, by the app that can run a
/// converter. This app has every number it needs and had no way to ask.
///
/// ── IT ANSWERS IN FACTS, NOT SENTENCES ────────────────────────────────────
///
/// `fitWarnings` returned English prose — "Model footprint 555×529 mm is larger
/// than …" — which an Arabic shop would have been shown verbatim. A rule that
/// answers in one language is a rule only one app can use. This returns the
/// numbers and lets each app say them.
public enum PrintFit {

    /// A millimetre of slack.
    ///
    /// Bed sizes are nominal and meshes carry floating-point bounds, so a model
    /// measured at 270.0001 mm on a 270 mm bed is a rounding artefact rather
    /// than a part that will not print. Inherited from `mf-convert.fitWarnings`,
    /// where it has always been ±1, and kept identical so the converter's
    /// answers do not move.
    public static let slack = 1.0

    static func num(_ value: JSONValue?) -> Double {
        let n = JSSemantics.number(value)
        return n.isFinite ? n : 0
    }

    public struct Over: Sendable, Equatable {
        public let x: Double
        public let y: Double
        public let z: Double
    }

    public struct Verdict: Sendable, Equatable {
        /// False when either side did not say. An unmeasured model, or a
        /// machine with no bed recorded, is NOT a model that does not fit and
        /// must never be shown as one.
        public let known: Bool
        public let ok: Bool
        public let footprint: Bool
        public let height: Bool
        /// Turned a quarter turn. A 300×200 model on a 250×250 bed does not fit
        /// as it lies and fits perfectly rotated, and the converter's own
        /// advice has always been "rotate or rescale in your slicer" — so
        /// saying WHICH is more use than refusing.
        public let rotated: Bool
        public let over: Over

        static let unknown = Verdict(known: false, ok: true, footprint: false,
                                     height: false, rotated: false,
                                     over: Over(x: 0, y: 0, z: 0))
    }

    public static func check(bounds: JSONValue?, bed: JSONValue?) -> Verdict {
        guard case .object(let m)? = bounds, case .object(let b)? = bed
        else { return .unknown }
        let mx = num(m["x"]), my = num(m["y"]), mz = num(m["z"])
        let bx = num(b["x"]), by = num(b["y"]), bz = num(b["z"])
        guard mx > 0, my > 0, bx > 0, by > 0 else { return .unknown }

        let footprint = mx > bx + slack || my > by + slack
        // A bed with no height recorded cannot refuse one, which is
        // `fitWarnings`' own rule: `if (b.z && …)`.
        let height = bz > 0 && mz > bz + slack
        // Only meaningful when it does not already fit.
        let rotated = footprint && !(my > bx + slack || mx > by + slack)

        return Verdict(known: true, ok: !footprint && !height,
                       footprint: footprint, height: height, rotated: rotated,
                       over: Over(x: Swift.max(0, mx - bx),
                                  y: Swift.max(0, my - by),
                                  z: bz > 0 ? Swift.max(0, mz - bz) : 0))
    }

    public enum Outcome: String, Sendable, Equatable {
        case fits, rotate, none
    }

    public struct Best: Sendable, Equatable {
        public let machineIndex: Int?
        public let verdict: Outcome
        public let checked: Int
    }

    /// The best a shop can do with the machines it owns: the first it fits
    /// outright, else the first it fits rotated, else nothing — which is the
    /// order a maker would try them in.
    ///
    /// The INDEX rather than the machine, because the caller already has the
    /// list and a copy across the bridge would be a second one.
    public static func bestFit(bounds: JSONValue?, machines: [JSONValue]) -> Best {
        var rotate: Int?
        var checked = 0
        for (i, machine) in machines.enumerated() {
            var bed: JSONValue?
            if case .object(let m) = machine { bed = m["bed"] }
            let r = check(bounds: bounds, bed: bed)
            guard r.known else { continue }
            checked += 1
            if r.ok { return Best(machineIndex: i, verdict: .fits, checked: checked) }
            if r.rotated && !r.height && rotate == nil { rotate = i }
        }
        if let rotate { return Best(machineIndex: rotate, verdict: .rotate, checked: checked) }
        return Best(machineIndex: nil, verdict: .none, checked: checked)
    }
}
