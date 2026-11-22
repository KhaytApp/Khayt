import Foundation

/// The four sides a model is looked at from in the library's viewer, and the
/// camera each one is.
///
/// ── THE SAME CONVENTION AS A SLICER ───────────────────────────────────────
///
/// Z is up and the front of the bed is −Y, as every slicer lays a plate out.
/// FRONT looks from −Y with +X to the right, TOP looks down with +Y up the
/// picture, SIDE looks from +X (the slicer's "Right"), and ISO is the
/// three-quarter view from the front right, above — the picture a tile wears.
///
/// ── THE CAMERA IS A RIGHT-HANDED ONE ──────────────────────────────────────
///
/// The thumbnail renderer used to turn the model with a rotation whose
/// screen axis ran the wrong way for its depth axis: it drew the view from
/// the back-left, flipped — a mirror image, invisible on a vase and plain on
/// a nameplate. `project` is built from three orthonormal vectors (right, up,
/// towards the camera) with right × up = towards, so nothing it draws is
/// mirrored; the tests hold that on an asymmetric point set.
public enum ModelViewAngle: String, CaseIterable, Sendable, Codable {
    case iso, front, top, side

    /// Round the bed from the front, towards +X, in degrees.
    public var yawDegrees: Double {
        switch self {
        case .iso: 35
        case .front, .top: 0
        case .side: 90
        }
    }

    /// Above the bed, in degrees.
    public var pitchDegrees: Double {
        switch self {
        case .iso: 24
        case .front, .side: 0
        case .top: 90
        }
    }

    /// The word key for its button.
    public var key: String {
        switch self {
        case .iso: "mac.mv_iso"
        case .front: "mac.mv_front"
        case .top: "mac.mv_top"
        case .side: "mac.mv_side"
        }
    }

    public var camera: Camera { Camera(yawDegrees: yawDegrees, pitchDegrees: pitchDegrees) }

    /// An orthographic camera: where a point lands on the picture (`u` right,
    /// `v` up) and how near it is (`depth`, larger is nearer).
    public struct Camera: Sendable, Equatable {
        public let right: (Double, Double, Double)
        public let up: (Double, Double, Double)
        /// From the model towards the camera.
        public let towards: (Double, Double, Double)

        public init(yawDegrees: Double, pitchDegrees: Double) {
            let t = yawDegrees * .pi / 180, p = pitchDegrees * .pi / 180
            let ct = cos(t), st = sin(t), cp = cos(p), sp = sin(p)
            right = (ct, st, 0)
            up = (-sp * st, sp * ct, cp)
            towards = (st * cp, -ct * cp, sp)
        }

        @inline(__always)
        public func project(_ x: Double, _ y: Double, _ z: Double) -> (u: Double, v: Double, depth: Double) {
            (x * right.0 + y * right.1 + z * right.2,
             x * up.0 + y * up.1 + z * up.2,
             x * towards.0 + y * towards.1 + z * towards.2)
        }

        public static func == (a: Camera, b: Camera) -> Bool {
            a.right == b.right && a.up == b.up && a.towards == b.towards
        }
    }

    /// The plates a picker offers, from the plate numbers a file's triangles
    /// came on: sorted, each once, and none at all for a file of one plate.
    public static func platesToPick(_ seen: some Sequence<Int>) -> [Int] {
        let plates = Array(Set(seen)).sorted()
        return plates.count > 1 ? plates : []
    }
}
