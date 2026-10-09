import AppIntents
import SwiftUI
import WidgetKit

/// Control Center, Lock Screen and Action button controls: the two shop
/// actions that start with the phone in hand. Each opens Khayt on its sheet
/// (`supportedModes = .foreground(.immediate)`); the action itself — weighing
/// a failed print, reading a label — is done in the app.
struct LogWasteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.khaytapp.companion.control.waste") {
            ControlWidgetButton(action: LogWasteIntent()) {
                Label("Log a failed print", systemImage: "trash")
            }
        }
        .displayName("Log a failed print")
        .description("Opens Khayt on the failed-print form.")
    }
}

struct ScanSpoolControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.khaytapp.companion.control.spool") {
            ControlWidgetButton(action: ScanSpoolIntent()) {
                Label("Scan a spool", systemImage: "barcode.viewfinder")
            }
        }
        .displayName("Scan a spool")
        .description("Opens Khayt on booking in a spool.")
    }
}
