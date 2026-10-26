import AppKit
import SwiftUI
import KhaytCore

/// ── A VAULT OVER ITS PLAN, ON THE SAMPLE ─────────────────────────────────
///
/// `KHAYT_SNAPSHOT_VAULTLAPSE=1`: the plan pane, the library's banner and the
/// Links, Products and Share sheets in three states — not over (nothing
/// shown), read-only with no date yet, and deleting with a date — in whichever
/// appearance and language this run was started in.
///
/// ALL IN MEMORY. The plan pane is handed a catalogue and a billing answer
/// written here, the sheets are handed no links and no products, and the
/// lapse is put on the shop directly. Nothing asks the cloud, nothing is
/// written, and the shop's lapse is cleared at the end.
extension Snapshot {

    static func captureVaultLapse(_ shop: Shop, into dir: URL, dark: Bool) async {
        let tag = (dark ? "-dark" : "-light") + "-" + shop.words.language
        await shop.load(.sample)
        shop.pretendsWritable = true
        defer {
            shop.pretendsWritable = false; shop.pretendsOwner = false
            shop.vaultLapse = nil; shop.vaultLapseAsked = nil; shop.vaultOnlyIds = []
        }
        await settle()

        let rtl = Direction.rtlLanguages.contains(shop.words.language)
        func shot(_ name: String, width: CGFloat, _ view: some View) {
            captureView(named: "lapse-\(name)\(tag)",
                        view.frame(width: width, alignment: .topLeading)
                            .background(dark ? Color(white: 0.16) : Khayt.ground)
                            .environment(\.colorScheme, dark ? .dark : .light)
                            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                            // The sheets' content sits in a ScrollView, which a
                            // photograph cannot see into (`photographFlat`).
                            .environment(\.photographFlat, true)
                            .modifier(ShopsLocale(words: shop.words)),
                        into: dir)
        }

        // The deletion date 90 days from today's noon, so the count is the
        // same whenever the run happens.
        let noon = Calendar.book.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
        let end = Calendar.book.date(byAdding: .day, value: 90, to: noon) ?? noon
        let iso = { (d: Date) in Date.ISO8601FormatStyle().format(d) }
        let scenes: [(String, CloudPlans.Lapse)] = [
            ("1-not-over", .notOver),
            ("2-read-only", CloudPlans.Lapse(over: true, overBytes: 12_400_000_000, readOnlySince: nil,
                                             deleteAfter: nil, deleting: false)),
            ("3-deleting", CloudPlans.Lapse(over: true, overBytes: 12_400_000_000, readOnlySince: iso(noon),
                                            deleteAfter: iso(end), deleting: true)),
        ]
        for (name, lapse) in scenes {
            shop.vaultLapse = lapse
            shop.vaultLapseAsked = Date()   // no refresh: the sample has no cloud to ask
            // Three sample models moved online by Free Up Space: the warning
            // and "Bring back 3 models …" (beta.8). The sample has no library
            // folder, so nothing recounts them away.
            shop.vaultOnlyIds = lapse.over ? ["PF-sample-falcon", "PF-sample-vase", "PF-sample-dallah"] : []
            await settle()
            shot("\(name)-plan", width: 560,
                 CloudPlanSettings(shop: shop, shown: planState(lapse), flat: true).padding(18))
            // The owner's pane: the same, with the Upgrade to the plan that fits.
            shop.pretendsOwner = true
            shot("\(name)-plan-owner", width: 560,
                 CloudPlanSettings(shop: shop, shown: planState(lapse), flat: true).padding(18))
            shop.pretendsOwner = false
            // Not over, the banner draws nothing at all: an empty picture.
            shot("\(name)-banner", width: 820, VaultLapseBanner(shop: shop, always: true).frame(minHeight: 8))
            shot("\(name)-links", width: SheetMetrics.outerWidth(560), VaultLinksSheet(shop: shop, preloaded: []))
            shot("\(name)-products", width: SheetMetrics.outerWidth(600), VaultProductsSheet(shop: shop, shown: []))
            shot("\(name)-share", width: SheetMetrics.outerWidth(440),
                 VaultShareSheet(shop: shop, request: VaultShareRequest(recordIds: ["PF-sample-falcon"],
                                                                        titles: ["Falcon hood"])))
        }
    }

    /// Free, after a move down from Maker: the catalogue the live cloud
    /// answered on 2026-10-24, and billing/me with this scene's lapse.
    static func planState(_ lapse: CloudPlans.Lapse) -> Shop.CloudPlanState {
        let catalogue = try? JSONDecoder().decode(CloudPlans.Catalogue.self, from: Data("""
        {"plans":[
         {"name":"free","label":"Free","priceSar":0,"period":"month","limits":{"maxVaultBytes":2000000000,"maxActiveLinks":0}},
         {"name":"maker","label":"Maker","priceSar":25,"priceUsd":7,"period":"month","limits":{"maxVaultBytes":150000000000,"maxActiveLinks":50,"maxSeats":3}},
         {"name":"creator","label":"Creator","priceSar":65,"period":"month","limits":{"maxVaultBytes":400000000000,"maxActiveLinks":200,"publishing":true}}],
         "defaultPlan":"free","pricesInclusive":true,"beta":{"freeUpgrades":true,"endsAt":null,"graceDays":30}}
        """.utf8))
        let lapseJSON = (try? JSONEncoder().encode(lapse)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
        let mine = try? JSONDecoder().decode(CloudPlans.Mine.self, from: Data("""
        {"billingEnabled":true,"plan":"free","label":"Free","status":"active","active":true,"lapse":\(lapseJSON)}
        """.utf8))
        return Shop.CloudPlanState(catalogue: catalogue, mine: mine, problem: nil)
    }
}
