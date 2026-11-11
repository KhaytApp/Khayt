import SwiftUI

/// A source list: the pipeline, in the order a job moves through it.
///
/// Not alphabetical, and not "whatever statuses the data happens to contain".
/// The order comes from `lib/order-progress.js`, so the sidebar reads down the
/// way work actually flows — quotes at the top, delivered at the bottom.
struct Sidebar: View {
    @Bindable var shop: Shop
    /// "More" opened by hand, remembered per window.
    @SceneStorage("sidebar.more") private var showMore = false
    @SceneStorage("sidebar.library") private var showLibrary = false

    var body: some View {
        // NOTHING behind the lock: the shelves' counts, the pipeline's stage
        // totals and the library's group names are the book, and the classic
        // sidebar showed them beside the sign-in screen (alpha.62 re-check,
        // round 3). The new shell's rows are inert and countless the same way.
        if shop.needsSignIn {
            List { EmptyView() }
        } else {
            shelves
        }
    }

    /// The eyebrow over a group: small, monospaced, tracked, in the secondary
    /// ink. No rule or dash beside it — the grouping is the spacing.
    ///
    /// Tracking is off in Arabic: spacing out joined letters pulls a word apart
    /// into its isolated forms, which is a different (and unreadable) word.
    private func eyebrow(_ key: String) -> some View {
        Text(shop.words.callIt(key))
            .font(TypeScale.eyebrow(10))
            .tracking(shop.words.isRTL ? 0 : 1.2)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }

    /// Waste, the portfolio, gift cards and the colour studio sit behind
    /// "More". Open by itself when the screen you are on is inside it, so the
    /// selected row is never hidden.
    private var moreShelves: [Shop.Shelf] { [.waste, .portfolio, .giftCards, .colour] }

