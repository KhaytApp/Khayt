import SwiftUI
import KhaytCore

/// Figures this app draws instead of writing down.
///
/// ── WHAT THIS IS FOR ──────────────────────────────────────────────────────
///
/// `Craft.swift` gave the app drawings of its own; `Marks.swift` gave it a set
/// of marks. Both of them DECORATE — they say which screen you are on and what
/// a section is about. Not one of them carries a number.
///
/// So the screens stayed what they were: rows of label-and-value. "31,400 /
/// 30,000 g" is a fact a shop reads, works out, and then acts on, and the
/// working-out is the part the screen should have done. A ring three-quarters
/// filled is read without arithmetic; a ring with a second arc outside it is
/// read as "past its life" from across a room.
///
/// Everything here obeys the two rules the rest of the app already obeys:
/// nothing computes money or wear (the figures arrive from the shared rules in
/// `lib/`), and no colour is the only signal — every drawing here sits beside
/// the words it draws.
enum Drawings {}

/// How far through its life a wearing part is.
///
/// ── WHY NOT `ProgressView` ────────────────────────────────────────────────
///
/// That is what the machine card used, and a stock capsule has one flaw that
/// matters here: **it stops at full.** A nozzle at 99% and a nozzle at 140%
/// drew exactly the same bar, and the only thing separating them was the word
/// beside it. This shop has a printer at 105%.
///
/// So the overshoot is drawn OUTSIDE the ring — a second, thinner arc that only
/// exists once the part is past its threshold. It cannot be confused with the
/// ring itself, it costs nothing when there is no overshoot, and it is the one
/// state on the machines screen worth walking over to.
struct WearGauge: View {
    /// 0–100, and legitimately more. `lib/nozzle-wear.js` rounds it; this does
    /// not round it again.
    let pct: Double
    var size: CGFloat = 46

    @Environment(\.accessibilityReduceMotion) private var reduced
    /// Drawn from empty on first appearance, so the ring is READ as a
    /// quantity rather than seen as a static piece of furniture. It sweeps
    /// once, on arrival, and never again — a gauge that re-animates every time
    /// a screen redraws is a distraction, not information.
    @State private var shown: Double = 0

    private var over: Bool { pct >= 100 }
    private var tint: Color { over ? Khayt.attention : Khayt.cyan }
    /// The ring's own stroke, and the radius its centreline sits on.
    private var stroke: CGFloat { size * 0.108 }
    private var radius: CGFloat { size / 2 - stroke / 2 - 1 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Khayt.layerLine, lineWidth: stroke)
                .frame(width: radius * 2, height: radius * 2)
            Circle()
                .trim(from: 0, to: min(1, max(0, shown / 100)))
                .stroke(tint, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .frame(width: radius * 2, height: radius * 2)
                .rotationEffect(.degrees(-90))
            if over {
                // Only the part that went past, and outside the ring so it
                // reads as an overflow rather than as more of the same bar.
                Circle()
                    .trim(from: 0, to: min(1, pct / 100 - 1))
                    .stroke(Khayt.attention, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .frame(width: (radius + stroke / 2 + 2.5) * 2, height: (radius + stroke / 2 + 2.5) * 2)
                    .rotationEffect(.degrees(-90))
            }
            // Rounded, monospaced-digit, and the per-cent sign smaller than the
            // number — the same treatment `BigFigure` gives a unit, for the
            // same reason.
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("\(Int(shown.rounded()))")
                    .font(.system(size: size * 0.30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    // The figure counts up with the ring rather than sitting at
                    // its final value while the arc travels — two halves of one
                    // reading that disagreed for two thirds of a second.
                    .contentTransition(.numericText())
                if size >= 40 {
                    Text("%").font(.system(size: size * 0.17, weight: .medium, design: .rounded))
                }
            }
            .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard !reduced else { shown = pct; return }
            withAnimation(Motion.gauge) { shown = pct }
        }
        // A wear figure that changes while the screen is open — a print
        // finishing — moves to the new reading rather than jumping.
        .onChange(of: pct) { _, now in
            withAnimation(Motion.of(Motion.gauge, unless: reduced)) { shown = now }
        }
        // The row beside this carries the words; a label here would be read out
        // twice, which is the rule the rest of the drawings follow.
        .accessibilityHidden(true)
    }
}

/// A machine's bed, drawn against the biggest bed in the shop.
///
/// ── THE QUESTION THIS ANSWERS ─────────────────────────────────────────────
///
/// "270 × 270 × 270 mm" on one card and "1300 × 900 × 200 mm" on another is two
/// facts a shop compares by reading both and doing the arithmetic. Drawn to one
/// scale they are compared by looking, which is what a shop actually wants from
/// this screen: whether the thing on the bench will fit on the machine.
///
/// The dashed rectangle is the largest bed on the floor, so a small bed looks
/// small. That is the point and not a rendering fault — a card whose drawing
/// fills its box would say every machine is the same size, which is the thing
/// the words were already failing to say.
struct BedPlan: View {
    let x: Double
    let y: Double
    /// The biggest bed on the floor, which every card is drawn against.
    let widest: Double
    let deepest: Double
    var box: CGSize = CGSize(width: 104, height: 74)

