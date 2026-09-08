import SwiftUI

/// What the menu bar needs to reach inside the window.
///
/// The menu bar is built once, outside any window, so a command cannot see a
/// window's `@SceneStorage` or `@State` directly. `focusedSceneValue` is the
/// way across: the window publishes a binding, the command reads whichever
/// window is frontmost, and the item disables itself when there is no window at
/// all — which is what makes "Show Details" grey out with no window open rather
/// than doing nothing when chosen.
///
/// This is scene state on purpose. Whether the details pane is open belongs to
/// a window, not to a shop: two windows on the same book should be able to
/// disagree about it.
struct InspectorShowingKey: FocusedValueKey { typealias Value = Binding<Bool> }
struct SearchWantedKey: FocusedValueKey { typealias Value = Binding<Bool> }

extension FocusedValues {
    /// Whether the trailing details pane is open in the frontmost window.
    var inspectorShowing: Binding<Bool>? {
        get { self[InspectorShowingKey.self] }
        set { self[InspectorShowingKey.self] = newValue }
    }

    /// Set true to put the caret in the toolbar's search field.
    ///
    /// A request rather than a state: it goes true, the field takes focus, and
    /// the window sets it back. `searchFocused` is macOS 15, so on 14 this is
    /// simply never honoured and ⌘F does nothing — which is why the item is
    /// present and working, on every version this app runs on.
    var searchWanted: Binding<Bool>? {
        get { self[SearchWantedKey.self] }
        set { self[SearchWantedKey.self] = newValue }
    }
}

/// Puts the caret in the search field when `wanted` goes true.
///
/// Still a modifier rather than being folded into the view: `@FocusState` has
/// to live beside the `.searchFocused` that reads it, and a modifier is where
/// that pairing stays together. It used to ALSO carry an `if #available` for
/// macOS 15, which is what made the wrapper necessary rather than merely tidy.
struct FocusSearchWhenAsked: ViewModifier {
    @Binding var wanted: Bool
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .searchFocused($focused)
            .onChange(of: wanted) {
                guard wanted else { return }
                focused = true
                // Put it back down, so asking twice in a row works.
                wanted = false
            }
    }
}

extension View {
    func focusSearchWhenAsked(_ wanted: Binding<Bool>) -> some View {
        modifier(FocusSearchWhenAsked(wanted: wanted))
    }
}
