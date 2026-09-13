import SwiftUI
import KhaytCore

/// Storefronts and payment systems, for the market the shop sells in.
///
/// ── WHAT A MAC-ONLY SHOP COULD NOT DO ─────────────────────────────────────
///
/// Connect a store at all. Khayt's cloud serves an import route per platform —
/// paste it into Salla or Shopify as an order webhook and new orders arrive in
/// Order requests — and a feed route that publishes the catalogue back. Both
/// URLs were built and shown only by `renderer/settings.js`, so a shop keeping
/// its book on this app had the cloud, had the shop id, and had no way to find
/// out what to paste.
///
/// ── AND WHY THE LIST IS CURATED RATHER THAN COMPLETE ──────────────────────
///
/// `lib/integrations-registry.js` holds a handful of storefronts and payment
/// systems per market. Not every platform in the world: the ones a shop in that
/// market is actually likely to be on. A Riyadh shop is shown Salla, Zid and
/// Mada rather than a scroll of two hundred entries it has to search, and the
/// market can still be switched — a shop selling into two of them exists, which
/// is exactly why saving must not switch the other one off.
struct IntegrationsPane: View {
    let shop: Shop

    /// The provider settings as the directory edits them.
    struct Draft: Equatable {
        /// Provider id → (on, the shop's own pay link).
        var providers: [String: PayProvider] = [:]

        struct PayProvider: Equatable {
            var enabled = false
            var payLink = ""
        }

        @MainActor static func read(_ settings: [String: JSONValue]) -> Draft {
            guard case .object(let map)? = settings["paymentProviders"] else { return Draft() }
            var out: [String: PayProvider] = [:]
            for (id, value) in map {
                guard case .object(let cfg) = value else { continue }
                out[id] = PayProvider(enabled: Shop.plainBool(cfg["enabled"]) ?? false,
                                      payLink: Shop.plainString(cfg["payLink"]) ?? "")
            }
            return Draft(providers: out)
        }

        /// EVERY provider, not the ones on screen.
        ///
        /// The directory shows one market at a time, and a shop selling into two
        /// has providers configured outside the visible list. Sending only what
        /// is drawn would look like a complete answer to the merge in
        /// `settings-edit.js` — which is why that merge keeps what it holds, and
        /// why this sends the whole map rather than relying on it to.
        func form() -> [String: JSONValue] {
            var map: [String: JSONValue] = [:]
            for (id, p) in providers {
                map[id] = .object(["enabled": .bool(p.enabled), "payLink": .string(p.payLink)])
            }
            return ["paymentProviders": .object(map)]
        }
    }

    @State private var draft = Draft()
    @State private var original = Draft()
    @State private var market: String?
    @State private var markets: [KhaytEngine.MarketChoice] = []
    @State private var showing: KhaytEngine.IntegrationMarket?
    @State private var copied: String?

