import SwiftUI
import KhaytCore

/// Settings › Online: whether this shop's orders show in a customer's portal
/// beside other Khayt shops' (`CloudPortalSettings`). On by default. Read-only
/// for anyone who is not the owner or a manager, as the payment link is.
/// Saved the moment it changes, and put back if the cloud refuses.
struct PortalCrossShopSetting: View {
    let shop: Shop

    @State private var on = true
    @State private var loaded = false
    @State private var busy = false
    @State private var problem: String?

    private var mayWrite: Bool { shop.cloudCanManageEmbed }

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { on }, set: { wanted in Task { await save(wanted) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(shop.words.callIt("mac.portal_cross_shop"))
                    Text(shop.words.callIt("mac.portal_cross_shop_hint"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!loaded || !mayWrite || busy)
            if !mayWrite && loaded {
                Text(shop.words.callIt("mac.paylink_role")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let (c, t) = await shop.vaultSession() else { return }
        do {
            on = try await CloudPortalSettings.get(c, token: t, fetch: Shop.plansFetch).crossShop
            problem = nil
            loaded = true
        } catch {
            problem = said(error)
        }
    }

    private func save(_ wanted: Bool) async {
        guard mayWrite, let (c, t) = await shop.vaultSession() else { return }
        let was = on
        on = wanted
        busy = true; defer { busy = false }
        do {
            on = try await CloudPortalSettings.put(crossShop: wanted, c, token: t, fetch: Shop.plansFetch).crossShop
            problem = nil
        } catch {
            on = was
            problem = said(error)
        }
    }

    private func said(_ error: Error) -> String {
        if let r = error as? CloudPortalSettings.Refusal {
            if r.reason == "role" { return shop.words.callIt("mac.paylink_role") }
            if !r.error.isEmpty { return r.error }
        }
        return ErrorText.plain(error)
    }
}
