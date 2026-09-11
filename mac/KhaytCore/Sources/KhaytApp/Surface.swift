import SwiftUI

/// How this app draws a surface, and why it is not `.quinary` any more.
///
/// ── WHAT WAS WRONG ────────────────────────────────────────────────────────
///
/// Every panel in the app was the same call:
///
///     .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
///
/// Nine of them down the dashboard, eight more as tiles, and the same again on
/// every other screen. That is a faithful reading of the default SwiftUI idiom
/// and it produces a column of identical grey boxes, which is exactly what
/// "generic" means: the screen has a structure and none of it is visible,
/// because nothing is drawn differently from anything else.
///
/// The palette in `Palette.swift` was already chosen, contrast-checked and
/// documented — and 48 of its 71 uses were the one amber, while the app's own
/// cyan appeared six times and `note` never at all. The identity existed and
/// never reached the screen.
///
/// ── THE DEVICE ────────────────────────────────────────────────────────────
///
/// A **rail**: a short bar down the leading edge of a card, in the colour of
/// what the card is about. It is the one repeated shape in the app, so it is
/// the thing that makes two Khayt screens look like the same program, and it
/// carries meaning rather than decorating — `Khayt.late` on the late work,
/// `Khayt.hot` on what is being made right now, `Khayt.cyan` on the shop's own
/// figures.
///
/// **A card with nothing to say gets no rail.** That is the half that makes it
/// work: a device on everything is wallpaper, and the eye stops reading it. The
/// rail is worth looking at because most cards do not have one.
///
/// It is a bar and not a tinted background because the HIG's colour guidance
/// wants colour used sparingly and never as the only signal — every rail here
/// sits beside a title that says the same thing in words, and a shop reading
/// this screen colour-blind loses nothing.
extension View {

    /// The app's card. One corner radius, one border, one padding — set here
    /// so that "a panel" is a decision made once rather than at ninety call
    /// sites with slightly different numbers.
    ///
    /// `rail` is the colour of what the card is about, or nil for the ordinary
    /// case. See the note above on why most cards should pass nil.
    /// - Parameter fills: stretch to the height offered, instead of hugging the
    ///   content. For a card in a grid row, where the row is already as tall as
    ///   its tallest card and a short one would otherwise float in it — see
    ///   `KhaytCard`.
    func card(rail: Color? = nil, padding: CGFloat = 12, fills: Bool = false) -> some View {
        modifier(KhaytCard(rail: rail, padding: padding, fills: fills))
    }
}

/// The height of the tallest card in a grid.
///
/// ── WHY A PREFERENCE AND NOT JUST `maxHeight: .infinity` ──────────────────
///
/// `maxHeight: .infinity` makes a card fill its ROW, and a `LazyVGrid` sizes
/// every row independently. So a shelf came out as two tidy rows of different
/// heights — five tall boxes above four short ones — which is the same ragged
/// look one row down, and reads as two grids rather than one.
///
/// A card cannot know what the tallest one is, so each reports its own natural
/// height up and the grid hands the maximum back down. `reduce` takes the
/// larger, which is what makes it a maximum rather than a last-one-wins.
struct CardHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Make every card in a grid the height of the tallest one.
    ///
    /// Put this on the GRID and `fills: true` on the cards in it. Both are
    /// needed and they do different things: this decides what the height is,
    /// and `fills` is what makes a card's surface actually take it instead of
    /// hugging its contents inside a taller cell.
    func equalCardHeights(_ tallest: Binding<CGFloat>) -> some View {
        onPreferenceChange(CardHeight.self) { height in
            // Only upward, and only when it changes. `onPreferenceChange`
            // already filters equal values; the guard is for the case where a
            // measurement arrives as 0 during a pass in which no card has been
            // laid out yet, which would otherwise drop every card to nothing
            // for a frame.
            guard height > 0, height != tallest.wrappedValue else { return }
            tallest.wrappedValue = height
        }
    }

    /// The height every card in this grid settled on, or nothing yet.
    ///
    /// Applied OUTSIDE the card, so the measurement inside it stays the card's
    /// own natural height. A `.frame` does not stretch its child — it makes a
    /// box of the given size and puts the child in at the alignment — which is
    /// what stops this feeding back on itself: forcing the height does not
    /// change the height that gets reported, so a shelf that later filters down
    /// to shorter cards shrinks instead of staying stuck at the old tallest.
    func atCardHeight(_ tallest: CGFloat) -> some View {
        frame(height: tallest > 0 ? tallest : nil, alignment: .top)
    }
}

