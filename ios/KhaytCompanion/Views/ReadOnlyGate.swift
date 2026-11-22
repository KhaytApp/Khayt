import SwiftUI

/// A screen that edits the shop, on a phone that may not: a viewer's cloud
/// sign-in with no Mac paired (`KhaytAPIClient.canWrite`). The controls are
/// switched off and say why, rather than take an edit that the next sync
/// would quietly throw away. The book refuses the edit as well, so a control
/// this misses still fails with the reason instead of pretending.
private struct ShopEditGate: ViewModifier {
    @EnvironmentObject private var api: KhaytAPIClient

    func body(content: Content) -> some View {
        content
            .disabled(!api.canWrite)
            .safeAreaInset(edge: .top, spacing: 0) {
                if !api.canWrite { ReadOnlyNote() }
            }
    }
}

/// "Read-only sign-in", said once at the top of a screen that would edit.
struct ReadOnlyNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "eye")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(KhaytDesign.attention)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.tr("cloud.read_only"))
                    .font(.khayt(12, .semibold, relativeTo: .caption))
                    .foregroundStyle(KhaytDesign.attention)
                Text(L10n.tr("cloud.read_only.line"))
                    .font(.khayt(11, relativeTo: .caption2))
                    .foregroundStyle(KhaytDesign.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, KhaytDesign.pad)
        .padding(.vertical, 7)
        .background(KhaytDesign.attention.opacity(0.12))
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Switch this screen's edits off while the phone may not edit the shop.
    func editsShop() -> some View { modifier(ShopEditGate()) }
}
