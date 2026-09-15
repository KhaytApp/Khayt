import SwiftUI

/// The Dashboard — the chosen direction, "Triage / Ledger".
///
/// ── TWO ANSWERS TO TWO DIFFERENT QUESTIONS ────────────────────────────────
///
/// **Triage** answers *what needs me* — at most three things, each with the
/// sentence that explains it and the buttons that end it. **Ledger** answers
/// *where does the work stand* — every job, sorted by urgency, with an
/// inspector on the one you picked.
///
/// They are one screen with a switch rather than two entries in the sidebar
/// because they are the same question at two distances, and a shop crossing
/// between them should not lose its place.
///
/// Above both sits the money masthead, which is the only thing on the screen
/// that is true regardless of which of the two you are reading.
struct Triage: View {
    @Bindable var shop: Shop

    enum Mode: String, CaseIterable { case triage, ledger }
    @SceneStorage("dashboard.mode") private var mode: Mode = .triage

    var body: some View {
        VStack(spacing: 0) {
            MoneyMasthead(shop: shop, mode: $mode)
            if shop.orders.isEmpty && shop.machines.isEmpty {
                // §6: never a blank screen. What the thing is for, why it
                // matters, one obvious next step, one escape hatch.
                FirstRun(shop: shop)
            } else {
                switch mode {
                case .triage: TriageBoard(shop: shop)
                case .ledger: Ledger(shop: shop)
                }
            }
        }
    }
}

/// The navy strip: what is owed, what the month made, and the two figures a
/// shop is asked to trust.
///
/// `MATERIAL COST` is drawn with a dash and a reason whenever any job in the
/// month carries no material cost. That is §5 doing its job on the most
/// expensive number on the screen: a material cost averaged over the jobs
/// that happen to have one is a margin that reads as measured and is not.
struct MoneyMasthead: View {
    @Bindable var shop: Shop
    @Binding var mode: Triage.Mode

