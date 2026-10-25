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
    }

    @objc private func tickFired() { refresh() }

    /// What the item last drew, so a tick that changes nothing redraws nothing.
    private(set) var shown: FloorRead.Label?

    /// The style picker changed: draw the new one now rather than in five
    /// seconds.
    func restyle() { shown = nil; refresh() }

    /// The ring and figures for the print that finishes soonest, "+N" for the
    /// others, or the nozzle alone — with a dot when a machine wants somebody
    /// (`FloorRead`). Read off what the shop holds; no printer is asked.
    private func refresh() {
        guard let shop, let button = item?.button else { return }
        let lines = FloorRead.lines(shop)
        let label = FloorRead.label(lines, style: MenuBarStyle.current, words: shop.words)
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
        button.image = StatusGlyph.image(ring: label.ring, attention: label.attention)
        button.title = label.text.isEmpty ? "" : " " + label.text
    }

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

    @objc private func toggle() {
        guard let shop, let button = item?.button else { return }
        if let popover, popover.isShown { popover.performClose(nil); self.popover = nil; return }
        // Built on opening and dropped on closing, so the panel costs nothing
        // while it is not on screen.
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 1)
        popover.contentViewController = NSHostingController(rootView: FloorPanel(shop: shop).modifier(ShopsLocale(words: shop.words)))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        self.popover = popover
    }
}

/// What the strip shows when it is pulled down: the fleet, problems first.
///
/// Not private: the snapshot runner renders it through `ImageRenderer`, because
/// a menu bar extra is not a window and the window shot cannot see it. A panel
/// nobody photographs is a panel that ships however it looks.
///
/// READ-ONLY. A row opens its machine in the main window; pausing or
/// cancelling a print is the machine card's, where the shop can see what it is
/// about to stop.
struct FloorPanel: View {
    let shop: Shop
    /// The job each print belongs to. Looked up when the panel opens (`.task`);
    /// handed in by the snapshot runner, which cannot wait for a task.
    @State var jobs: [String: Order] = [:]
    /// The clock the finish times are read against — fixed by the snapshot.
    var now: Date? = nil
    @Environment(\.openWindow) private var openWindow

    /// More rows than this scroll, so a farm's panel still fits the screen.
    static let rowsBeforeScrolling = 7

    var body: some View {
        let lines = FloorRead.lines(shop)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shop.shopName).font(.headline)
                Text(Self.summary(shop)).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)

            Divider()

            // Retired printers are not on the floor any more (`machinesInUse`).
            if lines.isEmpty {
                Text(shop.words.callIt("mac.no_machines"))
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(14)
            } else if lines.count > Self.rowsBeforeScrolling {
                ScrollView { rows(lines) }.frame(height: 430)
            } else {
                rows(lines)
            }

            Divider()

            // What a person would go to the app FOR, rather than a list of
            // everything the app can do.
            VStack(spacing: 1) {
                MenuLine(text: shop.words.callIt("mac.mb_open_khayt"), key: "⌘0") {
                    openWindow(id: "shop")
                    NSApp.activate(ignoringOtherApps: true)
                }
                // Planning the floor is editing jobs; and nothing that opens a
                // sheet over the sign-in screen (alpha.62 re-check).
                if !shop.schedulableRows.isEmpty && !shop.workingMachines.isEmpty
                    && shop.lockAllows("orders", "edit") {
                    MenuLine(text: shop.words.callIt("sched.suggest_btn"), key: nil) {
                        openWindow(id: "shop")
                        NSApp.activate(ignoringOtherApps: true)
                        shop.shelf = .machines
                        shop.forgetSchedule()
                        shop.schedulingWork = true
                    }
                }
            }
            .padding(.vertical, 5)
        }
        .frame(width: 320)
        .task {
            guard jobs.isEmpty else { return }
            jobs = await FloorRead.jobs(shop, lines: FloorRead.lines(shop))
        }
    }

    @ViewBuilder private func rows(_ lines: [FloorLine]) -> some View {
        VStack(spacing: 0) {
            ForEach(lines) { line in
                FleetRow(line: line, shop: shop, job: jobs[line.id], now: now ?? Date()) {
                    FloorStatus.shared.open(machine: line.id)
                }
                if line.id != lines.last?.id { Divider().padding(.leading, 14) }
            }
        }
        .padding(.vertical, 4)
    }

    /// One line saying where the shop stands, chosen so it is never a zero.
    static func summary(_ shop: Shop) -> String {
        let printing = shop.printingNow
        if printing == 0 { return shop.words.callIt("mac.nothing_printing") }
        guard let soonest = shop.soonestFinish else {
            return shop.words.counting(printing, "mac.printing_count")
        }
        return shop.words.counting(printing, "mac.printing_count")
             + " · " + shop.words.callIt("mac.next_free") + " " + PrinterWatch.spell(soonest, shop.words)
    }
}