    /// The market being looked at: the shop's own language until it picks one.
    private var viewing: String { market ?? shop.words.language }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker(shop.words.callIt("integ.market"),
                           selection: Binding(get: { viewing }, set: { market = $0 })) {
                        ForEach(markets) { Text($0.title).tag($0.id) }
                    }
                }

                Section(shop.words.callIt("integ.storefronts")) {
                    if !shop.cloudConnected {
                        // The links are cloud routes and there is nothing to
                        // build one from. Said once, here, rather than as a
                        // disabled button on every row.
                        Text(shop.words.callIt("integ.cloud_hint"))
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(showing?.storefronts ?? []) { store in
                        StorefrontRow(shop: shop, store: store, copied: $copied)
                    }
                }

                Section(shop.words.callIt("integ.payments")) {
                    ForEach(showing?.payments ?? []) { system in
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(system.name, isOn: enabled(system.id))
                            // The shop's own link, with {amount} put in by the
                            // invoice. Only worth asking for once the provider
                            // is on — an address for a service nobody uses is a
                            // field that can only be wrong.
                            if draft.providers[system.id]?.enabled == true {
                                TextField(shop.words.callIt("integ.pay_link_ph"),
                                          text: payLink(system.id))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.callout)
                            }
                        }
                    }
                }

                if let copied {
                    Section { Text(copied).font(.callout).foregroundStyle(Khayt.done) }
                }
            }
            .formStyle(.grouped)
            SaveBar(shop: shop, dirty: draft != original,
                    save: { Task { await shop.saveSettings(draft.form()); reset() } },
                    revert: { draft = original })
        }
        .task(id: shop.settingsValue) { reset() }
        .task(id: shop.words.language) {
            markets = (try? await shop.engine?.integrationMarkets(in: shop.words.language)) ?? []
        }
        .task(id: viewing) {
            showing = try? await shop.engine?.integrationMarket(viewing)
        }
    }

    private func reset() { original = .read(shop.settingsDict); draft = original }

    private func enabled(_ id: String) -> Binding<Bool> {
        Binding(
            get: { draft.providers[id]?.enabled ?? false },
            set: { on in
                var p = draft.providers[id] ?? Draft.PayProvider()
                p.enabled = on
                draft.providers[id] = p
            }
        )
    }

    private func payLink(_ id: String) -> Binding<String> {
        Binding(
            get: { draft.providers[id]?.payLink ?? "" },
            set: { link in
                var p = draft.providers[id] ?? Draft.PayProvider()
                p.payLink = link
                draft.providers[id] = p
            }
        )
    }
}

/// One storefront, and what the shop can take away from it.
private struct StorefrontRow: View {
    let shop: Shop
    let store: KhaytEngine.Storefront
    @Binding var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(store.name).font(.body.weight(.medium))
                Spacer()
                Text(directions).font(.caption).foregroundStyle(.secondary)
            }
            if shop.cloudConnected {
                HStack(spacing: 8) {
                    if store.importsOrders {
                        Button(shop.words.callIt("integ.copy_import")) {
                            Task { await copyLink(feed: false) }
                        }
                    }
                    if store.publishesCatalogue {
                        Button(shop.words.callIt("integ.copy_feed")) {
                            Task { await copyLink(feed: true) }
                        }
                    }
                    // A platform with no webhook UI needs the CODE as well as
                    // the URL. Handing it only a link is handing it a URL with
                    // nowhere to paste it.
                    if store.needsSubscriberCode {
                        Button(shop.words.callIt("integ.copy_subscriber")) {
                            Task { await copySubscriber() }
                        }
                    }
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        }
        .padding(.vertical, 2)
    }

    private var directions: String {
        store.dir.map {
            $0 == "in" ? shop.words.callIt("integ.import")
                       : shop.words.callIt("integ.publish")
        }.joined(separator: " · ")
    }

    private func copyLink(feed: Bool) async {
        guard let engine, let cloud = shop.cloudAddress else { return }
        let url = feed
            ? try? await engine.storefrontFeedURL(cloud: cloud.url, shopId: cloud.shopId, platform: store.id)
            : try? await engine.storefrontImportURL(cloud: cloud.url, shopId: cloud.shopId, platform: store.id)
        guard let url else { return }
        put(url)
        copied = feed
            ? shop.words.callIt("integ.feed_copied")
            : shop.words.callIt("integ.import_copied")
    }

    private func copySubscriber() async {
        guard let engine, let cloud = shop.cloudAddress,
              let url = try? await engine.storefrontImportURL(
                cloud: cloud.url, shopId: cloud.shopId, platform: store.id),
              let source = try? await engine.medusaSubscriber(importURL: url) else { return }
        put(source)
        // The shared string already names the file and where it goes —
        // `medusaSubscriberPath()` is there for a caller that needs the path
        // itself, and repeating it here would be the same sentence twice.
        copied = shop.words.callIt("integ.subscriber_copied")
    }

    private var engine: KhaytEngine? { shop.engine }

    private func put(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
