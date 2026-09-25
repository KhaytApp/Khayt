import SwiftUI

/// The pieces `design/ios-v2/` builds its forms from — New order is the one it
/// draws, and the sheets it has not drawn yet (waste, expense, quote) are made
/// of the same parts so they read as one app:
///
/// - `V2FieldCard`: one card of fields, hairlines between them;
/// - `V2Field`: a small uppercase label above a large value;
/// - `V2Chips`: a choice among a few words, wrapping onto a second line;
/// - `V2PrimaryButton`: the one brand-blue button a screen ends on;
/// - `V2Note`: the line under a form that says what will happen.
struct V2FieldCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }.card()
    }
}

struct V2Field<Input: View>: View {
    let label: String
    var last = false
    @ViewBuilder let input: Input

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label.uppercased())
                .font(.khayt(10, .bold, relativeTo: .caption2))
                .tracking(1)
                .foregroundStyle(KhaytDesign.note)
            input
                .font(.khayt(16, .medium, relativeTo: .body))
                .foregroundStyle(KhaytDesign.ink)
                .frame(minHeight: 32)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
        }
    }
}

/// A choice among a handful of words. Chips rather than a picker: every option
/// is visible at once, which is the point when there are six of them and the
/// person is holding a failed print in the other hand.
struct V2Chips<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    var body: some View {
        FlowLayout(spacing: 7) {
            ForEach(options, id: \.self) { option in
                let on = option == selection
                Button { selection = option } label: {
                    Text(label(option))
                        .font(.khayt(13, .semibold, relativeTo: .subheadline))
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 40)
                        .foregroundStyle(on ? KhaytDesign.brand : KhaytDesign.note)
                        .background(on ? KhaytDesign.brand.opacity(0.16) : .clear, in: Capsule())
                        .overlay(Capsule().strokeBorder(on ? KhaytDesign.brand.opacity(0.5) : KhaytDesign.hairline,
                                                        lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

struct V2PrimaryButton: View {
    let title: String
    var busy = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if busy { ProgressView().tint(KhaytDesign.onBrand) } else { Text(title) }
            }
            .font(.khayt(17, .semibold, relativeTo: .headline))
            .foregroundStyle(KhaytDesign.onBrand)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(KhaytDesign.brand.opacity(disabled && !busy ? 0.45 : 1), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(disabled || busy)
    }
}

struct V2Note: View {
    let text: String
    var tone: Color = KhaytDesign.note

    var body: some View {
        Text(text)
            .font(.khayt(12.5, relativeTo: .footnote))
            .foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
    }
}

/// Lays its children out in rows, wrapping when the next one does not fit —
/// and mirroring in Arabic, since `Layout` places in the leading direction.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