/// One machine: what it is doing, how far in, when it is free, and which job.
private struct FleetRow: View {
    let line: FloorLine
    let shop: Shop
    let job: Order?
    let now: Date
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 9) {
                mark.frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(line.name).font(.callout.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 6)
                        trailing
                    }
                    if line.printing, let left = line.left {
                        Text(verbatim: shop.words.callIt("mac.mbp_left",
                                                         ["left": .string(FloorRead.duration(left, shop.words))])
                             + " · " + FloorRead.finishes(left, now: now, words: shop.words))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if !line.filename.isEmpty, line.printing || line.attention != nil {
                        Text(verbatim: line.filename)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if let job {
                        Text(verbatim: FloorRead.jobLine(job, shop: shop))
                            .font(.caption).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    if line.rank == .idle || line.rank == .offline {
                        Text(verbatim: quiet).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(hovered ? Color.accentColor.opacity(0.12) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityHint(shop.words.callIt("mac.mbp_open_machine", ["machine": .string(line.name)]))
    }

    @ViewBuilder private var mark: some View {
        if line.printing {
            ProgressRing(value: Double(line.progress) / 100,
                         tint: line.attention == nil ? Color.accentColor : Khayt.attention)
        } else {
            Circle().fill(dot).frame(width: 8, height: 8)
        }
    }

    @ViewBuilder private var trailing: some View {
        if let attention = line.attention {
            HStack(spacing: 4) {
                Image(systemName: attention == .fault ? "exclamationmark.octagon.fill"
                                                      : "exclamationmark.triangle.fill")
                Text(verbatim: shop.words.callIt(attention.wordKey))
                if line.progress > 0, line.printing || attention == .paused || attention == .runout {
                    Text(verbatim: shop.words.callIt("mac.mbp_pct", ["pct": .string(shop.words.numeral(line.progress))]))
                        .monospacedDigit()
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(attention == .fault ? Khayt.late : Khayt.attention)
        } else if line.printing {
            // A print going well is not an alarm: ordinary ink, so the warm
            // colours above are kept for the lines that need a look.
            Text(verbatim: shop.words.callIt("mac.mbp_pct", ["pct": .string(shop.words.numeral(line.progress))]))
                .font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(.primary)
        }
    }

    private var dot: Color {
        switch line.rank {
        case .attention: line.attention == .fault ? Khayt.late : Khayt.attention
        case .printing: Color.accentColor
        case .idle: line.quiet == nil ? Khayt.done : Color(nsColor: .tertiaryLabelColor)
        case .offline: Color(nsColor: .quaternaryLabelColor)
        }
    }

    /// Why there is no print, rather than a blank that reads as broken. A
    /// machine nobody configured is not a machine that is failing — the same
    /// sentences the front door's tiles use (`Shop.quiet`).
    private var quiet: String {
        guard let quiet = line.quiet else { return shop.words.callIt("mac.idle") }
        if quiet == .notAnswering, let problem = shop.printers.readings[line.id]?.problem { return problem }
        return shop.words.callIt(quiet == .noProtocol ? "mac.cannot_ask" : quiet.wordKey)
    }
}

/// A row that behaves like a menu item without being one.
private struct MenuLine: View {
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
