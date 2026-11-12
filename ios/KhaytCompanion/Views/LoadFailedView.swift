import SwiftUI

/// What a screen says when its read FAILED — never the empty state's "Queue
/// clear" / "Nothing is owed" with the error tucked underneath, which told a
/// shop all was well when the phone simply could not look (UI review Nov 11,
/// F3). Its own title, the reason, and a way to try again.
struct LoadFailedView: View {
    let message: String
    var retry: (() async -> Void)?
    @State private var retrying = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title3)
                .foregroundStyle(KhaytDesign.late)
                .accessibilityHidden(true)
            Text(L10n.tr("load.failed.title"))
                .font(.khayt(15, .semibold, relativeTo: .headline))
                .foregroundStyle(KhaytDesign.ink)
            Text(message)
                .font(.khayt(13, relativeTo: .footnote))
                .foregroundStyle(KhaytDesign.note)
                .fixedSize(horizontal: false, vertical: true)
            if let retry {
                Button {
                    Task {
                        retrying = true
                        await retry()
                        retrying = false
                    }
                } label: {
                    if retrying { ProgressView() } else { Text(L10n.tr("load.retry")) }
                }
                .font(.khayt(14, .semibold, relativeTo: .subheadline))
                .foregroundStyle(KhaytDesign.brand)
                .frame(minWidth: 88, minHeight: 44)
                .contentShape(Rectangle())
                .disabled(retrying)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44).padding(.horizontal, 16)
    }
}