private struct KhaytCard: ViewModifier {
    let rail: Color?
    let padding: CGFloat
    /// ── WHY A CARD WOULD WANT TO BE TALLER THAN ITS CONTENTS ──────────────
    ///
    /// A `LazyVGrid` row is as tall as its tallest cell, and a cell that hugs
    /// its content leaves the rest of that height as a gap. So a row of machine
    /// cards was a row of boxes of different heights: a laser cutter has no
    /// nozzle, no colour count and no extruder, and drew a card a hundred and
    /// eighty points shorter than the printer beside it.
    ///
    /// Top alignment on the `GridItem` fixed WHERE the short card sat — it used
    /// to float in the middle of the row, which read as a card that had come
    /// loose — but not that it was short. Four boxes of four heights is a shelf
    /// that looks unfinished whatever they are aligned to.
    ///
    /// The content still starts at the top; it is the SURFACE that grows. That
    /// is the whole difference between "these cards are the same size" and
    /// "this card's contents are stretched apart", and only the first is wanted.
    let fills: Bool

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .padding(.leading, rail == nil ? 0 : 5)
            // MEASURED HERE, which is before the frame below and therefore
            // the card's own natural height — what it would be if nothing were
            // imposed on it. That is the number the grid needs to work out
            // which card is tallest, and measuring after the frame would
            // report back whatever was just handed down.
            .background {
                if fills {
                    GeometryReader { geo in
                        Color.clear.preference(key: CardHeight.self, value: geo.size.height)
                    }
                }
            }
            // `maxHeight` BEFORE the background, so the surface, the rail and
            // the border all take the full height rather than framing a short
            // card inside a tall cell.
            .frame(maxWidth: .infinity,
                   maxHeight: fills ? .infinity : nil,
                   alignment: fills ? .topLeading : .leading)
            .background(Khayt.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .leading) {
                // Clipped to the card's own shape so the bar takes the corner
                // radius on the two corners it touches and stays square on the
                // two it does not — a rounded pill floating inside the edge
                // reads as a stray element rather than as part of the card.
                if let rail {
                    Rectangle().fill(rail).frame(width: 3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Khayt.hairline, lineWidth: 1)
            }
    }
}

extension Khayt {

    /// What a card is drawn on.
    ///
    /// Deliberately NOT a material. A material samples what is behind it, and
    /// behind these is a plain window background, so the blur costs a
    /// compositing pass to produce a flat grey — and it renders as nothing at
    /// all in the offline bitmap the snapshot runner uses, which would leave
    /// every reviewed screenshot showing a layout this app never draws.
    ///
    /// Light is a warm off-white lifted OFF the window rather than a grey laid
    /// over it: `.quinary` on white is a grey box, and a column of grey boxes
    /// is what this file exists to stop. Dark lifts, because in dark appearance
    /// a raised surface is lighter than its ground.
    /// The dark value is the LIGHTEST background a palette colour is ever drawn
    /// on in dark appearance, so it is the one that sets their contrast. An
    /// early version used `#24262B` and quietly broke two — `late` fell to
    /// 4.25:1 where AA text needs 4.5. Measured, not noticed by eye.
    ///
    /// ── AND THE TEST THAT SAID IT WAS FINE WAS ASKING ABOUT WHITE ─────────
    ///
    /// `PaletteTests` measured every colour against `#FFFFFF` and `#1E1E1E`,
    /// neither of which this app draws on. Made to ask about the three real
    /// surfaces instead, it failed **ten** pairs on the palette as it then
    /// shipped: `cyan` at 3.84:1 on a recessed strip, `hot` at 4.02, `marked`
    /// at 2.56. Every one of them had been on screen for months.
    ///
    /// The whole light ramp is solved against `recessed` now — the darkest
    /// thing a coloured label sits on — and the dark ramp against this, the
    /// lightest. Anything that moves either has to be measured again, and the
    /// test will say so.
    static let surface = adaptive(light: 0xFBF9F5, dark: 0x201C17, name: "khaytSurface")

