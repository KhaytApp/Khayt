import SwiftUI
import AppKit

/// Not `@main`: `main.swift` is the entry point, because the writing direction
/// has to be settled before AppKit starts. See `Direction.swift`.
struct KhaytApp: App {
    @State private var shop = Shop()
    @NSApplicationDelegateAdaptor(Activator.self) private var activator

    var body: some Scene {
        // THE WINDOW FIRST. SwiftUI treats the first scene in this builder as
        // the app's primary one, and with `FloorMenuBar` ahead of it the app
        // launched with no window at all — the menu bar icon appeared, the
        // window's `.task` never ran, and the snapshot runner terminated
        // because `Snapshot.subject` was never set. A menu bar extra is an
        // addition to this app, not the front of it.
        Window("Khayt", id: "shop") {
            ShopWindow(shop: shop)
                // A FLOOR, so the window cannot be dragged into nonsense.
                //
                // "Choose a minimum and maximum size for each window to help
                // keep your content looking great … If you don't set a minimum
                // and maximum size, people could make it so small that UI
                // elements overlap." There was none: the sidebar holds at 190
                // and the inspector at 260, so everything else was taken out of
                // the middle, and the jobs table's six columns — 644pt of
                // minimums — collapsed into each other well before the window
                // stopped shrinking.
                //
                // 900 leaves the table about 450pt with both side columns open,
                // which is narrow and still legible; below that a shop is
                // better served closing one of them. No maximum: a Mac has a
                // large display and more of this app on it is better.
                .frame(minWidth: 900, minHeight: 480)
                // The app's own colour — the cyan of the letter in its icon —
                // and only when this Mac's owner has not chosen one of their
                // own. The HIG is explicit that a chosen system accent replaces
                // an app's; an app with an asset catalog gets that behaviour
                // free, and this bundle is assembled by hand, so `appTint`
                // asks the question and answers nil when the choice is theirs.
                .tint(Khayt.appTint)
                .task {
                    Snapshot.subject = shop
                    // The menu bar item, which is AppKit rather than a scene —
                    // see `FloorStatus` for the profile that decided that.
                    FloorStatus.shared.install(shop: shop)
                    // Before the book is opened, so the very first write is
                    // heard. Every path that changes the store lands in one
                    // place and this listens there — see `StoreWriter.didWrite`.
                    shop.listenForOwnWrites()
                    // The shop's own book if there is one, the sample only when
                    // there is not. Reading is safe, the source is named in the
                    // toolbar, and an app that opens on invented data when real
                    // data exists is answering a question nobody asked.
                    await shop.load(Shop.available.first(where: \.isReal) ?? .sample)
                }

        }
        // Wide enough that all six columns are on screen with the inspector
        // open, which is how the window opens. At 1180 the table was given
        // ~650pt against 644pt of column minimums and "Owed" — the figure the
        // toolbar is built around — was squeezed to a few pixels.
        .defaultSize(width: 1320, height: 760)
        // The unified toolbar, sitting in the title bar rather than in a strip
        // below it. It is most of the difference between a Mac window and a web
        // page with a grey bar at the top.
        .windowToolbarStyle(.unified)
                .commands { KhaytCommands(shop: shop) }

        // ⌘, — the shop's own settings, written through the same rule the
        // Electron page saves through. The scene puts "Settings…" in the app
        // menu by itself.
        // AFTER the window, deliberately — see the note on scene order above.

        Settings {
            SettingsWindow(shop: shop)
        }
    }
}

