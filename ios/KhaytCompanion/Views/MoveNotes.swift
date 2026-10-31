import SwiftUI
import UIKit

/// What the shop's rule said about a move — "Took 120 g off 1 spool", "Running
/// low: Boxes" — shown at the foot of the screen that made it, as the Mac's
/// toast does. A spool that changes weight by itself is a number nobody trusts,
/// and a low-stock warning nobody sees is the one part a shop has to act on.
///
/// Goes away by itself after a few seconds, or on a tap; two or more lines
/// stay longer.
struct MoveNotesModifier: ViewModifier {
    @Binding var notes: [String]

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom) {
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(notes.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.khayt(13.5, relativeTo: .footnote))
                            .foregroundStyle(KhaytDesign.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(KhaytDesign.surfaceV2, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(KhaytDesign.hairlineV2))
                .padding(.horizontal, 16).padding(.bottom, 8)
                .contentShape(Rectangle())
                .onTapGesture { notes = [] }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: notes) {
                    let shown = notes
                    let seconds: UInt64 = shown.count > 1 ? 9 : 5
                    try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                    if notes == shown { withAnimation { notes = [] } }
                }
            }
        }
        .animation(.default, value: notes)
        .onChange(of: notes) { _, now in
            guard !now.isEmpty else { return }
            UIAccessibility.post(notification: .announcement, argument: now.joined(separator: "\n"))
        }
    }
}

extension View {
    /// Show what a move's rule said, at the foot of this screen.
    func moveNotes(_ notes: Binding<[String]>) -> some View {
        modifier(MoveNotesModifier(notes: notes))
    }
}
