import SwiftUI

/// Narrowing the gift cards.
///
/// ── WHERE THE STATE WENT ──────────────────────────────────────────────────
///
/// This screen used to carry a Status column: Active · Used · Expired, as a
/// coloured word. §4 has ruled that out — *"a chip is earned only when nothing
/// else in the row states the fact"* — and here three other things state it:
/// the balance column, the expires column, and the 55% treatment §6 gives a
/// closed row. A fourth statement of a fact stated three times costs three
/// silhouettes from a set kept scarce on purpose.
///
/// The three words are not deleted, though: they are *how a shop asks*. They
/// live here as filter chips and in each row's accessibility label, which is
/// what the design asked for and is also the only place a screen reader can
/// hear the state now that the column is gone.
struct GiftCardFilterBar: View {
    @Bindable var shop: Shop

    private var chips: [FilterChipModel] {
        // In the order a shop asks them: the cards it can still spend, the
        // ones it cannot, and then the reason it cannot.
        [("active", "gcActive"), ("used", "gcUsed"), ("expired", "gcExpired")]
            .compactMap { state, key in
                let n = shop.giftCards.filter { shop.giftCardStatuses[$0.id] ?? "active" == state }.count
                // A chip that would find nothing is never offered — the rule
                // `FilterBar` is built around.
                guard n > 0 || shop.giftCardState == state else { return nil }
                return FilterChipModel(id: state, label: shop.words.callIt(key),
                                       count: n, on: shop.giftCardState == state) {
                    shop.giftCardState = shop.giftCardState == state ? nil : state
                }
            }
    }

    var body: some View {
        FilterBar(chips: chips,
                  showingClear: shop.giftCardState != nil,
                  clearLabel: shop.words.callIt("log.clear_filters")) {
            shop.giftCardState = nil
        }
    }
}
