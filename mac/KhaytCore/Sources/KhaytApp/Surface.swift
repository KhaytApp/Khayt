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
    static let surface = adaptive(light: 0xFDFCFA, dark: 0x24262B, name: "khaytSurface")

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
    static let ground = adaptive(light: 0xF2F0EC, dark: 0x1A1B1F, name: "khaytGround")

    /// The line around a card. Low contrast on purpose — it is there to say
    /// where the card ends, not to be seen.
    static let hairline = Color(nsColor: NSColor(name: NSColor.Name("khaytHairline")) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.09)
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
    static let recessed = adaptive(light: 0xE7E4DE, dark: 0x141518, name: "khaytRecessed")
}

extension View {
    /// A column of cards, set into the window.
    func lane(padding: CGFloat = 10) -> some View {
        self.padding(padding)
            .background(Khayt.recessed, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
