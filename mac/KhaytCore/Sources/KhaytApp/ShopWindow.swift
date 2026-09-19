import SwiftUI
import QuickLook

struct ShopWindow: View {
    @Bindable var shop: Shop
    // Both restored on relaunch. Reopening an app onto a different screen from
    // the one you left is a small thing that makes it feel like a web page.
    @SceneStorage("inspector.showing") private var showInspector = true
    /// Whether the panel is on screen RIGHT NOW, which is not the same question
    /// as whether this screen wants one.
    ///
    /// ── WHY THIS IS STATE AND NOT A COMPUTED VALUE ────────────────────────
    ///
    /// It was computed inline from the shelf, so changing screen resized the
    /// detail pane AND replaced its contents in one state update. AppKit then
    /// collapses an `NSSplitViewItem` while SwiftUI is rebuilding the view
    /// inside it, and somewhere in that overlap SwiftUI's own bridging changes
    /// a layout constraint from inside the window's constraint pass:
    ///
    ///     NSHostingView._willUpdateConstraintsForSubtree
    ///     NSLayoutConstraint.setConstant
    ///     AppKitPlatformViewHost._layoutMetricsInvalidatedForHostedView
    ///     NSHostingView.setNeedsUpdate
    ///     -[NSWindow _postWindowNeedsUpdateConstraints]   → throw → abort
    ///
    /// AppKit will not forgive an invalidation raised during its own pass, and
    /// the exception escapes the display-cycle observer uncaught, so the app
    /// dies rather than glitches. It came in from a real morning's use and
    /// reproduced 4 times in 6 under `KHAYT_CHURN`, which changes shelf on
    /// consecutive runloop turns.
    ///
    /// Splitting it in two fixes it: the shelf changes now, and the panel
    /// follows on the NEXT turn, by which time the pane has settled. Nobody
    /// can see one frame, and the two layout passes no longer overlap.
    ///
    /// A capture-only or timing-only explanation was wrong twice before on
    /// this same assertion. This one has a driver that reproduces it and a
    /// driver that proves the fix — `ChurnTests` runs both.
    @State private var panelIsOpen = true
    /// A request from the menu bar to put the caret in the search field.
    @State private var searchWanted = false
    @SceneStorage("shelf") private var storedShelf = ""
    @SceneStorage("library.sort") private var storedSort = LibrarySort.khayt.rawValue
    /// Nil where a context has no undo, which the documentation says to expect
    /// and which every registration in `Shop` is guarded for.
    @Environment(\.undoManager) private var undoManager


    /// Does the screen you are on have a panel at all?
    ///
    /// Closed on the dashboard, not filled with a placeholder: that screen is
    /// already a summary, and a panel beside it has nothing to say. Closed on
    /// the screens that carry their own detail — a card, or a table wide
    /// enough to read — because a panel there would repeat.
    private var wantsPanel: Bool {
        showInspector && !shop.showingDashboard && !shop.showingBoard
            && !shop.showingMachines && !shop.showingInventory
            && !shop.showingExpenses && !shop.showingWaste && !shop.showingReports
            && !shop.showingCatalogue && !shop.showingColour && !shop.showingPortfolio
            && !shop.showingCalculator
            && !shop.showingGiftCards
    }

    /// Which window the shop is looking at.
    ///
    /// The redesign is a whole new shell — its own title bar, its own sidebar,
    /// its own Dashboard — so it cannot be grafted into the existing
    /// `NavigationSplitView` a screen at a time without the app briefly having
    /// two sidebars. It goes behind a switch instead: the new one can be built,
    /// looked at and lived with while the old one keeps working, and the screens
    /// underneath are shared by both.
    ///
    /// ON as of 4.0.0-alpha.12. The shell, the sidebar and the Dashboard are
    /// drawn to the spec; the other screens are unchanged and sit inside it,
    /// which is a mixed state and the point of an alpha. Settings → General →
    /// Appearance switches back in one click, and the preference is a
    /// preference — nothing about the book changes either way.
    @AppStorage(ShellChoice.key) private var newShell = ShellChoice.byDefault

