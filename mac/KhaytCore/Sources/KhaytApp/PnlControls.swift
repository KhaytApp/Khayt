import SwiftUI
import KhaytCore

/// Which stretch of the book the profit and loss covers.
///
/// A Menu and not a Picker, for the reason `PeriodMenu` gives: a toolbar
/// Picker drew as an empty chevron, and which period a page is showing is the
/// one thing a period control has to say. Its own control rather than
/// `PeriodMenu`, because the P&L has periods the lists do not (last quarter,
/// last year, a custom range) and the Best page's choice is a different
/// question that should not move when this one does.
struct PnlPeriodMenu: View {
    let shop: Shop

    /// Nearest first, then the shop's own pair of days, then everything.
    static let order: [PnlRange.Kind] = [.month, .last_month, .quarter, .last_quarter,
                                         .year, .last_year, .custom, .all]

    var body: some View {
        Menu {
            ForEach(Self.order) { kind in
                if kind == .custom || kind == .all { Divider() }
                Button {
                    shop.pnlRange.kind = kind
                } label: {
                    if shop.pnlRange.kind == kind {
                        Label(shop.words.callIt(kind.key), systemImage: "checkmark")
                    } else {
                        Text(shop.words.callIt(kind.key))
                    }
                }
            }
        } label: {
            Text(shop.pnlPeriodTitle())
        }
        .menuStyle(.borderlessButton)
        .help(shop.words.callIt("an.pnl_period"))
        .accessibilityLabel(shop.words.callIt("an.pnl_period"))
    }
}

/// The P&L as a file: CSV for a spreadsheet, PDF for a person. The same two
/// items are in the Book menu, so a shop can export from anywhere.
struct PnlExportMenu: View {
    let shop: Shop

    var body: some View {
        Menu {
            Button(shop.words.callIt("pnl.export_csv")) { Task { await shop.exportPnl(.csv) } }
            Button(shop.words.callIt("pnl.export_pdf")) { Task { await shop.exportPnl(.pdf) } }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(shop.words.callIt("pnl.export"))
        .accessibilityLabel(shop.words.callIt("pnl.export"))
    }
}

/// The custom range's two days, under the page's tabs while it is chosen.
///
/// Typed, as the custom report's are (`DayField`), rather than a date picker:
/// a picker draws in the Mac's calendar, which for a Saudi shop may be Umm
/// al-Qura, while the book is written in Gregorian days.
struct PnlCustomRange: View {
    @Bindable var shop: Shop

    var body: some View {
        let words = shop.words
        HStack(alignment: .bottom, spacing: 14) {
            DayField(title: words.callIt("rb.from"), hint: words.callIt("mac.date_hint"),
                     text: $shop.pnlRange.from)
            DayField(title: words.callIt("rb.to"), hint: words.callIt("mac.date_hint"),
                     text: $shop.pnlRange.to)
            if shop.pnlRange.resolve() == .invalid {
                Text(words.callIt("pnl.custom_invalid"))
                    .font(.caption).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metric.screen)
        .padding(.bottom, 8)
    }
}

/// What the shop owes the authority for the period: the tax on its sales, the
/// tax it paid on its purchases, and the difference.
///
/// `lib/vat-summary.js` sums the P&L's own rows, so this and the table beside
/// it are one answer. Drawn only for a shop with a tax set; a summary of three
/// zeros reads like a filed return.
struct VatSummaryCard: View {
    let shop: Shop
    let vat: VatSummary
    let period: String

    var body: some View {
        let words = shop.words
        DetailSection(words.callIt("pnl.vat_title") + " · " + period) {
            VStack(alignment: .leading, spacing: 6) {
                DetailLine(words.callIt("pnl.vat_sales"), Money.text(vat.sales, shop.currency), dim: true)
                LayerRule()
                DetailLine(words.callIt("pnl.vat_output"), Money.text(vat.output, shop.currency))
                // Paid, and coming off what is owed: signed as a cost, as
                // every line that comes off a figure on this page is.
                DetailLine(words.callIt("pnl.vat_input"), Money.cost(vat.input, shop.currency))
                DetailLine(words.callIt(vat.net < 0 ? "pnl.vat_refund" : "pnl.vat_net"),
                           Money.text(abs(vat.net), shop.currency), strong: true,
                           tint: vat.net < 0 ? Khayt.done : nil)
                // How revenue relates to the tax — mode-aware, because an
                // inclusive shop's revenue had it taken out and an exclusive
                // shop's never held it.
                Text(words.callIt(vat.mode == "exclusive" ? "pnl.vat_exclusive" : "pnl.vat_inclusive"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Input VAT is only what the expenses RECORDED. Said, so a low
                // figure is not mistaken for the rule getting it wrong.
                if vat.expensesWithoutVat > 0 {
                    Text(words.callIt("pnl.vat_missing", ["n": .number(Double(vat.expensesWithoutVat))]))
                        .font(.caption).foregroundStyle(Khayt.attention)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .card()
        }
    }
}
