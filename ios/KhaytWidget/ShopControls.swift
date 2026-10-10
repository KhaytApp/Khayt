import AppIntents
import Foundation

// Shared by the app and the widget extension (the KhaytWidget folder is in
// both targets): Siri and Shortcuts run these in the app, and the Control
// Center buttons in ShopControlWidgets.swift name them from the extension.

/// Open the app on the failed-print sheet.
struct LogWasteIntent: AppIntent {
    static let title: LocalizedStringResource = "Log a failed print"
    static let description = IntentDescription("Opens Khayt on the failed-print form.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingAction.ask("waste")
        return .result()
    }
}

/// Open the app on booking in a spool.
struct ScanSpoolIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan a spool"
    static let description = IntentDescription("Opens Khayt on booking in a spool.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingAction.ask("addspool")
        return .result()
    }
}

/// A sheet an intent asked Home to open, taken once.
///
/// In the App Group's defaults, not the app's own: an intent run from a
/// Control may perform in the widget extension's process, whose
/// `UserDefaults.standard` the app never reads.
enum PendingAction {
    static let key = "khayt.pending.action"
    private static var shared: UserDefaults? { UserDefaults(suiteName: "group.com.khaytapp.companion") }

    static func ask(_ action: String) { shared?.set(action, forKey: key) }

    static func take() -> String? {
        guard let v = shared?.string(forKey: key) else { return nil }
        shared?.removeObject(forKey: key)
        return v
    }
}