    /// The ground a screen is drawn on, and the reason the two above work.
    ///
    /// **A macOS window background is pure white in light appearance** —
    /// measured, not assumed: `NSColor.windowBackgroundColor` resolves to
    /// `#FFFFFF` under `.aqua` and `#1E1E1E` under `.darkAqua`. Which means a
    /// card in light appearance could not be raised at all: there is nothing
    /// lighter than white to lift it to, so every panel in this app was
    /// necessarily drawn as a grey box laid ON white, and a screen of grey
    /// boxes on white is precisely the look this file was written to fix.
    ///
    /// So the ground moves instead. A warm off-white to put the cards ON,
    /// which is what System Settings and Reminders do and why their panels
    /// read as objects rather than as shaded regions. Warm rather than neutral
    /// because the app's mark has one warm colour in it and a cold grey ground
    /// fights it.
    ///
    /// Dark barely moves — `#1E1E1E` is already a ground and only needs to be
    /// a shade below `surface`.
    static let ground = adaptive(light: 0xEFEBE3, dark: 0x16130F, name: "khaytGround")

    /// The line around a card: low contrast on purpose, there to say where the
    /// card ends rather than to be seen.
    ///
    /// A WARM LINE, not black at 9%.
    ///
    /// An alpha-black hairline over a warm ground is a grey line, and a grey
    /// line on every card edge in the app is most of what "it looks washed out"
    /// was. This is a colour of its own, from the same family as the surfaces
    /// it separates.
    static let hairline = adaptive(light: 0xDCD5C8, dark: 0x3A342C, name: "khaytHairline")

    /// The rule between two rows of a list.
    ///
    /// ── A LAYER LINE, NOT A ZEBRA STRIPE ─────────────────────────────────
    ///
    /// The usual way to separate rows is to tint every other one, and it works
    /// — at the cost of putting a grey band across half the screen. This app is
    /// about a thing built out of stacked layers, and a stack of layers is
    /// separated by LINES. So rows are ruled rather than striped: one hairline
    /// between them, lighter than the line round the card, so the card's own
    /// edge still reads as the edge.
    ///
    /// It is also the denser of the two. A ruled row can be 28pt; a striped one
    /// needs padding above and below the fill or the stripe looks like a
    /// selection.
    static let layerLine = adaptive(light: 0xEAE4D9, dark: 0x2E2822, name: "khaytLayerLine")

    /// The bare part of a spool, where the filament no longer reaches.
    ///
    /// ── WHY NOT `ground` ──────────────────────────────────────────────────
    ///
    /// It was `ground`, which is a shade BELOW `surface` in both appearances —
    /// correct for a screen background, wrong for a shape drawn on a card. In
    /// dark appearance the empty flange came out at `#141518` against a
    /// `#1D1F24` card: two near-blacks, so an 86%-full black spool read as
    /// emptier than a 12%-full grey one. Exactly backwards, and invisible in
    /// light appearance where the same two tones are far enough apart to look
    /// deliberate.
    ///
    /// So this one goes the OTHER way in dark: an empty spool is a lighter
    /// object than the card it sits on, because that is the only direction
    /// with room in it.
    static let bareSpool = adaptive(light: 0xE3DCCD, dark: 0x35302A, name: "khaytBareSpool")

    /// The edge of a drawn object, as opposed to the edge of a card.
    ///
    /// `hairline` is deliberately almost invisible; a shape needs more than
    /// that or a black spool on a dark card has no outline at all. Roughly
    /// double, and it goes white in dark appearance rather than staying black —
    /// which is the whole bug: `.black.opacity(0.14)` was doing nothing in dark
    /// appearance, so the one comment promising a black spool would not be "a
    /// black hole" was describing light mode only.
    static let drawnEdge = Color(nsColor: NSColor(name: NSColor.Name("khaytDrawnEdge")) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? NSColor(white: 1, alpha: 0.30) : NSColor(white: 0, alpha: 0.16)
    })
}

