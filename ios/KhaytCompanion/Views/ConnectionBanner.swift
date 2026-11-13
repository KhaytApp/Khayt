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
    @EnvironmentObject private var settings: ConnectionSettings

    var body: some View {
        if settings.isSampleShop {
            // Said on every screen: nothing here is a real shop, and the way
            // out is to pair with one — which clears the sample away.
            // One line (review W9): it sits on every screen, so it gives back
            // the room the two-line version took. The explanation is still
            // read out by VoiceOver, with the words.
            HStack(spacing: 8) {
                Circle().fill(KhaytDesign.attention).frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(L10n.tr("sample.banner"))
                    .font(.khayt(12.5, .semibold, relativeTo: .caption))
                    .foregroundStyle(KhaytDesign.attention)
                    .lineLimit(1)
                    .accessibilityLabel(L10n.tr("sample.banner") + ". " + L10n.tr("sample.banner.line"))
                Spacer(minLength: 0)
                Button { api.unpair() } label: {
                    Text(L10n.tr("sample.pair"))
                        .font(.khayt(12, .semibold, relativeTo: .caption))
                        .foregroundStyle(KhaytDesign.brand)
                        .lineLimit(1)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(KhaytDesign.brand.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(L10n.tr("sample.banner.line"))
            }
            .padding(.horizontal, KhaytDesign.pad)
            .background(KhaytDesign.attention.opacity(0.12))
        } else if let moved = health.macMoved {
            moveStrip(moved)
        } else if settings.needsPairAgain {
            pairAgainStrip
                .sheet(isPresented: $pairingAgain) { PairAgainSheet() }
        } else if !api.canWrite {
            // A viewer's cloud sign-in, no Mac: every screen says it reads only.
            ReadOnlyNote()
                .overlay(alignment: .bottom) { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
        } else if health.state == .pinTooShort {
            strip(tint: KhaytDesign.attention, loud: true,
                  title: L10n.tr("connection.pin_too_short"), line: L10n.tr("pair.pin.too_short"),
                  action: true)
        } else if health.state == .unauthorized {
            strip(tint: KhaytDesign.attention, loud: true,
                  title: L10n.tr("connection.unauthorized"), line: L10n.tr("connection.banner.pin"),
                  action: true)
        } else {
            switch (api.holdsBook, health.macInReach) {
            case (true, true):
                if api.pendingCount > 0 {
                    strip(tint: api.macRefused == nil ? KhaytDesign.note : KhaytDesign.attention, loud: false,
                          title: pending, line: api.macRefused, action: false)
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

    @State private var pairingAgain = false

    /// The Mac proved it no longer knows this phone, or it moved to an
    /// address that could not prove itself. No PIN is sent by itself: the
    /// person types it, in `PairAgainSheet`.
    private var pairAgainStrip: some View {
        HStack(spacing: 10) {
            Circle().fill(KhaytDesign.attention).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.tr("pair.again.title"))
                    .font(.khayt(12, .semibold, relativeTo: .caption))
                    .foregroundStyle(KhaytDesign.attention)
                Text(L10n.tr("pair.again.line"))
                    .font(.khayt(11, relativeTo: .caption2))
                    .foregroundStyle(KhaytDesign.textDim)
            }
            Spacer(minLength: 0)
            Button(L10n.tr("pair.again.button")) { pairingAgain = true }
                .font(.khayt(12, .semibold, relativeTo: .caption))
                // onBrand: white on the light fill, dark ink on the dark one,
                // where white on #E0A73C read at about 2:1 (F9).
                .foregroundStyle(KhaytDesign.onBrand)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(KhaytDesign.attention, in: RoundedRectangle(cornerRadius: 8))
                .tapTarget()
        }
        .padding(.horizontal, KhaytDesign.pad)
        .padding(.vertical, 7)
        .background(KhaytDesign.attention.opacity(0.14))
        .overlay(alignment: .bottom) { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
    }

    private var pending: String { L10n.format("sync.pending", api.pendingCount) }

    /// The paired Mac's name answers at a new address. Moving there asks the
    /// person for the PIN (no stored one is sent), so it waits for them — see `ConnectionHealth.followTheMac`.
    private func moveStrip(_ moved: MacAddress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle().fill(KhaytDesign.attention).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.tr("connection.moved"))
                        .font(.khayt(12, .semibold, relativeTo: .caption))
                        .foregroundStyle(KhaytDesign.attention)
                    Text(L10n.format("connection.moved.line", "\(moved.host):\(moved.port)"))
                        .font(.khayt(11, relativeTo: .caption2))
                        .foregroundStyle(KhaytDesign.textDim)
                }
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(L10n.tr("connection.moved.not_now")) { health.declineMove() }
                    .font(.khayt(12, .semibold, relativeTo: .caption))
                    .foregroundStyle(KhaytDesign.textDim)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .tapTarget()
                Button(L10n.tr("connection.moved.use")) { Task { await health.acceptMove() } }
                    .font(.khayt(12, .semibold, relativeTo: .caption))
                    .foregroundStyle(KhaytDesign.onBrand)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(KhaytDesign.attention, in: RoundedRectangle(cornerRadius: 8))
                    .tapTarget()
            }
        }
        .padding(.horizontal, KhaytDesign.pad)
        .padding(.vertical, 7)
        .background(KhaytDesign.attention.opacity(0.14))
        .overlay(alignment: .bottom) { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
    }

    private var asOf: String {
        let when = api.bookAsOf.map { $0.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale)) } ?? "—"
        return L10n.format("connection.as_of", when)
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
                .foregroundStyle(loud ? KhaytDesign.onBrand : KhaytDesign.brand)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(loud ? tint : KhaytDesign.brand.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                .tapTarget()
            }
        }
        .padding(.horizontal, KhaytDesign.pad)
        .padding(.vertical, 7)
        .background(loud ? tint.opacity(0.14) : KhaytDesign.sunk)
        .overlay(alignment: .bottom) { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
    }
}
