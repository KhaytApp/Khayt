import Foundation

/// A colour's plain name, never its code (`lib/colour-name.js`).
///
/// Turki, Nov 27 2026: "dont want the color code, the actual color showing,
/// and color name if known". The swatch is drawn by the caller; this is the
/// word beside it. In KhaytCore so the phone names a colour the same way.
extension KhaytEngine {

    /// The spool's own name (`known`: the catalogue's `colourVariant`, a tag's
    /// `colorName`) when it has one; else the nearest everyday name in `lang`
    /// ("Black", "Light grey"), when one is close enough; else nil, and the
    /// caller shows the swatch alone. Never a hex.
    public func colourName(hex: String, lang: String, known: String? = nil) throws -> String? {
        try runtime.call2("KhaytColourName.colourName(ARG0, ARG1, ARG2)",
                          [.string(hex), .string(lang), known.map { .object(["known": .string($0)]) } ?? .null],
                          as: String?.self)
    }
}
