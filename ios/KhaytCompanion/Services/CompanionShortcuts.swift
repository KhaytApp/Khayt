import AppIntents

struct OpenOrdersShortcut: AppIntent {
    static var title: LocalizedStringResource = "Open production queue"
    static var description = IntentDescription("Opens Khayt Companion orders tab.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set("orders", forKey: "khayt.pending.tab")
        return .result()
    }
}

struct OpenInventoryShortcut: AppIntent {
    static var title: LocalizedStringResource = "Open filament inventory"
    static var description = IntentDescription("Opens Khayt Companion inventory.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set("inventory", forKey: "khayt.pending.tab")
        return .result()
    }
}

struct KhaytCompanionShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenOrdersShortcut(),
            phrases: ["Open \(.applicationName) queue", "Show \(.applicationName) orders"],
            shortTitle: "Queue",
            systemImageName: "rectangle.stack"
        )
        AppShortcut(
            intent: OpenInventoryShortcut(),
            phrases: ["Open \(.applicationName) inventory", "Show \(.applicationName) spools"],
            shortTitle: "Inventory",
            systemImageName: "cylinder.split.1x2"
        )
        AppShortcut(
            intent: AdvanceJobIntent(),
            phrases: ["Advance a job in \(.applicationName)", "Move a \(.applicationName) job on"],
            shortTitle: "Advance a job",
            systemImageName: "arrow.forward.circle"
        )
        AppShortcut(
            intent: FilamentLeftIntent(),
            phrases: ["How much filament is left in \(.applicationName)", "\(.applicationName) filament left"],
            shortTitle: "Filament left",
            systemImageName: "cylinder"
        )
        AppShortcut(
            intent: LogWasteIntent(),
            phrases: ["Log a failed print in \(.applicationName)"],
            shortTitle: "Log a failed print",
            systemImageName: "trash"
        )
        AppShortcut(
            intent: ScanSpoolIntent(),
            phrases: ["Scan a spool in \(.applicationName)"],
            shortTitle: "Scan a spool",
            systemImageName: "barcode.viewfinder"
        )
    }
}
