import SwiftUI

/// "Paired phones" under Settings › Phones & Wi-Fi (signed frame 268:7): each
/// phone's name, how it was paired, when it was last seen, and its role.
/// Read-only, for the owner's phone, on the shop's Wi-Fi. Nothing is drawn
/// until the Mac has answered, signed.
struct PairedPhonesSection: View {
    @EnvironmentObject private var api: KhaytAPIClient
    @EnvironmentObject private var settings: ConnectionSettings
    @EnvironmentObject private var health: ConnectionHealth
    @State private var phones: [PairedPhone]?

    var body: some View {
        Group {
            if let phones, !phones.isEmpty {
                SettingsPieces.eyebrow(L10n.tr("owner.phones.title"))
                VStack(spacing: 0) {
                    ForEach(Array(phones.enumerated()), id: \.element.id) { index, phone in
                        OwnerRow(title: title(phone), sub: OwnerViews.detail(phone), value: OwnerViews.roleWords(phone.role),
                                 last: index == phones.count - 1)
                    }
                }
                .card()
                SettingsPieces.foot(L10n.tr("owner.phones.foot"))
            }
        }
        .task(id: health.macInReach) {
            guard OwnerViews.asks(role: settings.effectiveRole, macInReach: health.macInReach, sampleShop: settings.isSampleShop)
            else { phones = nil; return }
            phones = await api.pairedPhones()
        }
    }

    private func title(_ phone: PairedPhone) -> String {
        let name = (phone.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = name.isEmpty ? L10n.tr("owner.phones.unnamed") : name
        return phone.isSelf ? L10n.format("owner.phones.this", shown) : shown
    }
}

/// "Prices in the slicer" under Settings › Connectors (signed frame 268:28):
/// the shop's switch, and each paired slicer as "May see prices" or "Prices
/// hidden". Read-only, for the owner's phone.
struct SlicerPricesSection: View {
    @EnvironmentObject private var api: KhaytAPIClient
    @EnvironmentObject private var settings: ConnectionSettings
    @EnvironmentObject private var health: ConnectionHealth
    @State private var prices: SlicerPrices?

    var body: some View {
        Group {
            if let prices {
                SettingsPieces.eyebrow(L10n.tr("owner.prices.title"))
                VStack(spacing: 0) {
                    OwnerRow(title: L10n.tr("owner.prices.switch"), sub: L10n.tr("owner.prices.switch.sub"),
                             value: L10n.tr(prices.shown ? "state.on" : "state.off"), last: prices.slicers.isEmpty)
                    ForEach(Array(prices.slicers.enumerated()), id: \.element.id) { index, slicer in
                        OwnerRow(title: name(slicer), sub: L10n.tr(slicer.priceGrant ? "owner.prices.may" : "owner.prices.hidden"),
                                 value: L10n.tr(slicer.priceGrant ? "owner.prices.allowed" : "owner.prices.not_allowed"),
                                 last: index == prices.slicers.count - 1)
                    }
                }
                .card()
                SettingsPieces.foot(L10n.tr("owner.prices.foot"))
            }
        }
        .task(id: health.macInReach) {
            guard OwnerViews.asks(role: settings.effectiveRole, macInReach: health.macInReach, sampleShop: settings.isSampleShop)
            else { prices = nil; return }
            prices = await api.slicerPrices()
        }
    }

    private func name(_ slicer: SlicerPrices.Slicer) -> String {
        let name = (slicer.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? L10n.tr("owner.prices.unnamed") : name
    }
}

/// One line of either list: a title, a quieter line under it, and a value.
private struct OwnerRow: View {
    let title: String
    let sub: String
    let value: String
    let last: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.khayt(14.5, relativeTo: .subheadline))
                    .foregroundStyle(KhaytDesign.ink)
                if !sub.isEmpty {
                    Text(sub)
                        .font(.khayt(12, relativeTo: .caption))
                        .foregroundStyle(KhaytDesign.note)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Text(value)
                .font(.khayt(13, .semibold, relativeTo: .footnote))
                .foregroundStyle(KhaytDesign.note)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
        }
        .accessibilityElement(children: .combine)
    }
}
