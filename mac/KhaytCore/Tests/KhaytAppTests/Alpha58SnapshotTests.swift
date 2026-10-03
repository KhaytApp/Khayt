import Foundation
import SwiftUI
import Testing
import KhaytCore
@testable import KhaytApp

/// Pictures of the screens alpha.58 added, so a review can SEE them.
///
/// The sync-loss review, the spool repair, the held web-store prices, the
/// free-up-space question, the missing-copy block, the LAN PIN note, the
/// went-backwards banner — each shipped with no photograph of it at all, which
/// is how a reviewer came to judge them from source. Light and dark here;
/// run once more with `KHAYT_LANG=ar` for the right-to-left set.
///
/// A confirmation dialog is an `NSAlert`, which `ImageRenderer` cannot host, so
/// the questions are drawn by `DialogPicture` from the SAME words the dialog
/// asks with — the wording is what a review of a question is for. Buttons come
/// out as `ImageRenderer`'s yellow placeholders, as everywhere in this harness.
@MainActor
struct Alpha58SnapshotTests {

    static func shop() async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        return shop
    }

    func both(_ view: some View, _ name: String, size: CGSize) throws {
        let lang = Direction.shopLanguage()
        let ground = view.background(Khayt.ground)
        try SnapshotTests().render(ground, "a58-\(name)-\(lang)-light", size: size)
        try SnapshotTests().renderDark(view, "a58-\(name)-\(lang)-dark", size: size)
    }

    static let losses: [SyncLoss] = [
        SyncLoss(kind: .replaced, collection: "clients", recordId: "C-1",
                 record: .object(["id": .string("C-1"), "name": .string("Nora Al-Harbi")]),
                 replacedBy: .object(["id": .string("C-1"), "name": .string("Nora")])),
        SyncLoss(kind: .removed, collection: "printLog", recordId: "J-204",
                 record: .object(["id": .string("J-204"), "project": .string("Saudi Kings — set of 7")]),
                 replacedBy: nil),
        SyncLoss(kind: .keptDeleted, collection: "inventory", recordId: "S-9",
                 record: .object(["id": .string("S-9"), "brand": .string("Bambu PLA Basic")]),
                 replacedBy: nil),
    ]

    @Test("the new screens of alpha.58, light and dark")
    func newScreens() async throws {
        guard SnapshotTests.outputDir != nil else { return }
        let shop = await Self.shop()
        let words = shop.words
        let width: CGFloat = 760

        // ── What sync took: the banner, and the review sheet ──────────────
        let notice = SyncLossNotice(files: [], losses: Self.losses)
        shop.spoolRepairPending = 3
        shop.syncLossNotice = notice
        shop.syncLossesPutBack = [Self.losses[0].id]
        try both(VStack(spacing: 0) {
            SyncLossBanner(shop: shop, lost: notice)
            WentBackwardsBanner(shop: shop, shown: (seen: 412, got: 37))
            SpoolRepairBanner(shop: shop, shown: true)
            PriceHoldBanner(shop: shop, shown: true)
        }.frame(width: width), "banners", size: CGSize(width: width, height: 200))
        try both(SyncLossesSheet(shop: shop).background(Khayt.surface), "sync-losses-sheet",
                 size: CGSize(width: SheetMetrics.outerWidth(560), height: 360))

        // ── The ✕'s question, and the went-backwards one ──────────────────
        try both(DialogPicture(title: words.callIt("mac.losses_dismiss_q"),
                               message: words.callIt("mac.losses_dismiss_body", ["n": .number(2)]),
                               confirm: words.callIt("mac.losses_dismiss"),
                               cancel: words.callIt("common.cancel")),
                 "ask-close-losses", size: CGSize(width: 360, height: 260))
        try both(DialogPicture(title: words.callIt("mac.cloud_accept_rollback_q"),
                               message: words.callIt("mac.cloud_accept_rollback_body"),
                               confirm: words.callIt("mac.cloud_accept_rollback"),
                               cancel: words.callIt("common.cancel")),
                 "ask-rollback", size: CGSize(width: 360, height: 240))

        // ── The spool repair: only the prices that move ───────────────────
        let changes = [
            Shop.SpoolRepairChange(id: "P1", name: "Saudi Kings — set of 7", was: .object([:]), now: [:],
                                   priceWas: 450, priceNow: 432.5),
            Shop.SpoolRepairChange(id: "P2", name: "Filament clip", was: .object([:]), now: [:],
                                   priceWas: 12, priceNow: 12),
            Shop.SpoolRepairChange(id: "P3", name: "Hexagon planter", was: .object([:]), now: [:],
                                   priceWas: 85, priceNow: 91),
        ]
        try both(VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(words.callIt("mac.spool_repair_title")).font(.headline)
                Text(words.callIt("mac.spool_repair_explain"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            Divider()
            ForEach(SpoolRepairSheet.repriced(changes)) { change in
                SpoolRepairSheet.row(change, currency: shop.currency).padding(.horizontal).padding(.vertical, 6)
                Divider()
            }
            SpoolRepairSheet.sameNote(changes, words: words)
            HStack {
                Spacer()
                Text(SpoolRepairSheet.applyLabel(changes, words: words))
                    .font(.callout.weight(.medium)).foregroundStyle(Khayt.brand)
            }
            .padding()
        }.frame(width: 520), "spool-repair", size: CGSize(width: 520, height: 330))

        // ── The web store's held prices ───────────────────────────────────
        let held = [
            WebStorePriceChange(id: "P1", name: "Saudi Kings — set of 7", was: "450", now: "432.5"),
            WebStorePriceChange(id: "P3", name: "Hexagon planter", was: "85", now: "91"),
            WebStorePriceChange(id: "P4", name: "Desk tidy", was: "", now: "40"),
        ]
        try both(VStack(alignment: .leading, spacing: 8) {
            Text(words.callIt("mac.ws_prices_held")).font(.headline)
            ForEach(held) { HeldPriceRow(shop: shop, change: $0) }
            Text(words.callIt("mac.ws_prices_held_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(16).frame(width: 600), "webstore-held", size: CGSize(width: 600, height: 200))

        // ── Free up space: the question before anything leaves ────────────
        try both(DialogPicture(
            title: words.callIt("mac.cloudlib_free_confirm_title", ["n": .number(14), "size": .string("2.3 GB")]),
            message: words.callIt("mac.cloudlib_free_confirm_body", [
                "where": .string("Google Drive"),
                "names": .string(CloudLibrary.firstNames(["Saudi Kings", "Hexagon planter", "Desk tidy",
                                                          "Filament clip", "Benchy"]) {
                    words.callIt("mac.cloudlib_and_more", ["n": .number(Double($0))])
                }),
            ]),
            confirm: words.callIt("mac.cloudlib_free_confirm"),
            cancel: words.callIt("common.cancel")),
                 "ask-free-up-space", size: CGSize(width: 380, height: 300))

        // ── A moved model the cloud no longer has ─────────────────────────
        shop.cloudMissing = [
            .init(id: "/lib/a.3mf", name: "Saudi Kings — King Abdulaziz", key: "k1", inTrash: true),
            .init(id: "/lib/b.3mf", name: "Hexagon planter", key: "k2", inTrash: false),
        ]
        try both(CloudMissingBlock(shop: shop).padding(16).frame(width: 560),
                 "cloud-missing", size: CGSize(width: 560, height: 140))

        // ── The LAN owner PIN, too short and not set ──────────────────────
        try both(VStack(alignment: .leading, spacing: 8) {
            LanPinNotes(words: words, tooShort: true, missing: false)
            LanPinNotes(words: words, tooShort: false, missing: true)
        }.padding(16).frame(width: 560), "lan-pin", size: CGSize(width: 560, height: 110))

        // ── A chosen group tile beside a chosen model: one look ───────────
        let model = try #require(shop.files.first)
        try both(HStack(alignment: .top, spacing: 16) {
            FolderCell(name: "Saudi Kings", count: 7, thumbnail: nil, words: words,
                       kind: .collection, selected: true).frame(width: 176)
            Cell(file: model, thumbnail: shop.thumbnail(for: model), selected: true, words: words)
                .frame(width: 176)
            FolderCell(name: "Luffy Card", count: 3, thumbnail: nil, words: words,
                       kind: .parts, selected: false).frame(width: 176)
        }.padding(16).frame(width: 620), "selected-tiles", size: CGSize(width: 620, height: 300))

        // ── The library's strip at 900 points: the decoration gives way ───
        shop.shelf = .library(nil)
        try both(ShellTitleBar(shop: shop, searchWanted: .constant(false)).frame(width: 900),
                 "strip-900", size: CGSize(width: 900, height: 60))
        try both(ShellTitleBar(shop: shop, searchWanted: .constant(false)).frame(width: 1440),
                 "strip-1440", size: CGSize(width: 1440, height: 60))

        shop.syncLossNotice = nil
        shop.cloudMissing = []
    }
}

/// A confirmation dialog's words, laid out the way the alert lays them out.
struct DialogPicture: View {
    let title: String
    let message: String
    let confirm: String
    let cancel: String

    var body: some View {
        VStack(spacing: 10) {
            Drawn(mark: .nozzle, size: 40).foregroundStyle(Khayt.brand)
            Text(title).font(.headline).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(message).font(.callout).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                Text(confirm).font(.callout.weight(.medium)).foregroundStyle(Khayt.attention)
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                Text(cancel).font(.callout)
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(.top, 4)
        }
        .padding(18)
        .frame(width: 300)
        .background(Khayt.surface, in: RoundedRectangle(cornerRadius: 12))
        .padding(20)
    }
}
