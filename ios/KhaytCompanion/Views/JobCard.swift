import SwiftUI

/// One job, as `design/ios-v2/` draws it on Home and in Orders: a card that is
/// swiped FORWARD to move the job on (trailing in English, leading in Arabic),
/// and tapped to open its page.
///
/// Two layouts, both the design's. `.compact` is Home's — the job, then who it
/// is for with its stage beside it. `.full` is the Orders list — the same two
/// lines, and a third with the stage, a late tag and the due date.
///
/// The 2026 redesign's row (Figma "Job row"): a stage tile, the id in mono
/// beside a stage pill, the title, who it is for. Only a late job gets a
/// coloured outline.
struct JobCard: View {
    enum Layout { case compact, full }

    let order: QueueOrder
    var facts: OrderFacts? = nil
    /// The live reading of the machine this job is on, when there is one and
    /// the job is printing — the design's progress row. Nil draws no row: a
    /// bar with nothing behind it would be a figure the phone does not have.
    var live: MachineLiveStatus? = nil
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
            if let q = facts.quantity { parts.append("×" + q.formatted(.number.locale(L10n.locale))) }
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
                        .khaytTracking(0.9)
                        .foregroundStyle(past ? KhaytDesign.brand : KhaytDesign.note)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(past ? KhaytDesign.brand.opacity(0.22) : KhaytDesign.sunk, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
        .accessibilityAction(named: next.map { L10n.format("order.detail.move_to", $0.localizedLabel) } ?? "") {
            if next != nil { onAdvance() }
        }
    }

    private var tone: Color { KhaytDesign.statusColor(for: order.status) }

    private var stageChip: some View {
        Group {
            if isUpdating {
                ProgressView().controlSize(.mini)
            } else {
                // The redesign's pill: a dot in the stage colour, the words in ink.
                HStack(spacing: 5) {
                    Circle().fill(tone).frame(width: 6, height: 6)
                    Text(chipLabel)
                        .font(.khayt(11.5, .semibold, relativeTo: .caption2))
                        .foregroundStyle(KhaytDesign.ink)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(tone.opacity(0.16), in: Capsule())
            }
        }
    }

    /// "Printing 64%" while the machine reports it, else the stage's word.
    private var chipLabel: String {
        let word = L10n.tr("stage.short.\(order.status)")
        if order.status == "printing", let live, live.isPrinting, let p = live.progress {
            return word + " " + p.formatted(.number.locale(L10n.locale)) + "%"
        }
        return word
    }

    /// The redesign's job row: a tile in the stage's colour, the id in mono
    /// with the stage pill beside it, the title, then who it is for. A late job
    /// is outlined in `late`; nothing else gets a coloured edge.
    private var card: some View {
        let edge = order.isOverdue ? KhaytDesign.late.opacity(0.7) : KhaytDesign.hairline
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: CompanionTheme.statusIcon(for: order.status))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(order.isOverdue ? KhaytDesign.late : tone)
                .frame(width: 46, height: 46)
                .background((order.isOverdue ? KhaytDesign.late : tone).opacity(0.16),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(order.reference)
                        .font(.khaytMono(11.5, .medium))
                        .foregroundStyle(KhaytDesign.note)
                        .lineLimit(1)
                        .environment(\.layoutDirection, .leftToRight)
                    stageChip
                    if order.isRush { RushBadge() }
                    // Home's compact card says "Late" in words as well as with
                    // the red outline (the full layout says it on its due line).
                    if layout == .compact, order.isOverdue { LateBadge() }
                    Spacer(minLength: 0)
                }
                Text(order.displayTitle)
                    .font(.khayt(16, .semibold, relativeTo: .body))
                    .foregroundStyle(KhaytDesign.ink)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(subtitle)
                        .font(.khayt(12.5, relativeTo: .footnote))
                        .foregroundStyle(KhaytDesign.note)
                        .lineLimit(1)
                    if layout == .full, let due = order.formattedDueDate {
                        Text("· " + due)
                            .font(.khayt(12.5, relativeTo: .footnote))
                            .foregroundStyle(order.isOverdue ? KhaytDesign.late : KhaytDesign.note)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if layout == .full, order.isOverdue { LateBadge() }
                }
                if order.status == "printing", let live, live.isPrinting, let progress = live.progress {
                    HStack(spacing: 9) {
                        LevelBar(fraction: Double(min(100, max(0, progress))) / 100, color: KhaytDesign.thread)
                        if let eta = live.etaLocalized {
                            Text(eta)
                                .font(.khaytMono(11, .regular, relativeTo: .caption2))
                                .foregroundStyle(KhaytDesign.note)
                        }
                    }
                    .padding(.top, 3)
                    .animation(.easeOut(duration: 0.45), value: progress)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(edge, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
