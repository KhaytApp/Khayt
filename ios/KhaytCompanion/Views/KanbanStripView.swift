import SwiftUI

struct KanbanStripView: View {
    let status: ShopStatus
    var onSelect: ((OrderStatus) -> Void)?

    private var stages: [(OrderStatus, Int)] {
        [
            (.pending, status.pending),
            (.printing, status.printing),
            (.post, status.post),
            (.qc, status.qc),
            (.completed, status.completedToday)
        ]
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(stages.enumerated()), id: \.offset) { index, item in
                    let (stage, count) = item
                    let active = count > 0
                    let color = KhaytDesign.statusColor(for: stage.rawValue)
                    Button {
                        onSelect?(stage)
                    } label: {
                        VStack(spacing: 5) {
                            Text("\(count)")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(active ? color : KhaytDesign.textMuted)
                            stageLabel(stage.localizedLabel, active: active, color: color)
                        }
                        .frame(minWidth: 52, minHeight: 44)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            active ? KhaytDesign.statusSoft(for: stage.rawValue) : Color.white.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: KhaytDesign.radiusMD)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: KhaytDesign.radiusMD)
                                .stroke(active ? color.opacity(0.25) : KhaytDesign.sep, lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                    if index < stages.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(KhaytDesign.textFaint)
                            .frame(width: 16)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func stageLabel(_ label: String, active: Bool, color: Color) -> some View {
        let text = Text(label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(active ? color : KhaytDesign.textMuted)
        if L10n.usesArabicLayout {
            text
        } else {
            text.textCase(.uppercase)
        }
    }
}
