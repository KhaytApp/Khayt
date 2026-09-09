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
            $0.code.lowercased().contains(term) || (holder($0) ?? "").lowercased().contains(term)
        }
    }

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
                ContentUnavailableView.search(text: shop.search)
            } else {
                Table(shown) {
                    TableColumn(shop.words.callIt("giftCardCode")) { card in
                        Text(card.code).monospaced()
                    }
                    .width(min: 100, ideal: 120)
                    TableColumn(shop.words.callIt("giftCardBalance")) { card in
                        // Both figures, because "120" alone does not say whether
                        // the card was small or is nearly spent.
                        HStack(spacing: 4) {
                            Text(Money.figure(card.balance ?? 0)).monospacedDigit()
                            Text("/").foregroundStyle(.tertiary)
                            Text(Money.text(card.initialBalance ?? 0, shop.currency))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 140, ideal: 180)
                    TableColumn(shop.words.callIt("giftCardIssuedTo")) { card in
                        Text(holder(card) ?? "—").foregroundStyle(holder(card) == nil ? .tertiary : .primary)
                    }
                    .width(min: 120, ideal: 200)
                    // "Expires", not "Expiry Date (optional)" — that string is
                    // the FORM's, and "(optional)" above a column of dates says
                    // nothing about the dates in it.
                    TableColumn(shop.words.callIt("giftCardExpires")) { card in
                        Text(card.expiresAt ?? "—").monospacedDigit()
                            .foregroundStyle(card.expiresAt == nil ? .tertiary : .secondary)
                    }
                    .width(min: 100, ideal: 130)
                    TableColumn(shop.words.callIt("common.status")) { card in
                        Badge(state: shop.giftCardStatuses[card.id] ?? "active", shop: shop)
                    }
                    .width(min: 80, ideal: 100)
                }
                // As every other table in the app: the ground shows through.
                .scrollContentBackground(.hidden)
            }
        }
        .background(Khayt.ground)
        .toolbar {
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

    /// The word and the colour, both chosen by the state the RULE returned.
    struct Badge: View {
        let state: String
        let shop: Shop

        var body: some View {
            Text(word).font(.callout).foregroundStyle(tint)
        }

        private var word: String {
            switch state {
            case "expired": shop.words.callIt("gcExpired")
            case "used": shop.words.callIt("gcUsed")
            default: shop.words.callIt("gcActive")
            }
        }

        private var tint: Color {
            switch state {
            case "expired": Khayt.attention
            case "used": .secondary
            default: Khayt.done
            }
        }
    }
}
