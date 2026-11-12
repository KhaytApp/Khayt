import SwiftUI

/// The shop's filament, as `design/ios-v2/` draws it: a search, two chips, and
/// the spools lowest first — the ones about to run out are the ones worth
/// seeing. Tapping one pushes its page.
///
/// Inventory travels WHOLE to the phone, so the list ends with a line saying
/// so: this is every spool the shop has, not the newest few.
struct InventoryView: View {
    @EnvironmentObject private var api: KhaytAPIClient
    @EnvironmentObject private var ordersNav: OrdersNavigationState

    @State private var spools: [InventorySpool] = []
    @State private var loaded = false
    @State private var errorMessage: String?
    @State private var showAddSpool = false
    @State private var searchText = ""
    @State private var lowOnly = false
    @State private var openSpool: InventorySpool?
    /// The shopping list (`ShoppingListPage`) — from the book, so offered
    /// only when this phone holds one.
    @State private var showShopping = false

    private func takeLowStockRequest() {
        guard ordersNav.pendingLowStock else { return }
        ordersNav.pendingLowStock = false
        lowOnly = true
    }

    private var displayed: [InventorySpool] {
        var list = spools
        if lowOnly { list = list.filter(\.isLowStock) }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            list = list.filter {
                [$0.displayLabel, $0.brand ?? "", $0.material ?? "", $0.color ?? "", $0.lot ?? "", $0.sku ?? ""]
                    .joined(separator: " ").lowercased().contains(q)
            }
        }
        return list.sorted { ($0.remainingGrams ?? 0) < ($1.remainingGrams ?? 0) }
    }

    /// Side by side in regular width, pushed in compact — see `OrdersView`.
    @Environment(\.horizontalSizeClass) private var widthClass
    private var isSplit: Bool { widthClass == .regular }

    var body: some View {
        if isSplit {
            // ListBesidePage, as Orders and Customers: a NavigationSplitView
            // sidebar drew an inline title and a sidebar button here, unlike
            // every other tab's large title.
            ListBesidePage {
                listPage
            } page: {
                NavigationStack {
                    if let spool = openSpool {
                        detailPage(spool)
                    } else {
                        ContentUnavailableView(L10n.tr("inventory.pick"), systemImage: "cylinder",
                                               description: Text(L10n.tr("inventory.pick.sub")))
                            .background(KhaytDesign.ground.ignoresSafeArea())
                    }
                }
            }
        } else {
            NavigationStack {
                listPage
                    .navigationDestination(item: $openSpool) { detailPage($0) }
            }
        }
    }

    private func detailPage(_ spool: InventorySpool) -> some View {
        SpoolDetailPage(spool: spool) { await load() }
            .id(spool.id)
    }

    private var listPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                search
                chips
                list
                if api.holdsAll("inventory"), !spools.isEmpty {
                    wholeLine
                }
            }
            .padding(.bottom, 18)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .khaytScreen(title: L10n.tr("tab.inventory"))
        .background(KhaytDesign.ground.ignoresSafeArea())
        .toolbar {
            if api.holdsBook {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showShopping = true } label: { Image(systemName: "cart") }
                        .accessibilityLabel(L10n.tr("shop.title"))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAddSpool = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel(L10n.tr("spool.add.title"))
            }
        }
        .navigationDestination(isPresented: $showShopping) { ShoppingListPage() }
        .sheet(isPresented: $showAddSpool) {
            AddSpoolSheet { Task { await load() } }
        }
        .refreshable { await load() }
        .task { await load() }
        .onAppear { takeLowStockRequest() }
        .onChange(of: ordersNav.lowStockRequest) { _, _ in takeLowStockRequest() }
    }

    // MARK: - Parts

    private var search: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(KhaytDesign.note)
            TextField(L10n.tr("inventory.search.v2"), text: $searchText)
                .font(.khayt(15, relativeTo: .body))
                .foregroundStyle(KhaytDesign.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(KhaytDesign.note)
                }
                .buttonStyle(.plain)
                .tapTarget()
                .accessibilityLabel(L10n.tr("common.clear"))
            }
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 46)
        .card(radius: 12)
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private var chips: some View {
        HStack(spacing: 7) {
            chip(L10n.tr("inventory.filter.all"), on: !lowOnly) { lowOnly = false }
            chip(L10n.tr("inventory.filter.low"), on: lowOnly) { lowOnly = true }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.khayt(13, .semibold, relativeTo: .subheadline))
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .foregroundStyle(KhaytDesign.ink)
                .background(on ? KhaytDesign.brand.opacity(0.18) : KhaytDesign.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(on ? KhaytDesign.brand.opacity(0.5) : KhaytDesign.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder
    private var list: some View {
        if !loaded && errorMessage == nil {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 44)
        } else if displayed.isEmpty, let errorMessage {
            LoadFailedView(message: errorMessage) { await load() }
        } else if displayed.isEmpty {
            let searching = !searchText.isEmpty || lowOnly
            VStack(spacing: 5) {
                Text(L10n.tr(searching ? "inventory.no_results" : "inventory.none"))
                    .font(.khayt(15, .semibold, relativeTo: .headline))
                    .foregroundStyle(KhaytDesign.ink)
                Text(L10n.tr(searching ? "inventory.no_results.sub" : "inventory.none.sub"))
                    .font(.khayt(13, relativeTo: .footnote))
                    .foregroundStyle(KhaytDesign.note)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 44).padding(.horizontal, 16)
        } else {
            // The redesign's shelf: spools as tiles, two to a row on a
            // phone and as many as fit where there is room.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 10)], spacing: 10) {
                ForEach(displayed) { spool in
                    Button { openSpool = spool } label: { SpoolRow(spool: spool) }
                        .buttonStyle(.plain)
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(KhaytDesign.brand, lineWidth: 2)
                            .opacity(isSplit && openSpool?.id == spool.id ? 1 : 0))
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var wholeLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.format("inventory.whole.count", spools.count.formatted(.number.locale(L10n.locale))))
                .font(.khayt(12.5, .semibold, relativeTo: .footnote).monospacedDigit())
                .foregroundStyle(KhaytDesign.ink)
            Text(L10n.tr("inventory.whole.body"))
                .font(.khayt(12, relativeTo: .caption))
                .foregroundStyle(KhaytDesign.note)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 14)
        .overlay(alignment: .top) { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
        .padding(.horizontal, 16)
        .padding(.top, 18)
    }

    private func load() async {
        errorMessage = nil
        do {
            spools = try await api.fetchInventory()
            // A spool removed from its own page: in the split view `dismiss()`
            // has no stack to pop, so the page is closed by forgetting it here.
            if let open = openSpool, !spools.contains(where: { $0.id == open.id }) { openSpool = nil }
            #if DEBUG
            if let id = KhaytCompanionApp.ScreenshotOpen.take("spool:") { openSpool = spools.first { $0.id == id } }
            if KhaytCompanionApp.ScreenshotOpen.take("shopping") != nil { showShopping = true }
            #endif
        } catch {
            spools = []
            errorMessage = error.localizedDescription
        }
        loaded = true
    }
}

/// A spool on the shelf — the redesign's spool tile: its colour as a reel,
/// what it is, how much is left in grams and as a share, and a bar in the
/// collect teal, amber when it is running low.
private struct SpoolRow: View {
    let spool: InventorySpool

    /// What is left as a share of what it arrived with, or nil when the book
    /// never recorded the arrival weight — a bar drawn against a guessed kilo
    /// would read a 3 kg roll as three times full.
    private var fraction: Double? {
        guard let left = spool.remainingGrams, let full = spool.initialWeight, full > 0 else { return nil }
        return min(1, max(0, left / full))
    }

    private var tone: Color { spool.isLowStock ? KhaytDesign.attention : KhaytDesign.collect }

    /// The colour's own name when it has one ("Galaxy Black"), else the label.
    private var title: String {
        let c = spool.color?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return c.isEmpty || c.hasPrefix("#") ? spool.displayLabel : c
    }

    /// "PLA Matte · Bambu" above the title, when the title is the colour.
    private var meta: String? {
        let c = spool.color?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !c.isEmpty, !c.hasPrefix("#") else { return nil }
        let parts = [spool.material, spool.brand].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The reel: the colour with the ground showing through its hub.
            SpoolSwatch(hex: spool.colorHex, size: 48)
                .overlay(Circle().fill(KhaytDesign.surface).frame(width: 14, height: 14))
                .overlay(Circle().strokeBorder(KhaytDesign.ink.opacity(0.22), lineWidth: 1).frame(width: 14, height: 14))
            if let meta {
                Text(meta)
                    .font(.khayt(12, relativeTo: .caption))
                    .foregroundStyle(KhaytDesign.note)
                    .lineLimit(1)
                    .padding(.top, 12)
            }
            Text(title)
                .font(.khayt(16, .semibold, relativeTo: .body))
                .foregroundStyle(KhaytDesign.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, meta == nil ? 12 : 2)
            Spacer(minLength: 10)
            HStack(alignment: .firstTextBaseline) {
                if let left = spool.remainingGrams {
                    // Not forced left-to-right: in Arabic the unit is
                    // a word, "١٢٠ غ", and reads in the line's own direction.
                    Text(L10n.grams(Int(left.rounded())))
                        .font(.khaytMono(13, .medium, relativeTo: .caption))
                        .foregroundStyle(spool.isLowStock ? KhaytDesign.attention : KhaytDesign.ink)
                }
                Spacer(minLength: 0)
                if let fraction {
                    Text((fraction * 100).rounded().formatted(.number.locale(L10n.locale)) + "%")
                        .font(.khaytMono(11, .regular, relativeTo: .caption2))
                        .foregroundStyle(KhaytDesign.note)
                }
            }
            if let fraction {
                LevelBar(fraction: fraction, color: tone)
                    .padding(.top, 7)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
        .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(spool.isLowStock ? KhaytDesign.attention.opacity(0.55) : KhaytDesign.hairline, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