    var body: some View {
        // One scale for both axes, or the drawing lies about the shape.
        let s = min(box.width / max(widest, 1), box.height / max(deepest, 1))
        let w = max(2, x * s), h = max(2, y * s)
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(Khayt.hairline, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            Rectangle()
                .fill(Khayt.bareSpool)
                .overlay(Rectangle().strokeBorder(Khayt.drawnEdge, lineWidth: 1))
                .frame(width: w, height: h)
        }
        .frame(width: box.width, height: box.height)
        .accessibilityHidden(true)
    }
}

/// One step of a waterfall: what it is called, what it did to the running
/// total, and whether it is a total in its own right.
struct WaterfallStep: Identifiable {
    let label: String
    /// Signed. A cost is negative.
    let amount: Double
    /// A bar measured from zero rather than from the running total: the opening
    /// figure and the closing one.
    var anchored = false
    var id: String { label }
}

/// A quarter's arithmetic, drawn.
///
/// ── WHY THE REPORT NEEDED A PICTURE ───────────────────────────────────────
///
/// The P&L page was a table and a panel of totals — the one screen in this app
/// with no drawing on it at all. It printed a quarter's net as a number in a
/// cell, and a number in a cell is something a shop either trusts or does not.
///
/// This is the same arithmetic laid out so it can be checked by eye: what came
/// in, what each thing took out of it, and what was left. Nothing here is
/// computed — every figure is `lib/pnl-report.js`'s, passed in.
///
/// ── COLOUR CARRIES ROLE, NOT DIRECTION ────────────────────────────────────
///
/// Direction is already in the geometry: a bar hanging below the one before it
/// went out. So money in is the deep step of the cyan ramp and money out the
/// light one, and only the closing bar takes a status colour — `done` when the
/// quarter made money and `late` when it did not.
///
/// **Green and red never appear on this chart together, on purpose.** Measured
/// on this app's own palette, `done` and `late` separate by ΔE 2.4 under
/// simulated protanopia — which is to say they are the same colour to the
/// commonest form of colour blindness. Only one closing bar is ever drawn, so
/// the pair never has to be told apart.
struct Waterfall: View {
    let steps: [WaterfallStep]
    let currency: String
    var height: CGFloat = 260

    /// The light step of the cyan ramp — validated against this app's surface
    /// as an ordinal ramp, and at 2.43:1 it is legal only because every bar
    /// carries its own figure in writing.
    private static let out = Color(nsColor: NSColor(hex: 0x63ADBC))
    private static let inward = Khayt.cyan

    /// Where one bar starts and stops on the running total.
    ///
    /// A named type rather than a tuple: written as `[(WaterfallStep, Double,
    /// Double)]` the compiler inferred `[Any]` out of the `flatMap` below and
    /// the arithmetic stopped type-checking with an error pointing at the
    /// multiplication rather than at the tuple.
    private struct Span {
        let step: WaterfallStep
        let from: Double
        let to: Double
    }

