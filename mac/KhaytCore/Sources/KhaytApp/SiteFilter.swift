import SwiftUI
import KhaytCore

// MARK: - One site at a time
//
// A shop with branches narrows the screens it works from to the branch it is
// standing in: the jobs, the board, the machines, the stock, and the parts of
// the dashboard about them. What belongs to a site is `lib/site-filter.js` —
// the desktop's own rule, lifted — asked once per change of book or filter
// and kept here as ids, because the screens filter as they draw.
//
// WHAT IS NOT NARROWED, on purpose, as on the desktop: money. The figures,
// the P&L and Reports are the shop's; Reports → By machine already splits the
// P&L by site. And the kiosk: it is the screen on the wall of the floor it
// stands on, and a shop with two floors opens one per screen — a filter set
// on the desk would silently empty the wall.

extension Shop {

    /// Is this job shown at the chosen site? Always, when none is chosen.
    func inSite(_ order: Order) -> Bool {
        guard let scope = siteScope, scope.active != nil else { return true }
        return siteOrderIds.contains(order.id)
    }

    func inSite(machine id: String) -> Bool {
        guard let scope = siteScope, scope.active != nil else { return true }
        return scope.machineIds.contains(id)
    }

    func inSite(spool id: String) -> Bool {
        guard let scope = siteScope, scope.active != nil else { return true }
        return scope.spoolIds.contains(id)
    }

    /// An attention row is about a job, a machine or a spool, by its `kind`
    /// (`lib/attention.js`: a nozzle row carries its machine's id, a stock
    /// row its spool's). The desktop narrows this bar to the site too.
    func inSite(attention item: DashboardFacts.Item) -> Bool {
        guard siteScope?.active != nil else { return true }
        switch item.kind {
        case "order": return siteOrderIds.contains(item.id)
        case "machine", "nozzle": return inSite(machine: item.id)
        case "stock": return inSite(spool: item.id)
        default: return true
        }
    }

    private var siteOrderIds: Set<String> { Set(siteScope?.orderIds ?? []) }

    /// The machines the chosen site shows.
    var siteMachines: [Machine] { machines.filter { inSite(machine: $0.id) } }
    /// The spools the chosen site shows.
    var siteSpools: [Spool] { spools.filter { inSite(spool: $0.id) } }

    /// The chosen site's name, when one is chosen and still in the book.
    var siteName: String? {
        guard let scope = siteScope, scope.active != nil else { return nil }
        return scope.name
    }

    /// Ask the rule again. A filter naming a site the book no longer has is
    /// dropped — the desktop's restore does the same with a stale session.
    func refreshSiteScope() async {
        guard let id = siteFilter else { siteScope = nil; return }
        guard locations.contains(where: { $0.id == id }) else {
            siteFilter = nil
            siteScope = nil
            return
        }
        guard let engine else { siteScope = nil; return }
        siteScope = try? await engine.siteScope(orders: orderRows, machines: machineRows,
                                                inventory: inventoryRows, locations: locationRows,
                                                active: id)
        // A selected job the site does not show is a row the table cannot
        // draw and an inspector describing something invisible.
        if let selection, let job = orders.first(where: { $0.id == selection }), !inSite(job) {
            self.selection = nil
        }
    }
}

/// The site picker, under the book's card in the sidebar. Only for a shop
/// that has sites: a menu with one entry is a control that does nothing.
struct SitePicker: View {
    @Bindable var shop: Shop

    var body: some View {
        if !shop.locations.isEmpty {
            Menu {
                Button {
                    shop.siteFilter = nil
                } label: {
                    if shop.siteFilter == nil { Label(shop.words.callIt("loc.show_all"), systemImage: "checkmark") }
                    else { Text(shop.words.callIt("loc.show_all")) }
                }
                Divider()
                ForEach(shop.locations) { site in
                    Button {
                        shop.siteFilter = site.id
                    } label: {
                        if shop.siteFilter == site.id { Label(site.name, systemImage: "checkmark") }
                        else { Text(site.name) }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 10, weight: .semibold))
                    // Two lines, not a truncation: a branch's name is the
                    // whole point of the row, and "Riyadh work…" was measured
                    // at the sidebar's width.
                    Text(shop.siteName ?? shop.words.callIt("loc.show_all"))
                        .font(TypeScale.body(10.5))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                // Lit when narrowed: a sidebar that looks the same filtered
                // and not is how a shop forgets it filtered.
                .foregroundStyle(shop.siteName == nil ? Role.onNavy3 : Role.onNavy)
                .padding(.horizontal, Space.md)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(shop.siteName == nil ? Color.clear : Role.onNavy.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help(shop.words.callIt("mac.site_menu_hint"))
            .padding(.horizontal, 8)
            .padding(.bottom, Space.md)
        }
    }
}

/// Above every narrowed screen: which site, how many of how many, and the way
/// back. A filtered list with nothing saying so is a shop that thinks the other
/// branch's work has gone.
struct SiteScopeBanner: View {
    enum Counting { case jobs, machines, spools, none }
    let shop: Shop
    let counting: Counting

    var body: some View {
        if let name = shop.siteName, let scope = shop.siteScope {
            HStack(spacing: 8) {
                Image(systemName: "mappin.and.ellipse").foregroundStyle(Khayt.brand)
                Text(line(name, scope))
                    .font(.callout)
                    .lineLimit(1)
                    .help(shop.words.callIt("mac.site_banner_hint"))
                Spacer(minLength: 8)
                Button(shop.words.callIt("loc.show_all")) { shop.siteFilter = nil }
                    .controlSize(.small)
            }
            .padding(.horizontal, Metric.screen)
            .padding(.vertical, 6)
            .background(Khayt.brand.opacity(0.08))
        }
    }

    private func line(_ name: String, _ scope: KhaytEngine.SiteScope) -> String {
        let site = Figure.isolated(name)
        let (shown, total): (Int, Int) = switch counting {
        case .jobs: (scope.orderIds.count, scope.total.orders)
        case .machines: (scope.machineIds.count, scope.total.machines)
        case .spools: (scope.spoolIds.count, scope.total.spools)
        case .none: (0, 0)
        }
        if counting == .none { return shop.words.callIt("mac.site_only", ["site": .string(site)]) }
        return shop.words.callIt("mac.site_banner", ["site": .string(site),
                                                     "shown": .number(Double(shown)),
                                                     "total": .number(Double(total))])
    }
}
