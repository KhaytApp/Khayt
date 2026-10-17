import SwiftUI

/// `.sheet` and `.popover` that keep the shop's locale.
///
/// ── WHY THESE EXIST ──────────────────────────────────────────────────────
///
/// On macOS a sheet or popover inherits its presenter's environment EXCEPT
/// `\.locale`: the new window starts again from the Mac's own. Measured on
/// macOS 26 under `-AppleLocale ar_SA@calendar=islamic-umalqura` — a
/// DatePicker in a sheet took the window's Gregorian `\.calendar` but came
/// back `ar_SA`, and one in a popover the same. So every sheet the shop
/// opened (Edit spool, Receive, New job …) wrote Arabic month names in the
/// English app, whatever `ShopsLocale` and the digits setting said
/// (alpha.79 UI review).
///
/// Each of these reads the locale where it is attached — the window's, set by
/// `ShopsLocale` — and puts it back on the content. `DigitsTests` fails if a
/// plain `.sheet(` or `.popover(` comes back in KhaytApp.
extension View {
    func shopSheet<C: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                            @ViewBuilder content: @escaping () -> C) -> some View {
        modifier(ShopSheet(isPresented: isPresented, onDismiss: onDismiss, sheet: content))
    }

    func shopSheet<Item: Identifiable, C: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                @ViewBuilder content: @escaping (Item) -> C) -> some View {
        modifier(ShopItemSheet(item: item, onDismiss: onDismiss, sheet: content))
    }

    func shopPopover<C: View>(isPresented: Binding<Bool>, arrowEdge: Edge = .top,
                              @ViewBuilder content: @escaping () -> C) -> some View {
        modifier(ShopPopover(isPresented: isPresented, arrowEdge: arrowEdge, popover: content))
    }
}

private struct ShopSheet<C: View>: ViewModifier {
    @Binding var isPresented: Bool
    let onDismiss: (() -> Void)?
    let sheet: () -> C
    @Environment(\.locale) private var locale

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented, onDismiss: onDismiss) {
            sheet().environment(\.locale, locale)
        }
    }
}

private struct ShopItemSheet<Item: Identifiable, C: View>: ViewModifier {
    @Binding var item: Item?
    let onDismiss: (() -> Void)?
    let sheet: (Item) -> C
    @Environment(\.locale) private var locale

    func body(content: Content) -> some View {
        content.sheet(item: $item, onDismiss: onDismiss) {
            sheet($0).environment(\.locale, locale)
        }
    }
}

private struct ShopPopover<C: View>: ViewModifier {
    @Binding var isPresented: Bool
    let arrowEdge: Edge
    let popover: () -> C
    @Environment(\.locale) private var locale

    func body(content: Content) -> some View {
        content.popover(isPresented: $isPresented, arrowEdge: arrowEdge) {
            popover().environment(\.locale, locale)
        }
    }
}
