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
    /// The menu bar's "put the caret in the search field" request — the window
    /// owns it, because the menu item reaches the window, not the strip.
    @Binding var searchWanted: Bool
    /// Whether the detail panel is open on this screen. The window decides —
    /// it owns the switch and the list of screens that have one.
    var showingPanel = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            ShellTitleBar(shop: shop, searchWanted: $searchWanted)
            HStack(spacing: 0) {
                ShellSidebar(shop: shop)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Role.bg)
                // A COLUMN, NOT AN `.inspector`.
                //
                // `.inspector` is a `NavigationSplitView` column: applied
                // anywhere else it goes to the window instead, and the window
                // came back 310pt narrower with no panel in it. §10 calls this
                // a trailing inspector of a fixed width, which is a column.
                if showingPanel {
                    Divider()
                    InspectorPane(shop: shop)
                        .frame(width: Wide.inspector)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(Role.surf)
                }
            }
        }
        .background(Role.bg)
        // BOTH LINES, AND EACH ONE ALONE IS A DIFFERENT WRONG HEADER.
        //
        // `.hiddenTitleBar` on the scene stops the window painting its own bar,
        // but SwiftUI keeps a 32pt top safe area where it used to be — and a
        // background extends through a safe area while the content inside it
        // does not, so the strip came out 71pt of navy with the traffic lights
        // on one row and the title on another, 31pt below them. Measured at
        // 2..143 in a 2× shot; the strip is 40.
        //
        // Without the scene modifier, this line alone pulls the strip up under
        // an opaque 32pt band and leaves 8pt of navy showing.
        .ignoresSafeArea(.container, edges: .top)
        // The window's own title bar is off at the scene — see `shopScene` in
        // `KhaytApp`, and `WindowChrome` for what the old shell keeps.
        .windowTitleBar(hidden: true)
    }
}

/// Which shell the window wears, and the ONE place its default lives.
///
/// ── THE BUG THIS EXISTS FOR ───────────────────────────────────────────────
///
/// `@AppStorage` takes its default per declaration, not per key. `ShopWindow`
/// declared `= true` and `SettingsWindow` declared `= false`, under a comment
/// saying "the same key, so the two cannot drift apart" — and before the key
/// had ever been written they read different answers. The app opened in the
/// new shell with the switch showing OFF, so a shop wanting the old one had to
/// turn the switch ON and then off again.
///
/// A default is a value, so it is written down once and both sides read it.
enum ShellChoice {
    static let key = "ui.newShell"
    /// ON as of 4.0.0-alpha.12 — see `ShopWindow.newShell` for why.
    static let byDefault = true
}

/// The 40px navy strip.
struct ShellTitleBar: View {
    @Bindable var shop: Shop
    /// The menu bar's request for the caret, passed down from the window.
    @Binding var searchWanted: Bool

