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

struct CompanionStatusBadge: View {
    let status: String
    var compact = false

    var body: some View {
        let color = KhaytDesign.statusColor(for: status)
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: compact ? 6 : 7, height: compact ? 6 : 7)
            Text(OrderStatus(rawValue: status)?.localizedLabel ?? status.capitalized)
        }
        // As the Mac's StatusPill: a dot in the stage colour, the label in
        // ink on the stage's tint, so the words never sit in a colour that
        // reads at 2:1.
        .font(.khayt(compact ? 11 : 12, .semibold, relativeTo: .caption))
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 4 : 5)
        .foregroundStyle(KhaytDesign.ink)
        .background(KhaytDesign.statusSoft(for: status), in: Capsule())
        .environment(\.layoutDirection, .leftToRight)
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
