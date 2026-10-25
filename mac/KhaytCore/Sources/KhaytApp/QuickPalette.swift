import SwiftUI

/// The chrome ⌘K and ⌘J share: a dimmed window, a panel near the top with
/// one field, the results under it and a line of keys at the foot.
///
/// Lifted out of `GoToPalette` so the library's palette (`LibraryJumpPalette`)
/// is the same object rather than a copy of it — the same size, the same
/// focus, the same Esc and click-outside, the same arrow keys. What each one
/// lists, and what Return does, is its own.
///
/// An overlay in the window, never a sheet: see `GoToPalette`'s note — it
/// inherits the window's mirroring and appearance, so it is right-to-left in
/// Arabic and dark in dark mode without a line of its own saying so.
struct QuickPaletteFrame<Results: View>: View {
    let prompt: String
    let label: String
    let hint: String
    @Binding var query: String
    let close: () -> Void
    let move: (Int) -> Void
    /// Return, with the modifiers held — empty for a plain Return.
    let submit: (EventModifiers) -> Void
    @ViewBuilder let results: () -> Results

    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            // A click outside closes it, as it does Spotlight.
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }
                .accessibilityHidden(true)
            panel
                .padding(.top, 72)
                .padding(.horizontal, Space.xl)
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.md) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Role.text3)
                TextField(prompt, text: $query)
                    .textFieldStyle(.plain)
                    .font(TypeScale.title(15, weight: .regular))
                    .foregroundStyle(Role.text)
                    .focused($fieldFocused)
                    .onSubmit { submit([]) }
                    // ⌘↩ and ⌥↩ are read before the field takes the Return:
                    // a plain one falls through to `onSubmit`.
                    .onKeyPress(.return, phases: .down) { press in
                        let mods = press.modifiers.intersection([.command, .option])
                        guard !mods.isEmpty else { return .ignored }
                        submit(mods)
                        return .handled
                    }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                    .accessibilityLabel(label)
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md + 2)

            Divider().overlay(Role.line)

            results()
                .frame(maxHeight: 380)

            Divider().overlay(Role.line)
            Text(hint)
                .font(TypeScale.label(10, weight: .regular))
                .foregroundStyle(Role.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.sm)
        }
        .frame(maxWidth: 580)
        .background(Role.sheet, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Role.line2, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
        .onAppear { fieldFocused = true }
        .onExitCommand { close() }
    }
}

/// One row of either palette: a mark, a title, a quieter line under it, and
/// the accent's soft fill when the cursor is on it.
struct QuickPaletteRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let selected: Bool

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(selected ? Role.accInk : Role.text2)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(TypeScale.row(12.5))
                    .foregroundStyle(Role.text)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(TypeScale.body(10.5))
                        .foregroundStyle(Role.text3)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .background(selected ? Role.accSoft : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
