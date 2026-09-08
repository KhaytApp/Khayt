import SwiftUI

/// The marks this app draws for itself.
///
/// ── COUNTED BEFORE THIS EXISTED: 41 SYMBOLS, ONE DRAWN SHAPE ──────────────
///
/// `shippingbox` for the filament shelf. `tray.full` for the jobs. `function`
/// for the calculator, `square.grid.2x2.fill` for the dashboard, `creditcard`
/// for expenses. Every mark on every screen was Apple's, arranged by us — and
/// arranging borrowed marks better is what three rounds of "make it less
/// generic" had been doing without touching the thing that made it generic.
///
/// Khayt is about a craft with a visual language of its own. A nozzle laying a
/// bead. Layers stacking. A spool seen face on. A build plate seen from above.
/// A purge tower. None of it appeared anywhere except in the words.
///
/// ── ONE GRID, ONE WEIGHT ──────────────────────────────────────────────────
///
/// Every mark is drawn in the same 24-unit square with the same stroke, which
/// is the only reason a set reads as a set rather than as fifteen drawings.
/// The stroke scales with the mark so a 32pt one is not a 16pt one with a
/// hairline: `1.7 / 24` of the size, the weight the design work settled on.
///
/// Every one of them is a thing on the shop floor seen straight on or from
/// above — never a metaphor borrowed from finance software, which is what
/// `creditcard` and `tray.full` are. The one exception is `clients`, because a
/// customer is a person and there is no shop-floor object for that.
enum Mark: String, CaseIterable {
    case dashboard, jobs, board, machines, filament, library, catalogue
    case calculator, colour, giftCards, portfolio, expenses, waste, reports, clients
    case nozzle, clock
}

/// What a mark is made of, in the 24-unit square.
///
/// Kept as data rather than as drawing code so the whole set can be checked at
/// once — that every mark stays inside its square, that none of them is empty,
/// that they are all built from the same handful of primitives.
struct Ink {
    /// Open polylines, stroked. Round caps and joins.
    var lines: [[CGPoint]] = []
    /// Closed outlines, stroked.
    var closed: [[CGPoint]] = []
    /// Stroked rings: centre and radius.
    var rings: [(CGPoint, CGFloat)] = []
    /// Filled polygons — the one warm thing in the app's mark is a bead of
    /// plastic, and a bead is solid.
    var solid: [[CGPoint]] = []
    /// Filled dots.
    var dots: [(CGPoint, CGFloat)] = []
}

extension Mark {

    /// The grid every one of them is drawn on.
    static let grid: CGFloat = 24
    /// The stroke, as a fraction of the mark's size.
    static let weight: CGFloat = 1.7 / 24

