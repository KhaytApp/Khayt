import SwiftUI
import KhaytWidgetData
import AppKit
import KhaytCore

/// The floor, in the menu bar.
///
/// ── WHY THIS IS NOT A SMALLER WINDOW ──────────────────────────────────────
///
/// A print runs for eleven hours. Nobody sits in front of the app for eleven
/// hours, and nobody wants a shop-management window occupying a Space all day
/// to answer one question: *is it still going, and when is the printer free?*
///
/// So the answer lives in the menu bar, where macOS puts the things you glance
/// at rather than the things you use.
///
/// ── AND WHY IT IS APPKIT ──────────────────────────────────────────────────
///
/// This was written twice. The first version was SwiftUI's `MenuBarExtra`,
/// which is three lines and looks right, and it made the app unusable: the
/// snapshot runner went from a full pass in ninety seconds to seven pictures in
/// as long, and a sample of the stuck process showed 706 of 846 samples inside
///
///     AppDelegate.appGraphDidChange
///       → makeMainMenu(commandsList:updateImmediately:)
///         → AppKitMainMenuItem.updateMainMenu
///           → AttributeGraph churn
///
/// A `MenuBarExtra` is a SCENE. Every change to the app's scene graph rebuilds
/// the whole main menu, and this app's `Commands` tree is large — so a menu bar
/// item that watches a live shop rebuilt the File menu every time a printer
/// reported a temperature. Making the label static did not fix it, because the
/// panel's content is part of the same graph.
///
/// An `NSStatusItem` is not in that graph. It is created once, its title is set
/// from a timer, and the panel inside it is built the moment somebody opens it
/// and thrown away when they close it — so nothing is evaluated while nobody is
/// looking. That is the whole reason this file is sixty lines of AppKit instead
/// of three of SwiftUI, and it is worth writing down because the SwiftUI
/// version is the one anybody would reach for first.
@MainActor
final class FloorStatus {
    static let shared = FloorStatus()
    private init() {}

    private var item: NSStatusItem?
    private var popover: NSPopover?
    private var tick: Timer?
    private weak var shop: Shop?

    /// Mac-local, and read straight from defaults rather than through
    /// `AppStorage`: this is AppKit and there is no view to invalidate.
    static var wanted: Bool {
        UserDefaults.standard.object(forKey: "mac.menuBar") as? Bool ?? true
    }

    func install(shop: Shop) {
        self.shop = shop
        guard Self.wanted else { remove(); return }
        guard item == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = StatusGlyph.image(ring: nil, attention: false)
        item.button?.imagePosition = .imageLeading
        // Monospaced digits, so the item does not jitter as the figures move.
        item.button?.font = StatusGlyph.font
        item.button?.target = self
        item.button?.action = #selector(toggle)
        self.item = item
        refresh()

        // Five seconds. A menu bar is glanced at, not watched: polling the
        // shop's own printer readings any harder would put this back in the
        // business of costing something.
        //
        // ── TARGET AND SELECTOR, NOT A BLOCK ──────────────────────────────
        //
        // The block form has to get from a C function pointer back into Swift
        // isolation, and the only way to do that is `MainActor.assumeIsolated`,
        // which asks the concurrency runtime whether this is the main executor.
        // During application teardown that runtime is being dismantled while
        // the run loop is still firing timers, and the question is asked of
        // metadata that is going away underneath it:
        //
        //     objc_opt_class + 48
        //     swift_getObjectType + 204
        //     swift_task_isMainExecutorImpl + 36
        //     swift_task_isCurrentExecutorWithFlags + 72
        //     MainActor.assumeIsolated<A>
        //     closure #1 in FloorStatus.install(shop:)   ← here
        //
        // — a byte read at address 0x1e, which is not a nil of ours.
        //
        // A target/selector timer is dispatched by the Objective-C runtime
        // straight to a method on a `@MainActor` class, exactly as this file's
        // button action already is. The executor check is not in the path at
        // all, so there is nothing there to be torn down mid-question.
        tick = Timer.scheduledTimer(timeInterval: 5, target: self,
                                    selector: #selector(tickFired),
                                    userInfo: nil, repeats: true)
    }

    /// Is the clock running? For the tests, which cannot see an `NSTimer`
    /// otherwise and need to prove that stopping it actually stops it.
    var isTicking: Bool { tick?.isValid == true }

    func remove() {
        tick?.invalidate(); tick = nil
        popover?.performClose(nil); popover = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        shown = nil
        seen = nil
        tickUntil = nil
    }

    @objc private func tickFired() { refresh() }

    /// What the item last drew, so a tick that changes nothing redraws nothing.
    private(set) var shown: FloorRead.Label?

    /// The style picker changed: draw the new one now rather than in five
    /// seconds.
    func restyle() { shown = nil; refresh() }

