import SwiftUI

/// The window shell — §7 of the design spec.
///
/// ── WHAT THE MOCK DRAWS AND THIS DOES NOT ─────────────────────────────────
///
/// `Khayt App.dc.html` draws a 26px menu bar and three traffic lights, because
/// a browser has to. This is a real Mac app: the menu bar belongs to the
/// system and the traffic lights belong to the window. Drawing our own would
/// be two menu bars and two sets of buttons, one of which does nothing.
///
/// What IS ours is the 40px navy strip: the view's title, the ⌘K field, the
/// wordmark, and the state of the book. The real traffic lights sit in it,
/// which is why the title starts clear of them.
///
/// Everything else follows the spec exactly — the 150px navy sidebar in three
/// groups, the tinted selection pill with its 2.5px leading accent bar, and a
/// content region on `bg`.
struct Shell<Content: View>: View {
    @Bindable var shop: Shop
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            ShellTitleBar(shop: shop)
            HStack(spacing: 0) {
                ShellSidebar(shop: shop)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Role.bg)
            }
        }
        .background(Role.bg)
    }
}

/// The 40px navy strip.
struct ShellTitleBar: View {
    @Bindable var shop: Shop

    var body: some View {
        HStack(spacing: Space.lg) {
            // Clear of the traffic lights. A fixed inset rather than a
            // measurement because the buttons are a fixed size and the window
            // is never without them.
            Spacer().frame(width: 72)

            Text(shop.words.callIt(shop.shelfTitleKey))
                .font(TypeScale.title(12, weight: .semibold))
                .foregroundStyle(Role.onNavy)
                .lineLimit(1)

            Spacer(minLength: Space.md)

            CommandField(words: shop.words)
                .frame(width: 290)

            Spacer(minLength: Space.md)

            // The wordmark, tracked wide. Not an image — at 10pt a bitmap
            // wordmark is mush — and not a literal either: an Arabic shop sees
            // خيط, and the tracking that opens up Latin capitals would pull an
            // Arabic word apart at the joins, so it is applied to neither.
            Text(shop.words.callIt("app.title"))
                .font(TypeScale.label(10))
                .tracking(shop.words.language == "ar" ? 0 : 2.4)
                .foregroundStyle(Role.onNavy3)

            // What the book is doing. Two `Text`s, never one string — see §5.
            HStack(spacing: Space.xs) {
                Text(shop.words.callIt(shop.isCloudLinked ? "mac.synced" : "mac.offline"))
                Text("·")
                Text(shop.lastSavedLabel)
            }
            .font(TypeScale.figure(10.5))
            .foregroundStyle(Role.onNavy3)
        }
        .padding(.horizontal, Space.lg)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .background(Role.navy)
    }
}

