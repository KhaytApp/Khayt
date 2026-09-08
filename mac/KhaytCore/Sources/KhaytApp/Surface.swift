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
    func card(rail: Color? = nil, padding: CGFloat = 12) -> some View {
        modifier(KhaytCard(rail: rail, padding: padding))
    }
}

private struct KhaytCard: ViewModifier {
    let rail: Color?
    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .padding(.leading, rail == nil ? 0 : 5)
            .frame(maxWidth: .infinity, alignment: .leading)
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