    /// The running total at the start and end of each bar.
    ///
    /// BOTH anchored bars are measured from zero, but only the OPENING one
    /// starts the running total. Missing that, every bar after the first was
    /// measured from zero as well: the quarter drew revenue above the line and
    /// the whole of expenses below it, as two unrelated columns, and the sum of
    /// the picture was not the net income printed beside it.
    private var spans: [Span] {
        var run = 0.0
        return steps.enumerated().map { index, step in
            if step.anchored {
                if index == 0 { run = step.amount }
                return Span(step: step, from: 0, to: step.amount)
            }
            let from = run
            run += step.amount
            return Span(step: step, from: from, to: run)
        }
    }

    var body: some View {
        let values: [Double] = spans.flatMap { [$0.from, $0.to] } + [0]
        let hi = (values.max() ?? 0) * 1.28
        let lo = (values.min() ?? 0) * 1.30
        let span = max(hi - lo, 1)

        // ── A CANVAS, NOT A GeometryReader FULL OF VIEWS ──────────────────
        //
        // The first version of this drew each bar as a `RoundedRectangle` and
        // each figure as a `Text`, positioned inside a `GeometryReader`. It
        // rendered correctly and it hung the app: the reader proposes a size,
        // the positioned children report an ideal size back, that changes the
        // proposal, and AppKit never reaches a fixed point. Sampled while stuck,
        // the main thread was 132 frames deep in
        // `-[NSView _layoutSubtreeWithOldSize:]` under one AppKitScrollView,
        // and every screen the snapshot runner photographs after this one was
        // lost with it.
        //
        // `Canvas` has no child views to feed anything back. It takes the size
        // it is given, draws, and takes no part in layout — which is the right
        // shape for a chart anyway.
        Canvas { context, size in
            let plot = size.height - 34            // room for the names
            let step = size.width / CGFloat(max(spans.count, 1))
            let barW = min(46, step * 0.58)
            func y(_ v: Double) -> CGFloat { CGFloat((hi - v) / span) * plot }

            // The zero line — the only rule on the chart that means anything,
            // so the only one drawn at all.
            context.fill(Path(CGRect(x: 0, y: y(0), width: size.width, height: 1)),
                         with: .color(Khayt.hairline))

            for (index, bar) in spans.enumerated() {
                let top = min(y(bar.from), y(bar.to))
                // The step from one bar to the next, so the row reads as one
                // running total rather than as a bar chart of unrelated
                // figures. Dashed and faint: it is a guide, not a value.
                if index > 0, !bar.step.anchored {
                    let previous = step * CGFloat(index - 1) + step / 2 + barW / 2
                    var line = Path()
                    line.move(to: CGPoint(x: previous + 1, y: y(bar.from)))
                    line.addLine(to: CGPoint(x: step * CGFloat(index) + step / 2 - barW / 2 - 1,
                                             y: y(bar.from)))
                    context.stroke(line, with: .color(Khayt.hairline),
                                   style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
                let tall = max(3, abs(y(bar.to) - y(bar.from)))
                let closing = bar.step.anchored && index > 0
                let tint: Color = closing
                    ? (bar.step.amount < 0 ? Khayt.late : Khayt.done)
                    : (bar.step.amount >= 0 ? Self.inward : Self.out)
                let centre = step * CGFloat(index) + step / 2

                context.fill(
                    Path(roundedRect: CGRect(x: centre - barW / 2, y: top, width: barW, height: tall),
                         cornerRadius: 4, style: .continuous),
                    with: .color(tint))

                // Every bar carries its figure. The light step of the ramp sits
                // under 3:1 on this surface, and that is only allowed where the
                // value is written on the bar.
                context.draw(
                    Text(Money.figure(bar.step.amount))
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(closing ? tint : Color.secondary),
                    at: CGPoint(x: centre, y: bar.step.amount >= 0 ? top - 8 : top + tall + 8),
                    anchor: .center)

                context.draw(
                    Text(bar.step.label)
                        .font(.system(size: 10.5, weight: bar.step.anchored ? .semibold : .regular))
                        .foregroundStyle(bar.step.anchored ? Color.primary : Color.secondary),
                    at: CGPoint(x: centre, y: plot + 16),
                    anchor: .center)
            }
        }
        .frame(height: height)
    }
}
