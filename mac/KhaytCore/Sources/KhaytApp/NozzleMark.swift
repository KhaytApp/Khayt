import SwiftUI

/// A printer head drawn as a nozzle (page 29, the Head component): a heater
/// block in the spool's colour over a tapered tip, outlined 1.5 pt in the
/// secondary colour at 0.55 like the phone's swatch ring (review W7), so a
/// near-black or near-white spool still has an edge. Dashed when empty.
struct NozzleMark: View {
    let hex: String?
    var faded = false

    var body: some View {
        let fill = hex.flatMap { Swatch.rgb(fromHex: $0) }.map { Color(red: $0.r, green: $0.g, blue: $0.b) }
        let ring = Color.secondary.opacity(0.55)
        VStack(spacing: -1) {
            RoundedRectangle(cornerRadius: 6)
                .fill(fill ?? Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(ring, style: StrokeStyle(lineWidth: 1.5, dash: fill == nil ? [3, 3] : [])))
                .frame(width: 32, height: 30)
            NozzleTip().fill(Color.secondary.opacity(0.45))
                .overlay(NozzleTip().stroke(ring, lineWidth: 1.5))
                .frame(width: 14, height: 16)
        }
        .opacity(faded ? 0.45 : 1)
        .accessibilityHidden(true)
    }
}

/// The tapered tip under the heater block.
struct NozzleTip: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX + r.width * 0.18, y: r.maxY - 2))
        p.addQuadCurve(to: CGPoint(x: r.midX - r.width * 0.18, y: r.maxY - 2), control: CGPoint(x: r.midX, y: r.maxY + 1))
        p.closeSubpath()
        return p
    }
}
