import SwiftUI
import KhaytCore

/// A card the shop sold, and what is left on it.
///
/// The money on one belongs to the CUSTOMER, which is what makes this different
/// from the rest of the book: a figure the shop gets wrong in its own favour is
/// a figure the customer cannot check. Everything that decides anything here is
/// `lib/gift-card.js`, shared with the app next door.
struct GiftCard: Identifiable, Decodable, Hashable, Sendable {
    let id: String
    let code: String
    let balance: Double?
    let initialBalance: Double?
    /// The client's id, when it was issued to somebody on the books.
    let issuedTo: String?
    /// The name as it was at the time, for a card issued to a walk-in.
    let issuedToName: String?
    let issuedAt: String?
    let expiresAt: String?
}

/// The cards, and the one button that makes another.
struct GiftCards: View {
    @Bindable var shop: Shop

    private var shown: [GiftCard] {
        let term = shop.search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return shop.giftCards }
        return shop.giftCards.filter {
            guard shop.giftCardState == nil
                    || shop.giftCardStatuses[$0.id] ?? "active" == shop.giftCardState else { return false }
            guard !term.isEmpty else { return true }
            return $0.code.lowercased().contains(term)
                || (holder($0) ?? "").lowercased().contains(term)
        }
    }

    /// What this card's state is called, for the filter and for VoiceOver.
    private func state(_ card: GiftCard) -> String {
        shop.giftCardStatuses[card.id] ?? "active"
    }

    private func stateWord(_ card: GiftCard) -> String {
        switch state(card) {
        case "expired": shop.words.callIt("gcExpired")
        case "used":    shop.words.callIt("gcUsed")
        default:        shop.words.callIt("gcActive")
        }
    }

    /// A card that cannot be spent again. §6's fifth row state: 55% opacity,
    /// which is the app's word for "this is settled, and it is not gone".
    private func closed(_ card: GiftCard) -> Bool { state(card) != "active" }

    /// Who it was issued to: the client if they are still on the books, the
    /// name written down at the time if not, and a dash for a card sold across
    /// the counter to nobody in particular.
    private func holder(_ card: GiftCard) -> String? {
        if let id = card.issuedTo, let client = shop.clients.first(where: { $0.id == id }) {
            return shop.clientNames[client.id]?.name ?? client.id
        }
        let written = card.issuedToName ?? ""
        return written.isEmpty ? nil : written
    }

    var body: some View {
        Group {
            if shop.giftCards.isEmpty {
                EmptyHere(title: shop.words.callIt("giftCardEmpty"), mark: .giftCards) {
                    Button(shop.words.callIt("issueGiftCard")) { shop.issuingGiftCard = true }
                        .buttonStyle(.borderedProminent)
                }
            } else if shown.isEmpty {
                NothingMatched(shop: shop, mark: .giftCards)
            } else {
                VStack(spacing: 0) {
                GiftCardFilterBar(shop: shop)
                Table(shown) {
                    TableColumn(shop.words.callIt("giftCardCode")) { card in
                        Text(card.code).monospaced()
                            .opacity(closed(card) ? 0.55 : 1)
                            // THE ONLY PLACE THE STATE IS STILL SAID IN WORDS.
                            // With the chip gone, a sighted shop reads the
                            // state off the balance and the date; a screen
                            // reader has to be told, so the row says it.
                            .accessibilityLabel(Text(card.code + ", " + stateWord(card)))
                    }
                    .width(min: 100, ideal: 120)
                    TableColumn(shop.words.callIt("giftCardBalance")) { card in
                        // Both figures, because "120" alone does not say whether
                        // the card was small or is nearly spent.
                        //
                        // AND `closed` WHERE A SPENT CARD'S FIGURE WOULD BE.
                        // This is the column §4 points at when it says a gift
                        // card earns no state chip: "0.00 / 200.00" is a sum,
                        // and what the shop wants to know is that there is
                        // nothing left on it.
                        HStack(spacing: 4) {
                            if closed(card) {
                                Text(shop.words.callIt("mac.gc_closed"))
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text(Money.figure(card.balance ?? 0)).monospacedDigit()
                            }
                            Text("/").foregroundStyle(.tertiary)
                            Text(Money.text(card.initialBalance ?? 0, shop.currency))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        .opacity(closed(card) ? 0.55 : 1)
                    }
                    .width(min: 140, ideal: 180)
                    TableColumn(shop.words.callIt("giftCardIssuedTo")) { card in
                        Text(holder(card) ?? "—")
                            .foregroundStyle(holder(card) == nil ? .tertiary : .primary)
                            .opacity(closed(card) ? 0.55 : 1)
                    }
                    .width(min: 120, ideal: 200)
                    // "Expires", not "Expiry Date (optional)" — that string is
                    // the FORM's, and "(optional)" above a column of dates says
                    // nothing about the dates in it.
                    TableColumn(shop.words.callIt("giftCardExpires")) { card in
                        Text(card.expiresAt ?? "—").monospacedDigit()
                            .foregroundStyle(card.expiresAt == nil ? .tertiary : .secondary)
                            .opacity(closed(card) ? 0.55 : 1)
                    }
                    .width(min: 100, ideal: 130)
                }
                // As every other table in the app: the ground shows through.
                .scrollContentBackground(.hidden)
                }
            }
        }
        .background(Khayt.ground)
        .screenToolbar {
            ToolbarItem {
                Button {
                    shop.issuingGiftCard = true
                } label: {
                    Label(shop.words.callIt("issueGiftCard"), systemImage: "plus")
                }
                .help(shop.words.callIt("issueGiftCard"))
            }
        }
    }

}
