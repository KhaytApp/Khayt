import SwiftUI

/// One job, as `design/ios-v2/` draws it on Home and in Orders: a card that is
/// swiped FORWARD to move the job on (trailing in English, leading in Arabic),
/// and tapped to open its page.
///
/// Two layouts, both the design's. `.compact` is Home's — the job, then who it
/// is for with its stage beside it. `.full` is the Orders list — the same two
/// lines, and a third with the stage, a late tag and the due date.
///
/// Only printing and QC earn a rail (`KhaytDesign.isRailed`), and a late job,
/// whatever its stage. A pending job with no colour is what makes the coloured
/// ones readable.
struct JobCard: View {
    enum Layout { case compact, full }

    let order: QueueOrder
    var facts: OrderFacts? = nil
    var layout: Layout = .compact
    let isUpdating: Bool
    let onAdvance: () -> Void
    let onOpen: () -> Void

    @Environment(\.layoutDirection) private var direction
    @State private var drag: CGFloat = 0
    /// The design's `THRESHOLD`: how far forward a card travels before
    /// letting go moves the job on.
    static let threshold: CGFloat = 92

    private var next: OrderStatus? { OrderStatus(rawValue: order.status)?.nextInQueue }
    private var forward: CGFloat { direction == .rightToLeft ? -1 : 1 }
    private var past: Bool { drag * forward > Self.threshold }

    /// "Acme · PLA · Ink · ×4" — who it is for, then what it is made of and how
    /// many, when the book says. With no book, the printer stands in: on a shop
    /// floor it is the next most useful thing to know.
    var subtitle: String {
        var parts = [order.displayClient]
        if let facts {
            if let m = facts.material { parts.append(m) }
            if let q = facts.quantity { parts.append("×\(q)") }
        } else if let machine = order.machine, !machine.isEmpty {
            parts.append(machine)
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        ZStack(alignment: .leading) {
            if let next, drag != 0 {
                HStack {
                    Text((past ? L10n.tr("stage.short.\(next.rawValue)") : L10n.tr("pulse.move_to")).uppercased())
                        .font(.khayt(11.5, .bold, relativeTo: .caption))
                        .tracking(0.9)
                        .foregroundStyle(past ? KhaytDesign.brand : KhaytDesign.note)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(past ? KhaytDesign.brand.opacity(0.22) : KhaytDesign.sunk, in: RoundedRectangle(cornerRadius: 11))
            }
            card
                .offset(x: drag)
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            guard next != nil, !isUpdating else { return }
                            let d = value.translation.width
                            // Only forward is tracked; a backwards drag does nothing.
                            drag = d * forward > 0 ? min(abs(d), 150) * forward : 0
                        }
                        .onEnded { _ in
                            let go = past
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { drag = 0 }
                            if go { onAdvance() }
                        }
                )
                .onTapGesture(perform: onOpen)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: next.map { String(format: L10n.tr("order.detail.move_to"), $0.localizedLabel) } ?? "") {
            if next != nil { onAdvance() }
        }
    }

    private var tone: Color { KhaytDesign.statusColor(for: order.status) }

    private var stageChip: some View {
        Group {
            if isUpdating {
                ProgressView().controlSize(.mini)
            } else {
                Text(L10n.tr("stage.short.\(order.status)"))
                    .font(.khayt(11, .semibold, relativeTo: .caption2))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .foregroundStyle(tone)
                    .background(tone.opacity(0.14), in: Capsule())
            }
        }
    }

    private var card: some View {
        let railed = KhaytDesign.isRailed(order.status) || order.isOverdue
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(order.displayTitle)
                    .font(.khayt(15, .medium, relativeTo: .body))
                    .foregroundStyle(KhaytDesign.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("#\(order.id)")
                    .font(.khayt(12, .medium, relativeTo: .caption).monospacedDigit())
                    .foregroundStyle(KhaytDesign.note)
                    .lineLimit(1)
                    .environment(\.layoutDirection, .leftToRight)
            }
            HStack(spacing: 9) {
                Text(subtitle)
                    .font(.khayt(12.5, relativeTo: .footnote))
                    .foregroundStyle(KhaytDesign.note)
                    .lineLimit(1)
                if layout == .compact {
                    Spacer(minLength: 0)
                    stageChip
                }
            }
            if layout == .full {
                HStack(spacing: 7) {
                    stageChip
                    if order.isOverdue { LateBadge() }
                    Spacer(minLength: 0)
                    if let due = order.formattedDueDate {
                        Text(due)
                            .font(.khayt(12, relativeTo: .caption))
                            .foregroundStyle(KhaytDesign.note)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, layout == .full ? 12 : 11).padding(.leading, 16).padding(.trailing, 13)
        .frame(maxWidth: .infinity, minHeight: layout == .full ? 70 : 0, alignment: .leading)
        .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: 11))
        .overlay(alignment: .leading) {
            if railed { Rectangle().fill(order.isOverdue ? KhaytDesign.late : tone).frame(width: 3) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 11))
    }
}
