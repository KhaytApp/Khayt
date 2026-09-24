import SwiftUI

/// The connection, as `design/ios-v2/` settles it: a two-by-two of "does this
/// phone hold the book" and "is the Mac answering".
///
/// | | Mac in reach | Mac away |
/// |---|---|---|
/// | **book** | nothing to say | a QUIET as-of stamp, and Refresh |
/// | **no book** | a quiet "live from the Mac" note | the only red — the screens really are empty |
///
/// Losing the Mac used to be alarm red with "Retry". With a book on the phone
/// that is the normal condition of a phone in a workshop, not a failure: the
/// screens are right, only old. So it is said once, quietly, with the time —
/// and the action is to refresh a book that is working fine, not to retry
/// something that did not fail. Edits waiting to reach the Mac are said in the
/// same strip, because an unsent edit is a fact about the shop's records.
struct ConnectionBanner: View {
    @EnvironmentObject private var health: ConnectionHealth
    @EnvironmentObject private var api: KhaytAPIClient

    var body: some View {
        if health.state == .unauthorized {
            strip(tint: KhaytDesign.attention, loud: true,
                  title: L10n.tr("connection.unauthorized"), line: L10n.tr("connection.banner.pin"),
                  action: true)
        } else {
            switch (api.holdsBook, health.macInReach) {
            case (true, true):
                if api.pendingCount > 0 {
                    strip(tint: KhaytDesign.note, loud: false, title: pending, line: nil, action: false)
                }
            case (true, false):
                strip(tint: KhaytDesign.note, loud: false, title: asOf,
                      line: api.pendingCount > 0 ? pending : nil, action: true)
            case (false, true):
                strip(tint: KhaytDesign.note, loud: false, title: L10n.tr("connection.live_only"),
                      line: nil, action: false)
            case (false, false):
                strip(tint: KhaytDesign.late, loud: true,
                      title: L10n.tr("connection.unreachable"), line: L10n.tr("connection.banner.unreachable"),
                      action: true)
            }
        }
    }

    private var pending: String { String(format: L10n.tr("sync.pending"), api.pendingCount) }

    private var asOf: String {
        let when = api.bookAsOf.map { $0.formatted(date: .omitted, time: .shortened) } ?? "—"
        return String(format: L10n.tr("connection.as_of"), when)
    }

    private func strip(tint: Color, loud: Bool, title: String, line: String?, action: Bool) -> some View {
        HStack(spacing: 10) {
            if loud { Circle().fill(tint).frame(width: 7, height: 7) }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.khayt(12, loud ? .semibold : .medium, relativeTo: .caption))
                    .foregroundStyle(loud ? tint : KhaytDesign.textDim)
                if let line {
                    Text(line)
                        .font(.khayt(11, relativeTo: .caption2))
                        .foregroundStyle(KhaytDesign.textDim)
                }
            }
            Spacer(minLength: 0)
            if action {
                Button(L10n.tr("connection.refresh")) {
                    Task { await health.refresh() }
                }
                .font(.khayt(12, .semibold, relativeTo: .caption))
                .foregroundStyle(loud ? Color.white : KhaytDesign.brand)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(loud ? tint : KhaytDesign.brand.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, KhaytDesign.pad)
        .padding(.vertical, 7)
        .background(loud ? tint.opacity(0.14) : KhaytDesign.sunk)
        .overlay(alignment: .bottom) { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
    }
}