    var body: some View {
        HStack(spacing: Space.lg) {
            // Clear of the traffic lights. A fixed inset rather than a
            // measurement because the buttons are a fixed size and the window
            // is never without them.
            Spacer().frame(width: 72)

            Text(shop.shelfTitle)
                .font(TypeScale.title(12, weight: .semibold))
                .foregroundStyle(Role.onNavy)
                .lineLimit(1)

            Spacer(minLength: Space.md)

            CommandField(shop: shop, wanted: $searchWanted)
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

            // What this screen can do. The window has no title bar to put a
            // toolbar in any more, so the items its screens used to declare are
            // here — see `ScreenActions`.
            ScreenActions(shop: shop)

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

/// The field in the strip.
///
/// ── WHAT §8 ASKS FOR, AND WHAT THIS IS UNTIL THEN ────────────────────────
///
/// §8 wants ⌘K to open a PALETTE: it searches the whole book and offers
/// actions, which is a different thing from filtering the list in front of
/// you. That palette is not built.
///
/// What was here instead was the palette's lid — a field-shaped `Text` reading
/// "Search jobs, models, spools, people" that could not be typed into, on a
/// shell where the real search field was gone as well (it lived in the old
/// shell's toolbar, and this shell has no toolbar). So the app showed a search
/// box and had no search.
///
/// So it narrows the screen you are on, which is what the old field did, and
/// says what it narrows in that screen's own words. When the palette lands it
/// takes this place and this becomes its lid again.
struct CommandField: View {
    @Bindable var shop: Shop
    @Binding var wanted: Bool
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
            field
            Spacer(minLength: Space.xs)
            // Not a shortcut this field owns — the menu bar's Find item is what
            // ⌘F reaches, and it asks for the caret through `wanted`.
            Text(shop.canSearch ? "⌘F" : "⌘K")
                .font(TypeScale.figure(10.5))
        }
        .foregroundStyle(Role.onNavy2)
        .padding(.horizontal, 11)
        .frame(height: 24)
        .background(Color.white.opacity(0.1), in:
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .onChange(of: wanted) { _, asked in
            guard asked else { return }
            focused = true
            wanted = false
        }
    }

    @ViewBuilder private var field: some View {
        if shop.canSearch {
            // THE PLACEHOLDER IS DRAWN HERE, not handed to the field as a
            // prompt. A styled `prompt:` is honoured in light appearance and
            // IGNORED in dark — measured, not guessed: the same red prompt drew
            // red on aqua and system grey on darkAqua — and on this navy strip
            // the system's dark placeholder came out near-white, so "Job,
            // customer or number" read as something already typed. An overlay
            // in the strip's own secondary ink says the same in both.
            ZStack(alignment: .leading) {
                if shop.search.isEmpty {
                    Text(shop.searchPrompt)
                        .font(TypeScale.body(11.5))
                        .foregroundStyle(Role.onNavy3)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextField("", text: $shop.search)
                    .textFieldStyle(.plain)
                    .font(TypeScale.body(11.5))
                    .foregroundStyle(Role.onNavy)
                    .focused($focused)
                    .lineLimit(1)
                    .accessibilityLabel(shop.searchPrompt)
            }
        } else {
            // A screen with nothing to narrow says so by not offering to. The
            // words stay because the strip is the same width either way.
            Text(shop.words.callIt("mac.search_the_book"))
                .font(TypeScale.body(11.5))
                .lineLimit(1)
        }
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
        .frame(width: Wide.sidebar)
        .frame(maxHeight: .infinity)
        .background(Role.navy)
    }

    /// Whose book this is. At the top because on a Mac that can open more than
    /// one, "which shop am I looking at" is the first question the window has
    /// to answer.
    ///
    /// ── AND WHICH BOOK, NOT JUST WHOSE ────────────────────────────────────
    ///
    /// The mock draws this card as a name and two counts. That is not enough on
    /// its own: the old shell put the book's SOURCE in the toolbar because
    /// mistaking the sample for the shop's real position is the one error this
    /// app must not allow, and the new shell has no toolbar. So the card says
    /// the source whenever it is not the shop's own book, and the card is the
    /// menu that switches it — the same items the toolbar offered.
    private var book: some View {
        Menu {
            ForEach(Shop.available) { source in
                Button {
                    Task { await shop.load(source) }
                } label: {
                    Label(source.title(shop.words), systemImage: source.symbol)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(shop.shopName)
                    .font(TypeScale.row(11.5, weight: .bold))
                    .foregroundStyle(Role.onNavy)
                    .lineLimit(1)
                // ON ITS OWN LINE, and that was measured too: inline after
                // the counts the card read "Samp… · 5 ma… · 31 p…" — three
                // truncations in a 134pt card, and the one word that matters
                // was the first one cut.
                if !shop.source.isReal {
                    Text(shop.source.title(shop.words))
                        .font(TypeScale.label(9))
                        .foregroundStyle(Role.lateOnNavy)
                        .lineLimit(1)
                }
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
            .contentShape(Rectangle())
        }
        // A PLAIN LABEL, NOT A CONTROL. `.borderlessButton` still draws the
        // system's own light well behind the label, which on navy is a white
        // chip over the shop's name — and it clipped the counts line off the
        // bottom of the card as well.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
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
            // WHAT THE SHOP'S MODE INCLUDES. Asked here rather than at each
            // row, so a screen added to this list later is gated by having a
            // gate rather than by somebody remembering to write one.
            ForEach(items.filter { shop.canShow($0.shelf) }) { item in
                NavRow(item: item, shop: shop)
            }
        }
    }

    /// What the app has to tell the shop, above the book's name.
    ///
    /// ── THESE THREE SHIPPED IN NO WINDOW AT ALL ───────────────────────────
    ///
    /// They were written into `Sidebar.swift`'s footer, and that is the shell
    /// the app stopped opening with in 4.0.0-alpha.12. Nothing else in the app
    /// read `shop.skipped`, `shop.lastCrash` or the sync line, so a shop was
    /// never told that records in its book could not be read, never told that
    /// Khayt had closed unexpectedly, and never shown what sync was doing.
    ///
    /// The neighbouring lines in that same footer — the tax summary, the
    /// backup state, the engine failure — all survived, because they are named
    /// `…Problem` or are read by another screen, and `MessagesAreShownTests`
    /// ratchets that naming. These three slipped through on their names.
    ///
    /// One line each, capped, with the detail in the tooltip: this column is
    /// 150pt and a wrapped sentence here pushes the book's name off the bottom.
    private var notices: some View {
        VStack(alignment: .leading, spacing: 3) {
            if shop.productionPaused {
                // THE ONE NOTICE THAT IS ALSO A DEAD END. The shared rule
                // refuses a move to printing while this is set, and this app
                // used to translate that refusal without ever saying the floor
                // was stopped or offering a way to start it again. Tapping it
                // resumes.
                noticeLine(shop.pauseReason.isEmpty
                             ? shop.words.callIt("prod.paused_banner")
                             : shop.words.callIt("prod.paused_banner") + " — " + shop.pauseReason,
                           "pause.circle", Role.lateOnNavy,
                           help: shop.words.callIt("prod.resume"))
                    .onTapGesture { shop.resumeProduction() }
            }
            if !shop.skipped.isEmpty {
                // The app DROPPED data. Whatever else is wrong, a shop should
                // not have to find that out by noticing something missing.
                noticeLine(shop.words.callIt("mac.unreadable_records",
                                             ["n": .number(Double(shop.skipped.count))]),
                           "exclamationmark.triangle", Role.lateOnNavy,
                           help: shop.skipped.prefix(8).joined(separator: "\n"))
            }
            if shop.cloudConnected {
                // Only for a book that expects to be in step with somewhere
                // else. A shop that has never connected is not missing
                // anything, and a line telling it so is one people stop
                // reading.
                let line = shop.syncLine
                // Where people look for the cloud, so it is where the cloud
                // can be handled: a click unlocks it (or checks it once it is
                // unlocked), and a right-click has every cloud action.
                noticeLine(line.text, line.symbol,
                           line.tone == .attention ? Role.lateOnNavy : Role.onNavy2,
                           help: shop.words.callIt("mac.sync_auto_why") + "\n"
                               + shop.words.callIt("mac.cloud_line_hint"))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if shop.cloudUnlocked { shop.checkingCloud = true } else { shop.signingIntoCloud = true }
                    }
                    .contextMenu {
                        Button(shop.words.callIt("mac.cloud_sign_in") + "\u{2026}") { shop.signingIntoCloud = true }
                        Button(shop.words.callIt("mac.check_cloud") + "\u{2026}") { shop.checkingCloud = true }
                        Button(shop.words.callIt("mac.lock_cloud")) { shop.forgetCloudKey() }
                            .disabled(!shop.cloudUnlocked)
                        Divider()
                        Button(shop.words.callIt("mac.cloud_sign_out") + "\u{2026}") { shop.confirmingSignOut = true }
                    }
            }
            if let crash = shop.lastCrash {
                // Clicking it says it has been read.
                noticeLine(shop.words.callIt("mac.last_crash"),
                           "exclamationmark.bubble", Role.lateOnNavy, help: crash)
                    .onTapGesture { shop.forgetLastCrash() }
            }
        }
    }

    private func noticeLine(_ text: String, _ symbol: String, _ tint: Color,
                            help: String) -> some View {
        Label(text, systemImage: symbol)
            .font(TypeScale.body(9.5))
            .foregroundStyle(tint)
            // Two lines, not one: "Syncing automatically" did not fit the
            // sidebar and read "Syncing auto…", and a status cut off mid-word
            // is a status nobody can read.
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .help(help)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var file: some View {
        VStack(alignment: .leading, spacing: 2) {
            notices
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
                    Text(ShopState.stockOut.glyph)
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