    var body: some View {
        if newShell {
            // AROUND THE CONTENT, not around the shell: an `.inspector` on the
            // shell's root splits the navy strip too, and the panel comes up
            // beside the title bar rather than beside the table.
            Shell(shop: shop, searchWanted: $searchWanted,
                  showingPanel: wantsPanel && !InspectorPane.hasOwnDetail(shop)) { screen }
                // The panel itself is drawn by the shell; this is the rest of
                // `WindowPanels` — the menu bar's reach into the window.
                .modifier(Reachable(shop: shop, showInspector: $showInspector,
                                    searchWanted: $searchWanted))
                // The screens inside still declare toolbars; this is what tells
                // them there is no window title bar to put one in. See
                // `ScreenActions`.
                .environment(\.classicShell, false)
                .modifier(WindowSheets(shop: shop))
        } else {
            classic
                .environment(\.classicShell, true)
                .windowTitleBar(hidden: false)
                .modifier(WindowSheets(shop: shop))
        }
    }

    /// The detail panel, the search field and the menu-bar plumbing, built
    /// once and applied by both shells — see `WindowPanels`.
    private var panels: WindowPanels {
        WindowPanels(shop: shop, showInspector: $showInspector,
                     panelIsOpen: $panelIsOpen, searchWanted: $searchWanted,
                     wantsPanel: wantsPanel, searchPrompt: searchPrompt)
    }

    /// The content region, with no chrome of its own — shared by both shells,
    /// which is what stops this being a fork of the app.
    @ViewBuilder private var screen: some View {
        if shop.showingDashboard {
            Triage(shop: shop)
        } else {
            VStack(spacing: 0) {
                EngineBanner(shop: shop)
                MoveBanners(shop: shop)
                SpendBanner(shop: shop)
                classicScreens
            }
        }
    }

    /// Every screen but the Dashboard, shared by both shells.
    @ViewBuilder private var classicScreens: some View {
            if shop.showingDashboard {
                Dashboard(shop: shop)
            } else if shop.showingLibrary {
                LibraryGrid(shop: shop)
            } else if shop.showingBoard {
                Kanban(shop: shop)
            } else if shop.showingMachines {
                Machines(shop: shop).environment(shop.cameras)
            } else if shop.showingInventory {
                Inventory(shop: shop)
            } else if shop.showingExpenses {
                Expenses(shop: shop)
            } else if shop.showingWaste {
                Waste(shop: shop)
            } else if shop.showingReports {
                Reports(shop: shop)
            } else if shop.showingCatalogue {
                Catalogue(shop: shop)
            } else if shop.showingCalculator {
                Calculator(shop: shop)
            } else if shop.showingColour {
                ColourStudio(shop: shop)
            } else if shop.showingPortfolio {
                Portfolio(shop: shop)
            } else if shop.showingGiftCards {
                GiftCards(shop: shop)
            } else if shop.showingCustomers {
                CustomersTable(shop: shop)
            } else {
                // The kits above the book they group. Nothing at all when
                // the shop has never made one — a band explaining an empty
                // feature is furniture on the screen people live in.
                VStack(spacing: 0) {
                    KitBand(shop: shop)
                    OrdersTable(shop: shop)
                }
            }
    }

