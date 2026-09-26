import SwiftUI

/// Whether this screen is inside the old shell, which owns a real toolbar.
///
/// Default true, so a screen rendered on its own — a preview, a snapshot of one
/// table — keeps the buttons it has always had. Only the new shell says false,
/// and it says it once, for the whole content region.
private struct ClassicShellKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    var classicShell: Bool {
        get { self[ClassicShellKey.self] }
        set { self[ClassicShellKey.self] = newValue }
    }
}

/// A screen's toolbar, which only the old shell has somewhere to put.
///
/// `.toolbar` does not ask where it is: it goes to the window's title bar, and
/// in the new shell the window has no title bar — see `WindowChrome`. Declaring
/// one there brought the system's bar back, which is the "big header above the
/// header" the shop saw on Jobs and the Board.
///
/// Every screen that had a toolbar calls this instead, and `ShellChromeTests`
/// fails if a bare `.toolbar` reappears in one.
extension View {
    func screenToolbar<C: ToolbarContent>(@ToolbarContentBuilder _ items: @escaping () -> C) -> some View {
        modifier(ScreenToolbar(items: items))
    }
}

private struct ScreenToolbar<C: ToolbarContent>: ViewModifier {
    @Environment(\.classicShell) private var classic
    @ToolbarContentBuilder let items: () -> C

    @ViewBuilder func body(content: Content) -> some View {
        if classic { content.toolbar(content: items) } else { content }
    }
}

/// What the screen in front of you can do, drawn in the app's own strip.
///
/// ── THE SAME ACTIONS, A DIFFERENT BAR ─────────────────────────────────────
///
/// These are not new buttons. Each one is the item its screen used to declare
/// as `ToolbarContent`, moved from the window's title bar into ours, because
/// the new shell has no window title bar to put them in. The conditions are the
/// screen's own — `canMoveJobs` still refuses on a sample book, the schedule
/// suggestion still needs something to schedule — so a button that was disabled
/// is disabled here.
///
/// The order follows `ShopWindow.classicScreens`, which is the order the app
/// decides what to show. Anything not listed simply has no actions: the
/// Dashboard, the customers, the calculator. (The inventory was on that list
/// and should not have been — see the New Spool item below.)
struct ScreenActions: View {
    @Bindable var shop: Shop
    /// The detail panel's switch, shared with `ShopWindow` through the same
    /// scene key rather than a second piece of state.
    @SceneStorage("inspector.showing") private var showInspector = true
    /// The catalogue's list-or-grid switch. The same scene key the screen
    /// itself reads, so the two are one control in two places rather than two
    /// controls disagreeing.
    @SceneStorage("catalogue.layout") private var catalogueLayout: Catalogue.Layout = .table

