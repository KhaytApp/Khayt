import Foundation

/// The key for "the same mesh, however it was packaged" — ported to Swift.
///
/// ── THE FIRST MODULE OF THE PORT, AND WHY IT IS THIS ONE ──────────────────
///
/// It is three numbers joined by punctuation, which `lib/geometry-key.js` says
/// is "exactly the kind of thing two implementations agree on until they do
/// not: a rounding, a separator, an order". That makes it the honest first
/// test of whether a port can hold: if Swift can reproduce this byte for byte
/// over generated input, the method works; if it cannot, better to learn that
/// on seventy lines than on seven hundred.
///
/// Every key here is compared against records the other app wrote, so this is
/// not a re-derivation of what a geometry key OUGHT to be. It is the same
/// answer, spelled the same way, including the parts that look like accidents:
/// `Math.round`'s half-up, and a whole number printed without a `.0`. Both live
/// in `JSSemantics` and both are why this is a port rather than a rewrite.
///
/// `test/…`'s JavaScript remains the specification. `GeometryKeyParityTests`
/// runs both over generated geometry and fails on the first disagreement.
public enum GeometryKey {

    /// Which reader measured a record, and the number that goes up when a
    /// reader fault is fixed.
    ///
    /// Reader 2: one plate's size rather than every plate boxed together,
    /// every component placed, roots over 8 MB read, zip64 containers opened.
    public static let reader = 2

    /// `round(v, dp)` — nil where the module returns null.
    public static func round(_ value: JSONValue?, _ dp: Int) -> Double? {
        let n = JSSemantics.number(value)
        guard n.isFinite else { return nil }
        let f = pow(10.0, Double(dp))
        return JSSemantics.round(n * f) / f
    }

    /// The key, or nil for geometry with no substance.
    ///
    /// Nil rather than a key, so an unparsed or empty model never acquires an
    /// identity that another empty one would share.
    public static func key(of geometry: JSONValue?) -> String? {
        guard case .object(let g)? = geometry else {
            // `geometry || {}` in the module: anything that is not an object
            // reads as an empty one, and an empty one has no triangles.
            return nil
        }
        let tris = JSSemantics.number(g["triangleCount"])
        let volume = JSSemantics.number(g["volumeMm3"])
        guard tris.isFinite, tris > 0 else { return nil }
        guard volume.isFinite, volume > 0 else { return nil }

        var box: [String: JSONValue] = [:]
        if case .object(let b)? = g["bbox"] { box = b }
        guard let x = round(box["x"], 2), let y = round(box["y"], 2),
              let z = round(box["z"], 2), let vol = round(.number(volume), 2)
        else { return nil }

        let dims = [x, y, z].map(JSSemantics.string).joined(separator: "x")
        return "\(JSSemantics.string(tris)):\(JSSemantics.string(vol)):\(dims)"
    }

    /// Whether a record is due to be measured again.
    public static func needsRemeasure(_ record: JSONValue?) -> Bool {
        var value: JSONValue?
        if case .object(let r)? = record { value = r["geometryReader"] }
        let n = JSSemantics.number(value)
        return !(n.isFinite && n >= Double(reader))
    }
}
