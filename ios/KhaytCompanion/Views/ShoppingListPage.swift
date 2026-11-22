import SwiftUI

/// The shopping list: every filament at or under its reorder point, grouped
/// by who sells it, with what is on the shelf and how much to buy — the Mac's
/// and the desktop's Shopping list, from the same rule (`ReorderRules`, the
/// shared `lib/reorder.js` ported and parity-tested). Share sends the text
/// the other apps copy. A planning aid: nothing here orders anything.
struct ShoppingListPage: View {
    @EnvironmentObject private var api: KhaytAPIClient
    @EnvironmentObject private var settings: ConnectionSettings
    @State private var list = ShopShoppingList()
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if loaded && list.isEmpty {
                    Text(L10n.tr("shop.none"))
                        .font(.khayt(14, relativeTo: .subheadline))
                        .foregroundStyle(KhaytDesign.note)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 44)
                } else {
                    ForEach(list.groups) { group in
                        section(group)
                    }
                    Text(L10n.tr("shop.hint"))
                        .font(.khayt(12, relativeTo: .caption))
                        .foregroundStyle(KhaytDesign.note)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 18)
        }
        .scrollIndicators(.hidden)
        .refreshable { load() }
        .khaytScreen(title: L10n.tr("shop.title"))
        .background(KhaytDesign.ground.ignoresSafeArea())
        .toolbar {
            if !list.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: list.text) {
                        Label(L10n.tr("shop.share"), systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .task { load() }
    }

    private func load() {
        list = api.shoppingList(shopName: settings.shopLabel) ?? ShopShoppingList()
        loaded = true
    }

    private func section(_ group: ReorderRules.Group) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(group.supplier.uppercased())
                .font(.khayt(10.5, .bold, relativeTo: .caption2))
                .khaytTracking(1.05)
                .foregroundStyle(KhaytDesign.note)
                .padding(.horizontal, 2)
            VStack(spacing: 0) {
                ForEach(Array(group.items.enumerated()), id: \.offset) { i, item in
                    if i > 0 { Divider().overlay(KhaytDesign.hairline) }
                    line(item)
                }
            }
            .padding(.horizontal, 16)
            .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(KhaytDesign.hairline, lineWidth: 1))
        }
    }

    private func line(_ item: ReorderRules.Item) -> some View {
        HStack(spacing: 12) {
            SpoolSwatch(hex: item.color, size: 26)
            Text(item.name)
                .font(.khayt(15, .semibold, relativeTo: .body))
                .foregroundStyle(KhaytDesign.ink)
                .lineLimit(2)
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(L10n.format("shop.buy", L10n.grams(Int(item.buy))))
                    .font(.khayt(14, .semibold, relativeTo: .subheadline).monospacedDigit())
                    .foregroundStyle(KhaytDesign.ink)
                Text(L10n.format("shop.have", L10n.grams(Int(item.have))))
                    .font(.khayt(12, relativeTo: .caption).monospacedDigit())
                    .foregroundStyle(KhaytDesign.attention)
            }
            .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

/// What a finished print drew from the wall, when a metering smart plug
/// measured enough of it (`JobEnergy`, the shared `lib/print-energy.js`
/// ported and parity-tested): the energy, and its cost at the job's tariff
/// when the job or the shop has one. Read-only; the computer writes it.
struct EnergyCard: View {
    let energy: JobEnergy

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.fill").foregroundStyle(KhaytDesign.brandV2)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.format("energy.used", Self.kWh(energy.kWh)))
                    .font(.khayt(14.5, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(KhaytDesign.ink)
                Text(L10n.tr("energy.sub"))
                    .font(.khayt(12, relativeTo: .caption))
                    .foregroundStyle(KhaytDesign.note)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if let cost = energy.cost {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Money.text(cost, energy.currency))
                        .font(.khayt(14.5, .semibold, relativeTo: .subheadline).monospacedDigit())
                        .foregroundStyle(KhaytDesign.ink)
                    Text(L10n.tr("energy.cost"))
                        .font(.khayt(12, relativeTo: .caption))
                        .foregroundStyle(KhaytDesign.note)
                }
                .multilineTextAlignment(.trailing)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityElement(children: .combine)
    }

    /// "0.42 kWh", Western digits in every language.
    static func kWh(_ v: Double) -> String {
        "\u{2068}" + v.formatted(.number.locale(L10n.locale).precision(.fractionLength(2)).grouping(.never))
            + " " + L10n.tr("unit.kwh") + "\u{2069}"
    }
}
