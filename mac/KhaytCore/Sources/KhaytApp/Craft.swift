import SwiftUI
import AppKit

/// The shapes this app draws for itself.
///
/// ── WHY THERE WAS NOTHING HERE ────────────────────────────────────────────
///
/// Counted before writing a line of it: forty-three distinct SF Symbols,
/// twenty-nine `ContentUnavailableView`s, one typeface — and **zero** drawn
/// shapes. Not one `Path`, not one `Canvas`. Every mark on every screen was
/// Apple's, arranged by us.
///
/// That is what "generic" turned out to mean, and it is why three rounds of
/// making the arrangement better did not fix it. A depth order, a semantic
/// palette and an honest type scale make an app *coherent*; none of them make
/// it *this app*. Khayt is about a craft with a strong visual language of its
/// own — layers, a nozzle, a bead of plastic laid down and cooling — and none
/// of that appeared anywhere except in the words.
///
/// ── WHAT IS DRAWN, AND WHAT DELIBERATELY IS NOT ──────────────────────────
///
/// A nozzle, a drop, and layer lines. Those are the craft, they are simple
/// geometry, and they are unmistakable at any size.
///
/// **The Arabic khaa in the app's mark is NOT drawn here, on purpose.** A
/// letterform approximated in bezier curves by somebody who cannot read it is
/// wrong in a way its readers see immediately and its author never does, and
/// this app's shop reads Arabic. The mark is used where the mark is wanted —
/// `NSApp.applicationIconImage`, the real artwork, already in the bundle and
/// already correct. Drawing is for the things drawing cannot get wrong.
enum Craft {}

/// The hot end, seen from the front: a body tapering to a tip.
///
/// Proportions are a real nozzle's rather than a cartoon's — the taper starts
/// past halfway down and the tip is a short flat, which is what makes it read
/// as a nozzle instead of an arrow.
struct NozzleShape: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y)
        }
        var path = Path()
        path.move(to: p(0.10, 0.00))
        path.addLine(to: p(0.90, 0.00))
        path.addLine(to: p(0.90, 0.44))
        path.addLine(to: p(0.62, 0.82))
        path.addLine(to: p(0.62, 1.00))
        path.addLine(to: p(0.38, 1.00))
        path.addLine(to: p(0.38, 0.82))
        path.addLine(to: p(0.10, 0.44))
        path.closeSubpath()
        return path
    }
}

/// The bead leaving the tip. The one warm thing in the app's own mark, and the
/// one warm thing here.
struct BeadShape: Shape {
    func path(in r: CGRect) -> Path {
        var path = Path()
        let w = r.width, h = r.height
        path.move(to: CGPoint(x: r.midX, y: r.minY))
        path.addQuadCurve(to: CGPoint(x: r.midX + w * 0.42, y: r.minY + h * 0.62),
                          control: CGPoint(x: r.midX + w * 0.30, y: r.minY + h * 0.16))
        path.addQuadCurve(to: CGPoint(x: r.midX - w * 0.42, y: r.minY + h * 0.62),
                          control: CGPoint(x: r.midX, y: r.maxY))
        path.addQuadCurve(to: CGPoint(x: r.midX, y: r.minY),
                          control: CGPoint(x: r.midX - w * 0.30, y: r.minY + h * 0.16))
        path.closeSubpath()
        return path
    }
}

/// Layers, laid down and cooling.
///
/// Uneven lengths on purpose. Rows of equal width read as a barcode or a list;
/// a real cross-section is ragged because a wall follows a shape, and the
/// raggedness is most of what makes this read as printing rather than as
/// decoration. The lengths are fixed rather than random so that the same screen
/// draws the same thing twice — a motif that reshuffles on every redraw is a
/// distraction, and it would make every snapshot differ from the last.
struct LayerLinesShape: Shape {
    /// How much of the stack has been laid. 1 draws them all.
    var progress: Double = 1
    /// Centred reads as an OBJECT; leading reads as lines of text.
    ///
    /// That is not a nicety — the first drawing of this had ragged lines
    /// aligned to the left under a nozzle, and it read as a paragraph with a
    /// bulb over it. The same lengths centred read immediately as a printed
    /// part seen from the front. A progress bar wants the other one, because
    /// it fills from one end.
    var centred = false
    /// Fewer, fatter rows for the drawing; more, finer ones for a bar.
    var widths: [CGFloat] = [0.92, 0.78, 0.96, 0.66, 0.88, 0.72, 0.98, 0.60, 0.84, 0.74]

