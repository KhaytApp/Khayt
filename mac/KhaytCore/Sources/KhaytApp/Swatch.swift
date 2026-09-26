import SwiftUI

/// A filament colour, drawn so it can be seen.
///
/// A white swatch on a white panel is nothing at all. The library inspector
/// outlined every colour in `.separator` — which is visible around a black
/// filament and INVISIBLE around a white one, because a hairline designed to
/// sit on the window background disappears when the fill is the window
/// background. This shop prints white; three of the four filaments on its Hulk
/// helmet showed a swatch and the fourth showed a gap.
///
/// The outline is therefore chosen from the FILL, never from the surroundings:
/// a dark line around a pale colour and a pale line around a dark one. That is
/// the only version that survives both light mode and dark, and a swatch drawn
/// over a photograph as well as over a panel.
struct Swatch: View {
    let rgb: (r: Double, g: Double, b: Double)?
    var size: CGFloat = 14
    var corner: CGFloat = 3
    /// A circle for the small dots on a thumbnail, a rounded square in a list.
    var round = false

    /// `#RRGGBB` → components, or nil.
    ///
    /// Lived on `LibraryFile.Colour` and is now here, because the filament
    /// shelf needs the same reading and a second parser is how one screen comes
    /// to show a colour the other calls unknown. An unparseable or absent value
    /// is nil rather than black — black is a real filament choice and must not
    /// be what "nobody said" looks like.
    ///
    /// `#RGB` and `#RRGGBBAA` are read too. A Bambu AMS reports its trays as
    /// `RRGGBBAA` and Spoolman allows the alpha, so a spool that came in that
    /// way HAD a colour and the shelf drew it as the grey disc of "nobody
    /// said" — the one thing this reading exists to prevent. The alpha is
    /// dropped: a filament is not see-through on a shelf card.
    static func rgb(fromHex hex: String?) -> (r: Double, g: Double, b: Double)? {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.allSatisfy(\.isHexDigit) else { return nil }
        switch s.count {
        case 3: s = s.map { "\($0)\($0)" }.joined()
        case 8: s = String(s.prefix(6))
        default: break
        }
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    /// Perceived brightness — the ITU-R BT.709 coefficients, which weight green
    /// far above blue because an eye does. A flat average calls #0000FF light.
    static func isPale(_ c: (r: Double, g: Double, b: Double)) -> Bool {
        (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b) > 0.6
    }

    var body: some View {
        Group {
            if let rgb {
                shape
                    .fill(Color(red: rgb.r, green: rgb.g, blue: rgb.b))
                    .overlay(shape.stroke(Self.outline(rgb), lineWidth: size < 12 ? 0.5 : 1))
            } else {
                // No colour recorded. Dashed, so it reads as "not known" rather
                // than as a colour that happens to match the paper.
                shape.stroke(.separator, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
        .frame(width: size, height: size)
    }

    /// `InsettableShape` is what `strokeBorder` needs and `AnyShape` is not one,
    /// so the stroke is drawn on the path and the frame keeps it inside.
    private var shape: AnyShape {
        round ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: corner))
    }

    private static func outline(_ rgb: (r: Double, g: Double, b: Double)) -> Color {
        isPale(rgb) ? .black.opacity(0.28) : .white.opacity(0.45)
    }
}
