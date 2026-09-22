import SwiftUI

/// Every job, sorted by urgency, with an inspector on the one you picked —
/// §7's first layout shape, the dense table.
///
/// The footer is the part that matters: it totals what is SHOWN and names
/// what is unknown. A table footer that adds up only the rows it could price
/// and prints the result as a total is the §5 failure at its most expensive,
/// because it is the number a shop quotes from.
struct Ledger: View {
    @Bindable var shop: Shop

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                LedgerFilters(shop: shop)
                LedgerHead(words: shop.words)
                ScrollView { LedgerRows(shop: shop) }
                LedgerFooter(shop: shop)
            }
            .background(Role.surf)

            if let picked = shop.ledgerSelection {
                JobInspector(row: picked, shop: shop)
                    .frame(width: Wide.inspector)
            }
        }
    }
}

/// The rows, outside their scroller — see `TriageContent` for why.
struct LedgerRows: View {
    @Bindable var shop: Shop

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(shop.ledgerRows) { row in
                LedgerRow(row: row, shop: shop)
            }
        }
    }
}

/// The filter row. Chips, not a segmented control: these are not four views
/// of one thing, they are four questions, and "Needs me" is the one the
/// screen opens on.
struct LedgerFilters: View {
    @Bindable var shop: Shop

    var body: some View {
        HStack(spacing: Space.sm) {
            ForEach(Shop.LedgerFilter.allCases, id: \.self) { filter in
                let on = shop.ledgerFilter == filter
                Button { shop.ledgerFilter = filter } label: {
                    HStack(spacing: Space.xs) {
                        Text(shop.words.callIt(filter.titleKey))
                        Figure(value: Double(shop.ledgerCount(filter)), size: 10,
                               weight: on ? .bold : .medium,
                               tint: on ? Role.onNavy : Role.text2)
                    }
                    .font(TypeScale.row(10.5, weight: on ? .bold : .medium))
                    .foregroundStyle(on ? Role.onNavy : Role.text)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 2.5)
                    .background(on ? Role.navy : Role.surf3,
                                in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
            Spacer(minLength: Space.sm)
            Text(shop.words.callIt("mac.sorted_by_urgency"))
                .font(TypeScale.body(10.5))
                .foregroundStyle(Role.text3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(Role.line).frame(height: 1) }
    }
}

/// The column heads. `surf2`, because a head is not content.
struct LedgerHead: View {
    let words: Words

    var body: some View {
        HStack(spacing: 8) {
            CapsLabel(words.callIt("mac.col_state"), size: 9).frame(width: 78, alignment: .leading)
            CapsLabel(words.callIt("mac.col_job"), size: 9)
                .frame(maxWidth: .infinity, alignment: .leading)
            CapsLabel(words.callIt("mac.col_due"), size: 9).frame(width: 64, alignment: .trailing)
            CapsLabel(words.callIt("mac.col_charged"), size: 9).frame(width: 68, alignment: .trailing)
            CapsLabel(words.callIt("mac.col_margin"), size: 9).frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Role.surf2)
        .overlay(alignment: .bottom) { Rectangle().fill(Role.line).frame(height: 1) }
    }
}

/// One job. Five of §6's row states live here: default, selected, attention,
/// closed, and hover — which SwiftUI gives via `onHover` rather than CSS.
struct LedgerRow: View {
    let row: Shop.LedgerLine
    @Bindable var shop: Shop
    @State private var hovering = false

    private var selected: Bool { shop.ledgerSelection?.id == row.id }

    /// The shop charged less than the job cost it. Nil margin is not this —
    /// a cost the book was never told is unknown, not a loss.
    private var soldBelowCost: Bool { (row.margin ?? 0) < 0 }

    var body: some View {
        HStack(spacing: 8) {
            StateChip(state: row.state, words: shop.words, onNavy: selected)
                .frame(width: 78, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(TypeScale.row(11.5, weight: .semibold))
                    .foregroundStyle(selected ? Role.onNavy : Role.text)
                    .lineLimit(1)
                Text(row.who)
                    .font(TypeScale.body(10))
                    .foregroundStyle(selected ? Role.onNavy2 : Role.text2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.due)
                .font(TypeScale.figure(10.5))
                .foregroundStyle(dueTint)
                .frame(width: 64, alignment: .trailing)
            Figure(value: row.charged, style: .money(code: shop.currency), size: 10.5,
                   tint: selected ? Role.onNavy : Role.text)
                .frame(width: 68, alignment: .trailing)
            // A margin nobody can compute is a dash — never a zero, and never
            // a percentage of a cost the book was not told.
            //
            // ── A MARGIN IS A LEVEL, AND A LOSS IS NEWS ───────────────────
            //
            // It was set in `signedPercent`, so every row on this screen read
            // "+56%", "+58%", "+65%" — fifteen plus signs down a column, which
            // is a sign that carries nothing. That style is for a rise or a
            // fall; a margin is how much of the price was kept, and nobody
            // says a job made "plus fifty-six percent".
            //
            // A NEGATIVE one is the row this column exists to find, and it was
            // drawn in the same secondary grey as every other. `ProductProfit`
            // had already made this call for the same figure — "red for a
            // product that loses money, and nothing for one that does not:
            // every other row is the ordinary case" — and the ledger, which is
            // where a shop actually reads its jobs, had not.
            Figure(value: row.margin, style: .percent, size: 10.5,
                   tint: soldBelowCost ? Role.late
                                       : (selected ? Role.onNavy2 : Role.text2))
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .opacity(row.state.rowOpacity)
        .background(ground)
        .overlay(alignment: .leading) {
            // §6: an attention row carries a 3px leading border as well as a
            // ground, so it reads in greyscale too.
            if row.state.isAttention && !selected {
                Rectangle().fill(row.state.tint).frame(width: 3)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Role.line).frame(height: 1) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { shop.ledgerSelection = row }
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var ground: Color {
        if selected { return Role.navy }
        if let ground = row.state.ground { return ground }
        return hovering ? Role.surf2 : .clear
    }

    private var dueTint: Color {
        if selected { return Role.onNavy2 }
        return row.state.isAttention ? row.state.tint : Role.text2
    }
}

/// What is shown, and what is not known about it.
struct LedgerFooter: View {
    @Bindable var shop: Shop

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: Space.xs) {
                Text(shop.words.counting(shop.openJobCount, "mac.n_open"))
                Text("·")
                Text(shop.words.counting(shop.orders.count - shop.openJobCount, "mac.n_closed"))
            }
            .font(TypeScale.body(10.5))
            .foregroundStyle(Role.text2)

            Spacer(minLength: Space.sm)

            HStack(spacing: Space.xs) {
                Figure(value: shop.ledgerShownTotal, style: .money(code: shop.currency),
                       size: 10.5, weight: .semibold)
                Text(shop.words.callIt("mac.open_total"))
                    .font(TypeScale.body(10.5))
                    .foregroundStyle(Role.text2)
            }
            // The hole, named. Not an asterisk — a sentence.
            if let unpriced = shop.ledgerUnpricedNote {
                Text(unpriced)
                    .font(TypeScale.body(10.5))
                    .foregroundStyle(Role.text3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Role.surf2)
        .overlay(alignment: .top) { Rectangle().fill(Role.line).frame(height: 1) }
    }
}

/// The 282px inspector — §7's optional trailing pane, with its own fixed
/// action footer.
struct JobInspector: View {
    let row: Shop.LedgerLine
    @Bindable var shop: Shop

    var body: some View {
        VStack(spacing: 0) {
            ScrollView { inspected }
            Spacer(minLength: 0)
            footer
        }
        .background(Role.surf2)
        .overlay(alignment: .leading) {
            Rectangle().fill(Role.line2).frame(width: 1)
        }
    }

    /// Everything above the fixed footer, outside the scroller.
    @ViewBuilder var inspected: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Role.line).frame(height: 1)
            money
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.sm) {
                StateChip(state: row.state, words: shop.words)
                Text(row.reference)
                    .font(TypeScale.figure(10.5))
                    .foregroundStyle(Role.text3)
            }
            Text(row.title)
                .font(TypeScale.title(15, weight: .bold))
                .foregroundStyle(Role.text)
            Text(row.who)
                .font(TypeScale.body(11.5))
                .foregroundStyle(Role.text2)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var money: some View {
        VStack(alignment: .leading, spacing: 0) {
            line("mac.charged_net", row.net)
            line("mac.vat", row.vat)
            line("mac.charged_gross", row.charged, rule: true, bold: true)
            // The unknown, said in a sentence rather than shown as a gap.
            if let why = row.costUnknownWhy {
                Text(why)
                    .font(TypeScale.body(10))
                    .foregroundStyle(Role.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.sm)
            }
            line("mac.margin",
                 row.marginMoney, rule: true, bold: true,
                 certainty: row.costUnknownWhy == nil ? .exact : .atLeast)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
    }

    private func line(_ key: String, _ value: Double?, rule: Bool = false,
                      bold: Bool = false,
                      certainty: Figure.Certainty = .exact) -> some View {
        HStack {
            Text(shop.words.callIt(key))
                .font(TypeScale.body(11, weight: bold ? .semibold : .regular))
                .foregroundStyle(bold ? Role.text : Role.text2)
            Spacer(minLength: Space.sm)
            Figure(value: value, style: .money(code: shop.currency),
                   certainty: certainty, size: 11,
                   weight: bold ? .bold : .medium)
        }
        .padding(.top, rule ? 5 : 2.5)
        .padding(.bottom, 2.5)
        .overlay(alignment: .top) {
            if rule { Rectangle().fill(Role.line).frame(height: 1) }
        }
    }

    /// Fixed at the bottom, so the actions can never scroll away — the same
    /// rule §6 gives sheets, for the same reason.
    private var footer: some View {
        HStack(spacing: Space.sm) {
            Button {
                if let order = shop.orders.first(where: { $0.id == row.id }) {
                    shop.selection = order.id
                    shop.shelf = .jobs(nil)
                }
            } label: {
                Text(shop.words.callIt("mac.edit_job"))
                    .font(TypeScale.row(11, weight: .semibold))
                    .foregroundStyle(Role.onNavy)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Role.navy, in: RoundedRectangle(cornerRadius: Radius.control,
                                                                style: .continuous))
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(Role.surf3)
        .overlay(alignment: .top) { Rectangle().fill(Role.line2).frame(height: 1) }
    }
}