    func path(in r: CGRect) -> Path {
        var path = Path()
        let rows = widths.count
        let gap = r.height / CGFloat(rows)
        let thickness = min(gap * 0.62, 5)
        // Bottom up: a print grows from the bed, so a partial stack is the
        // LOWER layers, never the upper ones floating with nothing under them.
        let drawn = Int((Double(rows) * max(0, min(1, progress))).rounded())
        for i in 0..<drawn {
            let w = r.width * widths[rows - 1 - i]
            let y = r.maxY - gap * CGFloat(i) - thickness
            let x = centred ? r.midX - w / 2 : r.minX
            path.addRoundedRect(
                in: CGRect(x: x, y: y, width: w, height: thickness),
                cornerSize: CGSize(width: thickness / 2, height: thickness / 2))
        }
        return path
    }
}

/// A nozzle laying a first layer — the app's own drawing, for the screens that
/// have nothing on them yet.
struct CraftArt: View {
    var tint: Color = Khayt.cyan
    var size: CGFloat = 76

    var body: some View {
        VStack(spacing: 0) {
            NozzleShape()
                .fill(tint.opacity(0.85))
                .frame(width: size * 0.44, height: size * 0.50)
            // The bead sits in the gap between the tip and the top layer, which
            // is the whole story of the picture: this is the moment plastic
            // leaves the nozzle. Small — it is a bead, and one the size of the
            // tip reads as a blob somebody dropped there.
            BeadShape()
                .fill(Khayt.hot)
                .frame(width: size * 0.085, height: size * 0.10)
                .padding(.top, size * 0.015)
            // Narrower than the nozzle is wide is wrong, and much wider is
            // wrong too: the stack has to look like what that nozzle just laid.
            LayerLinesShape(centred: true,
                            widths: [0.98, 0.86, 0.94, 0.78, 0.90, 0.72])
                .fill(tint.opacity(0.38))
                .frame(width: size * 0.72, height: size * 0.30)
                .padding(.top, size * 0.03)
        }
        .frame(width: size)
        .accessibilityHidden(true)
    }
}

/// A screen with nothing on it yet.
///
/// Replaces `ContentUnavailableView`, which is a good component and the single
/// most generic thing in any SwiftUI app: the same grey glyph, the same layout,
/// in every app on the Mac. This one is drawn by Khayt and says the same thing.
///
/// The argument order matches the component it replaces, so a call site changes
/// by its name and nothing else.
struct EmptyHere<Actions: View>: View {
    let title: String
    var message: String?
    /// Shown instead of the drawing where a screen has a better idea — the
    /// library's own thumbnail placeholder, say. Nil takes the nozzle.
    var symbol: String?
    /// What a shop can do from here, where there is something. An empty screen
    /// with the button that fills it is the difference between a dead end and
    /// a starting point.
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Khayt.cyan.opacity(0.55))
            } else {
                CraftArt()
            }
            VStack(spacing: 5) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                if let message, !message.isEmpty {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            actions.padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyHere where Actions == EmptyView {
    /// The ordinary case: a drawing and some words, nothing to press.
    init(title: String, message: String? = nil, symbol: String? = nil) {
        self.init(title: title, message: message, symbol: symbol, actions: { EmptyView() })
    }
}

/// The app's own mark, from the bundle rather than from a bezier curve.
///
/// `NSApp.applicationIconImage` is the artwork that is already correct in every
/// size and every appearance, including the Arabic letter this file refuses to
/// redraw. Watermarked behind an empty screen it says whose app this is without
/// anybody having to letter it a second time.
struct KhaytWatermark: View {
    var size: CGFloat = 148
    var opacity: Double = 0.05

    var body: some View {
        Group {
            if let icon = NSApp?.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .opacity(opacity)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