    private var classic: some View {
        NavigationSplitView {
            Sidebar(shop: shop)
                // 190 was under every published minimum for a Mac source list
                // (225-275), and the app was paying for it: `SidebarLayoutTests`
                // caps every sidebar label at 22 characters because they
                // truncate, which is a test managing the symptom of a column
                // too narrow to hold its own words. Arabic is the tighter of
                // the two languages and set the cap.
                //
                // The extra 25 points come out of a detail pane that is
                // hundreds wide and, on the dashboard, capped anyway.
                .navigationSplitViewColumnWidth(min: 225, ideal: 240, max: 340)
        } detail: {
            VStack(spacing: 0) {
                // What the last move said, above whatever screen you are on.
                //
                // It used to live inside the board, which is where a drag
                // starts — but ⇧⌘H and the Job menu move a job from the table
                // too, and there a refusal appeared nowhere at all. A move that
                // did not happen and said nothing is the worst of the three
                // possible outcomes.
                EngineBanner(shop: shop)
                MoveBanners(shop: shop)
                SpendBanner(shop: shop)

                classicScreens
            }
        }
        // The detail panel, the search field and the menu-bar plumbing —
        // here rather than inside `detail`, for the reason `WindowPanels`
        // gives. Both shells apply it.
        .modifier(panels)
        // On the window rather than the board, because ⇧⌘H and the Job menu
        // reach a job from the table too, and the sheet has to be somewhere all
        // of them can raise it.
        .toolbar {
            ToolbarItem(placement: .navigation) {
                // Which book is open, always visible. Mistaking the sample for
                // the shop's real position is the one error this app must not
                // allow, so it is stated rather than implied.
                Menu {
                    ForEach(Shop.available) { source in
                        Button {
                            Task { await shop.load(source) }
                        } label: {
                            Label(source.title(shop.words), systemImage: source.symbol)
                        }
                    }
                } label: {
                    Label(shop.source.title(shop.words), systemImage: shop.source.symbol)
                }
            }
            ToolbarItem(placement: .principal) {
                // Two menus in one item rather than two items: the three axes
                // belong together, and a toolbar that collapses them apart when
                // the window narrows would separate "which set" from "what it
                // is" at exactly the size where the sidebar is already gone.
                if shop.showingLibrary {
                    HStack(spacing: 6) {
                        GroupMenu(shop: shop)
                        CategoryMenu(shop: shop)
                        // Where it came from is the FOURTH thing a library row
                        // can say, and the only one that decides whether a
                        // print may be sold. It sits here rather than in the
                        // inspector because it is set on a selection — twenty
                        // models downloaded from one site share one answer.
                        ProvenanceMenu(shop: shop)
                    }
                } else { OwedSummary(shop: shop) }
            }
            // IMPORT, ON THE SCREEN IT IMPORTS INTO.
            //
            // It existed only as "Add model" in the Book menu — the wrong name
            // in the wrong menu — and the library itself offered nothing, so a
            // shop with a folder of models had no way in that it could see.
            ToolbarItem {
                if shop.showingLibrary {
                    Button {
                        Task { await shop.addModelToLibrary() }
                    } label: {
                        Label(shop.words.callIt("mac.import_models"),
                              systemImage: "square.and.arrow.down")
                    }
                    .disabled(!shop.canMoveJobs || shop.importing)
                    .help(shop.words.callIt("mac.import_models_hint"))
                }
            }
            ToolbarItem {
                Button {
                    showInspector.toggle()
                } label: {
                    Label(shop.words.callIt("mac.details"), systemImage: "sidebar.trailing")
                }
                .help(shop.words.callIt("mac.details_toggle"))
                // The label above is the button's title; VoiceOver reads this.
                // "Don't include text that repeats information users already
                // have" — it is already a button, so this does not say so.
                .accessibilityLabel(shop.words.callIt(showInspector ? "mac.hide_details" : "mac.show_details"))
            }
        }
        // No `.environment(\.layoutDirection, …)` here on purpose: that line
        // loops SwiftUI's split view until AppKit aborts. The window is mirrored
        // before it exists instead — see `Direction`.
        // Handed over rather than reached for: `Shop` is not a view and has no
        // environment of its own. Re-run when it changes, because SwiftUI may
        // hand out a different manager than the one at first launch.
        .task(id: ObjectIdentifier(undoManager ?? UndoManager())) { shop.undoManager = undoManager }
        .task(id: shop.shelf) { storedShelf = Shelves.name(shop.shelf) }
        .task(id: shop.librarySort) { storedSort = shop.librarySort.rawValue }
        .task { shop.librarySort = LibrarySort(rawValue: storedSort) ?? .khayt }
        .task {
            // Only after the book has loaded: a group shelf means nothing until
            // the groups are known, and restoring one that no longer exists
            // would open on an empty screen with no way to tell why.
            if let restored = Shelves.shelf(storedShelf, in: shop) { shop.shelf = restored }
        }
        .navigationTitle(shop.shopName)
        .navigationSubtitle(subtitle)
    }