    private var shelves: some View {
        List(selection: $shop.shelf) {
            Section {
                // Which site, first: the classic sidebar had no picker, so a
                // shop on it could not narrow, and the banners on its screens
                // only ever offered the way back (alpha.61 review). Untagged,
                // so it is never a selectable row.
                SitePicker(shop: shop)
                SignedInRow(shop: shop)
            }
            // ── SHOP: what it sells ───────────────────────────────────
            Section {
                // First, and above the pipeline: it is the screen a shop opens
                // the app to look at.
                // Nothing at all when nothing needs a person, rather than a
                // "0". Every other count here is how many things a screen
                // lists; this one is how much is WRONG, and no news is not a
                // quantity worth printing. Seen in the running app — the row
                // read "Dashboard 0" on a book with nothing late, which is the
                // same thing that made Colour Studio look unfinished.
                Row(title: shop.words.callIt("mac.nav_today"), mark: .dashboard,
                    count: shop.attention.map(\.count).flatMap { $0 == 0 ? nil : $0 },
                    selected: shop.shelf == .dashboard,
                    tint: Khayt.attention)
                    .tag(Shop.Shelf.dashboard)
                // ONE ROW FOR JOBS AND THE BOARD. Board / List is a choice in
                // the toolbar of this screen (`JobsLayoutPicker`), and the
                // pipeline's stage rows are the table's own stage filter, so
                // neither is a place of its own to go to.
                Row(title: shop.words.callIt("mac.all_jobs"), mark: .jobs,
                    count: shop.orders.count(where: shop.inSite),
                    selected: shop.shelf.sameScreen(as: .jobs(nil)))
                    .tag(Shop.Shelf.jobs(nil))
                // The models, below the work, with the saved searches and the
                // groups folded under them. Folded by default: a Drive library
                // turns every folder into a group, and beta.18 drew all several
                // hundred of them open under Library with no way to close it.
                DisclosureGroup(isExpanded: libraryOpen) {
                    ClassicSmartFolderRows(shop: shop)  // saved searches
                    ForEach(shop.groups, id: \.self) { group in
                        Row(title: group, symbol: "square.stack", count: shop.count(group: group),
                            selected: shop.shelf == .library(group))
                            .tag(Shop.Shelf.library(group))
                    }
                } label: {
                    // What All models shows: an archived model is still in the
                    // book but not on the shelf, and counting it made the row
                    // say 14,343 over a screen of 14,307 (beta.19 review).
                    Row(title: shop.words.callIt("mac.all_models"), mark: .library,
                        count: shop.files.count { !$0.isArchived },
                        selected: shop.shelf.sameScreen(as: .library(nil)))
                        .tag(Shop.Shelf.library(nil))
                }
                // Only for a shop that has one. A catalogue is a decision a
                // shop makes, not a screen everybody needs, and an empty row
                // on every launch is a row people stop seeing.
                if !shop.catalogueRows.isEmpty {
                    Row(title: shop.words.callIt("cat.title"), mark: .catalogue,
                        count: shop.catalogueRows.count, selected: shop.shelf == .catalogue)
                        .tag(Shop.Shelf.catalogue)
                }
                if shop.canShow(.customers) {
                    Row(title: shop.words.callIt("tab.clients"), mark: .clients, count: shop.customers.count,
                        selected: shop.shelf == .customers)
                        .tag(Shop.Shelf.customers)
                }
            } header: { eyebrow("mac.group_shop") }
            // ── FLOOR: what the shop prints with and prints on ────────
            Section {
                Row(title: shop.words.callIt("mac.machines"), mark: .machines,
                    count: shop.machinesInUse.count, selected: shop.shelf == .machines,
                    live: shop.anySiteMachineRunning)
                    .tag(Shop.Shelf.machines)
                // A low-stock count replaces the total while there is one: the
                // total is on the screen, and "2 low" is news.
                let low = shop.lowSpools.count
                Row(title: shop.words.callIt("mac.inventory"), mark: .filament,
                    count: low > 0 ? low : shop.spools.count, selected: shop.shelf == .inventory,
                    tint: low > 0 ? Khayt.late : nil)
                    .tag(Shop.Shelf.inventory)
                // ── WHAT THE SHOP'S MODE INCLUDES ─────────────────────
                //
                // Expense tracking and full analytics are Professional features in
                // `lib/feature-tiers.js`, and the other app hides both from a
                // Simple shop. This one showed them to everybody, which is two
                // apps disagreeing about what a shop has.
                if shop.has("expenses") {
                    Row(title: shop.words.callIt("mac.nav_expenses"), mark: .expenses,
                        count: shop.expenses.count, selected: shop.shelf == .expenses)
                        .tag(Shop.Shelf.expenses)
                }
            } header: { eyebrow("mac.group_floor") }
            // ── MONEY: what it is worth ───────────────────────────────
            Section {
                // No count: a quarter is not a thing a shop has a number of.
                if shop.canShow(.reports) {
                    Row(title: shop.words.callIt("mac.nav_reports"), mark: .reports,
                        count: nil, selected: shop.shelf == .reports)
                        .tag(Shop.Shelf.reports)
                }
                // No count: "how many quotes" is not a thing a shop has a
                // number of, and this screen keeps nothing.
                Row(title: shop.words.callIt("mac.calc_title"), mark: .calculator,
                    count: nil, selected: shop.shelf == .calculator)
                    .tag(Shop.Shelf.calculator)
                DisclosureGroup(isExpanded: moreOpen) {
                    Row(title: shop.words.callIt("mac.nav_waste"), mark: .waste,
                        count: shop.wasteLog.count, selected: shop.shelf == .waste)
                        .tag(Shop.Shelf.waste)
                    // Only for a shop that has photographed something. A
                    // portfolio with nothing in it is a row that teaches people
                    // the app has an empty screen.
                    if !shop.snapshots.isEmpty {
                        Row(title: shop.words.callIt("pf.title"), mark: .portfolio,
                            count: shop.snapshots.count, selected: shop.shelf == .portfolio)
                            .tag(Shop.Shelf.portfolio)
                    }
                    // Unlike the portfolio, shown even at zero: this screen has
                    // an Issue button on it, so an empty one is where you go
                    // to make the first card rather than a dead end.
                    Row(title: shop.words.callIt("giftCards"), mark: .giftCards,
                        count: shop.giftCards.count, selected: shop.shelf == .giftCards)
                        .tag(Shop.Shelf.giftCards)
                    Row(title: shop.words.callIt("cmix.title"), mark: .colour,
                        count: nil, selected: shop.shelf == .colour)
                        .tag(Shop.Shelf.colour)
                } label: {
                    Text(shop.words.callIt("mac.nav_more"))
                }
            } header: { eyebrow("mac.group_money") }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { ShopCard(shop: shop) }
        .safeAreaInset(edge: .bottom) { Provenance(shop: shop) }
    }

    /// Open when asked, and open whenever the current screen is inside it.
    /// Opened by hand, or because a group in it is the screen showing.
    private var libraryOpen: Binding<Bool> {
        Binding(
            get: {
                if showLibrary { return true }
                if case .library(let group?) = shop.shelf { return shop.groups.contains(group) }
                return false
            },
            set: { showLibrary = $0 }
        )
    }

    private var moreOpen: Binding<Bool> {
        Binding(
            get: { showMore || moreShelves.contains(shop.shelf) },
            set: { showMore = $0 }
        )
    }

    private struct Row: View {
        let title: String
        /// A mark this app draws. Nil on the pipeline stages, which still wear
        /// Apple's — a stage is a state of work, not an object on the floor,
        /// and drawing eight of those is a different piece of work from
        /// drawing the shelves.
        var mark: Mark?
        /// A stage, said with a dot in its own colour. Sub-rows do not carry
        /// the same weight of mark as the shelves they sit under.
        var dot: Color?
        var symbol: String = ""
        /// How many, or nil where the row is not a count of anything.
        ///
        /// This was an `Int` and three call sites passed 0 to mean "no count",
        /// each with a comment saying so — and the row drew "0" anyway. Colour
        /// Studio and Reports have shown a literal zero next to them ever
        /// since, which reads as an empty screen rather than as a screen that
        /// is not a list.
        let count: Int?
        let selected: Bool
        /// The colour of the count, where the count is news. Only the
        /// dashboard's is: it is how many things want a person today.
        var tint: Color?
        /// Something is running on this screen right now: a dot in the live
        /// colour before the count.
        var live = false
        @Environment(\.accessibilityReduceMotion) private var reduced
        /// `.increased` while the system draws the selection FILLED in the
        /// accent (the sidebar has focus). Its text is white then; forcing the
        /// brand blue on top of a blue capsule made the selected row unreadable
        /// (beta.19, every screen, whenever the sidebar was clicked).
        @Environment(\.backgroundProminence) private var prominence

        /// The brand ink on a quiet selection, the system's own on a filled one.
        private var ink: AnyShapeStyle {
            selected && prominence != .increased ? AnyShapeStyle(Khayt.brand) : AnyShapeStyle(.primary)
        }

        var body: some View {
            HStack {
                // The selected row's icon and label take the brand colour; the
                // system draws the selection itself (an inset glass capsule on
                // macOS 26) and this is the only ink the app adds to it.
                // The app's own mark where it has one. `Label` is kept for the
                // group rows, so the two kinds of row still line up: a drawn
                // mark is given the same 16pt box a symbol takes.
                if let mark {
                    HStack(spacing: 6) {
                        Drawn(mark: mark, size: 16).frame(width: 18, alignment: .center)
                        Text(title)
                    }
                    .foregroundStyle(ink)
                } else if let dot {
                    HStack(spacing: 6) {
                        Circle().fill(dot).frame(width: 6, height: 6)
                            .frame(width: 18, alignment: .center)
                        Text(title)
                    }
                } else {
                    Label(title, systemImage: symbol)
                        .foregroundStyle(ink)
                }
                Spacer(minLength: 8)
                if live {
                    Circle().fill(Khayt.thread).frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
                if let count {
                    // The coloured badge stands down on the selected row: it says
                    // "there is something over there", and you are already there.
                    if let tint, count > 0, !selected {
                        Chip(text: "\(count)", tint: tint)
                    } else {
                        Text("\(count)")
                            .font(.caption)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    }
                }
            }
            // THE COUNT CHANGES AT THE MOMENT THE CARD MOVES.
            //
            // Moving a job along changes a stage count here in the same frame
            // the card lands in its new column. The card travels and the
            // number beside it jumped — two halves of one reading disagreeing,
            // which is the fault the running-print percentage had between the
            // dashboard and the floor strip.
            .animation(Motion.of(Motion.figure, unless: reduced), value: count)
        }
    }
}

/// Which shop this is, at the top of the sidebar — and the switch between
/// books.
///
/// A 32pt navy tile with the nozzle mark, the shop's name, and what is in it.
/// It is the menu the window's toolbar used to carry (the source of the book,
/// and Lock now while the operator lock is on), moved to where the shop's name
/// already is. Mistaking the sample for the shop's real position is the one
/// error this app must not allow, so when the book is not the shop's own the
/// card says which it is.
///
/// Every line is one line: this is the sidebar's top inset, and a height that
/// depended on the column's width is the loop `Provenance` explains.
private struct ShopCard: View {
    let shop: Shop

    var body: some View {
        if shop.needsSignIn {
            EmptyView()
        } else {
            Menu {
                if shop.lockInForce, shop.signedIn != nil {
                    Button {
                        shop.lockNow()
                    } label: {
                        Label(shop.words.callIt("mac.lock_now"), systemImage: "lock")
                    }
                    Divider()
                }
                ForEach(Shop.available) { source in
                    Button {
                        Task { await shop.load(source) }
                    } label: {
                        Label(source.title(shop.words), systemImage: source.symbol)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Drawn(mark: .nozzle, size: 18)
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Khayt.navy, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(shop.shopName).font(.headline).lineLimit(1)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .help(shop.source.title(shop.words))
        }
    }

    /// "5 machines · 12 people", with the book's source in front of it when it
    /// is not the shop's own.
    private var subtitle: String {
        let counts = shop.words.counting(shop.machinesInUse.count, "mac.n_machines")
            + " \u{00B7} " + shop.words.counting(shop.customers.count, "mac.n_people")
        return shop.source.isReal ? counts : shop.source.title(shop.words) + " \u{00B7} " + counts
    }
}

/// Where these figures came from, at the foot of the sidebar.
///
/// A read-only app that opens someone else's file has to say which file, and
/// whether anything in it was skipped. "The list looks short today" is not a
/// thing a shop should be left to notice on its own.
private struct Provenance: View {

    // `syncLine` moved to `Shop.syncLine` — the shipping shell needs the
    // same sentence, and two copies of "what sync is doing" is how the two
    // windows start telling a shop different things. The model returns a TONE;
    // this window's own styling stays here.
    static func tint(_ tone: Shop.SyncTone) -> AnyShapeStyle {
        switch tone {
        case .quiet: AnyShapeStyle(Khayt.faint)
        case .normal: AnyShapeStyle(.secondary)
        case .attention: AnyShapeStyle(Khayt.attention)
        }
    }

    let shop: Shop

    private var footerLabel: String {
        guard shop.source.isReal else { return shop.words.callIt("mac.sample") }
        return shop.words.callIt(shop.canWrite ? "mac.writable" : "mac.read_only")
    }
    /// Green when the book is as safe as it can be told to be; amber when sync
    /// wants a person.
    private var saveDot: Color {
        if shop.cloudConnected, shop.syncLine.tone == .attention { return Khayt.attention }
        return Khayt.live
    }
    private var saveHelp: String {
        var lines: [String] = []
        lines.append(shop.lastSavedLabel)
        lines.append(shop.words.callIt("mac.book") + " " + shop.bookFileName)
        lines.append(shop.words.callIt("mac.sync_auto_why"))
        return lines.joined(separator: "\n")
    }
    private var footerSymbol: String {
        guard shop.source.isReal else { return "theatermasks" }
        return shop.canWrite ? "pencil" : "lock"
    }

    /// EVERY LINE HERE IS ONE LINE, and that is a layout rule rather than a
    /// taste.
    ///
    /// This view is the sidebar's `.safeAreaInset(edge: .bottom)`, and the
    /// sidebar is a RESIZABLE SPLIT-VIEW COLUMN. A label allowed to wrap makes
    /// this view's HEIGHT depend on the column's WIDTH — and a child whose
    /// size depends on the size it is given is a feedback loop with
    /// `SplitViewChildController.hostingView(_:didUpdateMinSize:maxSize:)`.
    /// AppKit ends that loop by throwing out of
    /// `_postWindowNeedsUpdateConstraints`, which is an abort with no reason
    /// attached to it.
    ///
    /// It happened: a two-line "changes here reach the cloud…" shipped in
    /// #997, showed only for a cloud-connected book — so never on the sample
    /// this app photographs — and took the app down after a minute or two of
    /// ordinary use. Long text goes in `.help`, where its length costs nothing.
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            if let tax = shop.taxSummary {
                // Capped like every other line here. "VAT 15.00% included in
                // the price" is thirty-one characters and this column is
                // resizable, so without this its height depends on the width.
                Label(tax, systemImage: "percent").lineLimit(1).help(tax)
            }
            if shop.productionPaused {
                // THE ONE NOTICE THAT IS ALSO A DEAD END. The shared rule
                // refuses a move to printing while this is set, so the notice
                // says the floor is stopped and tapping it starts it again.
                Label(shop.pauseReason.isEmpty
                        ? shop.words.callIt("prod.paused_banner")
                        : shop.words.callIt("prod.paused_banner") + " \u{2014} " + shop.pauseReason,
                      systemImage: "pause.circle")
                    .foregroundStyle(Khayt.attention).lineLimit(1)
                    .help(shop.words.callIt("prod.resume"))
                    .onTapGesture { Task { await shop.resumeProduction() } }
            }
            if !shop.skipped.isEmpty {
                Label(shop.words.callIt("mac.unreadable_records",
                                        ["n": .number(Double(shop.skipped.count))]),
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Khayt.attention)
                    .lineLimit(1)
                    .help(shop.skipped.prefix(8).joined(separator: "\n"))
            }
            if let backupProblem = shop.backupProblem {
                Label(shop.words.callIt("mac.backup_failed"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Khayt.attention).font(.caption).lineLimit(1)
                    .help(backupProblem)
            }
            // What the app said as it died last time. One line, like every
            // other line here; the reason is in the tooltip, and clicking it
            // says it has been read.
            if shop.lastCrash != nil {
                Label(shop.words.callIt("mac.last_crash"), systemImage: "exclamationmark.bubble")
                    .foregroundStyle(Khayt.attention).font(.caption).lineLimit(1)
                    .help(shop.lastCrash ?? "")
                    .onTapGesture { shop.forgetLastCrash() }
                    // A crash is what a report is for — see `Feedback`. Not
                    // from behind the lock: a report can carry the book.
                    .contextMenu {
                        Button(shop.words.callIt("mac.feedback_menu")) { shop.askForFeedback() }
                            .disabled(shop.needsSignIn)
                    }
            }
            if let engineProblem = shop.engineProblem {
                // Above everything, in the one place that is on every screen.
                Label(shop.words.callIt("mac.engine_failed"), systemImage: "exclamationmark.octagon")
                    .foregroundStyle(Khayt.attention)
                    .font(.caption)
                    .lineLimit(1)
                    .help(engineProblem)
            }
            // SAVED, AND WHERE. A green dot, the word, and what the book is
            // saved to — the cloud's own sentence for a connected book, which
            // says what sync is doing and carries the tone (amber when it needs
            // a person), and otherwise whether this book can be written to.
            // The backup date is the tooltip: "when" is for the curious, and
            // "is it safe" is the dot.
            if shop.backupProblem == nil {
                HStack(spacing: 6) {
                    Circle().fill(saveDot).frame(width: 7, height: 7)
                    Text(shop.words.callIt("mac.nav_saved"))
                        .foregroundStyle(.primary).lineLimit(1)
                    Text(shop.cloudConnected ? shop.syncLine.text : footerLabel)
                        .foregroundStyle(shop.cloudConnected ? Self.tint(shop.syncLine.tone) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .help(saveHelp)
                .contentShape(Rectangle())
                // Where people look for the cloud, so it is where the cloud can
                // be handled: a click unlocks it (or checks it once it is
                // unlocked), and a right-click has every cloud action.
                .onTapGesture {
                    // The cloud is the owner's (`cloud` in lib/rbac.js).
                    guard shop.cloudConnected, shop.lockAllows("cloud", "edit") else { return }
                    if shop.cloudUnlocked { shop.checkingCloud = true } else { shop.signingIntoCloud = true }
                }
                .contextMenu {
                    if shop.cloudConnected {
                        Button(shop.words.callIt("mac.cloud_sign_in") + "\u{2026}") { shop.signingIntoCloud = true }
                        Button(shop.words.callIt("mac.check_cloud") + "\u{2026}") { shop.checkingCloud = true }
                        Button(shop.words.callIt("mac.lock_cloud")) { shop.forgetCloudKey() }
                            .disabled(!shop.cloudUnlocked)
                        Divider()
                        Button(shop.words.callIt("mac.cloud_sign_out") + "\u{2026}") { shop.confirmingSignOut = true }
                    }
                }
                .disabled(shop.cloudConnected && !shop.lockAllows("cloud", "edit"))
            }
            // The book's mode, on its own line where the line above is busy
            // saying something else (the cloud's state, or a failed backup).
            if shop.cloudConnected {
                Label(footerLabel, systemImage: footerSymbol).lineLimit(1)
            } else if shop.backupProblem != nil {
                Label(footerLabel, systemImage: footerSymbol).lineLimit(1)
            }
            // Who else has it open. Only shown when somebody does — a line that
            // says "nobody else is using this" on every ordinary launch is a
            // line people stop reading.
            if let owner = shop.owner {
                // The riskiest line here: this is another process's name, and
                // nothing bounds how long one of those is.
                Label(owner, systemImage: "person.badge.key")
                    .lineLimit(1).truncationMode(.middle)
                    .help(owner + "\n\n" + shop.words.callIt("mac.lock_why"))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        // A GROUND UNDER IT, and it is not decoration.
        //
        // This is the sidebar's `.safeAreaInset(edge: .bottom)`, so the list
        // scrolls UNDER it — that is what the inset is for. With nothing behind
        // it, the rows that pass beneath show through: an Arabic sample shop,
        // whose list is a few rows longer than the window, drew "الأشخاص" and
        // "Waste" straight across "Opened read-only" and the backup date. Six
        // lines of two different things in the same place.
        //
        // `.bar` is the material AppKit puts under a bottom accessory bar, so
        // it stays in step with the sidebar's own translucency rather than
        // painting a flat panel into it.
        .background(.bar)
    }
}