    var ink: Ink {
        switch self {

        // A nozzle laying a bead. The app's own act, and its dashboard.
        case .dashboard, .nozzle:
            Ink(lines: [[p(12, 17), p(12, 21)]],
                closed: [[p(5, 3), p(19, 3), p(16.5, 12), p(7.5, 12)]],
                solid: [[p(8.5, 12), p(15.5, 12), p(12, 17)]])

        // Layers stacking — widest at the bottom, because that is how a part
        // comes off a plate. Not a list: a list is what `tray.full` was.
        case .jobs:
            Ink(lines: [[p(4, 20), p(20, 20)], [p(6, 13), p(18, 13)], [p(8, 6), p(16, 6)]])

        // Lanes with a card sitting in the first one. Three separate bars read
        // as a chart — which is what the first attempt drew, and what `reports`
        // already is.
        case .board:
            Ink(lines: [[p(10, 4), p(10, 20)], [p(16, 4), p(16, 20)]],
                closed: [[p(4, 4), p(20, 4), p(20, 20), p(4, 20)]],
                solid: [[p(5.5, 7), p(8.5, 7), p(8.5, 12), p(5.5, 12)]])

        // A printer seen head on: the frame, the gantry rail across it, and a
        // part standing on the bed.
        //
        // Two goes before this read. A plate in perspective with a stem was a
        // plumb bob; a stem with a triangle on it was the arrow of every
        // download-into-a-box icon ever drawn. What makes it a printer is the
        // RAIL — nothing else in a toolbar has one.
        case .machines:
            Ink(lines: [[p(3, 8.5), p(21, 8.5)], [p(6, 16.5), p(18, 16.5)]],
                closed: [[p(3, 4), p(21, 4), p(21, 20), p(3, 20)]],
                solid: [[p(10.5, 16.5), p(13.5, 16.5), p(13, 12), p(11, 12)]])

        // A spool face on: the filament and the hole through the middle. The
        // same shape the shelf draws at 72pt.
        case .filament:
            Ink(rings: [(p(12, 12), 9), (p(12, 12), 3)])

        // A printed part, seen isometrically — the thing the library holds.
        case .library:
            Ink(lines: [[p(4, 7.5), p(12, 12), p(20, 7.5)], [p(12, 12), p(12, 21)]],
                closed: [[p(12, 3), p(20, 7.5), p(20, 16.5), p(12, 21), p(4, 16.5), p(4, 7.5)]])

        // A price tag. Two parts standing on a shelf is what this was, and at
        // 16pt it was indistinguishable from `reports` — two rectangles of
        // different heights on a baseline is a bar chart.
        case .catalogue:
            Ink(closed: [[p(3, 12), p(12, 3), p(21, 3), p(21, 12), p(12, 21)]],
                dots: [(p(17, 7), 1.5)])

        // A caliper, with the part it is measuring between its jaws. Drawn as
        // bare lines the jaws read as brackets; given width they read as jaws.
        // `function` was a mathematics symbol for a question about money.
        case .calculator:
            Ink(lines: [[p(3, 6), p(21, 6)]],
                closed: [[p(4, 6), p(7, 6), p(7, 20), p(4, 20)],
                         [p(15, 6), p(18, 6), p(18, 20), p(15, 20)]],
                solid: [[p(9, 12), p(13, 12), p(13, 17), p(9, 17)]])

        // Three spools of filament, overlapping where their colours mix.
        case .colour:
            Ink(rings: [(p(9, 10), 4.6), (p(15, 10), 4.6), (p(12, 15.5), 4.6)])

        // A card with a bow above it. A ribbon crossing a card both ways drew
        // a window pane.
        case .giftCards:
            Ink(lines: [[p(12, 9), p(12, 20)]],
                closed: [[p(3, 9), p(21, 9), p(21, 20), p(3, 20)]],
                rings: [(p(9, 6), 2.6), (p(15, 6), 2.6)])

        // A part on a plate, framed — a photograph of finished work.
        case .portfolio:
            Ink(lines: [[p(5, 16), p(19, 16)]],
                closed: [[p(3, 5), p(21, 5), p(21, 19), p(3, 19)],
                         [p(9, 16), p(11, 10), p(13, 10), p(15, 16)]])

        // A drawer of receipts, seen face on. Not a credit card: a shop that
        // buys a printer does not put it on a card, and the mark should not
        // say so.
        case .expenses:
            Ink(lines: [[p(4, 10), p(20, 10)], [p(9, 15), p(15, 15)]],
                closed: [[p(4, 5), p(20, 5), p(20, 19), p(4, 19)]])

        // A PURGE TOWER, which is what waste on this shop floor looks like:
        // a small stack of layers that was never part of anything.
        case .waste:
            Ink(lines: [[p(4, 20), p(20, 20)],
                        [p(8, 16), p(16, 16)], [p(8, 12), p(16, 12)], [p(8, 8), p(16, 8)]],
                closed: [[p(8, 4), p(16, 4), p(16, 20), p(8, 20)]])

        // Bars against a baseline.
        case .reports:
            Ink(lines: [[p(4, 19), p(20, 19)], [p(7, 19), p(7, 10)],
                        [p(12, 19), p(12, 5)], [p(17, 19), p(17, 13)]])

        // A person. The one mark here that is not a thing on the shop floor,
        // because a customer is not one.
        case .clients:
            Ink(lines: [[p(5, 20), p(5.6, 16.8), p(8.5, 14.6), p(12, 14),
                         p(15.5, 14.6), p(18.4, 16.8), p(19, 20)]],
                rings: [(p(12, 7.5), 3.5)])

        case .clock:
            Ink(lines: [[p(12, 8), p(12, 12.6), p(15, 14.6)]],
                rings: [(p(12, 12), 8)])
        }
    }

    private func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
}

/// A mark, drawn at a size, in whatever colour it is asked to be.
struct Drawn: View {
    let mark: Mark
    var size: CGFloat = 16

    var body: some View {
        let ink = mark.ink
        let s = size / Mark.grid
        ZStack {
            MarkPath(ink: ink, scale: s, filled: false)
                .stroke(style: StrokeStyle(lineWidth: size * Mark.weight,
                                           lineCap: .round, lineJoin: .round))
            MarkPath(ink: ink, scale: s, filled: true).fill()
        }
        .frame(width: size, height: size)
        // A drawn mark has no accessibility label of its own; the row it sits
        // in carries the words, and a label here would be read out twice.
        .accessibilityHidden(true)
    }
}

/// The strokes, or the fills, of one mark.
struct MarkPath: Shape {
    let ink: Ink
    let scale: CGFloat
    let filled: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        func at(_ point: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + point.x * scale, y: rect.minY + point.y * scale)
        }
        if filled {
            for polygon in ink.solid where polygon.count > 1 {
                path.move(to: at(polygon[0]))
                for point in polygon.dropFirst() { path.addLine(to: at(point)) }
                path.closeSubpath()
            }
            for (centre, r) in ink.dots {
                path.addEllipse(in: CGRect(x: at(centre).x - r * scale, y: at(centre).y - r * scale,
                                           width: r * 2 * scale, height: r * 2 * scale))
            }
            return path
        }
        for line in ink.lines where line.count > 1 {
            path.move(to: at(line[0]))
            for point in line.dropFirst() { path.addLine(to: at(point)) }
        }
        for shape in ink.closed where shape.count > 2 {
            path.move(to: at(shape[0]))
            for point in shape.dropFirst() { path.addLine(to: at(point)) }
            path.closeSubpath()
        }
        for (centre, r) in ink.rings {
            path.addEllipse(in: CGRect(x: at(centre).x - r * scale, y: at(centre).y - r * scale,
                                       width: r * 2 * scale, height: r * 2 * scale))
        }
        return path
    }
}