    /// Says which book is open before it says anything else. The sample must
    /// never be mistaken for the shop's real position.
    private var subtitle: String {
        // Says what this session can actually do. It said "read-only" for a
        // while after the app could write, which is the kind of stale label
        // people stop trusting the rest of the window over.
        let provenance = shop.source.isReal
            ? shop.words.callIt(shop.canWrite ? "mac.yours" : "mac.read_only")
            : shop.words.callIt("mac.not_real_shop")
        if shop.showingLibrary {
            let n = shop.shownFiles.count
            return shop.words.counting(n, "mac.models_count") + " · " + provenance
        }
        if shop.showingCustomers {
            let n = shop.shownCustomers.count
            return shop.words.counting(n, "mac.customers_count") + " · " + provenance
        }
        if shop.showingDashboard || shop.showingBoard { return provenance }
        if shop.showingMachines {
            return shop.words.counting(shop.machines.count, "mac.machines_count") + " · " + provenance
        }
        if shop.showingInventory {
            return shop.words.counting(shop.spools.count, "mac.spools_count") + " · " + provenance
        }
        return provenance
    }

    /// What this screen's search box looks for — on the shop, because both
    /// shells ask: the old one for its toolbar field, the new one for the strip.
    private var searchPrompt: String { shop.searchPrompt }
}

/// The three things the menu bar reaches into this window for, in a
/// modifier of their own.
///
/// Not tidiness: with these on the end of the body's chain the type-checker
/// gave up on the whole expression, which is the same wall `LibraryGrid`
/// hit. A `ViewModifier` is a separate expression, so it costs nothing to
/// check.
private struct Reachable: ViewModifier {
    let shop: Shop
    @Binding var showInspector: Bool
    @Binding var searchWanted: Bool

    func body(content: Content) -> some View {
        @Bindable var shop = shop
        return content
            .focusSearchWhenAsked($searchWanted)
            // On the window, not the grid: ⌘Y reaches a model from the menu
            // bar too, and the panel has to be somewhere both can raise it.
            .quickLookPreview($shop.previewing)
            // Published from the window so the commands act on whichever
            // one is frontmost.
            .focusedSceneValue(\.inspectorShowing, $showInspector)
            .focusedSceneValue(\.searchWanted, $searchWanted)
    }
}

/// `.searchable`, but only on a screen that has something to search.
///
/// A modifier rather than an `if` around the window's body: the branch is kept
/// as small as it can be, so moving to a screen without search rebuilds the
/// search field and nothing else.
private struct SearchWhereItWorks: ViewModifier {
    @Bindable var shop: Shop
    let prompt: String
    /// `.searchable(placement: .toolbar)` does not merely go unplaced without a
    /// toolbar — it MAKES one, and a toolbar brings the window's title bar back
    /// above the navy strip. The new shell's strip carries its own field; see
    /// `CommandField`.
    @Environment(\.classicShell) private var classic

    @ViewBuilder func body(content: Content) -> some View {
        if shop.canSearch {
            if classic {
                content
                    .searchable(text: $shop.search, placement: .toolbar, prompt: prompt)
            } else {
                // The new shell's field is in the strip, and the term is the
                // same `shop.search` — so nothing here, and NOT the clearing
                // branch below, which would wipe what the strip just typed.
                content
            }
        } else {
            // No field at all, and the term dropped on the way out — a search
            // left running on the library must not silently narrow the jobs
            // table when the shop comes back to it.
            content.onAppear { shop.search = "" }
        }
    }
}

