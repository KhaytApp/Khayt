import SwiftUI

struct ConnectionBanner: View {
    @EnvironmentObject private var health: ConnectionHealth
    @EnvironmentObject private var api: KhaytAPIClient

    var body: some View {
        // Shown when the Mac is out of reach, and ALSO when it is not but this
        // phone is still holding edits. An edit waiting to be sent is a fact
        // about the shop's records; leaving it invisible is how somebody comes
        // to believe a job was advanced when the Mac has never heard of it.
        if health.state != .connected || api.pendingCount > 0 {
            HStack(spacing: 10) {
                Circle()
                    .fill(iconColor)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(iconColor)
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(KhaytDesign.textDim)
                    if api.pendingCount > 0 {
                        Text(String(format: L10n.tr("sync.pending"), api.pendingCount))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(KhaytDesign.textDim)
                    }
                }
                Spacer(minLength: 0)
                if health.state == .unreachable || health.state == .unauthorized {
                    Button(L10n.tr("connection.retry")) {
                        Task { await health.refresh() }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(iconColor, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal, KhaytDesign.pad)
            .padding(.vertical, 7)
            .background(iconColor.opacity(0.16))
            .overlay(alignment: .bottom) {
                Rectangle().fill(iconColor.opacity(0.2)).frame(height: 1)
            }
        }
    }

    private var title: String {
        switch health.state {
        case .unauthorized: return L10n.tr("connection.unauthorized")
        default: return L10n.tr("connection.unreachable")
        }
    }

    private var message: String {
        switch health.state {
        case .unknown: return L10n.tr("connection.banner.checking")
        case .unreachable:
            // When the desktop is out of reach the screens are not empty any
            // more — they show the last good answer. Say when that was, because
            // an old number presented as current is worse than no number: a shop
            // could pick up a spool it finished this morning.
            if let since = api.servingCachedSince {
                return L10n.tr("connection.banner.cached").replacingOccurrences(
                    of: "{when}", with: Self.relative.localizedString(for: since, relativeTo: Date()))
            }
            return L10n.tr("connection.banner.unreachable")
        case .unauthorized: return L10n.tr("connection.banner.pin")
        case .connected: return ""
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private var iconColor: Color {
        switch health.state {
        case .unauthorized: return KhaytDesign.warn
        case .unknown: return KhaytDesign.textMuted
        default: return KhaytDesign.danger
        }
    }
}
