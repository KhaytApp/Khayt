import SwiftUI

/// The menu bar.
///
/// Everything this app can do is here, with a key for it. A menu you have to
/// know is there is a feature for the person who wrote it — and on a Mac the
/// menu bar is the one surface where a person can go looking for what an app
/// does without having to guess which thing is right-clickable.
///
/// ── THE ITEMS ARE VIEWS, AND THE SHOP IS HANDED TO THEM ─────────────────────
///
/// Two problems, and the fix for the second is what fixes the first.
///
/// A `Commands` body does not re-run when an `@Observable` it read changes, so
/// items built straight into `Commands` freeze in whatever enabled state they
/// had at launch. The developer forums' answer is to put the items in a `View`,
/// and that is right: a View body does re-run.
///
/// `focusedSceneValue` / `@FocusedValue` is the documented way to tell those
/// views WHICH shop to act on, and it delivers nil here. Tried under `Window`
/// and under `WindowGroup`, declared with `@Entry` and with an explicit
/// `FocusedValueKey`, read from a `Commands` type and from a `View`. Nil every
/// time — visible structurally, because the Book menu's picker is inside an
/// `if let shop` and simply is not built.
///
/// So the shop is handed down. This app has one window and one book; the
/// indirection would start paying for itself at the second window, and can be
/// put back then.
struct KhaytCommands: Commands {
    let shop: Shop

    var body: some Commands {
        // ⌘N takes a job. It IS the new-document gesture for this app: the
        // thing a shop makes is an order, and the File menu is where a Mac user
        // looks for "new".
        CommandGroup(replacing: .newItem) { NewJobCommand().environment(shop) }

        CommandGroup(replacing: .appInfo) {
            Button(shop.words.callIt("mac.about_khayt")) { About.show() }
        }

        // Into the View menu AppKit already puts there, beside Show Sidebar,
        // rather than a menu of our own: a shop looking for how a list is
        // ordered looks under View.
        CommandGroup(after: .sidebar) {
            DetailsCommand()
            Divider()
            SortMenu().environment(shop)
        }

        // Find, where every Mac app keeps it. `.searchable` puts the field in
        // the toolbar and wires nothing to it — a search box you can only reach
        // with the mouse is a search box in the wrong app.
        CommandGroup(after: .pasteboard) {
            Divider()
            FindCommand()
        }

        // `Words.upfront`, not `shop.words`: these titles are built with the
        // scene, before a book is open, and a menu title is never rewritten
        // afterwards. The catalogue is already warm — see `Words.preload`.
        CommandMenu(Text(Words.upfront("mac.menu_book"))) { BookMenu().environment(shop) }
        CommandMenu(Text(Words.upfront("mac.menu_go"))) { GoMenu().environment(shop) }
        CommandMenu(Text(Words.upfront("mac.menu_job"))) { JobMenu().environment(shop) }
        CommandMenu(Text(Words.upfront("mac.menu_model"))) { ModelMenu().environment(shop) }
    }
}

/// Show or hide the details pane.
///
/// ⌥⌘I, which is where macOS puts an inspector. The state belongs to the
/// window, so this reads it through the focused scene value and disables itself
/// when there is no window — rather than being a live menu item that does
/// nothing.
private struct DetailsCommand: View {
    @FocusedValue(\.inspectorShowing) private var showing

    var body: some View {
        Button(Words.upfront(showing?.wrappedValue == false ? "mac.show_details" : "mac.hide_details")) {
            showing?.wrappedValue.toggle()
        }
        .keyboardShortcut("i", modifiers: [.option, .command])
        .disabled(showing == nil)
    }
}

/// ⌘F puts the caret in the toolbar's search field.
private struct FindCommand: View {
    @FocusedValue(\.searchWanted) private var wanted

    var body: some View {
        Button(Words.upfront("mac.find")) { wanted?.wrappedValue = true }
            .keyboardShortcut("f")
            // Enabled wherever a screen offers a search field. It used to be
            // switched off on macOS 14 as well, because `searchFocused` arrived
            // in 15 and there was no way to move focus into a `.searchable`
            // field before it — so ⌘F was a menu item that could not work. The
            // app's floor is 26 now and it always can.
            .disabled(wanted == nil)
    }
}

/// Each menu's items, as a View so the focused value arrives and the enabled
/// state keeps up. See the note on `KhaytCommands`.
private struct BookMenu: View {
    @Environment(Shop.self) private var shop

