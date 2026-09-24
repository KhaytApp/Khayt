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

    var body: some View {
        NavigationStack {
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAddSpool = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel(L10n.tr("spool.add.title"))
                }
            }
            .sheet(isPresented: $showAddSpool) {
                AddSpoolSheet { Task { await load() } }
            }
            .navigationDestination(item: $openSpool) { spool in
                SpoolDetailPage(spool: spool) { await load() }
            }
            .refreshable { await load() }
            .task { await load() }
            .onAppear { takeLowStockRequest() }
            .onChange(of: ordersNav.lowStockRequest) { _, _ in takeLowStockRequest() }
        }
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
                .foregroundStyle(on ? KhaytDesign.brand : KhaytDesign.note)
                .background(on ? KhaytDesign.brand.opacity(0.16) : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(on ? KhaytDesign.brand.opacity(0.5) : KhaytDesign.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder
    private var list: some View {
        if !loaded && errorMessage == nil {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 44)
        } else if displayed.isEmpty {
            let searching = !searchText.isEmpty || lowOnly
            VStack(spacing: 5) {
                Text(L10n.tr(searching ? "inventory.no_results" : "inventory.none"))
                    .font(.khayt(15, .semibold, relativeTo: .headline))
                    .foregroundStyle(KhaytDesign.ink)
                Text(errorMessage ?? L10n.tr(searching ? "inventory.no_results.sub" : "inventory.none.sub"))
                    .font(.khayt(13, relativeTo: .footnote))
                    .foregroundStyle(KhaytDesign.note)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 44).padding(.horizontal, 16)
        } else {
            LazyVStack(spacing: 8) {
                ForEach(displayed) { spool in
                    Button { openSpool = spool } label: { SpoolRow(spool: spool) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var wholeLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(format: L10n.tr("inventory.whole.count"), spools.count.formatted()))
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
        } catch {
            spools = []
            errorMessage = error.localizedDescription
        }
        loaded = true
    }
}

/// A spool in the list: its colour, what it is, and how much is left. A roll
/// running low earns the amber rail — the design's only colour on this screen.
private struct SpoolRow: View {
    let spool: InventorySpool

    /// What is left as a share of what it arrived with, or nil when the book
    /// never recorded the arrival weight — a bar drawn against a guessed kilo
    /// would read a 3 kg roll as three times full.
    private var fraction: Double? {
        guard let left = spool.remainingGrams, let full = spool.initialWeight, full > 0 else { return nil }
        return min(1, max(0, left / full))
    }

    private var tone: Color { spool.isLowStock ? KhaytDesign.attention : KhaytDesign.note }

    var body: some View {
        HStack(spacing: 12) {
            SpoolSwatch(hex: spool.colorHex)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(spool.displayLabel)
                        .font(.khayt(15, .medium, relativeTo: .body))
                        .foregroundStyle(KhaytDesign.ink)
                        .lineLimit(1)
                    Text(spool.id)
                        .font(.khayt(11.5, .medium, relativeTo: .caption2))
                        .foregroundStyle(KhaytDesign.note)
                        .lineLimit(1)
                        .layoutPriority(-1)
                        .environment(\.layoutDirection, .leftToRight)
                }
                HStack(spacing: 9) {
                    if let fraction {
                        LevelBar(fraction: fraction, color: tone)
                    } else {
                        Spacer(minLength: 0)
                    }
                    if let left = spool.remainingGrams {
                        Text("\(Int(left.rounded())) g")
                            .font(.khayt(12.5, .medium, relativeTo: .caption).monospacedDigit())
                            .foregroundStyle(tone)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                }
            }
        }
        .padding(.vertical, 12).padding(.leading, 16).padding(.trailing, 13)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .background(KhaytDesign.surface)
        .overlay(alignment: .leading) {
            if spool.isLowStock { Rectangle().fill(KhaytDesign.attention).frame(width: 3) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .combine)
    }
}