/// A figure the shop reads before it reads anything else.
///
/// ── WHY A TYPE THIS BIG ───────────────────────────────────────────────────
///
/// The type across this app was 18 uses of `.caption`, 18 of `.callout`, 15 of
/// `.headline` and four of anything larger. Everything on screen was said at
/// one volume, so the screen had no answer to "what should I look at" — and a
/// dashboard whose job is to answer that in a glance was making the reader
/// find it.
///
/// The unit is drawn smaller and secondary beside the number. The figure is
/// what is being read; "SAR" is what it is measured in, and setting them at one
/// size makes a four-character word compete with the thing it qualifies.
struct BigFigure: View {
    let value: String
    var unit: String?
    var tint: Color?
    var size: CGFloat = 34

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value)
                // Rounded, because the app's mark is a drawn letter with no
                // sharp terminals and the numbers should belong to it. Weight
                // sits at semibold rather than bold: at this size bold is
                // shouting, and everything on this screen would then have to
                // shout back.
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
            if let unit {
                Text(unit)
                    .font(.system(size: size * 0.42, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.55)
    }
}

/// A count or a state, said in one small capsule.
///
/// The app had a dozen hand-rolled versions of this — a `Text` with a padding,
/// a corner radius and an opacity picked at the call site — which is how the
/// same idea ended up four different sizes on four screens.
struct Chip: View {
    let text: String
    var tint: Color = Khayt.cyan
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            }
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        // A wash of the same hue rather than a second colour, so a chip never
        // introduces a colour the palette has not accounted for.
        .background(tint.opacity(0.13), in: Capsule())
    }
}

extension Khayt {

    /// A lane: the ground a group of cards sits IN, rather than a card itself.
    ///
    /// The board needs two depths and only had one. Columns and the job cards
    /// inside them were both drawn on a light grey, so a column read as a card
    /// containing slightly different cards — and the eye had to use the gaps to
    /// work out where one job ended and the next began.
    ///
    /// Recessed in both appearances, which is the part that has to be checked
    /// rather than assumed: in dark appearance "further away" is DARKER, so
    /// this goes down from the window while `surface` goes up from it. A lane
    /// lightened in dark would come forward and swap the two depths over.
    static let recessed = adaptive(light: 0xE7E1D7, dark: 0x0E0C09, name: "khaytRecessed")
}