    var body: some View {
        Button(Words.upfront("mac.reload")) { shop.reload() }
            .keyboardShortcut("r")
            
        Divider()
        // A backup is taken once a day on its own; this is for the shop that
        // is about to do something it might want to undo.
        Button(Words.upfront("mac.back_up_now")) {
            Task { await shop.backUpNow() }
        }
        .disabled(!shop.canMoveJobs)
        Button(Words.upfront("mac.reveal_backups")) { shop.revealBackups() }
            .disabled(shop.source.build == nil)
        // The other half of a backup. Listed rather than opened through a file
        // picker: the backups a shop should be choosing between are the ones in
        // its own folder, and a picker invites choosing something else.
        Menu(Words.upfront("mac.restore_backup")) {
            let shelf = Array(shop.restorable.prefix(12))
            if shelf.isEmpty {
                Text(Words.upfront("mac.restore_none"))
            } else {
                ForEach(shelf) { backup in
                    Button(backup.filename) { shop.restoring = backup }
                }
            }
        }
        .disabled(!shop.canMoveJobs)
        // Not a backup, and named so nobody reaches for it as one: this is the
        // copy that leaves, and it has had the shop's credentials taken out.
        // Read only — it counts the difference and sends nothing.
        // Adding models. In the File menu with the other things that bring
        // something into the book, and disabled while one is running — a second
        // panel over a running import is two records for one file.
        Button(Words.upfront("mac.add_model") + "\u{2026}") {
            Task { await shop.addModelToLibrary() }
        }
        .disabled(!shop.canMoveJobs || shop.importing)
        .keyboardShortcut("i", modifiers: [.command, .shift])

        // The whole rack, from the menu; one spool from its own context menu on
        // the shelf. Not a write, so it does not wait on `canMoveJobs` — a
        // read-only book can still print labels for the rack it describes —
        // but an empty shelf has nothing to label.
        Button(Words.upfront("mac.print_labels")) {
            Task { await shop.askForShelfLabels() }
        }
        .disabled(shop.spools.isEmpty)

        Button(Words.upfront("mac.check_cloud") + "\u{2026}") { shop.checkingCloud = true }
            .disabled(!shop.cloudConnected)
        // The way back out of automatic sync, and the only one there is.
        //
        // The data key is held for the life of the app so pushes can happen in
        // the background; a shop leaving a Mac somewhere it does not control
        // needs to be able to take it away again without quitting. Disabled
        // rather than hidden when nothing is unlocked, so the item teaches what
        // it does before it is ever needed.
        Button(Words.upfront("mac.lock_cloud")) { shop.forgetCloudKey() }
            .disabled(!shop.cloudUnlocked)
        Button(Words.upfront("mac.export_copy")) {
            Task { await shop.exportForSharing() }
        }
        .disabled(shop.source.build == nil)
        // One item per accounting package, rather than a format picker in a
        // sheet. A shop uses one of these and uses it every quarter; the
        // choice is a property of the shop, not a question to be asked each
        // time, and a submenu remembers nothing but costs nothing either.
        Menu(Words.upfront("mac.export_accounting")) {
            ForEach(Shop.accountingFormats, id: \.0) { key, name in
                Button(name) { Task { await shop.exportForAccounting(format: key) } }
            }
        }
        .disabled(shop.orders.isEmpty && shop.expenses.isEmpty)

        Divider()
        Picker(Words.upfront("mac.open_book"), selection: Binding(get: { shop.source }, set: { shop.open($0) })) {
            ForEach(Shop.available) { Text($0.title(shop.words)).tag($0) }
        }
    }
}

private struct GoMenu: View {
    @Environment(Shop.self) private var shop

