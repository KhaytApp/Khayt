import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KhaytCore

/// The Bed Ready tools on the Mac: the HueForge studio, the Calibration
/// Assistant and the Orca filament profiles, in one window of their own.
///
/// ── WHY A WINDOW, AND WHY ONE ─────────────────────────────────────────────
///
/// The Mac has no separate Bed Ready edition (decided Nov 5 2026), so these
/// live in Khayt — but they are not part of the shop's book the way Jobs and
/// the Library are. A sidebar shelf would put a photo-to-relief studio between
/// Customers and Waste. A window beside the shop's is where a maker works on a
/// picture while the jobs stay on screen, and one window with a tab per tool
/// is one thing to find in the Tools menu rather than three.
///
/// None of these tools writes the book except the calibration result log,
/// which goes through the write chain like every other edit and asks the staff
/// lock for `settings`/`edit` first.
struct StudioWindow: View {
    static let id = "studio"

    @Bindable var shop: Shop
    /// Which tool is open. Remembered, and set by the Tools menu before it
    /// opens the window, so each menu item lands on its own tab.
    @AppStorage(StudioTab.storageKey) private var tab = StudioTab.hueforge.rawValue

    var body: some View {
        Group {
            if shop.needsSignIn {
                // Behind the staff lock, nothing — the menu that opens this is
                // disabled too, but a window left open stays on screen.
                EmptyHere(title: shop.words.callIt("mac.st_locked"))
            } else {
                TabView(selection: $tab) {
                    HueForgeStudio(shop: shop)
                        .tabItem { Text(shop.words.callIt("mac.st_hueforge")) }
                        .tag(StudioTab.hueforge.rawValue)
                    CalibrationAssistant(shop: shop)
                        .tabItem { Text(shop.words.callIt("mac.st_calibration")) }
                        .tag(StudioTab.calibration.rawValue)
                    OrcaFilamentProfiles(shop: shop)
                        .tabItem { Text(shop.words.callIt("mac.st_filaments")) }
                        .tag(StudioTab.filaments.rawValue)
                }
                .padding(.top, 6)
            }
        }
        .frame(minWidth: 820, minHeight: 600)
    }
}

enum StudioTab: String, CaseIterable {
    case hueforge, calibration, filaments
    static let storageKey = "studio.tab"
}

/// Tools ▸ HueForge Studio… and the rest. Each sets the tab, then opens the
/// window — `openWindow` brings an open one forward rather than making two.
struct ToolsMenu: View {
    @Environment(Shop.self) private var shop
    @Environment(\.openWindow) private var openWindow
    @AppStorage(StudioTab.storageKey) private var tab = StudioTab.hueforge.rawValue

    var body: some View {
        Button(Words.upfront("mac.st_hueforge") + "\u{2026}") { open(.hueforge) }
            .keyboardShortcut("h", modifiers: [.command, .option, .shift])
        Button(Words.upfront("mac.st_calibration") + "\u{2026}") { open(.calibration) }
        Button(Words.upfront("mac.st_filaments") + "\u{2026}") { open(.filaments) }
    }

    private func open(_ which: StudioTab) {
        tab = which.rawValue
        openWindow(id: StudioWindow.id)
    }
}

/// The one `StudioEngine` the app makes, started off the main thread.
///
/// Making one loads six modules into a fresh context on the engine's own
/// thread and waits for it — a tenth of a second the main thread should not
/// spend, so it is made on a utility queue and handed back.
@MainActor
enum Studio {
    private static var made: StudioEngine?
    private static var making: Task<StudioEngine?, Never>?

    static func engine() async -> StudioEngine? {
        if let made { return made }
        if let making { return await making.value }
        let task = Task<StudioEngine?, Never> {
            await withCheckedContinuation { (done: CheckedContinuation<StudioEngine?, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    done.resume(returning: try? StudioEngine())
                }
            }
        }
        making = task
        let engine = await task.value
        made = engine
        making = nil
        return engine
    }

    /// Run blocking work — a zip, a file write, a folder walk — on a queue,
    /// never on the main thread or Swift's cooperative pool (`DispatchQueue`,
    /// as `swift-pool-starvation` in the house notes says).
    nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                done.resume(with: Result { try work() })
            }
        }
    }

    /// Ask where to save, with the name filled in. Nil when the shop cancels.
    static func askWhereToSave(_ name: String, type: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        if let ut = UTType(filenameExtension: type) { panel.allowedContentTypes = [ut] }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
