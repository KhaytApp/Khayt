import SwiftUI
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
        item.button?.image = Self.glyph()
        item.button?.image?.isTemplate = true
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(toggle)
        self.item = item
        refresh()

        // Five seconds. A menu bar is glanced at, not watched: polling the
        // shop's own printer readings any harder would put this back in the
        // business of costing something.
        tick = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func remove() {
        tick?.invalidate(); tick = nil
        popover?.performClose(nil); popover = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    /// The count beside the glyph, or nothing when nothing is running.
    private func refresh() {
        guard let shop, let button = item?.button else { return }
        let n = shop.printingNow
        button.title = n > 0 ? " \(n)" : ""
    }

    @objc private func toggle() {
        guard let shop, let button = item?.button else { return }
        if let popover, popover.isShown { popover.performClose(nil); self.popover = nil; return }
        // Built on opening and dropped on closing, so the panel costs nothing
        // while it is not on screen.
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 300, height: 1)
        popover.contentViewController = NSHostingController(rootView: FloorPanel(shop: shop))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        self.popover = popover
    }

    /// The app's own nozzle, drawn once into a template image.
    private static func glyph() -> NSImage? {
        let renderer = ImageRenderer(content:
            NozzleShape().stroke(lineWidth: 1.5).frame(width: 12, height: 15).padding(1))
        renderer.scale = 2
        return renderer.nsImage
    }
}

/// What the strip shows when it is pulled down.
///
/// Not private: the snapshot runner renders it through `ImageRenderer`, because
/// a menu bar extra is not a window and the window shot cannot see it. A panel
/// nobody photographs is a panel that ships however it looks.
struct FloorPanel: View {
    let shop: Shop
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shop.shopName).font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)

            Divider()

            if shop.machines.isEmpty {
                Text(shop.words.callIt("mac.no_machines"))
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(14)
            } else {
                VStack(spacing: 0) {
                    ForEach(shop.machines) { machine in
                        MachineLine(machine: machine, shop: shop)
                        if machine.id != shop.machines.last?.id { Divider().padding(.leading, 14) }
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()

            // What a person would go to the app FOR, rather than a list of
            // everything the app can do.
            VStack(spacing: 1) {
                MenuLine(text: shop.words.callIt("mac.open_book"), key: "⌘0") {
                    openWindow(id: "shop")
                    NSApp.activate(ignoringOtherApps: true)
                }
                if !shop.schedulableRows.isEmpty && !shop.machines.isEmpty {
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
        .frame(width: 300)
    }

    /// One line saying where the shop stands, chosen so it is never a zero.
    private var summary: String {
        let printing = shop.printingNow
        if printing == 0 { return shop.words.callIt("mac.nothing_printing") }
        guard let soonest = shop.soonestFinish else {
            return shop.words.counting(printing, "mac.printing_count")
        }
        return shop.words.counting(printing, "mac.printing_count")
             + " · " + shop.words.callIt("mac.next_free") + " " + PrinterWatch.spell(soonest)
    }
}

/// One machine: what it is doing, how far in, and when it is free.
private struct MachineLine: View {
    let machine: Machine
    let shop: Shop

    var body: some View {
        let status = shop.printers.readings[machine.id]?.status
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Circle().fill(dot(status)).frame(width: 7, height: 7)
                Text(machine.name).font(.callout.weight(.medium)).lineLimit(1)
                Spacer(minLength: 6)
                if let status, status.progress > 0 {
                    Text(verbatim: "\(status.progress)%")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if let status {
                if !status.filename.isEmpty {
                    Text(status.filename).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if status.progress > 0 {
                    ProgressView(value: Double(status.progress) / 100).controlSize(.small)
                }
                if let left = status.timeRemaining, left > 0 {
                    Text(shop.words.callIt("mac.eta") + " " + PrinterWatch.spell(left))
                        .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                }
            } else {
                // Why there is no reading, rather than a blank that reads as
                // broken. A machine nobody configured is not a machine that is
                // failing.
                Text(quiet).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    private var quiet: String {
        switch PrinterWatch.notWatched(machine) {
        case .noConnection: return shop.words.callIt("mac.not_connected")
        case .otherProtocol(let name):
            return shop.words.callIt("mac.not_polled", ["protocol": .string(name)])
        case nil:
            return shop.printers.readings[machine.id]?.problem
                ?? shop.words.callIt("mac.asking")
        }
    }

    private func dot(_ status: KhaytEngine.PrinterStatus?) -> Color {
        guard let status else { return Color(nsColor: .quaternaryLabelColor) }
        switch status.state {
        case "printing": return Khayt.hot
        case "error":    return Khayt.late
        case "paused":   return Khayt.attention
        default:         return Khayt.done
        }
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
