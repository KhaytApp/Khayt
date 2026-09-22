import SwiftUI
import KhaytCore

/// The orders a storefront has already sent, and what the shelf can answer.
///
/// The Integrations screen has always handed a shop the address to paste into
/// Shopify, Salla, Zid, WooCommerce, Etsy or Medusa. The orders those send
/// arrive in Khayt Cloud's intake queue and this app never asked for one — so
/// the Mac could tell a storefront where to post its orders and could not show
/// the shop a single one that had.
///
/// It is on the catalogue because that is where the shelf is. The question an
/// online order raises — *do I already have this made?* — is the catalogue's
/// question, and the answer is in the row above.
struct OnlineOrdersSheet: View {
    @Bindable var shop: Shop
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetFrame(width: 520) {
            VStack(alignment: .leading, spacing: 4) {
                Text(shop.words.callIt("mac.online_orders")).font(.headline)
                Text(shop.words.callIt("mac.online_orders_hint"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let problem = shop.onlineProblem {
                Text(problem).font(.caption).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if shop.onlineBusy && shop.onlineOrders.isEmpty {
                ProgressView().controlSize(.small)
            } else if shop.onlineOrders.isEmpty {
                // The empty state a shop sees most days, and the one nobody
                // designs: nothing is wrong, the storefront simply has not
                // sent anything since the last look.
                Text(shop.words.callIt("mac.online_none"))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(shop.onlineOrders) { order in
                    OnlineOrderCard(shop: shop, order: order)
                    if order.id != shop.onlineOrders.last?.id { Divider() }
                }
            }
        } footer: {
            HStack {
                Button(shop.words.callIt("mac.online_refresh")) {
                    Task { await shop.readOnlineOrders() }
                }
                .disabled(shop.onlineBusy)
                Spacer()
                Button(shop.words.callIt("common.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .task { await shop.readOnlineOrders() }
    }
}

/// One incoming order, read against the shelf.
private struct OnlineOrderCard: View {
    @Bindable var shop: Shop
    let order: Shop.OnlineOrder

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(order.title).font(.body.weight(.medium)).lineLimit(1)
                Spacer()
                // ONLY WHEN THE TITLE DOES NOT ALREADY SAY IT. khayt-cloud
                // titles a storefront order "Salla order — SL-2291", so the
                // chip printed the word Salla a second time on every row; a
                // hand-typed customer request has no platform in its title and
                // still needs one.
                if let chip = platformChip {
                    Text(chip).font(.caption).foregroundStyle(.tertiary)
                }
            }
            if !order.customer.isEmpty {
                Text(order.customer).font(.caption).foregroundStyle(.secondary)
            }

            // ── LINE BY LINE, BECAUSE THAT IS THE DECISION ───────────────
            //
            // A summary ("2 from stock") hides the only thing worth checking:
            // WHICH line came off WHICH shelf, and which line this app could
            // not place at all. An unplaced line is shown as unplaced rather
            // than folded into the total, because a deduction is invisible
            // once made — the number it leaves looks exactly like a number
            // somebody counted.
            ForEach(order.lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // ISOLATED, because `×` is a neutral character and a
                    // digit is a weak one: in an Arabic paragraph the pair
                    // reorders and the quantity reads back to front. The same
                    // bidi rule that drew `+966 50…` as `…05 669+`.
                    Text(Figure.isolated("\(line.qty)×")).font(TypeScale.figure(11))
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, alignment: .trailing)
                    Text(line.name).font(.callout).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(reading(line)).font(.caption)
                        .foregroundStyle(line.unmatched ? Khayt.attention : .secondary)
                }
            }

            // ── THE BUTTON IS IN THE FLOW, NOT OVER IT ───────────────────
            //
            // Laid as an overlay on the card's bottom-trailing corner, it was
            // drawn straight THROUGH the last line's reading: "Record the
            // sale" and "2 off the shelf" on the same pixels, both unreadable.
            // Nothing in the source says so — it took the photograph.
            HStack {
                Spacer()
                record
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 6)
    }

    /// The platform's name, when the title has not already said it.
    private var platformChip: String? {
        guard !order.source.isEmpty else { return nil }
        let name = order.source.capitalized
        return order.title.localizedCaseInsensitiveContains(name) ? nil : name
    }

    /// What this line does to the shelf, in words.
    private func reading(_ line: Shop.OnlineOrder.Line) -> String {
        if line.unmatched { return shop.words.callIt("mac.online_unmatched") }
        if line.toPrint == 0 {
            return shop.words.callIt("mac.online_off_shelf",
                                     ["n": .number(Double(line.fromShelf))])
        }
        if line.fromShelf == 0 { return shop.words.callIt("mac.online_to_print") }
        return shop.words.callIt("mac.online_part",
                                 ["shelf": .number(Double(line.fromShelf)),
                                  "print": .number(Double(line.toPrint))])
    }

    /// One button, and its WORDS change with what the order turns out to be.
    ///
    /// An order the shelf answers in full is a sale that is already finished;
    /// one with printing left in it goes into the queue. Calling both "Import"
    /// would leave a shop to work out which happened by looking afterwards.
    @ViewBuilder private var record: some View {
        Button(order.allFromShelf
               ? shop.words.callIt("mac.online_record_sale")
               : shop.words.callIt("mac.online_add_to_queue")) {
            Task { await shop.recordOnlineOrder(order) }
        }
        .disabled(shop.onlineBusy || !shop.canMoveJobs)
        .controlSize(.small)
    }
}
