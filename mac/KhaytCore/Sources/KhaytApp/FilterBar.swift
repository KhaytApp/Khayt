import SwiftUI

/// A row of chips that narrows the list under it.
///
/// ── ONE OF THESE, NOT ONE PER SCREEN ──────────────────────────────────────
///
/// The library and the catalogue ask the same question in different words —
/// "which of these do I mean" — and the app's own note on `Surface.Chip`
/// records what happens when that is answered twice: *"the app had a dozen
/// hand-rolled versions of this, which is how the same idea ended up four
/// different sizes on four screens."* The screens differ in what the chips MEAN
/// and agree on everything else, so what varies is a list of chips and what does
/// not lives here.
///
/// ── AND IT HIDES ITSELF ───────────────────────────────────────────────────
///
/// A row of chips over a list with nothing to narrow is furniture, and on the
/// screen a shop sees the day it installs it is furniture in the way. A chip
/// that would find nothing is never offered, and when none is left the bar —
/// and its rule — are not drawn at all.
struct FilterBar: View {
    let chips: [FilterChipModel]
    /// Shown only while something is on, because "Clear filters" beside no
    /// filter is a button that does nothing, reads as broken, and is the exact
    /// complaint the search box on the calculator drew.
    let showingClear: Bool
    let clearLabel: String
    let clear: () -> Void

    var body: some View {
        if !chips.isEmpty {
            VStack(spacing: 0) {
                // ── A ROW THAT FITS IS NOT A SCROLL VIEW ──────────────────
                //
                // In Arabic the first chip of Gift cards and of the Catalogue
                // was cut at the leading edge — "ـطة 3" for "نشطة 3" — on a
                // row of three chips (Nov 11 2026 review, B19). The fade was
                // suspected first and was not it: with the fade ruled out
                // (`ScrollEdges`), the same picture came back. WHY a
                // right-to-left horizontal scroll view cuts content narrower
                // than itself was not established; that it does, here, was
                // photographed twice.
                //
                // So the scroll view is used only when the chips do not fit.
                // When they do — nearly always — the row is a plain stack
                // against the leading edge, which cannot be scrolled out of
                // place because it does not scroll.
                ViewThatFits(in: .horizontal) {
                    row.frame(maxWidth: .infinity, alignment: .leading)
                    ScrollView(.horizontal) { row }
                        // STILL OPEN: a row too long to fit (the Catalogue
                        // with seventeen chips) is still cut at its first
                        // chip in Arabic. `.defaultScrollAnchor(.leading)`
                        // was tried and photographed, and changed nothing.
                        .scrollIndicators(.never)
                        // The scroller is hidden, so the row said nothing about the
                        // chips past the window edge — the library's ran off mid-chip
                        // after the eighth creator. The far edge fades while there is
                        // more to see. See `HorizontalScrollCue`.
                        .horizontalScrollCue()
                }
                Divider()
            }
        }
    }
}

extension FilterBar {
    /// The chips and the clear link, with the row's own margins.
    fileprivate var row: some View {
        HStack(spacing: 6) {
            ForEach(chips) { chip in
                FilterChip(label: chip.label, count: chip.count,
                           on: chip.on, press: chip.press)
            }
            if showingClear {
                Button(clearLabel, action: clear)
                    .buttonStyle(.link)
                    .padding(.leading, 4)
            }
        }
        .padding(.horizontal, Metric.screen)
        .padding(.vertical, 6)
    }
}

/// One chip, as the screen means it.
///
/// `id` is the caller's, not the label's: two axes can offer the same word — a
/// category called "Resin" and a material called "Resin" — and two chips
/// sharing an identity is a `ForEach` drawing one of them.
struct FilterChipModel: Identifiable {
    let id: String
    let label: String
    let count: Int
    let on: Bool
    let press: () -> Void
    /// A colour drawn before the name, as hex — the Library's Colour rows.
    var swatch: String? = nil
    /// False for a row that is always listed but holds nothing just now: it
    /// is drawn greyed rather than taken away.
    var enabled = true
}

/// A chip that PRESSES, which is the only reason it is not `Chip`.
///
/// `Surface.Chip` says a count or a state and cannot be pressed; this turns a
/// filter on and off and has to show which it is. Everything else is taken from
/// it deliberately — the same capsule, the same 10pt semibold, the same
/// padding, the same wash of one hue rather than a second colour.
///
/// Its COUNT is part of it: "Busts 12" tells a shop whether the chip is worth
/// pressing, and one that turns out to hold a single model is a press it could
/// have been spared.
struct FilterChip: View {
    let label: String
    let count: Int
    let on: Bool
    let press: () -> Void

    var body: some View {
        Button(action: press) {
            HStack(spacing: 3) {
                Text(label)
                Text("\(count)").monospacedDigit().opacity(0.7)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(on ? Khayt.onBrand : Khayt.brand)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            // ON is the solid hue, OFF is the same hue washed — the chip never
            // introduces a colour the palette has not accounted for.
            .background(on ? AnyShapeStyle(Khayt.brand)
                           : AnyShapeStyle(Khayt.brand.opacity(0.13)),
                        in: Capsule())
        }
        .buttonStyle(.plain)
        // Colour is never the only signal: a pressed chip is also SAID, so a
        // shop that cannot tell the two hues apart is still told which of them
        // is narrowing the screen.
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .help(label)
    }
}