    var body: some View {
        Button(Words.upfront("mac.dashboard")) { shop.shelf = .dashboard }
            .keyboardShortcut("1", modifiers: .command)
        Button(Words.upfront("mac.all_jobs")) { shop.shelf = .jobs(nil) }
            .keyboardShortcut("2", modifiers: .command)
            
        Button(Words.upfront("mac.board")) { shop.shelf = .board }
            .keyboardShortcut("7", modifiers: .command)
        Button(Words.upfront("mac.customers")) { shop.shelf = .customers }
            .keyboardShortcut("3", modifiers: .command)
            
        Button(Words.upfront("mac.library")) { shop.shelf = .library(nil) }
            .keyboardShortcut("4", modifiers: .command)
        Button(Words.upfront("mac.machines")) { shop.shelf = .machines }
            .keyboardShortcut("5", modifiers: .command)
        Button(Words.upfront("mac.inventory")) { shop.shelf = .inventory }
            .keyboardShortcut("8", modifiers: .command)
        Button(Words.upfront("cat.title")) { shop.shelf = .catalogue }
            .keyboardShortcut("6", modifiers: .command)
        // ⇧⌘K, not a digit: ⌘0 through ⌘9 are all taken, and SwiftUI does not
        // warn about a clash — it drops the shortcut on the second claimant, so
        // adding a second ⌘9 here would have quietly cost Expenses its key and
        // given this nothing. Checked the whole app's shortcuts rather than
        // guessing at a free one.
        Button(Words.upfront("mac.calc_title")) { shop.shelf = .calculator }
            .keyboardShortcut("k", modifiers: [.command, .shift])

        Divider()
        // Three screens the sidebar has always had and this menu never listed,
        // so the only way to reach them was to click. "Use the menu bar to give
        // people easy access to all the commands they need to do things in your
        // app" — and a screen you cannot get to from the menu bar is a screen
        // with no keyboard route at all.
        Button(Words.upfront("exp.title")) { shop.shelf = .expenses }
            .keyboardShortcut("9", modifiers: .command)
        Button(Words.upfront("waste.title")) { shop.shelf = .waste }
        Button(Words.upfront("an.pnl_title")) { shop.shelf = .reports }
            .keyboardShortcut("0", modifiers: .command)
    }
}

private struct SortMenu: View {
    @Environment(Shop.self) private var shop

    var body: some View {
        @Bindable var shop = shop
        // A Picker rather than five buttons, so the current order carries a
        // tick and the menu says what is true as well as what is possible.
        Picker(Words.upfront("mac.sort_by"), selection: $shop.librarySort) {
            ForEach(LibrarySort.allCases) { sort in
                Text(Words.upfront(sort.key)).tag(sort)
            }
        }
        .disabled(!shop.showingLibrary)
    }
}

private struct NewJobCommand: View {
    @Environment(Shop.self) private var shop

    var body: some View {
        Button(Words.upfront("mac.new_job")) { shop.takingAJob = true }
            .keyboardShortcut("n")
            .disabled(!shop.canMoveJobs)
        Button(Words.upfront("mac.new_customer")) { shop.editingCustomer = Shop.newCustomer() }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(!shop.canMoveJobs)
    }
}

/// Moving the job that is selected, from wherever it is selected.
///
/// The board can drag; a table cannot, and the table is where somebody reads
/// one job and decides it is done. Without this, "mark this finished" meant
/// switching to the board, finding the card again and dragging it — for a
/// decision that was already made on the screen they were looking at.
///
/// EVERY STAGE IS OFFERED, and a move the rules refuse is refused with a
/// reason rather than greyed out. AppKit validates a menu against a responder
/// chain, and asking `gate()` per item on every menu draw would run the WIP
/// arithmetic seven times for a menu nobody opened. The refusal already says
/// exactly why — a disabled item says nothing at all.
private struct JobMenu: View {
    @Environment(Shop.self) private var shop

    /// The stages a job can be moved to from a menu.
    ///
    /// `on_hold` is not among them because it asks a question first, and
    /// `delivered` is not because it is not a status: handing a job over stamps
    /// a date on a completed job, and both have their own item below.
    private static let destinations: [Stage] =
        [.quote, .pending, .printing, .post, .qc, .completed]

    private var job: Order? { shop.selection.flatMap { id in shop.orders.first { $0.id == id } } }
    private var canMove: Bool { shop.canMoveJobs && job != nil }

    var body: some View {
        ForEach(Self.destinations) { stage in
            Button(Words.upfront(stage.key)) {
                guard let id = shop.selection else { return }
                // The same two questions the board asks. A move made from a
                // menu must leave the same record as a move made by dragging,
                // or which screen it was started from changes what is written
                // down.
                if let ask = shop.questionFor(id, moving: stage) { ask(); return }
                Task { await shop.moveJob(id, to: stage) }
            }
            // ⌘1…⌘7 belong to Go, and a rival wins nothing. The stages are
            // reached by name, which is also how they are read on the board.
            .disabled(!canMove || Stage.of(job!) == stage)
        }
        // Delivered sits with the stages because that is what it answers —
        // where the job is — even though it is not one. Everything below the
        // divider is something you DO to a job rather than somewhere you put it.
        Button(Words.upfront("queue.delivered")) {
            if let id = shop.selection { Task { await shop.markDelivered(id) } }
        }
        .disabled(!canMove || job?.status != "completed" || job?.deliveredAt != nil)

        Divider()
        Button(Words.upfront("mac.edit_job")) {
            guard let one = job else { return }
            shop.pendingEdit = Shop.PendingHold(id: one.id, project: one.project)
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(!canMove)
        Button(Words.upfront("pay.modal_title")) {
            guard let one = job else { return }
            shop.pendingPayment = Shop.PendingHold(id: one.id, project: one.project)
        }
        .keyboardShortcut("p", modifiers: [.command, .shift])
        .disabled(!canMove)
        Button(Words.upfront("ord.hold_btn")) {
            guard let one = job else { return }
            shop.pendingHold = Shop.PendingHold(id: one.id, project: one.project)
        }
        .keyboardShortcut("h", modifiers: [.command, .shift])
        .disabled(!canMove || job?.status == "on_hold")

        Divider()
        // The one item here that does not need the book to be ours: showing a
        // shop what it would hand a customer changes nothing, and refusing to
        // draw the sample's invoice would hide the thing this app is for.
        Button(Words.upfront("doc.invoice")) {
            if let one = job { shop.showInvoice(one.id) }
        }
        .keyboardShortcut("p")
        .disabled(job == nil)
    }
}

private struct ModelMenu: View {
    @Environment(Shop.self) private var shop