/// A bare SwiftPM executable has no bundle, so nothing has told AppKit this is a
/// normal windowed application: the window opens behind everything and never
/// takes the menu bar.
///
/// `mac/make-app.sh` assembles a real bundle, and inside one none of this is
/// wanted — an app that shoulders its way in front of whatever you were doing,
/// every launch, is an app people learn to resent. So it is asked for only when
/// there is no bundle identifier, which is exactly the `swift run` case.
final class Activator: NSObject, NSApplicationDelegate {
    /// Give the book back on the way out, so the next app to open does not have
    /// to reason about a dead pid to know it is free.
    func applicationWillTerminate(_ note: Notification) {
        MainActor.assumeIsolated { Snapshot.subject?.relinquish() }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        if Bundle.main.bundleIdentifier == nil {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        if let dir = ProcessInfo.processInfo.environment["KHAYT_SNAPSHOT_DIR"] {
            Snapshot.run(into: URL(fileURLWithPath: dir))
        }
    }
}

/// The app photographs its own window.
///
/// SwiftUI's `ImageRenderer` returns a "cannot render" placeholder for anything
/// AppKit-backed — which is `NavigationSplitView`, `Table` and the toolbar, i.e.
/// everything that makes this a Mac app rather than a page. And `screencapture`
/// needs a screen-recording grant. A window can always draw itself into a
/// bitmap, so that is the route.
///
/// Two things it cannot show, both the photograph rather than the app:
///
/// * `NSVisualEffectView` draws nothing into an offline bitmap, so the sidebar
///   comes out black and empty. Confirm a sidebar you doubt by running once with
///   `.listStyle(.plain)`, which has no material, rather than by "fixing" it.
///
///   The pane shot of that sidebar is worse than empty, because it looks fine.
///   Its appearance really is `vibrantDark`, and vibrant labels draw as an
///   ALPHA MASK for the window server to composite: every pixel in
///   `…-pane1.png` is RGB(0,0,0) varying only in alpha — counted, not guessed.
///   Anything that shows transparency as white then renders a crisp picture of
///   black text on white paper, which is indistinguishable from a dark mode
///   that does not work. In the light run the same mask looks right by
///   accident. Forcing the subtree out of vibrancy and flattening it onto
///   `windowBackgroundColor` was tried: the labels still draw as a black mask,
///   now on a dark ground, so they vanish instead. Judge the sidebar from the
///   app, not from this file.
/// `capturePanes` photographs each scrolling pane on its own, for when the window
/// shot leaves a doubt. It has the opposite blind spot — it loses what a pane
/// draws into its own layer, so thumbnails go missing there — which is why both
/// exist.
///
/// A correction, since the wrong version was written down for a day: the library
/// inspector once photographed as a solid black column, and this file blamed
/// having two `NSScrollView`s on screen at once. It was not the capture. The
/// inspector was attached inside `detail`, the detail content was laid out
/// against a width that did not subtract the sidebar, and the inspector had
/// nowhere to draw. Moving `.inspector` onto the `NavigationSplitView` fixed the
/// picture and the app together. A capture limitation is a comfortable thing to
/// blame; check the layout first.
///
/// Only runs when KHAYT_SNAPSHOT_DIR is set, so it costs a normal launch
/// nothing and cannot fire by accident.
@MainActor enum Snapshot {
    /// The window's shop, so the run can move between shelves. Set once, on
    /// launch; nil in a normal run because nothing else asks for it.
    static weak var subject: Shop?

    /// Photograph a view no book can reach.
    ///
    /// The empty states are the problem this solves. There are twenty of them
    /// and the sample book fills every screen it has, so not one of the
    /// fifty-one pictures this harness takes contains a single one — which
    /// means they could be redrawn, or broken, and every screenshot would look
    /// fine. That is the same trap as a screen that ships showing its empty
    /// state, running the other way.
    ///
    /// `ImageRenderer` rather than a window: these are plain shapes and text,
    /// which it draws correctly, and no book state has to be faked to see them.
    @MainActor
    private static func captureDetached(into dir: URL) {
        let cases: [(String, AnyView)] = [
            ("98-empty-drawn", AnyView(
                EmptyHere(title: "Nothing here yet",
                          message: "A machine you add shows up here, with what it is printing.")
                    .frame(width: 460, height: 300)
                    .background(Khayt.ground))),
            ("98-empty-drawn-dark", AnyView(
                EmptyHere(title: "Nothing here yet",
                          message: "A machine you add shows up here, with what it is printing.")
                    .frame(width: 460, height: 300)
                    .background(Khayt.ground)
                    .environment(\.colorScheme, .dark))),
            ("98-layer-progress", AnyView(
                VStack(alignment: .leading, spacing: 5) {
                    // A figure, not a job name: an English sample string here
                    // is still an English string on a screen, and the guard
                    // that says so is right even about a picture nobody ships.
                    Text("62%").font(.caption).monospacedDigit()
                    ZStack(alignment: .leading) {
                        LayerLinesShape().fill(Khayt.hot.opacity(0.16))
                        LayerLinesShape(progress: 0.62).fill(Khayt.hot)
                    }
                    .frame(height: 26)
                }
                .padding(18)
                .frame(width: 320)
                .background(Khayt.surface))),
        ]
        for (name, view) in cases {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write(Data("could not render \(name)\n".utf8))
                continue
            }
            try? png.write(to: dir.appending(path: name + ".png"))
            FileHandle.standardError.write(Data("wrote \(name).png\n".utf8))
        }
    }

