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
                    .padding(.bottom, 8)
                content
            }
            .khaytScreen(title: L10n.tr("tab.inventory"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Filter", selection: $filter) {
                            ForEach(Filter.allCases) { f in
                                Text(f.rawValue).tag(f)
                            }
                        }
                        Toggle("Newest first", isOn: $sortNewestFirst)
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
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
            ContentUnavailableView(
                filter == .lowStock ? "No low stock" : "No spools",
                systemImage: "cylinder",
                description: Text(
                    errorMessage
                        ?? (searchText.isEmpty
                            ? "Tap + to add a spool."
                            : "No match for \"\(searchText)\".")
                )
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
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        spoolToDelete = spool
                    } label: {
                        Label("Delete", systemImage: "trash")
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

private struct SpoolRow: View {
    let spool: InventorySpool

    var body: some View {
        HStack(spacing: 12) {
            swatch
            detail
        }
        .padding(.vertical, 2)
    }

    private var swatch: some View {
        let fill = spool.colorHex.map { Color(hex: UInt32($0.dropFirst(), radix: 16) ?? 0x888888) }
            ?? KhaytDesign.surface2
        return RoundedRectangle(cornerRadius: 7)
            .fill(fill)
            .frame(width: 34, height: 34)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(KhaytDesign.border, lineWidth: 0.5)
            )
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(spool.displayLabel)
                    .font(.headline)
                    .foregroundStyle(KhaytDesign.text)
                Spacer()
                if spool.isLowStock {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(KhaytDesign.warn)
                }
            }
            HStack(spacing: 8) {
                if let remaining = spool.remainingGrams {
                    Text("\(Int(remaining)) g")
                        .font(.caption)
                        .foregroundStyle(spool.isLowStock ? KhaytDesign.warn : KhaytDesign.textDim)
                }
                if let p = spool.printTemp, let b = spool.bedTemp {
                    Text("\(p)° / \(b)°")
                        .font(.caption2)
                        .foregroundStyle(KhaytDesign.brand)
                }
                if let lot = spool.lot, !lot.isEmpty {
                    Text(lot)
                        .font(.caption2)
                        .foregroundStyle(KhaytDesign.textMuted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(KhaytDesign.surface2, in: Capsule())
                }
            }
        }
    }
}
