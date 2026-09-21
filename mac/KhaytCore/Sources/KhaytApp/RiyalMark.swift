import SwiftUI

/// The Saudi Riyal sign, drawn.
///
/// ── WHY THIS IS A PATH AND NOT A CHARACTER ────────────────────────────────
///
/// The figure face — the tabular one every money figure in this app is set in
/// — has no U+20C1. So the mark could not be part of the figure's own run, and
/// it was set instead in the LABEL face beside it: a different cut, a
/// different optical weight, sitting next to digits it belongs to. On screen
/// that reads as a mark borrowed from somewhere else, which is exactly what it
/// was.
///
/// The answer the code already named — "`KhaytRiyal` is still the better cut
/// and still the plan" — was a font nobody ever cut. There is no such family
/// on any Mac, so `hasOwnFace` had been false since the day it was written and
/// every figure took the fallback.
///
/// But the mark is already drawn elsewhere in this product: the invoice sets
/// it as an SVG path, for the same reason, and has since ZATCA made the glyph
/// something that has to be certain. This is that path. One mark now, on the
/// paper and on the screen, and it takes the colour and the size of the text
/// it sits in because it is drawn rather than looked up.
///
/// `RiyalMarkTests` holds this data to `lib/invoice-document.js`'s, so the two
/// cannot drift into being two different marks.
struct RiyalMark: Shape {

    /// The outline, exactly as `lib/invoice-document.js` carries it.
    ///
    /// Copied rather than derived: there is no build step between the two
    /// products, and a test comparing them is a better guarantee than a
    /// generator nobody runs.
    static let viewBox = CGSize(width: 1124.14, height: 1256.39)

    static let subpaths = [
        "M699.62,1113.02h0c-20.06,44.48-33.32,92.75-38.4,143.37l424.51-90.24c20.06-44.47,33.31-92.75,38.4-143.37l-424.51,90.24Z",
        "M1085.73,895.8c20.06-44.47,33.32-92.75,38.4-143.37l-330.68,70.33v-135.2l292.27-62.11c20.06-44.47,33.32-92.75,38.4-143.37l-330.68,70.27V66.13c-50.67,28.45-95.67,66.32-132.25,110.99v403.35l-132.25,28.11V0c-50.67,28.44-95.67,66.32-132.25,110.99v525.69l-295.91,62.88c-20.06,44.47-33.33,92.75-38.42,143.37l334.33-71.05v170.26l-358.3,76.14c-20.06,44.47-33.32,92.75-38.4,143.37l375.04-79.7c30.53-6.35,56.77-24.4,73.83-49.24l68.78-101.97v-.02c7.14-10.55,11.3-23.27,11.3-36.97v-149.98l132.25-28.11v270.4l424.53-90.28Z",
    ]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Fitted, never stretched: the mark has one shape and a squashed
        // currency sign is a different sign.
        let scale = min(rect.width / Self.viewBox.width, rect.height / Self.viewBox.height)
        let size = CGSize(width: Self.viewBox.width * scale, height: Self.viewBox.height * scale)
        let origin = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        for data in Self.subpaths {
            SvgPath.add(data, to: &path, scale: scale, origin: origin)
        }
        return path
    }
}

/// Just enough SVG path to draw one mark.
///
/// Deliberately small and deliberately strict: it understands the commands
/// this one outline uses and traps on anything else, rather than silently
/// drawing a shape that is nearly right. A currency sign that is nearly right
/// is worse than one that is missing.
enum SvgPath {

    static func add(_ data: String, to path: inout Path, scale: CGFloat, origin: CGPoint) {
        var numbers: [CGFloat] = []
        var command: Character = "M"
        var point = CGPoint.zero      // in viewBox units
        var start = CGPoint.zero
        var token = ""

        func place(_ p: CGPoint) -> CGPoint {
            CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale)
        }

        func flush() {
            if !token.isEmpty, let value = Double(token) { numbers.append(CGFloat(value)) }
            token = ""
        }

        func run() {
            defer { numbers.removeAll() }
            switch command {
            case "M", "m":
                // Every pair after the first is an implicit lineto, which is
                // what SVG says and what this data relies on.
                var first = true
                for i in stride(from: 0, to: numbers.count - 1, by: 2) {
                    let raw = CGPoint(x: numbers[i], y: numbers[i + 1])
                    point = command == "m" ? CGPoint(x: point.x + raw.x, y: point.y + raw.y) : raw
                    if first { path.move(to: place(point)); start = point; first = false }
                    else { path.addLine(to: place(point)) }
                }
            case "L", "l":
                for i in stride(from: 0, to: numbers.count - 1, by: 2) {
                    let raw = CGPoint(x: numbers[i], y: numbers[i + 1])
                    point = command == "l" ? CGPoint(x: point.x + raw.x, y: point.y + raw.y) : raw
                    path.addLine(to: place(point))
                }
            case "H", "h":
                for value in numbers {
                    point.x = command == "h" ? point.x + value : value
                    path.addLine(to: place(point))
                }
            case "V", "v":
                for value in numbers {
                    point.y = command == "v" ? point.y + value : value
                    path.addLine(to: place(point))
                }
            case "C", "c":
                for i in stride(from: 0, to: numbers.count - 5, by: 6) {
                    let relative = command == "c"
                    let base = relative ? point : .zero
                    let c1 = CGPoint(x: base.x + numbers[i], y: base.y + numbers[i + 1])
                    let c2 = CGPoint(x: base.x + numbers[i + 2], y: base.y + numbers[i + 3])
                    let end = CGPoint(x: base.x + numbers[i + 4], y: base.y + numbers[i + 5])
                    path.addCurve(to: place(end), control1: place(c1), control2: place(c2))
                    point = end
                }
            case "Z", "z":
                path.closeSubpath()
                point = start
            default:
                assertionFailure("RiyalMark: unsupported path command \(command)")
            }
        }

        for character in data {
            if character.isLetter {
                flush(); run(); command = character
                if character == "Z" || character == "z" { run() }
            } else if character == "," || character == " " {
                flush()
            } else if character == "-" && !token.isEmpty && !token.hasSuffix("e") {
                // "-" starts a new number unless it is a sign or an exponent.
                flush(); token = "-"
            } else {
                token.append(character)
            }
        }
        flush(); run()
    }
}

/// The mark, sized to sit beside a figure as if it were set in the same face.
///
/// Height comes from the CAP HEIGHT of the figure's own font rather than from
/// its point size: a point size is the em box, and a mark drawn to the em box
/// stands taller than the digits it belongs to.
struct RiyalGlyph: View {
    let size: CGFloat
    var weight: Font.Weight = .regular

    /// What a reader is told it is. The drawn mark is not text — the same
    /// trade the invoice takes — so the word comes back this way.
    var body: some View {
        let cap = NSFont.systemFont(ofSize: size, weight: .regular).capHeight
        RiyalMark()
            .frame(width: cap * (RiyalMark.viewBox.width / RiyalMark.viewBox.height),
                   height: cap)
            // ON THE BASELINE, like a digit. A shape has no baseline of its
            // own, so an HStack centres it against the whole line box and the
            // mark floats low beside the figure it belongs to. Its bottom edge
            // IS the baseline, which is where the drawn sign sits.
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
            .alignmentGuide(.lastTextBaseline) { $0[.bottom] }
            .accessibilityLabel("SAR")
    }
}