/// What the shop is owed, in the title bar.
///
/// The number an owner opens the app to find. It is not a card halfway down a
/// dashboard here — it is on screen whatever else you are looking at, because
/// it is the only figure that is true of the whole book at once.
private struct OwedSummary: View {
    let shop: Shop

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 0) {
                Text(shop.words.callIt("mac.owed_caps"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Text(Money.text(shop.owed, shop.currency))
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
            }
            if shop.overdueCount > 0 {
                Label("\(shop.overdueCount) \(shop.words.callIt("mac.late"))",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Khayt.attention)
                    .labelStyle(.titleAndIcon)
                    .help(shop.words.callIt("mac.overdue_jobs",
                                    ["n": .number(Double(shop.overdueCount))]))
            }
        }
        .padding(.horizontal, 4)
    }
}


/// Which shelf was open, as something that survives a relaunch.
///
/// A string rather than the enum: `SceneStorage` takes only simple values, and a
/// shelf that names a group has to be checked against the book before it is
/// restored — the group may have been renamed or emptied since.
@MainActor enum Shelves {
    static func name(_ shelf: Shop.Shelf) -> String {
        switch shelf {
        case .jobs(nil): "jobs"
        case .jobs(let stage?): "jobs:\(stage.rawValue)"
        case .customers: "customers"
        case .dashboard: "dashboard"
        case .machines: "machines"
        case .inventory: "inventory"
        case .board: "board"
        case .expenses: "expenses"
        case .waste: "waste"
        case .reports: "reports"
        case .catalogue: "catalogue"
        case .colour: "colour"
        case .calculator: "calculator"
        case .portfolio: "portfolio"
        case .giftCards: "gift-cards"
        case .library(nil): "library"
        case .library(let group?): "library:\(group)"
        }
    }

    static func shelf(_ name: String, in shop: Shop) -> Shop.Shelf? {
        guard !name.isEmpty else { return nil }
        let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "jobs":
            guard parts.count == 2 else { return .jobs(nil) }
            return Stage(rawValue: parts[1]).map(Shop.Shelf.jobs)
        case "customers":
            return .customers
        case "dashboard":
            return .dashboard
        case "machines":
            return .machines
        case "inventory":
            return .inventory
        case "board":
            return .board
        case "expenses":
            // Same reasoning as the catalogue below: a window reopened onto a
            // screen whose row is gone has no way back to it.
            return shop.canShow(.expenses) ? .expenses : nil
        case "waste":
            return .waste
        case "reports":
            return shop.canShow(.reports) ? .reports : nil
        case "catalogue":
            // Only if the shop still has one — a catalogue that was emptied
            // since would restore to a screen with nothing on it and no way
            // back, because the sidebar row is gone too.
            return shop.catalogueRows.isEmpty ? nil : .catalogue
        case "colour":
            return .colour
        case "calculator":
            // Unconditional, unlike the catalogue above: this screen holds
            // nothing, so there is no state it could restore into that has
            // since gone away.
            return .calculator
        case "gift-cards":
            // Unlike the catalogue and the portfolio, this restores even when
            // empty: a shop with no cards issued still has an Issue button to
            // reach, so the screen is not a dead end the way an empty grid is.
            return .giftCards
        case "portfolio":
            // Only if there is still a photograph. Restoring to an empty grid
            // with no sidebar row to leave by is a corner nobody can get out of.
            return shop.snapshots.isEmpty ? nil : .portfolio
        case "library":
            guard parts.count == 2 else { return .library(nil) }
            // Only if it is still a group this shop has.
            return shop.groups.contains(parts[1]) ? .library(parts[1]) : .library(nil)
        default:
            return nil
        }
    }
}


