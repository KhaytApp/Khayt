import SwiftUI

/// Shared navigation chrome for inner screens.
extension View {
    func khaytScreen(title: String) -> some View {
        self
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
            .scrollContentBackground(.hidden)
            .background(KhaytDesign.bg.ignoresSafeArea())
    }
}

extension View {
    /// A system Form or List on the design's ground rather than iOS's grey —
    /// for the sheets `design/ios-v2/` has not drawn yet (quote, waste,
    /// expense, NFC write, cloud sign-in), so they sit in the same room as
    /// the screens it has.
    func khaytForm() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(KhaytDesign.ground.ignoresSafeArea())
            .tint(KhaytDesign.brand)
    }
}

/// Inline search field — a native-looking replacement for `.searchable`, which
/// segfaults when combined with toolbar appearance inside the app's nested
/// NavigationStack-in-TabView layout.
struct KhaytSearchField: View {
    @Binding var text: String
    var prompt: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(KhaytDesign.textMuted)
            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .foregroundStyle(KhaytDesign.text)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(KhaytDesign.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(KhaytDesign.surface2, in: RoundedRectangle(cornerRadius: 11))
    }
}

struct KhaytListRow<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(.vertical, 10)
            .listRowBackground(KhaytDesign.surface)
            .listRowSeparatorTint(KhaytDesign.hairline)
    }
}
