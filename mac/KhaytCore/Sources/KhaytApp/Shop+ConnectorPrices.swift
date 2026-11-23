import Foundation
import KhaytCore

/// "Show prices in OrcaSlicer" and each paired slicer's price grant
/// (Connected apps ▸ Slicers; Figma Qqxg4imtKVgC3TfNGcRGOk, page 24).
///
/// ── WHO MAY CHANGE THEM ───────────────────────────────────────────────────
///
/// The OWNER, and nobody else: what a device outside the book may learn of
/// the shop's prices is the owner's decision, like the staff lock itself
/// (`security`/`edit`). A manager sees the switch and each grant, and cannot
/// change either. "Price and cost" also needs the right to see reports
/// (`analytics`/`view`): nobody hands a slicer a margin they may not see
/// themselves. With the staff lock off, everyone is the owner, as everywhere.
///
/// Both gates are asked HERE, in the write, so no control, menu or shortcut
/// can step around them; the screen only disables what would be refused.
extension Shop {

    /// May whoever is here change the switch or a grant? Asks, says nothing.
    var mayChangeConnectorPrices: Bool { lockAllows("security", "edit") }

    /// May whoever is here give a device the cost and the margin?
    var mayGrantConnectorCost: Bool { mayChangeConnectorPrices && lockAllows("analytics", "view") }

    /// The switch as stored, read again (the screen appearing).
    func refreshConnectorPrices() {
        connectorPricesOn = connectorPricesDefaults.bool(forKey: LanConnectorPairing.pricesKey)
    }

    /// Turn "Show prices in OrcaSlicer" on or off. Off is immediate for every
    /// device: the route asks the switch on each request. Grants are kept, so
    /// turning it on again restores what each slicer was allowed.
    func setConnectorPrices(_ on: Bool) {
        guard permitted("security", "edit") else { return }
        connectorPricesDefaults.set(on, forKey: LanConnectorPairing.pricesKey)
        connectorPricesOn = on
    }

    /// Give one paired slicer a grant: nil (none), `price`, or `cost` (price,
    /// cost and margin). Anything else is refused, not stored as none.
    func setConnectorPriceGrant(_ id: String, _ grant: String?) {
        guard permitted("security", "edit") else { return }
        if let grant {
            guard LanDevices.priceGrants.contains(grant) else { return }
            if grant == "cost", !permitted("analytics", "view") { return }
        }
        lanDeviceStore.setPriceGrant(id, grant)
        refreshConnectedApps()
    }

    /// What a paired slicer does and sees, in one line: the grant only counts
    /// while the switch is on.
    static func connectorDoes(grant: String?, pricesOn: Bool, words: Words) -> String {
        var line = words.callIt("mac.apps_does")
        guard pricesOn, let grant else { return line }
        if grant == "price" { line += " · " + words.callIt("mac.apps_sees_price") }
        if grant == "cost" { line += " · " + words.callIt("mac.apps_sees_cost") }
        return line
    }

    /// The picker's label for a grant.
    static func connectorGrantName(_ grant: String?, words: Words) -> String {
        switch grant {
        case "price": words.callIt("mac.apps_grant_price")
        case "cost": words.callIt("mac.apps_grant_cost")
        default: words.callIt("mac.apps_grant_none")
        }
    }
}