/// Every sheet, dialog and confirmation the window can raise.
///
/// ── A MODIFIER BECAUSE THERE ARE TWO WINDOWS NOW ─────────────────────────
///
/// This was chained straight onto the `NavigationSplitView`, which was fine
/// while that was the only shell. It is not any more: the redesigned shell is
/// a different view, and a `.sheet` attached to the old one does not exist in
/// the new one.
///
/// That shipped, on by default. Every editor in the app — take a job, edit a
/// product, record a payment, add a spool — did nothing at all, because the
/// thing that presents them was attached to a view no longer being drawn.
/// Nothing errored. The buttons simply had no effect, which is the worst way
/// for this to fail: a shop concludes the app is broken and cannot say how.
///
/// So the chain lives here and both shells apply it. Adding a sheet to one
/// window and not the other is the same bug again, and there is now exactly
/// one place to add one.
struct WindowSheets: ViewModifier {
    @Bindable var shop: Shop

    func body(content: Content) -> some View {
        content
            // On the split view, not inside `detail`. Inside it, the detail content
            // is laid out against the window minus the inspector — the sidebar's
            // width is not taken off — so a Table stretches its columns across a
            // width it does not have and the right-hand ones are clipped away
            // rather than compressed. The Owed column disappeared twice that way.
            // Closed on the dashboard, not filled with a placeholder: that screen is
            // already a summary, and a panel beside it has nothing to say. The
            // binding is read-only there so the toolbar button cannot open an empty
            // one either.
            // The panel follows the shelf, one runloop turn behind — see the note
            // on `panelIsOpen`. `wantsPanel` is still the single place that says
            // WHICH screens have one; this only defers WHEN it moves.
            // Two things, and BOTH were needed. Deferring alone took the churn
            // driver from 4 crashes in 6 to 2 in 8 — better, and still a crash.
            // The surviving two came through a different frame,
            // `+[NSAnimationManager performAnimations:]`, which is the collapse
            // ANIMATING: AppKit drives `displayIfNeeded` from a display link and
            // lays the whole window out again inside it.
            //
            // A panel that slides is not worth an app that dies. Without the
            // animation the collapse is one layout pass, on a settled pane, on a
            // turn of its own.
            .sheet(item: $shop.pendingHold) { AskFirst(shop: shop, subject: $0, kind: .hold) }
            .sheet(item: $shop.pendingQC) { AskFirst(shop: shop, subject: $0, kind: .qcPass) }
            .sheet(item: $shop.pendingCompletion) { CompletionSheet(shop: shop, subject: $0) }
            .sheet(item: $shop.pendingPayment) { PaymentSheet(shop: shop, subject: $0) }
            .sheet(item: $shop.pendingEdit) { EditJobSheet(shop: shop, subject: $0) }
            .sheet(item: $shop.pendingQcFail) { QcFailSheet(shop: shop, subject: $0) }
            .sheet(isPresented: $shop.takingAJob) { NewJobSheet(shop: shop) }
            .sheet(isPresented: $shop.schedulingWork) { ScheduleSheet(shop: shop) }
            .sheet(isPresented: $shop.planningBatch) { BatchSheet(shop: shop) }
            .sheet(isPresented: $shop.reviewingDeposits) { DepositAuditSheet(shop: shop) }
            .sheet(item: $shop.receivingGoods) { ReceiveSheet(shop: shop, order: $0) }
            .sheet(item: $shop.editingCustomer) { CustomerSheet(shop: shop, existing: $0) }
            .sheet(item: $shop.editingProduct) { ProductSheet(shop: shop, existing: $0) }
            .sheet(item: $shop.droppingFrom) { DropObjectSheet(shop: shop, machine: $0) }
            .sheet(isPresented: $shop.findingPrinters) { FindPrintersSheet(shop: shop) }
            .sheet(item: $shop.ratingFor) { RatingSheet(shop: shop, job: $0) }
            .sheet(item: $shop.planFor) { PaymentPlanSheet(shop: shop, job: $0) }
            .sheet(isPresented: $shop.pausingProduction) { PauseSheet(shop: shop) }
            // Cancelling throws away every hour already in the plate, and no
            // printer asks twice. Pause and resume are each other's undo and are
            // not confirmed.
            .confirmationDialog(
                shop.words.callIt("mac.cancel_ask",
                                  ["machine": .string(shop.confirmingCancel?.name ?? "")]),
                isPresented: Binding(get: { shop.confirmingCancel != nil },
                                     set: { if !$0 { shop.confirmingCancel = nil } }),
                titleVisibility: .visible
            ) {
                Button(shop.words.callIt("mac.printer_cancel"), role: .destructive) {
                    guard let machine = shop.confirmingCancel else { return }
                    shop.confirmingCancel = nil
                    Task { await shop.tell(machine, .cancel) }
                }
                Button(shop.words.callIt("common.cancel"), role: .cancel) {
                    shop.confirmingCancel = nil
                }
            } message: {
                Text(shop.words.callIt("mac.cancel_why"))
            }
            // Deleting a model is the one library action that cannot be
            // undone — the files go — so it asks, in the words the Electron
            // app asks in, and the destructive button says what it does.
            .confirmationDialog(
                shop.words.callIt("plib.delete_title"),
                isPresented: Binding(get: { shop.pendingLibraryDelete != nil },
                                     set: { if !$0 { shop.pendingLibraryDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button(shop.words.callIt("common.delete"), role: .destructive) {
                    guard let file = shop.pendingLibraryDelete else { return }
                    Task { await shop.deleteLibraryFile(file) }
                }
                Button(shop.words.callIt("common.cancel"), role: .cancel) {
                    shop.pendingLibraryDelete = nil
                }
            } message: {
                Text(shop.words.callIt("plib.delete_confirm",
                                       ["name": .string(shop.pendingLibraryDelete?.title ?? "")]))
            }
            .sheet(item: $shop.pendingInvoice) { InvoiceSheet(shop: shop, subject: $0) }
            .sheet(item: $shop.pendingLabels) { LabelSheet(shop: shop, request: $0) }
            .sheet(item: $shop.editingSpool) { SpoolSheet(shop: shop, existing: $0) }
            .sheet(isPresented: $shop.addingSpool) { SpoolSheet(shop: shop, existing: nil) }
            .sheet(isPresented: $shop.issuingGiftCard) { GiftCardSheet(shop: shop) }
            .sheet(item: $shop.editingMachine) { MachineSheet(shop: shop, existing: $0) }
            .sheet(item: $shop.editingSupplier) { SupplierSheet(shop: shop, supplier: $0) }
            .sheet(item: $shop.loggingPurchaseFor) { PurchaseLogSheet(shop: shop, supplier: $0) }
            .sheet(item: $shop.showingHistoryFor) { PurchaseHistorySheet(shop: shop, supplier: $0) }
            .sheet(item: $shop.restoring) { RestoreSheet(shop: shop, subject: $0) }
            .sheet(isPresented: $shop.checkingCloud) { CloudCheckSheet(shop: shop) }
            .sheet(isPresented: $shop.scanning) { ScanSheet(shop: shop) }
            .sheet(isPresented: $shop.signingIntoCloud) { CloudSignInSheet(shop: shop) }
            .sheet(item: $shop.draftingFor) { job in
                DraftMessageSheet(shop: shop, job: job)
            }
            .sheet(item: $shop.messagingFor) { job in
                MessageSheet(shop: shop, job: job)
            }
            .sheet(isPresented: $shop.askingTheBook) {
                VStack(spacing: 0) {
                    AskTheBook(shop: shop)
                    Divider()
                    HStack {
                        Spacer()
                        Button(shop.words.callIt("common.close")) { shop.askingTheBook = false }
                            .keyboardShortcut(.cancelAction)
                    }
                    .padding(14)
                }
            }
            .sheet(isPresented: $shop.addingMachine) { MachineSheet(shop: shop, existing: nil) }
    }
}


/// The detail panel, the search field and the menu-bar plumbing.
///
/// ── THE SAME BUG AS `WindowSheets`, ONE LAYER IN ─────────────────────────
///
/// All three were chained onto the `NavigationSplitView`, so with the new
/// shell on — which is the default — selecting a model in the library
/// highlighted the tile and opened nothing, and the menu items that read a
/// focused value had nothing to read. The panel is where a job's dates, a
/// model's risk and a customer's history live; without it those are gone.
///
/// Unlike the sheets this is NOT applied to the whole window. A `.inspector`
/// on the shell's root would split the navy strip too, putting a panel beside
/// the title bar; it goes around the content region instead. The old shell
/// applies it exactly where it was — the note below about the split view
/// rather than `detail` is the reason, and it still holds.
///
/// The state stays in `ShopWindow` and arrives here as bindings, deliberately:
/// two shells with two copies of `panelIsOpen` is the same class of bug one
/// layer further down, and the deferral this chain performs was written
/// against a documented crash.
struct WindowPanels: ViewModifier {
    @Bindable var shop: Shop
    @Binding var showInspector: Bool
    @Binding var panelIsOpen: Bool
    @Binding var searchWanted: Bool
    /// Whether the screen in front of the shop has a panel at all.
    let wantsPanel: Bool
    let searchPrompt: String

    func body(content: Content) -> some View {
        content
            .onChange(of: wantsPanel, initial: true) { _, wanted in
                guard panelIsOpen != wanted else { return }
                Task { @MainActor in
                    var quietly = Transaction()
                    quietly.disablesAnimations = true
                    withTransaction(quietly) { panelIsOpen = wanted }
                }
            }
            .inspector(isPresented: Binding(
                get: { panelIsOpen && wantsPanel },
                set: { showInspector = $0; panelIsOpen = $0 && wantsPanel }
            )) {
                InspectorPane(shop: shop)
                    .inspectorColumnWidth(min: 260, ideal: 310, max: 420)
            }
            // ONLY WHERE IT NARROWS SOMETHING — see `Shop.canSearch`. This was
            // unconditional, so the calculator and the reports carried a search
            // field that could be typed into and did nothing.
            .modifier(SearchWhereItWorks(shop: shop, prompt: searchPrompt))
            .modifier(Reachable(shop: shop, showInspector: $showInspector,
                                searchWanted: $searchWanted))
    }
}


/// What the detail panel shows, whichever shell is holding it.
///
/// The two shells hold it differently and cannot share the holding: the old one
/// uses `.inspector`, which is a `NavigationSplitView` column and resizes the
/// WINDOW when it is applied anywhere else — tried, and the window came back
/// 310pt narrower with no panel in it. The new shell draws a trailing column of
/// its own, which is what §10's `Wide.inspector` describes anyway.
///
/// What they do share is this: the decision about which panel a screen gets,
/// and the screens that get none. A second copy of that list is how one shell
/// ends up showing a job's panel over a library.
struct InspectorPane: View {
    @Bindable var shop: Shop

    var body: some View {
        if shop.showingLibrary {
            LibraryInspector(shop: shop)
        } else if shop.showingCustomers {
            CustomerInspector(shop: shop)
        } else if Self.hasOwnDetail(shop) {
            // Both screens carry their own detail — a card and a table wide
            // enough to read. A panel beside them would repeat.
            EmptyView()
        } else {
            OrderInspector(shop: shop)
        }
    }

    /// The screens that carry their own detail and want no panel.
    static func hasOwnDetail(_ shop: Shop) -> Bool {
        shop.showingMachines || shop.showingInventory || shop.showingBoard
            || shop.showingExpenses || shop.showingWaste || shop.showingReports
            || shop.showingCatalogue || shop.showingColour || shop.showingPortfolio
            || shop.showingCalculator || shop.showingGiftCards
    }
}