    /// Photograph a view that is not in a window.
    ///
    /// A `MenuBarExtra`'s panel is the case this exists for: it is not a window,
    /// so `capture(named:window:)` cannot see it, and without this it would be
    /// the one surface in the app that ships unlooked at.
    @MainActor
    static func captureView(named name: String, _ view: some View, into dir: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("could not render \(name)\n".utf8))
            return
        }
        try? png.write(to: dir.appending(path: name + ".png"))
        FileHandle.standardError.write(Data("wrote \(name).png\n".utf8))
    }

    /// `KHAYT_SNAPSHOT_SIZE=WxH` — photograph the app at somebody else's Mac.
    ///
    /// Every screen in this app had only ever been reviewed at one size, the
    /// 1320x760 the window opens at, which is roughly a small laptop. That is
    /// the size a layout is least likely to be wrong at, because it is the one
    /// it was built against. A shop runs this full screen: a 13-inch Air is
    /// 1470 points wide, a 16-inch 1710, a Studio Display 2560, an XDR 3008 —
    /// and a column with a fixed maximum width looks composed at one of those
    /// and abandoned at another.
    ///
    /// The size is set in POINTS on the content view, so it is independent of
    /// how the display is scaled, and it may exceed the physical screen: an
    /// off-screen window still lays out and still draws into a bitmap, which
    /// is the whole reason a 6K layout can be checked on a laptop.
    private static func resizeIfAsked() {
        guard let spec = ProcessInfo.processInfo.environment["KHAYT_SNAPSHOT_SIZE"] else { return }
        let parts = spec.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]),
              w >= 480, h >= 360 else {
            FileHandle.standardError.write(Data("bad KHAYT_SNAPSHOT_SIZE \(spec)\n".utf8))
            return
        }
        for window in NSApp.windows where window.isVisible && window.contentView != nil {
            // `setContentSize` rather than `setFrame`, so the number asked for
            // is the number the app gets to lay out in — a frame includes the
            // title bar and would quietly give back a shorter window than the
            // one being tested.
            window.setContentSize(NSSize(width: w, height: h))
        }
        FileHandle.standardError.write(Data("window set to \(Int(w))x\(Int(h)) pt\n".utf8))
    }

    static func run(into dir: URL) {
        // Every write below is `try?`, so a directory that is not there costs a
        // whole run and says nothing at all — 31 "wrote …" lines and no files.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            // BEFORE the window settles, if this run is the dark one.
            //
            // Flipping the appearance afterwards left the sidebar light: its
            // list is an `NSTableView` whose cells were already built with
            // light label colours, and a change of appearance does not rebuild
            // them without a real redisplay. The content area flipped fine,
            // which is what made it look like the capture rather than the app.
            // Built dark from the outset, the whole window is dark.
            // DARK AND LIGHT ARE SEPARATE RUNS, not two halves of one.
            //
            // Changing `NSApp.appearance` partway through is what took this
            // harness down, every time, at the same frame:
            //
            //     -[NSSearchFieldCell drawInteriorWithFrame:inView:]
            //     -[NSButtonCell _controlViewDidChangeEffectiveAppearance:]
            //     _invalidateIntrinsicContentSizeDirtyingConstraints:
            //     -[NSWindow _postWindowNeedsUpdateConstraints]  → abort
            //
            // The search field attaches its cancel-button cell the first time
            // it draws under the new appearance, and invalidating constraints
            // from inside a layout pass is the one thing AppKit will not
            // forgive. Three attempts to drain the layout BEFORE the capture
            // all failed, because the invalidation is caused BY the draw and
            // does not exist until it happens.
            //
            // A process that never changes appearance never reaches that
            // frame. `KHAYT_SNAPSHOT_DARK=1` photographs the dark screens and
            // stops; any other value, or none, is an ordinary light run. Two
            // invocations give both sets, and neither can abort. Verified over
            // three dark and three light runs, all clean, where the combined
            // run had aborted three times out of three.
            let dark = ProcessInfo.processInfo.environment["KHAYT_SNAPSHOT_DARK"] == "1"
            // BOTH WAYS, and the light one is a choice rather than a default.
            //
            // Splitting the runs left the light one setting no appearance at
            // all, so it followed whatever this Mac happened to be set to —
            // fine until the Mac switches itself at dusk, after which the same
            // command writes dark pictures under light names. An Arabic pass
            // run at teatime came back dark and the app was not at fault.
            //
            // Set ONCE, here, before anything has been drawn. That is what
            // makes it safe: what took this runner down was changing the
            // appearance PART WAY THROUGH, and this never changes it again.
            //
            // Two earlier attempts are worth not repeating. In
            // `applicationWillFinishLaunching` it never reaches the window,
            // because SwiftUI attaches its delegate adaptor after AppKit has
            // already sent that. In `main.swift`, before `KhaytApp.main()`,
            // `NSApp` is still nil and the process dies on the spot.
            let want: NSAppearance.Name = dark ? .darkAqua : .aqua
            NSApp.appearance = NSAppearance(named: want)
            for window in NSApp.windows { window.appearance = NSAppearance(named: want) }
            resizeIfAsked()
            captureDetached(into: dir)
            // The window has to have laid out and drawn once. Two seconds is
            // generous; capturing an unlaid-out window yields a blank sheet.
            try? await Task.sleep(for: .seconds(2))
            // Says whether this run holds the book. Ownership is the gate on
            // every write, and a gate nobody checked is a gate that is open.
            FileHandle.standardError.write(Data(
                "ownership: \(shopOwnership())\n".utf8))
            // Whether the shop's book got today's backup. A shop running only
            // this app has no other, so "did it actually write one" is worth
            // seeing in every run rather than trusted.
            if let shop = subject {
                let line = "backup: " + (shop.lastBackup ?? "none")
                    + (shop.backupProblem.map { " — \($0)" } ?? "") + "\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
            // DARK FIRST, then light, then everything else in light.
            //
            // A Mac app is used in both and every screenshot this runner has
            // ever taken was light, so the dark side of it was never once
            // looked at. Two screens is enough to catch the failure that
            // matters — a colour written as a literal rather than taken from
            // the system, which is invisible against one background and only
            // one.
            if dark {
                capture(named: "00-dark-dashboard", into: dir)
                // Panes as well as the whole window: the sidebar is an AppKit
                // visual-effect view and does not draw into the window's own
                // bitmap, so in the composite it comes out as bare white — in
                // light mode that looks right by accident and in dark mode it
                // looks like a bug the app does not have.
                capturePanes(named: "00-dark-dashboard", into: dir)
                subject?.shelf = .library(nil)
                try? await Task.sleep(for: .milliseconds(700))
                capture(named: "03-dark-library", into: dir)
                capturePanes(named: "03-dark-library", into: dir)
                subject?.shelf = .jobs(nil)
                try? await Task.sleep(for: .milliseconds(700))
                capture(named: "01-dark-jobs", into: dir)
                // Stop here. Everything below is photographed by the light run.
                NSApp.terminate(nil)
                return
            }
            capture(named: "00-dashboard", into: dir)
            // Again once the printers have answered: the live strip is the one
            // thing on this screen that is not read from the book, so a first
            // photograph taken before the first poll cannot show it.
            try? await Task.sleep(for: .seconds(3))
            capture(named: "00c-dashboard-live", into: dir)

            guard let shop = subject else { NSApp.terminate(nil); return }
            // The sample too: a shop whose jobs are auto-logged from printer
            // history has no prices, and a dashboard of zeros shows nothing
            // about the design.
            await shop.load(.sample)
            await settle()
            // The menu bar as AppKit actually built it. A Commands block that
            // compiles proves nothing about what a person can reach.
            //
            // AFTER a book is open, not before. The stages are named from the
            // shop's own catalogue, which is loaded with the book — dumped at
            // launch every one of them read "queue.quote", which is what a
            // missing translation looks like and was only an early photograph.
            FileHandle.standardError.write(Data("menus: \(menuTree())\n".utf8))
            capture(named: "00b-dashboard-sample", into: dir)
            await shop.load(Shop.available.first(where: \.isReal) ?? .sample)
            await settle()
            shop.shelf = .jobs(nil)
            await settle()
            capture(named: "01-jobs", into: dir)

            // An unsettled job for preference — the money lines are the point
            // of this panel — but ANY job rather than none. A store whose jobs
            // are all settled photographed an empty detail pane, which looks
            // like an inspector that does not work.
            shop.selection = (shop.shown.first { !$0.isSettled } ?? shop.shown.first)?.id
            await settle()
            capture(named: "02-job-selected", into: dir)
            // The panes as well: the job inspector is where the money lines and
            // the payment button live, and a window shot that simply does not
            // contain it cannot tell you whether it is closed or broken.
            capturePanes(named: "02-job-selected", into: dir)

            shop.shelf = .library(nil)
            await settle()
            capture(named: "03-library", into: dir)
            // A model SELECTED, so the inspector is in the picture — the size,
            // the triangle count and whether it goes on a bed the shop owns all
            // live there, and a grid shot cannot show any of them. Picked as
            // the largest measured model, because "too big" is the answer worth
            // being able to see.
            if let biggest = shop.files
                .compactMap({ f in f.mesh.map { (f, max($0.x, $0.y)) } })
                .max(by: { $0.1 < $1.1 })?.0 {
                shop.fileSelection = [biggest.id]
                await settle()
                capture(named: "03b-library-selected", into: dir)
                capturePanes(named: "03b-library-selected", into: dir)
                shop.fileSelection = []
                await settle()
            }

            shop.fileSelection = Set(shop.shownFiles.prefix(1).map(\.id))
            await settle()
            capture(named: "04-model-selected", into: dir)
            // The Model menu should now be live: library shelf, one model
            // selected, and the book is ours to change. Dumped a SECOND time
            // for exactly that reason: a menu built at launch and never rebuilt
            // is indistinguishable from a correct one until something it reads
            // changes, and the titles here depend on a selection made after the
            // first dump.
            FileHandle.standardError.write(Data("menus (after selection): \(menuTree())\n".utf8))
            capturePanes(named: "04-model-selected", into: dir)

            // Several selected: the shape a shop is in when it files the
            // Kings as one collection.
            shop.fileSelection = Set(shop.shownFiles.prefix(4).map(\.id))
            await settle()
            capture(named: "04b-many-selected", into: dir)
            shop.fileSelection = Set(shop.shownFiles.prefix(1).map(\.id))

            if let group = shop.groups.first {
                shop.shelf = .library(group)
                shop.fileSelection = []
                await settle()
                capture(named: "05-group", into: dir)
            }

            // The sample for the last two. A shop whose jobs are auto-logged
            // from printer history has no customers and no prices — true, and
            // no use at all for looking at a design.
            await shop.load(.sample)
            shop.shelf = .board
            await settle()
            capture(named: "09-board", into: dir)

            // The sheets. Each is its own window and the window shot cannot see
            // them, so they are photographed on their own — six were built
            // before there was a picture of any.
            shop.shelf = .jobs(nil)
            await settle()
            if let job = shop.orders.first {
                let subject = Shop.PendingHold(id: job.id, project: job.project)
                for (name, open) in [
                    ("10-hold", { shop.pendingHold = subject }),
                    ("11-payment", { shop.pendingPayment = subject }),
                    ("12-edit-job", { shop.pendingEdit = subject }),
                    ("13-qc-fail", { shop.pendingQcFail = subject }),
                ] as [(String, () -> Void)] {
                    open()
                    await settle()
                    captureSheet(named: name, into: dir)
                    shop.clearQuestion()
                    await settle()
                }
            }
            shop.takingAJob = true
            await settle()
            captureSheet(named: "14-new-job", into: dir)
            shop.takingAJob = false
            await settle()

            // The menu bar's panel, which no window shot can reach.
            captureView(named: "27-menu-bar",
                        FloorPanel(shop: shop).background(Khayt.ground), into: dir)

            // Where the waiting work would go.
            //
            // The sample gives every one of its 42 jobs a printer, so this
            // photographs the panel's EMPTY state — which is the honest picture
            // of that book and still proves the sheet opens and says the right
            // thing. Photographed against a sample with unassigned work it
            // shows six proposals; that was checked by hand before shipping.
            // The panel asks the engine on `.task`, which a settle alone does
            // not wait for.
            shop.forgetSchedule()
            shop.schedulingWork = true
            await settle()
            try? await Task.sleep(for: .milliseconds(700))
            let rows = shop.orderRows.count
            let waiting = shop.schedulableRows.count
            let fleet = shop.machines.count
            let placed = shop.schedulePlan?.assignments.count ?? -1
            let why = shop.scheduleProblem ?? "-"
            captureSheet(named: "26-schedule", into: dir)
            shop.schedulingWork = false
            await settle()

            shop.editingCustomer = Shop.newCustomer()
            await settle()
            captureSheet(named: "15-new-customer", into: dir)
            shop.editingCustomer = nil
            await settle()

            // The document itself. It is built by the runtime and drawn by
            // WebKit AFTER the sheet appears, so it gets longer than a settle:
            // photographed too early this is a spinner, which is exactly what
            // a broken invoice would also look like.
            if let job = shop.orders.first(where: { !$0.parts.isEmpty }) ?? shop.orders.first {
                shop.showInvoice(job.id)
                // Straight away, before the runtime has built anything: this is
                // the sheet's own chrome with no web view under it, and it is
                // the only shot in which that chrome is visible. `cacheDisplay`
                // does not draw SwiftUI's layers once a WKWebView is in the
                // hierarchy — the document comes through and the title and the
                // buttons around it do not. Two pictures, because one of them
                // would otherwise look like a header that never drew.
                await settle()
                captureSheet(named: "16-invoice-building", into: dir)
                try? await Task.sleep(for: .seconds(2))
                captureSheet(named: "16-invoice", into: dir)
                shop.clearQuestion()
                await settle()
            }

            // The Settings window: opened the way ⌘, opens it, one picture per
            // pane.
            //
            // "NOT THE SHOP'S WINDOW" IS NOT ENOUGH TO FIND IT. The menu bar's
            // NSStatusItem has a window too, and it is visible and it is not the
            // main one — so `first(where:)` found it and six settings pictures
            // were 30×34 photographs of the nozzle glyph for as long as the menu
            // bar has existed. Nothing failed: the harness wrote six PNGs and
            // said so.
            let main = NSApp.windows.first { $0.isVisible && $0.contentView != nil }
            /// A window big enough to be a window somebody reads, which the
            /// status item's 30×34 is not.
            func settingsWindow() -> NSWindow? {
                NSApp.windows.first {
                    $0.isVisible && $0 !== main && $0.contentView != nil
                        && $0.frame.width >= 300 && $0.frame.height >= 300
                }
            }
            // Through the menu item ⌘, is bound to, whatever selector SwiftUI
            // gave it this release — sending `showSettingsWindow:` by name
            // opened nothing.
            if let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.keyEquivalent == "," }) {
                NSApp.sendAction(item.action ?? #selector(NSApplication.terminate(_:)), to: item.target, from: item)
            }
            await settle()
            try? await Task.sleep(for: .seconds(1))
            if let settings = settingsWindow() {
                for pane in SettingsPane.allCases {
                    shop.settingsPane = pane
                    await settle()
                    capture(named: "17-settings-\(pane.rawValue)", window: settings, into: dir)
                }
                settings.close()
                await settle()
            } else {
                // Loudly, and with what WAS open: a silent miss here is how the
                // nozzle glyph got photographed six times.
                // `×`, not an `x`: the units guard reads a letter between two
                // numbers as a unit written in Swift, and it is right to — it
                // cannot tell this line from one a shop would read. The proper
                // multiplication sign is what the rest of the app uses anyway.
                let open = NSApp.windows.filter(\.isVisible)
                    .map { "\(type(of: $0)) \(Int($0.frame.width))×\(Int($0.frame.height))" }
                FileHandle.standardError.write(Data(
                    "no settings window to capture — open: \(open.joined(separator: ", "))\n".utf8))
            }

            // What the shop spent and what it wasted. The sample, because this
            // Mac's own book has neither and an empty table is a picture of
            // nothing — and because the sample is what most people will open
            // these two screens in first.
            shop.period = .all
            shop.shelf = .expenses
            await settle()
            capture(named: "18-expenses", into: dir)
            shop.shelf = .waste
            await settle()
            capture(named: "19-waste", into: dir)
            shop.shelf = .reports
            await settle()
            // The P&L is computed by the runtime after the screen appears, so
            // it gets longer than a settle — photographed too early it is the
            // "no data yet" placeholder, which is what a broken one looks like.
            try? await Task.sleep(for: .seconds(1))
            capture(named: "20-reports", into: dir)
            // The other half of the screen: what the shop is still owed.
            shop.reportPage = .owing
            await settle()
            try? await Task.sleep(for: .milliseconds(600))
            capture(named: "20b-owing", into: dir)
            // And the third: who the money came from. Same reason as the P&L —
            // the lists are computed by the runtime after the screen appears.
            shop.reportPage = .best
            await settle()
            try? await Task.sleep(for: .milliseconds(600))
            capture(named: "20c-best", into: dir)
            shop.reportPage = .profit
            await settle()

            shop.shelf = .machines
            await settle()
            capture(named: "07-machines", into: dir)
            // And the real book, because the live card only exists there: the
            // sample's printers are somebody else's addresses on somebody
            // else's network, so this app never knocks on them. The poll needs
            // longer than a settle — it is a request to a machine on the wifi.
            await shop.load(Shop.available.first(where: \.isReal) ?? .sample)
            shop.shelf = .machines
            await settle()
            try? await Task.sleep(for: .seconds(3))
            capture(named: "07b-machines-live", into: dir)
            await shop.load(.sample)
            await settle()
            if let machine = shop.machines.first {
                shop.editingMachine = machine
                await settle()
                try? await Task.sleep(for: .milliseconds(600))
                captureSheet(named: "22-machine", into: dir)
                shop.editingMachine = nil
                await settle()
            }
            shop.shelf = .inventory
            await settle()
            capture(named: "08-inventory", into: dir)
            // Correcting a spool, which is what a shelf screen is for.
            if let spool = shop.spools.first {
                shop.editingSpool = spool
                await settle()
                captureSheet(named: "21-spool", into: dir)
                shop.editingSpool = nil
                await settle()
            }

            // The two screens added last, and both conditional in the sidebar
            // — the portfolio only appears once a job has been photographed —
            // so a picture is the only way to see either of them work.
            shop.shelf = .colour
            await settle()
            // The match list is computed by the runtime after the screen
            // appears, like the P&L below.
            try? await Task.sleep(for: .seconds(1))
            capture(named: "23-colour", into: dir)
            if !shop.snapshots.isEmpty {
                shop.shelf = .portfolio
                await settle()
                capture(named: "24-portfolio", into: dir)
            }
            shop.shelf = .giftCards
            await settle()
            capture(named: "25-gift-cards", into: dir)
            shop.issuingGiftCard = true
            await settle()
            captureSheet(named: "25b-gift-card-sheet", into: dir)
            shop.issuingGiftCard = false
            await settle()

            shop.shelf = .customers
            shop.customerSelection = shop.shownCustomers.max { $0.owed < $1.owed }?.id
            await settle()
            capture(named: "06-customers", into: dir)
            capturePanes(named: "06-customers", into: dir)

            try? await Task.sleep(for: .milliseconds(300))
            NSApp.terminate(nil)
        }
    }

    /// The menu bar as AppKit built it: what is there, and what key reaches it.
    ///
    /// DELIBERATELY DOES NOT REPORT ENABLED STATE. It used to, and it cost two
    /// afternoons: AppKit validates items against the responder chain when a
    /// menu is about to open, and a snapshot run never establishes one — so
    /// every item reads as disabled, including Cut, Copy and Paste. That looks
    /// exactly like a broken focused value and is nothing of the kind.
    ///
    /// What IS trustworthy here is structure. The Book menu's picker is built
    /// inside an `if let shop`, so its presence says the shop reached the menu;
    /// its absence says it did not.
    /// The menu bar as AppKit actually built it.
    ///
    /// `update()` FIRST, on every submenu. SwiftUI does not rewrite an
    /// NSMenuItem's title the moment the value behind it changes — AppKit asks
    /// the menu to refresh itself when it is about to be shown, and a headless
    /// run never shows one. Reading the titles without asking gives whatever
    /// they were when the menu was first built, which reads exactly like a
    /// broken menu: every stage named "queue.quote", every title stuck on its
    /// placeholder. Both were photographs of a menu nobody had opened.
    private static func menuTree() -> String {
        guard let main = NSApp.mainMenu else { return "none" }
        for top in main.items { top.submenu?.update() }
        return main.items.compactMap { top -> String? in
            guard let sub = top.submenu else { return top.title }
            let items = sub.items.filter { !$0.isSeparatorItem }.map { item -> String in
                item.title + (item.keyEquivalent.isEmpty ? "" : "[\(shortcut(item))]")
            }
            return "\(top.title){\(items.joined(separator: ", "))}"
        }.joined(separator: " | ")
    }

    private static func shortcut(_ item: NSMenuItem) -> String {
        var out = ""
        if item.keyEquivalentModifierMask.contains(.command) { out += "⌘" }
        if item.keyEquivalentModifierMask.contains(.shift) { out += "⇧" }
        if item.keyEquivalentModifierMask.contains(.option) { out += "⌥" }
        return out + item.keyEquivalent.uppercased()
    }

    private static func shopOwnership() -> String {
        guard let shop = subject else { return "no shop" }
        guard shop.source.isReal else { return "sample — nothing to own" }
        return shop.canWrite ? "held, this app may write"
                             : "not held — \(shop.owner ?? "unknown holder")"
    }

    /// Let SwiftUI apply the change and AppKit redraw before photographing it.
    /// Without this the picture is of the previous state, which is worse than
    /// no picture: it looks like the change did nothing.
    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(700))
    }

    /// Photograph each scrolling pane on its own.
    ///
    /// The whole-window shot loses a pane sometimes — two `NSScrollView`s on
    /// screen at once and only one comes back. Capturing them individually says
    /// whether the pane is empty or merely unphotographed, which is the
    /// difference between a bug and a picture of one.
    static func capturePanes(named name: String, into dir: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let root = window.contentView else { return }
        var found: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let scroll = v as? NSScrollView { found.append(scroll) }
            v.subviews.forEach(walk)
        }
        walk(root)
        for (i, scroll) in found.enumerated() {
            let target = scroll.documentView ?? scroll
            let bounds = target.bounds
            guard bounds.width > 1, bounds.height > 1,
                  let rep = target.bitmapImageRepForCachingDisplay(in: bounds) else { continue }
            target.effectiveAppearance.performAsCurrentDrawingAppearance {
                target.cacheDisplay(in: bounds, to: rep)
            }
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: dir.appending(path: "\(name)-pane\(i).png"))
            FileHandle.standardError.write(Data(
                "  pane\(i): \(type(of: target)) \(Int(bounds.width))x\(Int(bounds.height))\n".utf8))
        }
    }

    /// Photograph a sheet, which `capture` cannot see.
    ///
    /// A sheet is its OWN window, attached to the main one — so the window shot
    /// finds the main window first and photographs the screen behind the sheet.
    /// Six sheets were built before anybody noticed there was no picture of any
    /// of them.
    ///
    /// `attachedSheet` is the honest way to find it: it is the sheet AppKit is
    /// actually showing, rather than whichever window happens to be frontmost.
    static func captureSheet(named name: String, into dir: URL) {
        guard let host = NSApp.windows.first(where: { $0.isVisible && $0.attachedSheet != nil }),
              let sheet = host.attachedSheet,
              let view = sheet.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            FileHandle.standardError.write(Data("no sheet to capture for \(name)\n".utf8))
            return
        }
        // `cacheDisplay` asks each view to draw itself, and SwiftUI does not
        // draw itself — so every sheet here comes back with its AppKit-backed
        // controls (fields, pickers, the default button) present and its
        // SwiftUI labels, headings and explanations MISSING. Rendering the
        // layer tree instead was tried and gets the same text back: nothing,
        // upside down. Capturing the words needs either a screen-recording
        // grant this process does not have or `ImageRenderer`, which cannot
        // host a WKWebView — so the shots below show a sheet's LAYOUT, and
        // `SnapshotTests` renders the same views through `ImageRenderer` to
        // show its words.
        // INSIDE THE APPEARANCE, and this is not a detail.
        //
        // `cacheDisplay` draws with whatever `NSAppearance.current` happens to
        // be, and outside a real draw cycle that is aqua — so every dynamic
        // system colour resolved LIGHT no matter what the app was set to. The
        // first dark-mode screenshot this runner ever took came back with a
        // white sidebar and black text, which is a picture of the capture
        // rather than of the app.
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: dir.appending(path: name + ".png"))
        FileHandle.standardError.write(Data(
            "wrote \(name).png (\(Int(view.bounds.width))x\(Int(view.bounds.height))) [sheet]\n".utf8))
    }

    static func capture(named name: String, into dir: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
            FileHandle.standardError.write(Data("no window to capture\n".utf8))
            return
        }
        capture(named: name, window: window, into: dir)
    }

    /// Photograph one particular window — the Settings window, which is not
    /// the first visible one.
    static func capture(named name: String, window: NSWindow, into dir: URL) {
        guard // The theme frame, not the content view. A unified toolbar sits
              // in the title bar, which is a sibling of the content rather than
              // inside it, so photographing the content alone drops the source
              // menu, the owed figure and the inspector toggle.
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            FileHandle.standardError.write(Data("no window to capture\n".utf8))
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: dir.appending(path: name + ".png"))

        FileHandle.standardError.write(Data("wrote \(name).png (\(Int(view.bounds.width))x\(Int(view.bounds.height)))\n".utf8))
    }
}