/// The ⌘K field. A field-shaped button: ⌘K opens a palette, it is not a
/// search box that lives in the toolbar — §8 says it searches the whole book
/// and offers actions, which is a different thing from filtering a list.
struct CommandField: View {
    let words: Words
    @Environment(\.layoutDirection) private var direction

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
            Text(words.callIt("mac.search_the_book"))
                .font(TypeScale.body(11.5))
                .lineLimit(1)
            Spacer(minLength: Space.xs)
            Text("⌘K")
                .font(TypeScale.figure(10.5))
        }
        .foregroundStyle(Role.onNavy2)
        .padding(.horizontal, 11)
        .frame(height: 24)
        .background(Color.white.opacity(0.1), in:
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

/// The 150px navy sidebar, in three groups.
///
/// SHOP / FLOOR / MONEY is not a tidy-up of the old flat list: it is the
/// shop's own division of its work — what it sells, what makes it, what it is
/// worth. A screen belongs to exactly one.
struct ShellSidebar: View {
    @Bindable var shop: Shop

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            book
            group("mac.group_shop", [
                .init(.dashboard, "mac.dashboard"),
                .init(.jobs(nil), "mac.all_jobs", count: shop.orders.count),
                .init(.board, "mac.board"),
                .init(.library(nil), "mac.all_models", count: shop.files.count),
                .init(.catalogue, "cat.title", count: shop.catalogueRows.count),
                .init(.customers, "tab.clients", count: shop.customers.count),
            ])
            group("mac.group_floor", [
                .init(.machines, "mac.machines", dot: shop.anyMachineRunning ? Role.ok : nil),
                .init(.inventory, "mac.inventory", alarm: shop.lowSpools.count),
                .init(.expenses, "mac.nav_expenses"),
                .init(.waste, "mac.nav_waste"),
            ])
            group("mac.group_money", [
                .init(.reports, "mac.nav_reports"),
                .init(.portfolio, "pf.title"),
                .init(.calculator, "mac.calc_title"),
                .init(.colour, "cmix.title"),
                .init(.giftCards, "giftCards"),
            ])
            Spacer(minLength: 0)
            file
        }
        .frame(width: 150)
        .frame(maxHeight: .infinity)
        .background(Role.navy)
    }

    /// Whose book this is. At the top because on a Mac that can open more than
    /// one, "which shop am I looking at" is the first question the window has
    /// to answer.
    private var book: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(shop.shopName)
                .font(TypeScale.row(11.5, weight: .bold))
                .foregroundStyle(Role.onNavy)
                .lineLimit(1)
            HStack(spacing: Space.xs) {
                Text(shop.words.counting(shop.machines.count, "mac.n_machines"))
                Text("·")
                Text(shop.words.counting(shop.customers.count, "mac.n_people"))
            }
            .font(TypeScale.body(9.5))
            .foregroundStyle(Role.onNavy3)
            .lineLimit(1)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Role.navyLine, lineWidth: 1)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, Space.md)
    }

    private func group(_ titleKey: String, _ items: [NavItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CapsLabel(shop.words.callIt(titleKey), tint: Role.onNavy3, size: 8.5)
                .tracking(1.2)
                .padding(.horizontal, 14)
                .frame(height: 20, alignment: .leading)
            ForEach(items) { item in
                NavRow(item: item, shop: shop)
            }
        }
    }

    private var file: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(shop.words.callIt("mac.book"))
                .font(TypeScale.body(9))
                .foregroundStyle(Role.onNavy3)
            Text(shop.bookFileName)
                .font(TypeScale.figure(10))
                .foregroundStyle(Role.onNavy2)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Role.navyLine).frame(height: 1) }
    }
}

struct NavItem: Identifiable {
    let shelf: Shop.Shelf
    let titleKey: String
    var count: Int?
    /// A single dot — something is happening, no number worth reading.
    var dot: Color?
    /// A count that is a PROBLEM rather than a size. Drawn in `late` with the
    /// state's own glyph, because "2" beside Inventory and "▲ 2" beside it are
    /// different sentences.
    var alarm: Int = 0

    init(_ shelf: Shop.Shelf, _ titleKey: String, count: Int? = nil,
         dot: Color? = nil, alarm: Int = 0) {
        self.shelf = shelf
        self.titleKey = titleKey
        self.count = count
        self.dot = dot
        self.alarm = alarm
    }

    var id: String { titleKey }
}

private struct NavRow: View {
    let item: NavItem
    @Bindable var shop: Shop

    private var selected: Bool { shop.shelf.sameScreen(as: item.shelf) }

    var body: some View {
        HStack(spacing: Space.sm) {
            Text(shop.words.callIt(item.titleKey))
                .font(TypeScale.row(11.5, weight: selected ? .semibold : .medium))
                .foregroundStyle(Role.onNavy)
                .lineLimit(1)
            Spacer(minLength: Space.xs)
            if item.alarm > 0 {
                HStack(spacing: 2) {
                    Text(ShopState.late.glyph)
                    Figure(value: Double(item.alarm), size: 9.5, weight: .bold,
                           tint: Role.lateOnNavy)
                }
                .font(TypeScale.label(9.5))
                // NOT `Role.late`: this mark is mounted on navy, where the
                // content-surface value measures 3.33:1.
                .foregroundStyle(Role.lateOnNavy)
            } else if let dot = item.dot {
                Circle().fill(dot).frame(width: 5, height: 5)
            } else if let count = item.count {
                Figure(value: Double(count), size: 10, tint: Role.onNavy3)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background(alignment: .leading) {
            if selected {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(Role.accSoft)
                    // The 2.5px bar on the LEADING edge — `.leading`, so it
                    // moves to the right-hand side in Arabic without a second
                    // code path. §9: any physical direction is the bug that
                    // breaks Arabic.
                    Rectangle().fill(Role.acc).frame(width: 2.5)
                }
                .padding(.horizontal, 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { shop.shelf = item.shelf }
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