    var body: some View {
        HStack(spacing: Space.sm) {
            if shop.showingBoard || isJobs {
                plus("mac.new_job", enabled: shop.canMoveJobs) { shop.takingAJob = true }
            } else if shop.showingLibrary {
                // IMPORT, ON THE SCREEN IT IMPORTS INTO — the reason the old
                // toolbar grew this item. It exists in the Book menu as well,
                // and a shop with a folder of models that has not read the
                // menus has no way in that it can see.
                NavyAction(label: shop.words.callIt("mac.import_models"),
                           symbol: "square.and.arrow.down",
                           enabled: shop.canMoveJobs && !shop.importing) {
                    Task { await shop.addModelToLibrary() }
                }
            } else if shop.showingCatalogue {
                layoutSwitch
                // THE CLOUD'S TWO WAYS IN. They were declared as toolbar items
                // only, and this shell draws no toolbar — so a shop could not
                // reach its web store or its storefront orders at all.
                if shop.cloudConnected {
                    NavyAction(label: shop.words.callIt("mac.online_orders"),
                               symbol: "tray.and.arrow.down") { shop.showingOnlineOrders = true }
                    NavyAction(label: shop.words.callIt("mac.ws_button"),
                               symbol: "storefront") { shop.showingWebStore = true }
                }
                plus("mac.new_product", enabled: shop.canMoveJobs) {
                    shop.editingProduct = shop.newProduct()
                }
            } else if shop.showingMachines {
                NavyAction(label: shop.words.callIt("sched.suggest_btn"),
                           symbol: "wand.and.stars",
                           enabled: !shop.schedulableRows.isEmpty && !shop.machines.isEmpty) {
                    shop.forgetSchedule()
                    shop.schedulingWork = true
                }
                plus("mach.add", enabled: shop.canMoveJobs) { shop.addingMachine = true }
            } else if shop.showingInventory {
                // THE SHELF HAD NO WAY TO PUT ANYTHING ON IT.
                //
                // `SpoolSheet` has always handled a spool that is not on the
                // shelf yet — its own heading, the catalogue lookup that only
                // makes sense for a new one — and `Shop.saveSpool(id: nil)`
                // has always written it, with a test. `addingSpool` was
                // declared, bound to the sheet, and reset on save. Nothing
                // ever set it to TRUE, so none of that was reachable and a
                // shop could correct a spool here but never add one.
                //
                // The comment above this struct listed the inventory among
                // the screens that "simply have no actions", which is how it
                // stayed unnoticed: the absence read as a decision.
                // Every roll a shop already keeps in Spoolman, in one go
                // rather than one form at a time.
                Button(shop.words.callIt("mac.spoolman_import") + "…") { shop.importingSpoolman = true }
                    .disabled(!shop.canMoveJobs)
                    // ON NAVY. A system button draws its text for a light
                    // surface, and on this strip that was dark grey on navy —
                    // readable only by someone who already knew it was there.
                    .environment(\.colorScheme, .dark)
                plus("mac.new_spool", enabled: shop.canMoveJobs) { shop.addingSpool = true }
            } else if shop.showingExpenses {
                period
                plus("exp.add_title", enabled: shop.canMoveJobs) { shop.addingExpense = true }
            } else if shop.showingWaste {
                period
                plus("waste.add", enabled: shop.canMoveJobs) { shop.loggingWaste = true }
            } else if shop.showingGiftCards {
                plus("mac.issue_gift_card", enabled: true) { shop.issuingGiftCard = true }
            } else if shop.showingReports, shop.reportPage == .best {
                period
            } else if shop.showingReports, shop.reportPage == .profit {
                // The P&L's grain: by quarter, the table's word, or by month.
                Picker("", selection: $shop.pnlByMonth) {
                    Text(shop.words.callIt("mac.by_quarter")).tag(false)
                    Text(shop.words.callIt("mac.by_month")).tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                // On navy, like the button above: the segmented control's
                // labels were dark grey on the strip.
                .environment(\.colorScheme, .dark)
            }

            // THE PANEL'S SWITCH, on every screen that has a panel.
            //
            // The old toolbar carried it and the new strip did not, so with the
            // panel closed there was no way to open it again — the menu item
            // reads a focused value, which needs the window key and does not
            // help a shop looking for the button it had yesterday.
            if wantsPanel {
                NavyAction(label: shop.words.callIt(showInspector ? "mac.hide_details"
                                                                 : "mac.show_details"),
                           symbol: "sidebar.trailing") {
                    showInspector.toggle()
                }
            }
        }
    }

    /// Whether this screen has a panel at all — the same list `ShopWindow`
    /// keeps, minus the switch itself, because a button that says "show" and
    /// shows nothing is worse than no button.
    private var wantsPanel: Bool {
        !shop.showingDashboard && !shop.showingBoard
            && !shop.showingMachines && !shop.showingInventory
            && !shop.showingExpenses && !shop.showingWaste && !shop.showingReports
            && !shop.showingCatalogue && !shop.showingColour && !shop.showingPortfolio
            && !shop.showingCalculator && !shop.showingGiftCards
    }

    /// The jobs table: the screen the app falls through to, so it is named by
    /// everything else being off rather than by a flag of its own.
    private var isJobs: Bool {
        !shop.showingDashboard && !shop.showingLibrary && !shop.showingBoard
            && !shop.showingMachines && !shop.showingInventory && !shop.showingExpenses
            && !shop.showingWaste && !shop.showingReports && !shop.showingCatalogue
            && !shop.showingCalculator && !shop.showingColour && !shop.showingPortfolio
            && !shop.showingGiftCards && !shop.showingCustomers
    }

    private func plus(_ key: String, enabled: Bool, act: @escaping () -> Void) -> some View {
        NavyAction(label: shop.words.callIt(key), symbol: "plus", enabled: enabled, act: act)
    }

    private var period: some View {
        PeriodMenu(shop: shop)
            .font(TypeScale.body(11.5))
            .foregroundStyle(Role.onNavy2)
            .fixedSize()
    }

    private var layoutSwitch: some View {
        HStack(spacing: 2) {
            layoutChoice(.table, "list.bullet", "mac.view_list")
            layoutChoice(.grid, "square.grid.2x2", "mac.view_grid")
        }
        .padding(2)
        .background(Color.white.opacity(0.1), in:
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    private func layoutChoice(_ which: Catalogue.Layout, _ symbol: String, _ key: String) -> some View {
        let on = catalogueLayout == which
        return Button { catalogueLayout = which } label: {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .frame(width: 22, height: 18)
                .background(on ? Color.white.opacity(0.16) : .clear, in:
                                RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(on ? Role.onNavy : Role.onNavy3)
        .help(shop.words.callIt(key))
        .accessibilityLabel(shop.words.callIt(key))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

/// One action, on navy.
///
/// A symbol in a soft well rather than a bordered button: navy is a ground, and
/// a system-bordered control on it draws its own light grey capsule. The word
/// is not lost with the border — it is the help text AND the accessibility
/// label, which is what the toolbar item carried too.
private struct NavyAction: View {
    let label: String
    let symbol: String
    var enabled = true
    let act: () -> Void

    var body: some View {
        Button(action: act) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .frame(width: 26, height: 22)
                .background(Color.white.opacity(0.1), in:
                                RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Role.onNavy : Role.onNavy3)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }
}
