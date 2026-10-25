import SwiftUI
import KhaytCore

/// A vault over its plan after a move down (khayt-cloud #143).
///
/// ── WHAT THE CLOUD DOES ───────────────────────────────────────────────────
///
/// Any move down that leaves the vault holding more than the new plan allows
/// makes it READ-ONLY: downloads and existing links keep working, but new
/// share links and product changes are refused with 402 `vault-over`. After
/// 90 days the files over the limit are deleted, in a fixed order — Trash,
/// old versions, files in no product, product files nobody has bought, and
/// files buyers hold last, the least recently changed first in each — until
/// the vault fits. Deleting, trashing, purging and pruning stay allowed: they
/// are how a shop gets back under.
///
/// The cloud says so in `lapse` on billing/me, vault/usage and the plan
/// move. Until it has set a deletion date (`deleting` false) the app says
/// "read-only" and NO date: a date it guessed would be a promise the cloud
/// never made.
extension Shop {

    /// What the vault lapse looks like right now, in the book's calendar.
    var vaultLapseDisplay: CloudPlans.Lapse.Display {
        vaultLapse?.display(now: Date(), calendar: .book) ?? .notOver
    }

    /// Keep the cloud's answer. A reply without `lapse` (an older cloud) is
    /// not over.
    func noteVaultLapse(_ lapse: CloudPlans.Lapse?) {
        vaultLapse = lapse ?? .notOver
        vaultLapseAsked = Date()
    }

    /// Ask vault/usage, at most every ten minutes unless `force`. Quiet on
    /// failure: the banner keeps what it last knew, and the action that
    /// matters still gets its own 402.
    func refreshVaultLapse(force: Bool = false) async {
        guard libraryOnVault || force, cloudDek != nil else { return }
        if !force, let at = vaultLapseAsked, Date().timeIntervalSince(at) < 600 { return }
        guard let (connection, token) = await vaultSession() else { return }
        let client = VaultClient(connection: connection, token: token, fetch: CloudLibrary.fetch)
        if let usage = try? await client.usage() { noteVaultLapse(usage.lapse) }
    }

    /// An action met 402 vault-over: the cloud is sure, even if this Mac had
    /// not heard. Says over at once and asks for the dates.
    func noteVaultOver(used: Int, limit: Int) {
        if vaultLapse?.over != true {
            vaultLapse = CloudPlans.Lapse(over: true, overBytes: max(0, used - limit), readOnlySince: nil,
                                          deleteAfter: nil, deleting: false)
        }
        Task { await refreshVaultLapse(force: true) }
    }

    // MARK: - The words

    /// The headline: over by how much, and since when when it is known.
    static func lapseHeadline(_ d: CloudPlans.Lapse.Display, _ words: Words) -> String? {
        switch d {
        case .notOver: return nil
        case .readOnly(let bytes, let since):
            return headline(bytes, since, words)
        case .deleting(let bytes, _, _, let since):
            return headline(bytes, since, words)
        }
    }

    private static func headline(_ bytes: Int, _ since: Date?, _ words: Words) -> String {
        // Isolated: a Latin size inside an Arabic sentence.
        let size = "\u{2068}" + Format.fileSize(Int64(bytes)) + "\u{2069}"
        if let since {
            return words.callIt("mac.lapse_over_since", ["size": .string(size), "date": .string(day(since, words))])
        }
        return words.callIt("mac.lapse_over", ["size": .string(size)])
    }

    /// The deletion date and the count, only when the cloud has set one.
    static func lapseDeadline(_ d: CloudPlans.Lapse.Display, _ words: Words) -> String? {
        guard case .deleting(_, let end, let days, _) = d else { return nil }
        let count = days == 0 ? words.callIt("mac.lapse_today") : words.counting(days, "mac.lapse_days")
        return words.callIt("mac.lapse_delete_on", ["date": .string(day(end, words)), "days": .string(count)])
    }

    static func day(_ date: Date, _ words: Words) -> String {
        "\u{2068}" + words.say(date, .dateTime.day().month(.wide).year()) + "\u{2069}"
    }
}

/// The lapse said in full: over by, since, the date when there is one, what
/// still works, and the order files go in. The plan pane and the vault's
/// sheets show this; the window's banner shows the first two lines.
struct VaultLapseNotice: View {
    let shop: Shop
    let display: CloudPlans.Lapse.Display
    enum Upgrade {
        /// Opens Settings › Online, where the plan is changed.
        case settings
        /// The plan pane's own move up.
        case action(() -> Void)
        /// Nothing to offer: not the owner, upgrades closed, or no bigger plan.
        case none
    }
    var upgrade: Upgrade = .settings
    var showsOrder = true

    private var words: Words { shop.words }

    var body: some View {
        if let head = Shop.lapseHeadline(display, words) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: deleting ? "exclamationmark.triangle.fill" : "lock.fill")
                    .foregroundStyle(Khayt.attention)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(head).font(.callout.weight(.semibold))
                    if let when = Shop.lapseDeadline(display, words) {
                        Text(when).font(.callout.weight(.medium)).foregroundStyle(Khayt.attention)
                    }
                    Text(words.callIt("mac.lapse_what")).font(.callout)
                    if showsOrder {
                        Text(words.callIt("mac.lapse_order")).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(words.callIt("mac.lapse_fix")).font(.caption).foregroundStyle(.secondary)
                    switch upgrade {
                    case .action(let act):
                        Button(words.callIt("mac.plan_upgrade") + "\u{2026}", action: act)
                            .controlSize(.small).padding(.top, 2)
                    case .settings:
                        SettingsLink { Text(words.callIt("mac.plan_upgrade") + "\u{2026}") }
                            .simultaneousGesture(TapGesture().onEnded { shop.settingsPane = .online })
                            .controlSize(.small).padding(.top, 2)
                    case .none:
                        EmptyView()
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Khayt.attention.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Khayt.attention.opacity(0.35)))
            .accessibilityElement(children: .contain)
        }
    }

    private var deleting: Bool { if case .deleting = display { true } else { false } }
}

/// Across the top of the library while the vault is over its plan — the
/// screen where Share by Private Link and Sell as a Product live.
struct VaultLapseBanner: View {
    let shop: Shop
    /// Drawn wherever it is put, for a photograph (which is on no screen).
    var always = false

    private var shown: Bool { always || (shop.showingLibrary && shop.libraryOnVault) }

    var body: some View {
        let d = shop.vaultLapseDisplay
        Group {
            if shown, let head = Shop.lapseHeadline(d, shop.words) {
                Banner(text: [head, Shop.lapseDeadline(d, shop.words), shop.words.callIt("mac.lapse_what")]
                           .compactMap { $0 }.joined(separator: " "),
                       symbol: "lock.fill", tint: Khayt.attention) {
                    SettingsLink { Text(shop.words.callIt("mac.plan_upgrade") + "\u{2026}") }
                        .simultaneousGesture(TapGesture().onEnded { shop.settingsPane = .online })
                }
            }
        }
        // Asked by the library's Links button as it appears (`ScreenActions`):
        // an empty banner is not drawn, so a `.task` here would never run.
    }
}