    /// A model is selected, the library is showing, and the book is ours.
    private var canEdit: Bool { shop.showingLibrary && shop.canEditSelection }
    /// …and its file is on this Mac.
    private var canReach: Bool { shop.showingLibrary && shop.selectionIsOnThisMac }

    /// A 3MF is the only thing there is anything to convert IN: an STL carries
    /// no printer settings to rewrite, so offering it would be offering to do
    /// nothing.
    private var canConvert: Bool {
        canReach && !shop.printerProfiles.isEmpty
            && (shop.selectedFile?.sourceFile?.ext ?? "").lowercased() == "3mf"
    }

    var body: some View {
        // "Favourite", not "Add to Favourites" / "Remove from Favourites".
        //
        // It used to be the second, computed from the selection, and it never
        // once said either: a SwiftUI menu item's TITLE is baked when the menu
        // bar is built and is never rewritten — not on a change, not on
        // `NSMenu.update()`, not with the items in their own View or the model
        // injected through the environment. Every one of those was tried. So the
        // dynamic title read "Favourite" — its own no-selection fallback —
        // for every model, in every state, since the menu was added.
        //
        // The item toggles, and now it says so. Enablement is evaluated when the
        // menu is shown and does keep up; only the words are frozen.
        Button(Words.upfront("mac.favourite")) { shop.toggleFavouriteOnSelection() }
            .keyboardShortcut("d")
            .disabled(!canEdit)
        Divider()
        // ⌘Y, and Space in the grid — the two gestures Finder uses, because a
        // library of print files is a Finder window in everything but name.
        Button(Words.upfront("mac.quick_look")) { shop.quickLookSelection() }
            .keyboardShortcut("y")
            .disabled(!canReach)
        Button(Words.upfront("mac.reveal_in_finder")) { shop.revealSelection() }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!canReach)
        Button(Words.upfront("mac.open")) { shop.openSelection() }
            .keyboardShortcut("o")
            .disabled(!canReach)
        // CONVERT, in the menu bar as well as the right-click menu.
        //
        // It reached the library as a context menu only, which is a feature a
        // shop finds by accident or not at all — and a context menu cannot be
        // photographed by the snapshot runner, so it was also the one screen
        // nobody could check. The menu bar is printed on every run.
        // ALWAYS THERE, greyed when it cannot be used — a menu whose items come
        // and go is one a shop cannot learn, and Apple's own menus keep an item
        // and disable it. It is also the only way this can be checked: the
        // snapshot runner prints the menu bar, and an item that vanishes when
        // nothing is selected is an item no run ever sees.
        Menu(Words.upfront("mac.convert_for")) {
            ForEach(shop.printerProfiles) { profile in
                Button(profile.name) {
                    guard let file = shop.selectedFile else { return }
                    Task { await shop.convertModel(file, targetId: profile.id) }
                }
            }
            Divider()
            Button(Words.upfront("mac.standard_3mf")) {
                guard let file = shop.selectedFile else { return }
                Task { await shop.convertModel(file, targetId: nil) }
            }
        }
        .disabled(shop.converting || !canConvert)
    }
}

/// The About panel.
///
/// A bare SwiftPM binary has no Info.plist strings to fill Apple's default
/// panel, so it is given the version rather than showing a blank sheet with the
/// executable's name on it.
@MainActor enum About {
    static func show() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "Khayt",
            .applicationVersion: version ?? "development build",
            .init(rawValue: "Copyright"): "Khayt — the native Mac app",
        ])
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
