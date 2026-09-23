import SwiftUI

struct InventoryView: View {
    @EnvironmentObject private var api: KhaytAPIClient

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case lowStock = "Low stock"
        var id: String { rawValue }
    }

    @State private var spools: [InventorySpool] = []
    @State private var errorMessage: String?
    @State private var showAddSpool = false
    @State private var searchText = ""
    @State private var filter: Filter = .all
    @State private var selectedSpool: InventorySpool?
    @State private var spoolToDelete: InventorySpool?
    @State private var sortNewestFirst = true

    private var displayed: [InventorySpool] {
        var list = spools
        if filter == .lowStock {
            list = list.filter(\.isLowStock)
        }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            list = list.filter {
                $0.displayLabel.lowercased().contains(q)
                    || ($0.lot ?? "").lowercased().contains(q)
                    || ($0.sku ?? "").lowercased().contains(q)
            }
        }
        return list.sorted { a, b in
            let da = a.purchasedAt ?? a.addedAt ?? ""
            let db = b.purchasedAt ?? b.addedAt ?? ""
            return sortNewestFirst ? da > db : da < db
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                KhaytSearchField(text: $searchText, prompt: L10n.tr("inventory.search"))
                    .padding(.horizontal, KhaytDesign.pad)
                    .padding(.top, 4)
                // `khayt-inventory.jsx`: the two filters sit under the search,
                // counted, where a shop can see there IS low stock without
                // opening a menu to ask.
                HStack(spacing: 8) {
                    filterChip(.all, count: spools.count)
                    filterChip(.lowStock, count: spools.filter(\.isLowStock).count)
                    Spacer()
                }
                .padding(.horizontal, KhaytDesign.pad)
                .padding(.vertical, 8)
                content
            }
            .khaytScreen(title: L10n.tr("tab.inventory"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Toggle(L10n.tr("inventory.sort.newest"), isOn: $sortNewestFirst)
                    } label: {
                        Image(systemName: "arrow.up.arrow.down.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAddSpool = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAddSpool) {
                AddSpoolSheet { Task { await load() } }
            }
            .sheet(item: $selectedSpool) { spool in
                SpoolDetailSheet(spool: spool) { Task { await load() } }
            }
            .alert("Remove spool?", isPresented: showDeleteAlert, presenting: spoolToDelete) { spool in
                Button("Remove", role: .destructive) { Task { await delete(spool) } }
                Button("Cancel", role: .cancel) {}
            } message: { spool in
                Text("\(spool.displayLabel) will be removed from inventory.")
            }
            .task { await load() }
        }
    }

    private func filterChip(_ f: Filter, count: Int) -> some View {
        let selected = filter == f
        let tint = f == .lowStock ? KhaytDesign.danger : KhaytDesign.brand
        return Button { filter = f } label: {
            Text("\(L10n.tr(f == .all ? "inventory.filter.all" : "inventory.filter.low")) (\(count))")
                .font(.caption.bold())
                .monospacedDigit()
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(selected ? tint.opacity(0.16) : KhaytDesign.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? tint.opacity(0.32) : KhaytDesign.sep, lineWidth: 1.5))
                .foregroundStyle(selected ? tint : KhaytDesign.textDim)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var showDeleteAlert: Binding<Bool> {
        Binding(get: { spoolToDelete != nil }, set: { if !$0 { spoolToDelete = nil } })
    }

    private func delete(_ spool: InventorySpool) async {
        do {
            try await api.deleteSpool(id: spool.id)
            CompanionHaptics.success()
            await load()
        } catch {
            errorMessage = error.localizedDescription
            CompanionHaptics.warning()
        }
    }

    @ViewBuilder
    private var content: some View {
        if spools.isEmpty && errorMessage == nil {
            Spacer()
            ProgressView()
            Spacer()
        } else if displayed.isEmpty {
            let searching = !searchText.isEmpty || filter == .lowStock
            ContentUnavailableView(
                L10n.tr(searching ? "inventory.no_results" : "inventory.none"),
                systemImage: "cylinder",
                description: Text(errorMessage
                    ?? L10n.tr(searching ? "inventory.no_results.sub" : "inventory.none.sub"))
            )
        } else {
            List(displayed) { spool in
                Button {
                    selectedSpool = spool
                } label: {
                    SpoolRow(spool: spool)
                }
                .buttonStyle(.plain)
                .listRowBackground(KhaytDesign.surface)
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        spoolToDelete = spool
                    } label: {
                        Label(L10n.tr("inventory.delete"), systemImage: "trash")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .refreshable { await load() }
        }
    }

    private func load() async {
        errorMessage = nil
        do {
            spools = try await api.fetchInventory()
        } catch {
            spools = []
            errorMessage = error.localizedDescription
        }
    }
}

/// `khayt-inventory.jsx` SpoolRow: the colour, what it is, and how much is left.
private struct SpoolRow: View {
    let spool: InventorySpool

    /// What is left as a share of what it arrived with, or nil when the book
    /// never recorded the arrival weight — a bar drawn against a guessed
    /// kilo would read a 3 kg roll as three times full.
    private var fraction: Double? {
        guard let left = spool.remainingGrams, let full = spool.initialWeight, full > 0 else { return nil }
        return min(1, max(0, left / full))
    }

    /// The mockup's `remainingColor`: red under 15%, amber under 30%. A roll
    /// the shop's own low-stock rule flags is red whatever its share says.
    private var levelColor: Color {
        if spool.isLowStock { return KhaytDesign.danger }
        guard let f = fraction else { return KhaytDesign.textDim }
        if f < 0.15 { return KhaytDesign.danger }
        if f < 0.30 { return KhaytDesign.warn }
        return KhaytDesign.ok
    }

    private var subtitle: String {
        var parts: [String] = []
        if let sku = spool.sku, !sku.isEmpty { parts.append(sku) }
        if let lot = spool.lot, !lot.isEmpty { parts.append(lot) }
        if let p = spool.printTemp, let b = spool.bedTemp { parts.append("\(p)° / \(b)°") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            swatch
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(spool.displayLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KhaytDesign.text)
                        .lineLimit(1)
                    if spool.isLowStock {
                        Text(L10n.tr("inventory.low"))
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.4)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .foregroundStyle(KhaytDesign.danger)
                            .background(KhaytDesign.dangerSoft, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(KhaytDesign.textDim)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    if let f = fraction {
                        LevelBar(fraction: f, color: levelColor)
                    } else {
                        Spacer(minLength: 0)
                    }
                    if let left = spool.remainingGrams {
                        Text("\(Int(left.rounded())) g")
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(levelColor)
                    }
                }
            }
            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(KhaytDesign.textMuted)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var swatch: some View {
        let fill = spool.colorHex.map { Color(hex: UInt32($0.dropFirst(), radix: 16) ?? 0x888888) }
            ?? KhaytDesign.surface2
        return RoundedRectangle(cornerRadius: 12)
            .fill(fill)
            .frame(width: 40, height: 40)
            // A black roll on a dark card, or a white one on a light card, is
            // otherwise a hole in the row.
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(KhaytDesign.textFaint, lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
            .overlay(alignment: .topTrailing) {
                if spool.isLowStock {
                    Circle()
                        .fill(KhaytDesign.danger)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(KhaytDesign.surface, lineWidth: 2))
                        .offset(x: 4, y: -4)
                }
            }
            .accessibilityHidden(true)
    }
}

/// A thin rounded level, filled from the leading edge — so it reads the right
/// way round in Arabic too.
private struct LevelBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(KhaytDesign.surface3)
                Capsule().fill(color).frame(width: max(4, geo.size.width * fraction))
            }
        }
        .frame(height: 4)
    }
}