    var body: some View {
        HStack(spacing: 18) {
            LabelledFigure(label: shop.words.callIt("mac.owed"),
                           value: shop.owedTotal,
                           style: .money(code: shop.currency),
                           words: shop.words, onNavy: true)
            rule
            LabelledFigure(label: shop.monthNetLabel,
                           value: shop.monthNet,
                           style: .money(code: shop.currency),
                           note: shop.monthNetNote,
                           words: shop.words, onNavy: true)
            rule
            LabelledFigure(label: shop.words.callIt("mac.gross_short"),
                           value: shop.monthGross,
                           style: .money(code: shop.currency),
                           words: shop.words, onNavy: true, size: 14)
            rule
            LabelledFigure(label: shop.words.callIt("mac.material_cost"),
                           value: shop.monthMaterialCost,
                           style: .money(code: shop.currency),
                           certainty: shop.monthMaterialCost == nil ? .exact : .atLeast,
                           note: shop.materialCostGapNote,
                           words: shop.words, onNavy: true, size: 14)

            Spacer(minLength: Space.md)

            ModeSwitch(mode: $mode, words: shop.words)

            Button {
                shop.shelf = .jobs(nil)
            } label: {
                CapsLabel(shop.words.callIt("mac.record_a_payment"), tint: Role.onAcc, size: 11)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .padding(.vertical, Space.sm)
                    // `accInk`, never `acc` — this one carries white text.
                    .background(Role.accInk, in: RoundedRectangle(cornerRadius: 5,
                                                                  style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!shop.canMoveJobs)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Role.navy2)
    }

    /// A divider the height of the figures beside it, not the height of the
    /// window. `maxHeight: .infinity` inside an HStack asks the row to be as
    /// tall as it can be, and the row obliges — which is how a 56-point strip
    /// became 590 and pushed the whole dashboard off the screen.
    private var rule: some View {
        Rectangle().fill(Role.navyLine).frame(width: 1, height: 34)
    }
}

/// Triage / Ledger. A segmented control drawn to the spec rather than the
/// system's, because the system's sits on a light ground and this one is on
/// navy — `.pickerStyle(.segmented)` there is a grey slab.
struct ModeSwitch: View {
    @Binding var mode: Triage.Mode
    let words: Words

    var body: some View {
        HStack(spacing: 2) {
            segment(.triage, "mac.triage")
            segment(.ledger, "mac.ledger")
        }
        .padding(2)
        .background(Color.white.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    private func segment(_ which: Triage.Mode, _ key: String) -> some View {
        let on = mode == which
        return Button { mode = which } label: {
            Text(words.callIt(key))
                .font(TypeScale.row(10.5, weight: on ? .bold : .medium))
                // `onAcc` on the selected pill, because the pill is `accInk`.
                // White here reads fine in light and drops to 2.72:1 in dark.
                .foregroundStyle(on ? Role.onAcc : Role.onNavy2)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 11)
                .padding(.vertical, 3)
                .background {
                    if on {
                        Elevation.pill(
                            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                                .fill(Role.accInk))
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

/// At most three cards, and the sentence under each is the whole point.
///
/// The screen does not say "2 late" and leave the shop to find out which. It
/// names them, says how late, says what is holding them, and offers the two
/// buttons that end it. A count is a notification; this is a decision.
struct TriageBoard: View {
    @Bindable var shop: Shop

    var body: some View {
        ScrollView { TriageContent(shop: shop) }
    }
}

/// The board's content, outside its scroller.
///
/// Split out because `ImageRenderer` will not render the inside of a
/// `ScrollView` — every photograph of this screen came back as an empty
/// cream rectangle, which looks exactly like a layout bug and is not one. The
/// snapshot renders this; the app scrolls it.
struct TriageContent: View {
    @Bindable var shop: Shop

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading
            HStack(alignment: .top, spacing: 11) {
                ForEach(shop.triageCards) { card in
                    TriageCard(card: card, shop: shop)
                }
            }
            HStack(alignment: .top, spacing: Space.xl) {
                OnTheMachines(shop: shop).frame(maxWidth: .infinity)
                TheShelf(shop: shop).frame(width: 300)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(shop.words.counting(shop.triageCards.count, "mac.n_things_need_you"))
                .font(TypeScale.title(15, weight: .bold))
                .foregroundStyle(Role.text)
            // Date, then two counts — three `Text`s, never one sentence built
            // with `+`. §5 applies to prose as much as to figures.
            HStack(spacing: Space.xs) {
                Text(Date().formatted(date: .complete, time: .shortened))
                Text("·")
                Text(shop.words.counting(shop.openJobCount, "mac.n_open"))
            }
            .font(TypeScale.body(11))
            .foregroundStyle(Role.text2)
        }
    }
}

/// One thing that needs a person.
struct TriageCard: View {
    let card: Shop.TriageItem
    @Bindable var shop: Shop

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.sm) {
                Text(card.state.glyph)
                CapsLabel(card.title, tint: card.state.tint, size: 10)
            }
            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(Array(card.lines.enumerated()), id: \.offset) { index, line in
                    if index > 0 {
                        Rectangle().fill(Role.line).frame(height: 1)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.subject)
                            .font(TypeScale.body(13, weight: .semibold))
                            .foregroundStyle(Role.text)
                        Text(line.because)
                            .font(TypeScale.body(11))
                            .foregroundStyle(Role.text2)
                            // §10: a sentence that runs the width of a 2560
                            // display is a sentence nobody finishes.
                            .sentenceWidth(11)
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: Space.sm) {
                ForEach(card.actions) { action in
                    ActionButton(action: action, shop: shop)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .card(state: card.state.tint, padding: 12)
    }
}

/// §6's four button weights, and the fourth is a rule not a style: anything
/// that reaches a customer is drawn on `lateBg` with an envelope, ends in an
/// ellipsis, and confirms. An ordinary edit does none of those.
struct ActionButton: View {
    let action: Shop.TriageAction
    @Bindable var shop: Shop

    var body: some View {
        Button {
            shop.perform(action)
        } label: {
            HStack(spacing: Space.xs) {
                if action.reachesCustomer { Text("✉") }
                Text(shop.words.callIt(action.titleKey)
                     + (action.reachesCustomer ? "…" : ""))
            }
            .font(TypeScale.row(11, weight: .semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(ground, in: RoundedRectangle(cornerRadius: Radius.control,
                                                     style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var ink: Color {
        switch action.weight {
        case .primary:  Role.onNavy
        case .brand:    Role.onAcc
        case .ordinary: Role.text
        case .outward:  Role.late
        }
    }

    private var ground: Color {
        switch action.weight {
        case .primary:  Role.navy
        case .brand:    Role.accInk
        case .ordinary: .clear
        case .outward:  Role.lateBg
        }
    }

    private var border: Color {
        switch action.weight {
        case .ordinary: Role.line2
        case .outward:  Role.lateLine
        default:        .clear
        }
    }
}