extension View {
    /// A column of cards, set into the window.
    func lane(padding: CGFloat = 10) -> some View {
        self.padding(padding)
            .background(Khayt.recessed, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}


/// The spacing this app is laid out on, and where the numbers come from.
///
/// Before this existed, the margin around a screen's content was 14 on
/// Reports, 16 on the library, the machines, the board and the portfolio, and
/// 20 on the dashboard and Colour Studio — four values for one decision, none
/// of them chosen. Nobody notices a 20pt margin; everybody notices that two
/// screens in the same app do not agree, which is a large part of what makes
/// software look like it was assembled rather than designed.
///
/// The values are Apple's layout guidance for macOS rather than this app's
/// taste: 20pt margins at the edges of a window's content, and grouping done
/// with white space of 12 to 24 points.
enum Metric {
    /// The margin between a screen's content and the edges of its pane.
    ///
    /// 14, not 20. This app replaces a spreadsheet, and the thing a shop wants
    /// from it is to see the work — a 900pt window at 20 showed eighteen jobs
    /// where it now shows twenty-two, and the four it was spending on air are
    /// four a shop would otherwise scroll for.
    static let screen: CGFloat = 14
    /// The margin inside an inspector or summary pane. Tighter on purpose:
    /// these are narrow, dense and read at arm's length beside the thing they
    /// describe, and 20 on a 280pt pane spends a seventh of it on air.
    static let pane: CGFloat = 14
    /// Between one group of things and the next.
    static let gap: CGFloat = 12
    /// A row in a ruled list. The mockup's figure, and the reason the rules
    /// above are lines rather than fills: a striped row cannot be this tight.
    static let row: CGFloat = 28
}

/// The rule between two rows.
///
/// `Divider()` draws the system separator, which is a grey that belongs to
/// nobody. This is the app's own — see `Khayt.layerLine`.
struct LayerRule: View {
    var body: some View {
        Rectangle().fill(Khayt.layerLine).frame(height: 1)
    }
}

/// A figure with the arithmetic that produced it written underneath.
///
/// ── A SHOP CHECKS BY EYE ──────────────────────────────────────────────────
///
/// "Average job 540.46" is a number you either trust or do not. `1,080.93 ÷ 2`
/// underneath it is a number you can check while you read it, and a shop that
/// can check one derived figure trusts the other forty on the screen.
///
/// It also catches a whole class of mistake before anyone reports it: a total
/// printed beside the terms that make it cannot silently stop matching them.
/// The mockup this came from printed a free-hours total that did not match the
/// rows above it, and nothing on that artboard would ever have said so.
struct Derived: View {
    let value: String
    /// `1,080.93 ÷ 2`, `662 of 750 h`, `480 − 120`. The working, not a caption.
    let working: String
    var unit: String?
    var tint: Color?
    var size: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            BigFigure(value: value, unit: unit, tint: tint, size: size)
            HStack(spacing: 5) {
                // A tick, the way a dimension on a drawing is tied to what it
                // measures rather than floating near it.
                Rectangle().fill(Khayt.hairline).frame(width: 1, height: 9)
                Text(working)
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One figure in a strip of them.
struct Stat: Identifiable {
    let label: String
    let value: String
    /// The arithmetic, where there is any.
    var working: String?
    /// The app's own mark, preferred. `symbol` is the fallback for the handful
    /// of labels this app has no drawing for yet.
    var mark: Mark?
    var symbol: String?
    var tint: Color = .secondary
    /// Set on the one figure describing something happening right now.
    var alive = false
    var id: String { label }
}

/// Several figures in ONE card, ruled apart.
///
/// ── FOUR CARDS FOR FOUR NUMBERS ───────────────────────────────────────────
///
/// The dashboard drew "Printing 5", "Open 11", "Late 6" and "Online 0/5" as
/// four separate cards, each with its own border, corner radius, padding and
/// shadowless lift — four rectangles across seventeen hundred points to carry
/// four numbers and four words. The ink went almost entirely on the boxes.
///
/// They are one thing: the state of the floor, right now. So they are one card,
/// with a layer line between each figure and the next — which is also what the
/// rest of the app now uses to separate a row from the row below it.
struct StatStrip: View {
    let stats: [Stat]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(stats.enumerated()), id: \.element.id) { index, stat in
                if index > 0 {
                    Rectangle().fill(Khayt.layerLine).frame(width: 1)
                        .padding(.vertical, 8)
                }
                Cell(stat: stat)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .card(padding: 0)
    }

    private struct Cell: View {
        let stat: Stat
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    if let mark = stat.mark {
                        Drawn(mark: mark, size: 13)
                    } else if let symbol = stat.symbol {
                        Image(systemName: symbol)
                            // The one piece of motion in the app, on the one
                            // thing that is actually moving.
                            .symbolEffect(.variableColor.iterative.dimInactiveLayers,
                                          isActive: stat.alive && !reduceMotion)
                    }
                    Text(stat.label).lineLimit(1)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(stat.alive ? AnyShapeStyle(Khayt.hot) : AnyShapeStyle(.secondary))

                Text(stat.value)
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(stat.tint == .secondary
                                     ? AnyShapeStyle(.primary) : AnyShapeStyle(stat.tint))
                    .lineLimit(1).minimumScaleFactor(0.6)

                if let working = stat.working {
                    HStack(spacing: 5) {
                        Rectangle().fill(Khayt.hairline).frame(width: 1, height: 9)
                        Text(working).font(.caption2).monospacedDigit()
                            .foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 13).padding(.vertical, 11)
        }
    }
}
