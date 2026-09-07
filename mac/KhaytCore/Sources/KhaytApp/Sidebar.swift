import SwiftUI

/// A source list: the pipeline, in the order a job moves through it.
///
/// Not alphabetical, and not "whatever statuses the data happens to contain".
/// The order comes from `lib/order-progress.js`, so the sidebar reads down the
/// way work actually flows — quotes at the top, delivered at the bottom.
struct Sidebar: View {
    @Bindable var shop: Shop

    var body: some View {
        List(selection: $shop.shelf) {
            Section {
                // First, and above the pipeline: it is the screen a shop opens
                // the app to look at.
                Row(title: shop.words.callIt("mac.dashboard"), symbol: "square.grid.2x2.fill",
                    count: shop.attention?.count ?? 0, selected: shop.shelf == .dashboard,
                    tint: Khayt.attention)
                    .tag(Shop.Shelf.dashboard)
                Row(title: shop.words.callIt("mac.all_jobs"), symbol: "tray.full", count: shop.orders.count,
                    selected: shop.shelf == .jobs(nil))
                    .tag(Shop.Shelf.jobs(nil))
            }
            Section(shop.words.callIt("mac.pipeline")) {
                Row(title: shop.words.callIt("mac.board"), symbol: "rectangle.split.3x1",
                    count: shop.orders.count { Stage.of($0).map { $0 != .delivered && $0 != .cancelled } ?? false },
                    selected: shop.shelf == .board)
                    .tag(Shop.Shelf.board)
                ForEach(Stage.allCases) { stage in
                    let n = shop.count(stage)
                    Row(title: shop.words.callIt(stage.key), symbol: stage.symbol, count: n,
                        selected: shop.shelf == .jobs(stage))
                        .tag(Shop.Shelf.jobs(stage))
                        // An empty stage stays visible and dimmed rather than
                        // disappearing: a sidebar that changes shape as work
                        // moves through it is a sidebar you cannot learn.
                        .foregroundStyle(n == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                }
            }
            // The floor: what the shop prints with and prints on.
            Section(shop.words.callIt("mac.the_floor")) {
                Row(title: shop.words.callIt("mac.machines"), symbol: "printer",
                    count: shop.machines.count, selected: shop.shelf == .machines)
                    .tag(Shop.Shelf.machines)
                Row(title: shop.words.callIt("mac.inventory"), symbol: "shippingbox",
                    count: shop.spools.count, selected: shop.shelf == .inventory)
                    .tag(Shop.Shelf.inventory)
                // Only for a shop that has one. A catalogue is a decision a
                // shop makes, not a screen everybody needs, and an empty row
                // on every launch is a row people stop seeing.
                if !shop.catalogueRows.isEmpty {
                    Row(title: shop.words.callIt("cat.title"), symbol: "tag",
                        count: shop.catalogueRows.count, selected: shop.shelf == .catalogue)
                        .tag(Shop.Shelf.catalogue)
                }
                // No count: "how many colours" is not a thing a shop has a
                // number of, and the row is about the spools listed above it.
                Row(title: shop.words.callIt("cmix.title"), symbol: "paintpalette",
                    count: nil, selected: shop.shelf == .colour)
                    .tag(Shop.Shelf.colour)
                // Cards a shop has issued. Unlike the portfolio below, the row
                // shows even at zero: this screen has an Issue button on it, so
                // an empty one is where you go to make the first card rather
                // than a dead end.
                Row(title: shop.words.callIt("giftCards"), symbol: "giftcard",
                    count: shop.giftCards.count, selected: shop.shelf == .giftCards)
                    .tag(Shop.Shelf.giftCards)
                // Only for a shop that has photographed something. A portfolio
                // with nothing in it is a row that teaches people the app has
                // an empty screen.
                if !shop.snapshots.isEmpty {
                    Row(title: shop.words.callIt("pf.title"), symbol: "photo.on.rectangle",
                        count: shop.snapshots.count, selected: shop.shelf == .portfolio)
                        .tag(Shop.Shelf.portfolio)
                }
            }
            // What the shop spends and what it throws away. Below the floor,
            // because both are read at the end of a month rather than during a
            // day's work.
            Section(shop.words.callIt("mac.money")) {
                Row(title: shop.words.callIt("mac.nav_expenses"), symbol: "creditcard",
                    count: shop.expenses.count, selected: shop.shelf == .expenses)
                    .tag(Shop.Shelf.expenses)
                Row(title: shop.words.callIt("mac.nav_waste"), symbol: "trash",
                    count: shop.wasteLog.count, selected: shop.shelf == .waste)
                    .tag(Shop.Shelf.waste)
                // No count: a quarter is not a thing a shop has a number of.
                Row(title: shop.words.callIt("mac.nav_reports"), symbol: "chart.bar.doc.horizontal",
                    count: nil, selected: shop.shelf == .reports)
                    .tag(Shop.Shelf.reports)
            }
            Section(shop.words.callIt("mac.people")) {
                Row(title: shop.words.callIt("tab.clients"), symbol: "person.2", count: shop.customers.count,
                    selected: shop.shelf == .customers)
                    .tag(Shop.Shelf.customers)
            }
            // The models, below the work. A group is a set that belongs
            // together — the seven Saudi Kings, offered as one collection —
            // so the groups a shop has actually made are named here rather
            // than hidden behind a filter menu.
            Section(shop.words.callIt("mac.library")) {
                Row(title: shop.words.callIt("mac.all_models"), symbol: "square.grid.2x2", count: shop.files.count,
                    selected: shop.shelf == .library(nil))
                    .tag(Shop.Shelf.library(nil))
                ForEach(shop.groups, id: \.self) { group in
                    Row(title: group, symbol: "square.stack", count: shop.count(group: group),
                        selected: shop.shelf == .library(group))
                        .tag(Shop.Shelf.library(group))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { Provenance(shop: shop) }
    }

    private struct Row: View {
        let title: String
        let symbol: String
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

        var body: some View {
            HStack {
                // Deliberately NOT tinted when selected. A macOS sidebar draws
                // its own selection as a filled accent rounded rect with white
                // content on it; a colour set here would be that colour on top
                // of the accent fill, which is the one place in the app where
                // the palette cannot be checked — the snapshot runner captures
                // this pane as a vibrancy alpha mask, so every pixel comes back
                // black and no screenshot could show the mistake.
                Label(title, systemImage: symbol)
                Spacer(minLength: 8)
                if let count {
                    // The coloured badge stands down on the selected row, for
                    // the same reason the label above is not tinted: that row
                    // is a filled accent rectangle and amber on it is a guess
                    // nobody can check. Nothing is lost — the badge says "there
                    // is something over there", and you are already there.
                    if let tint, count > 0, !selected {
                        Chip(text: "\(count)", tint: tint)
                    } else {
                        Text("\(count)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    }
                }
            }
        }
    }
}

/// Where these figures came from, at the foot of the sidebar.
///
/// A read-only app that opens someone else's file has to say which file, and
/// whether anything in it was skipped. "The list looks short today" is not a
/// thing a shop should be left to notice on its own.
private struct Provenance: View {

    /// One line for every state sync can be in.
    ///
    /// Locked is the one worth reading twice: it is not a fault, it is a shop
    /// that has not typed its passphrase since the app opened, and the data key
    /// deliberately lives no longer than that.
    static func syncLine(_ shop: Shop) -> (String, String, AnyShapeStyle) {
        switch shop.syncStatus {
        case .off:
            return (shop.words.callIt("mac.sync_off"), "icloud.slash", AnyShapeStyle(.tertiary))
        case .locked:
            return (shop.words.callIt("mac.sync_locked"), "lock.icloud", AnyShapeStyle(.secondary))
        case .idle:
            return (shop.words.callIt("mac.sync_on"), "icloud", AnyShapeStyle(.tertiary))
        case .syncing:
            return (shop.words.callIt("mac.sync_sending"), "icloud.and.arrow.up",
                    AnyShapeStyle(.secondary))
        case .waiting:
            return (shop.words.callIt("mac.sync_waiting"), "clock.arrow.circlepath",
                    AnyShapeStyle(.tertiary))
        case .synced(let when):
            return (shop.words.callIt("mac.sync_done", ["time": .string(Self.clock(when))]),
                    "checkmark.icloud", AnyShapeStyle(.tertiary))
        case .failing:
            // `attention`, not `late`: it is going to be tried again and
            // nothing has been lost — the change is still in the book. Those
            // two colours are the difference between "this needs you when you
            // have a moment" and "this has failed".
            return (shop.words.callIt("mac.sync_retrying"), "exclamationmark.icloud",
                    AnyShapeStyle(Khayt.attention))
        }
    }

    /// The time of day, in the shop's own locale.
    static func clock(_ when: Date) -> String {
        when.formatted(date: .omitted, time: .shortened)
    }

    let shop: Shop

    private var footerLabel: String {
        guard shop.source.isReal else { return shop.words.callIt("mac.sample") }
        return shop.words.callIt(shop.canWrite ? "mac.writable" : "mac.read_only")
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
            } else if let day = shop.lastBackup {
                // Quiet, and always there. A shop should be able to answer
                // "when was this last backed up" by looking, not by trusting.
                Label(shop.words.callIt("set.last_backup") + " " + day, systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(.tertiary).font(.caption).lineLimit(1)
            }
            // Only for a book that expects to be in step with somewhere else.
            // A shop that has never connected to the cloud is not missing
            // anything, and a line telling it so is a line people stop reading.
            // This line used to read "Not synced automatically" and never
            // changed. It is now what sync is actually doing, because the
            // sentence it replaced was a standing apology rather than a status.
            if shop.cloudConnected {
                let (text, symbol, tint) = Self.syncLine(shop)
                Label(text, systemImage: symbol)
                    .foregroundStyle(tint).font(.caption).lineLimit(1)
                    .help(shop.words.callIt("mac.sync_auto_why"))
            }
            // What the app said as it died last time. One line, like every
            // other line here; the reason is in the tooltip, and clicking it
            // says it has been read.
            if shop.lastCrash != nil {
                Label(shop.words.callIt("mac.last_crash"), systemImage: "exclamationmark.bubble")
                    .foregroundStyle(Khayt.attention).font(.caption).lineLimit(1)
                    .help(shop.lastCrash ?? "")
                    .onTapGesture { shop.forgetLastCrash() }
            }
            if let engineProblem = shop.engineProblem {
                // Above everything, in the one place that is on every screen.
                Label(shop.words.callIt("mac.engine_failed"), systemImage: "exclamationmark.octagon")
                    .foregroundStyle(Khayt.attention)
                    .font(.caption)
                    .lineLimit(1)
                    .help(engineProblem)
            }
            Label(footerLabel, systemImage: footerSymbol).lineLimit(1)
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