    /// The ring and "64%" for one print, the ring and how many for several, a
    /// closed ring with a tick just after a finish, or the nozzle alone — with
    /// a dot when a machine wants somebody (`FloorRead.label`). Read off what
    /// the shop holds; no printer is asked.
    private func refresh() {
        guard let shop, let button = item?.button else { return }
        let lines = FloorRead.lines(shop)
        // A print turned finished since the last tick: the ring closes with a
        // tick in it for a short while (`FloorRead.iconHold`). The first tick
        // has nothing to compare with, so a plate that was already finished
        // when the app opened is not announced again.
        let now = Date()
        if let seen, !FloorRead.justFinished(previous: seen, current: lines, now: now).isEmpty {
            tickUntil = now.addingTimeInterval(FloorRead.iconHold)
        }
        seen = lines
        let label = FloorRead.label(lines, style: MenuBarStyle.current, words: shop.words,
                                    tickUntil: tickUntil, now: now)
        // What VoiceOver reads is kept current on its own: in the glyph-only
        // style the drawing barely changes while "2 printing, next done 14:20"
        // does, and the redraw guard below left it saying the first figures.
        let summary = FloorPanel.summary(shop)
        if summary != spoken {
            spoken = summary
            button.setAccessibilityLabel(summary)
        }
        guard label != shown else { return }
        shown = label
        button.image = StatusGlyph.image(ring: label.ring, attention: label.attention, tick: label.tick)
        button.title = label.text.isEmpty ? "" : " " + label.text
    }

    /// The floor as the last tick saw it, and until when the item shows its
    /// just-finished tick.
    private var seen: [FloorLine]?
    private var tickUntil: Date?

    /// What the item last told VoiceOver.
    private var spoken: String?

    /// A row of the panel, clicked: the machine in the main window, by the
    /// same road a khayt://machine/<id> link takes (`Activator.application(_:open:)`
    /// → `Shop.openedLinks` → `follow`), with its permission gate.
    func open(machine id: String) {
        popover?.performClose(nil); popover = nil
        ShopWindowOpener.raise()
        Shop.openedLinks += [.machine(id)]
    }

    /// "Open job" and "Start the next job": the job in the main window, by the
    /// same road and behind the same gate (`Shop.follow` asks `goToKinds`).
    func open(job id: String) {
        popover?.performClose(nil); popover = nil
        ShopWindowOpener.raise()
        Shop.openedLinks += [.job(id)]
    }

    /// "Mark printed" on a finished print: the job's own next step
    /// (`Shop.takeNextStep`, the inspector's button), not a second way to
    /// move a job. When that step has a question to ask first (finishing a
    /// job asks what it took), the question is a sheet in the main window, so
    /// the window is brought up for it; a plain step leaves the person where
    /// they are.
    func markPrinted(job id: String) {
        guard let shop, let there = shop.moveAlongTarget(id, by: 1) else { return }
        if shop.questionFor(id, moving: there) != nil {
            popover?.performClose(nil); popover = nil
            ShopWindowOpener.raise()
        }
        shop.takeNextStep(id)
    }

    @objc private func toggle() {
        guard let shop, let button = item?.button else { return }
        if let popover, popover.isShown { popover.performClose(nil); self.popover = nil; return }
        // Built on opening and dropped on closing, so the panel costs nothing
        // while it is not on screen.
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: FloorPanel.width, height: 1)
        popover.contentViewController = NSHostingController(rootView: FloorPanel(shop: shop).modifier(ShopsLocale(words: shop.words)))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        Self.joinTheSpaceInFront(popover)
        self.popover = popover
    }

    /// Over another app's FULL-SCREEN Space the panel did not appear: the menu
    /// bar slid down, the click landed, and the popover's window opened on the
    /// desktop Space behind, where Khayt's own window lives. A popover's window
    /// is an ordinary one and joins only the Space its app is on. Telling it
    /// it is a full-screen auxiliary that may join any Space puts it where the
    /// click was, and ordering it front without activating Khayt keeps the
    /// person in their full-screen app. It does not activate the app, because
    /// activating would switch to Khayt's window's Space, which is the same
    /// failure seen from the other side.
    static func joinTheSpaceInFront(_ popover: NSPopover) {
        guard let window = popover.contentViewController?.view.window else { return }
        window.collectionBehavior.formUnion([.fullScreenAuxiliary, .canJoinAllSpaces, .transient])
        window.level = .popUpMenu
        window.orderFrontRegardless()
        window.makeKey()
    }
}

/// A row that behaves like a menu item without being one.
struct MenuLine: View {
    let text: String
    let key: String?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(text)
                Spacer()
                if let key {
                    Text(verbatim: key).font(.caption).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14).padding(.vertical, 5)
            .background(hovered ? Color.accentColor.opacity(0.16) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
