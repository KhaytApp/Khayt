import SwiftUI

enum CompanionTheme {
    static var brand: Color { KhaytDesign.accent }
    static let lowStockThresholdGrams = 200.0

    static func statusColor(for status: String) -> Color {
        KhaytDesign.statusColor(for: status)
    }

    static func statusIcon(for status: String) -> String {
        switch status.lowercased() {
        case "pending": return "clock"
        case "printing": return "printer.fill"
        case "post": return "paintbrush"
        case "qc": return "checkmark.seal"
        case "completed": return "checkmark.circle.fill"
        case "on_hold": return "pause.circle"
        case "idle", "ready": return "checkmark.circle"
        case "busy": return "printer.fill"
        case "error": return "exclamationmark.triangle.fill"
        default: return "circle"
        }
    }
}

enum CompanionHaptics {
    static func success() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    static func warning() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }
}
