import Foundation

/**
 * The Money widget's figures, worked out by the app when it writes the
 * widget's snapshot (`WidgetSnapshotStore`).
 *
 * ── NOTHING HERE IS A NEW MONEY RULE ─────────────────────────────────────
 *
 * Each figure is one the app already shows, taken from the code that shows it:
 *
 * - Today: End of Day's "Earned today" (`BookReader.endOfDay`, the Mac's
 *   `EndOfDay.report` over `endOfDayFacts`): net revenue of the jobs finished
 *   on the shop's day, net of VAT, in the shop's currency.
 * - Owed: Home's Owed (`BookReader.pulse`, `owedByOrder` over open jobs).
 * - Low stock: the spools on the shopping list, i.e. those at or under their
 *   reorder point by the shared rule (`ReorderRules.isLowStock`).
 *
 * The texts are written the way Home's hero writes its figures (whole units,
 * Western digits whatever the phone's language, the currency's mark beside),
 * so the widget draws them and never formats or adds up money itself.
 *
 * ── WHEN THERE IS NOTHING TO SHOW ────────────────────────────────────────
 *
 * No book, no pairing or the sample shop: nil, and the widget shows a neutral
 * placeholder. The sample shop's money is invented, and a Home Screen widget
 * is the one place it could be mistaken for a real shop's.
 */
enum WidgetFigures {

    /// The figures from what the app already worked out. Nil when any of them
    /// is missing: a widget showing two figures of three would read the third
    /// as zero.
    static func money(pulse: ShopPulse?, day: DayReport?, lowStock: Int?, asOf: Date) -> WidgetMoney? {
        guard let pulse, let day, let lowStock else { return nil }
        let takings = day.report.revenue.isFinite ? day.report.revenue : 0
        return WidgetMoney(
            takingsToday: takings,
            owed: pulse.owed,
            unpaid: pulse.unpaid,
            lowStock: lowStock,
            currency: pulse.currency,
            takingsText: figure(takings),
            owedText: figure(pulse.owed),
            mark: pulse.currency.map(Money.mark) ?? "",
            asOf: asOf)
    }

    /// The spools at or under their reorder point: every line of the shopping
    /// list (`ReorderRules.shoppingList` lists each low spool once).
    static func lowStock(_ list: ShopShoppingList) -> Int {
        list.groups.reduce(0) { $0 + $1.items.count }
    }

    /// A figure as Home's hero writes it: whole units, grouped, 0–9.
    static func figure(_ amount: Double) -> String {
        amount.formatted(.number.precision(.fractionLength(0)).locale(L10n.locale))
    }

    /// From the phone's book. Nil for the sample shop, an unpaired phone and a
    /// phone with no book.
    @MainActor
    static func money(api: KhaytAPIClient, settings: ConnectionSettings, asOf: Date) async -> WidgetMoney? {
        guard settings.isPaired, !settings.isSampleShop else { return nil }
        let pulse = await api.fetchPulse()
        let day = await api.fetchEndOfDay()
        let low = api.shoppingList(shopName: settings.shopLabel).map(lowStock)
        return money(pulse: pulse, day: day, lowStock: low, asOf: asOf)
    }
}
