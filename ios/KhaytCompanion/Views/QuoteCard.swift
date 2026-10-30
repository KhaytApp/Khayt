import SwiftUI

/// One quote on the Orders tab's Quotes list: the job, who it is for, what it
/// was priced at, and how long the price stands.
///
/// A sibling of `JobCard`'s `.full` layout rather than a mode of it. A quote
/// has no next stage to swipe it into — the customer's answer is what moves
/// it, and that is given on its page, with a confirmation for a no — and the
/// facts it needs are a price and a last day, which a job's card has neither of.
struct QuoteCard: View {
    let quote: OrderLogEntry
    var currency: String? = nil
    let onOpen: () -> Void

    private var tone: Color { KhaytDesign.statusColor(for: quote.status) }
    private var expired: Bool { quote.isQuoteExpired() }

    /// "Acme · Made 28 Oct": who it is for, then when it was priced.
    var subtitle: String {
        var parts = [quote.displayClient]
        if let made = DueDateParser.display(quote.date) { parts.append(L10n.format("quote.made_on", made)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text(quote.displayTitle)
                        .font(.khayt(15, .medium, relativeTo: .body))
                        .foregroundStyle(KhaytDesign.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("#\(quote.id)")
                        .font(.khayt(12, .medium, relativeTo: .caption).monospacedDigit())
                        .foregroundStyle(KhaytDesign.note)
                        .lineLimit(1)
                        .environment(\.layoutDirection, .leftToRight)
                }
                Text(subtitle)
                    .font(.khayt(12.5, relativeTo: .footnote))
                    .foregroundStyle(KhaytDesign.note)
                    .lineLimit(1)
                HStack(spacing: 7) {
                    Text(L10n.tr("stage.short.quote"))
                        .font(.khayt(11, .semibold, relativeTo: .caption2))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .foregroundStyle(tone)
                        .background(tone.opacity(0.14), in: Capsule())
                    if expired {
                        Text(L10n.tr("quote.expired"))
                            .font(.khayt(10.5, .bold, relativeTo: .caption2))
                            .tracking(0.6)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .foregroundStyle(KhaytDesign.late)
                            .background(KhaytDesign.late.opacity(0.14), in: Capsule())
                    } else if let last = DueDateParser.display(quote.quoteExpiresAt) {
                        Text(L10n.format("quote.valid_until", last))
                            .font(.khayt(12, relativeTo: .caption))
                            .foregroundStyle(KhaytDesign.note)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let price = quote.price {
                        Text(Money.text(price, currency))
                            .font(.khayt(14, .semibold, relativeTo: .subheadline).monospacedDigit())
                            .foregroundStyle(KhaytDesign.ink)
                            .lineLimit(1)
                    }
                }
                .padding(.top, 2)
            }
            .padding(.vertical, 12).padding(.leading, 16).padding(.trailing, 13)
            .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
            .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
    }
}
