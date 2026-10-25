import SwiftUI
import KhaytCore

/// The printer chips under a Medium or Large tile, and in the list's Fits
/// column: where this model goes on the bed, ready ones first.
///
/// What each chip says is `LibraryFitChips` — the inspector's own answer
/// (`Shop.machineFits`), handed in already worked out and memoised. This view
/// draws it and decides nothing but how many fit the width: that question is
/// `LibraryFitChips.visibleCount`, asked by `FitChipLayout` with each chip
/// measured once. Past what fits, one "+N" chip, with every machine on hover.
///
/// Mirrored in Arabic by the layout itself: the first chip (the ready one) is
/// at the leading edge, which is the right in a right-to-left window.
struct FitChipRow: View {
    let row: LibraryFitChips.Row
    let words: Words
    /// Drawn on a chosen tile, which is the accent colour in both appearances.
    var selected = false

    /// The row's height, so a tile with no chips can keep the same line and
    /// a row of tiles stays level.
    static let height: CGFloat = 15

    var body: some View {
        Group {
            if row.tooBigEverywhere {
                chipBox(text: words.callIt("mac.lfc_too_big_all"), symbol: "arrow.up.left.and.arrow.down.right",
                        ink: selected ? .white : Khayt.late,
                        fill: selected ? Color.white.opacity(0.2) : Khayt.late.opacity(0.13))
            } else if !row.chips.isEmpty {
                FitChipLayout(count: row.chips.count) {
                    ForEach(row.chips) { chip in chipView(chip) }
                    ForEach(1...row.chips.count, id: \.self) { n in
                        chipBox(text: words.callIt("mac.lfc_more", ["n": .string(words.numeral(n))]), symbol: nil,
                                ink: selected ? .white : Color.secondary,
                                fill: selected ? Color.white.opacity(0.2) : Khayt.recessed)
                            .accessibilityLabel(words.counting(n, "mac.lfc_more_said"))
                    }
                }
                .clipped()
            }
        }
        .frame(height: Self.height, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(Self.said(row, words: words))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.said(row, words: words))
    }

    private func chipView(_ chip: LibraryFitChips.Chip) -> some View {
        let (ink, fill, symbol) = Self.look(chip.tone, selected: selected)
        return chipBox(text: chip.label, symbol: symbol, ink: ink, fill: fill)
    }

    private func chipBox(text: String, symbol: String?, ink: Color, fill: Color) -> some View {
        HStack(spacing: 2) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 7.5, weight: .bold))
            }
            Text(verbatim: text)
                .font(.system(size: 9.5, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 4.5)
        .padding(.vertical, 1.5)
        .background(fill, in: Capsule())
        .fixedSize()
    }

    /// How a chip of each tone is drawn: ready in the app's done colour with
    /// a tick, a swap with the swap mark, a plain fit quiet.
    static func look(_ tone: LibraryFitChips.Tone, selected: Bool) -> (Color, Color, String?) {
        if selected {
            return (.white, Color.white.opacity(tone == .ready ? 0.3 : 0.18),
                    tone == .ready ? "checkmark" : tone == .swap ? "arrow.triangle.2.circlepath" : nil)
        }
        switch tone {
        case .ready: return (Khayt.done, Khayt.done.opacity(0.15), "checkmark")
        case .swap: return (.secondary, Khayt.recessed, "arrow.triangle.2.circlepath")
        case .fits: return (.secondary, Khayt.recessed, nil)
        }
    }

    /// The whole answer in words, for the hover and VoiceOver: each machine's
    /// full name and the inspector's word for its state.
    @MainActor
    static func said(_ row: LibraryFitChips.Row, words: Words) -> String {
        if row.tooBigEverywhere { return words.callIt("mac.lfc_too_big_all") }
        let list = row.chips.map { chip -> String in
            let key: String
            switch chip.tone {
            case .ready: key = chip.turned ? "mac.li_state_ready_turned" : "mac.li_state_ready"
            case .swap: key = "mac.li_state_needs_swap"
            case .fits: key = chip.turned ? "mac.li_state_fits_turned" : "mac.li_state_fits"
            }
            return Figure.isolated(chip.name) + " \u{2014} " + words.callIt(key)
        }.joined(separator: " · ")
        return list.isEmpty ? "" : words.callIt("mac.lfc_where", ["list": .string(list)])
    }
}

/// Lays out `count` chips and, after them, `count` "+N" chips (+1 … +count);
/// shows as many chips as fit the width and the one "+N" for the rest. The
/// others are put outside the row, which `FitChipRow` clips.
///
/// Each chip is measured once per layout — no `ViewThatFits` trying every
/// combination on every tile.
struct FitChipLayout: Layout {
    let count: Int
    var spacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let height = sizes.map(\.height).max() ?? 0
        let natural = sizes.prefix(count).reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, count - 1))
        return CGSize(width: proposal.width ?? natural, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        guard sizes.count >= count * 2 else { return }
        let shown = LibraryFitChips.visibleCount(
            widths: sizes.prefix(count).map { Double($0.width) }, available: Double(bounds.width),
            spacing: Double(spacing), overflow: { n in Double(sizes[count + n - 1].width) })
        let away = CGPoint(x: bounds.maxX + 10_000, y: bounds.minY)
        var x = bounds.minX
        for i in 0..<count {
            if i < shown {
                subviews[i].place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: .unspecified)
                x += sizes[i].width + spacing
            } else {
                subviews[i].place(at: away, anchor: .leading, proposal: .unspecified)
            }
        }
        let rest = count - shown
        for n in 1...count {
            let view = subviews[count + n - 1]
            if n == rest {
                view.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: .unspecified)
            } else {
                view.place(at: away, anchor: .leading, proposal: .unspecified)
            }
        }
    }
}
