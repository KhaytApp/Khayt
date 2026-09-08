import Foundation

/// Which member of a `.3mf` is the picture of the print.
///
/// A 3MF is a zip. The format's own specification puts a preview at
/// `/Metadata/thumbnail.png`, and almost nothing writes one: the slicers a shop
/// actually uses write their own. Surveying the ten files in one real library
/// found no spec thumbnails at all and `Metadata/plate_1.png` in every single
/// file, so the rule below is written from what is in the files rather than
/// from what the standard says ought to be.
///
/// ── WHAT IS IN THERE, AND WHY MOST OF IT IS WRONG ─────────────────────────
///
/// An OrcaSlicer project carries several PNGs per plate and only one of them is
/// a picture a person would recognise:
///
/// * `plate_1.png`          the rendered plate. This is the one.
/// * `plate_1_small.png`    the same image at thumbnail size. Passed over on
///                          purpose: Quick Look asks for a size and scales, and
///                          starting from the larger one is sharper on a Retina
///                          display for the sake of about 130 KB read once.
/// * `plate_no_light_1.png` the same plate with the lighting off — flat, dark,
///                          and not what the object looks like.
/// * `top_1.png`            a plan view. Correct, and unrecognisable as the
///                          model for anything that is not flat.
/// * `pick_1.png`           a colour-coded mask the slicer uses to work out
///                          which object the mouse is over. Not a picture at
///                          all: solid blocks of flat colour.
///
/// A file with ten plates has ten of each. The lowest-numbered plate is taken,
/// because that is the one a slicer opens on and the one whose image the shop
/// has already seen.
public enum ThreeMF {

    /// The preview inside a 3MF, given the names of its members.
    ///
    /// Nil when there is none — which is a real answer for a 3MF exported by a
    /// CAD program rather than a slicer, and better than handing back a picking
    /// mask.
    public static func preview(among names: [String]) -> String? {
        // The format's own, whatever case it was written in.
        if let spec = names.first(where: {
            $0.lowercased() == "metadata/thumbnail.png"
        }) { return spec }

        // Then the lowest-numbered plate render. The pattern is deliberately
        // strict — `plate_` then digits then `.png` — so that `plate_1_small`,
        // `plate_no_light_1` and everything else fail to match rather than
        // being excluded by a list that the next slicer version can outgrow.
        var best: (number: Int, name: String)?
        for name in names {
            guard let n = plateNumber(of: name) else { continue }
            if best == nil || n < best!.number { best = (n, name) }
        }
        return best?.name
    }

    /// The plate number in `Metadata/plate_<n>.png`, or nil for anything else.
    static func plateNumber(of name: String) -> Int? {
        let lower = name.lowercased()
        let prefix = "metadata/plate_"
        let suffix = ".png"
        guard lower.hasPrefix(prefix), lower.hasSuffix(suffix) else { return nil }
        let middle = lower.dropFirst(prefix.count).dropLast(suffix.count)
        guard !middle.isEmpty, middle.allSatisfy(\.isNumber) else { return nil }
        return Int(middle)
    }
}
