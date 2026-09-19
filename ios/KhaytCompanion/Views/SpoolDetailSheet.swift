import SwiftUI

struct SpoolDetailSheet: View {
    let spool: InventorySpool
    var onChanged: () -> Void = {}
    @EnvironmentObject private var api: KhaytAPIClient
    @Environment(\.dismiss) private var dismiss
    @State private var showWriteNFC = false
    @State private var showAdjust = false
    @State private var adjustText = ""
    @State private var showDeleteConfirm = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var localRemaining: Int?

    var body: some View {
        NavigationStack {
            List {
                Section("Filament") {
                    if let hex = spool.colorHex {
                        LabeledContent("Color") {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color(hex: hex) ?? .gray)
                                    .frame(width: 22, height: 22)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5)
                                            .stroke(KhaytDesign.border, lineWidth: 0.5)
                                    )
                                Text(hex.uppercased())
                                    .font(.caption.monospaced())
                                    .foregroundStyle(KhaytDesign.textDim)
                            }
                        }
                    }
                    LabeledContent("Name", value: spool.displayLabel)
                    if let brand = spool.brand, !brand.isEmpty {
                        LabeledContent("Brand", value: brand)
                    }
                    if let material = spool.material, !material.isEmpty {
                        LabeledContent("Material", value: material)
                    }
                }

                Section("Stock") {
                    LabeledContent("Remaining", value: "\(remainingGrams) g")
                    if spool.isLowStock && localRemaining == nil {
                        Label("Low stock", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    // `spool.weight` is what is LEFT, not what it started as —
                    // the store keeps the full spool in `spoolWeight`. This
                    // printed the remaining grams under "Initial weight", so a
                    // 860 g spool of a 1 kg roll read 860 / 860: every spool in
                    // the shop looked unopened.
                    if let initial = spool.initialWeight {
                        LabeledContent("Initial weight", value: "\(Int(initial)) g")
                    }
                    if let purchased = spool.purchasedAt {
                        LabeledContent("Purchased", value: purchased)
                    }
                    Button {
                        adjustText = "\(remainingGrams)"
                        showAdjust = true
                    } label: {
                        Label("Adjust remaining", systemImage: "slider.horizontal.3")
                    }
                    .disabled(isWorking)
                }

                if spool.hasOptionalMeta {
                    Section("Label / tag info") {
                        if let sku = spool.sku, !sku.isEmpty {
                            LabeledContent("SKU", value: sku)
                        }
                        if let lot = spool.lot, !lot.isEmpty {
                            LabeledContent("Batch / lot", value: lot)
                        }
                        if let p = spool.printTemp {
                            LabeledContent("Print temp", value: "\(p)°C")
                        }
                        if let b = spool.bedTemp {
                            LabeledContent("Bed temp", value: "\(b)°C")
                        }
                    }
                }

                Section {
                    Button {
                        showWriteNFC = true
                    } label: {
                        Label(L10n.tr("nfc.write.title"), systemImage: "wave.3.right")
                    }
                } footer: {
                    Text(L10n.tr("nfc.write.footer"))
                        .font(.caption)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Remove spool", systemImage: "trash")
                    }
                    .disabled(isWorking)
                }

                Section {
                    LabeledContent("ID", value: spool.id)
                        .font(.caption)
                }
            }
            .navigationTitle("Spool")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showWriteNFC) {
                WriteNFCTagSheet(draft: SpoolDraft.from(spool: spool))
            }
            .alert("Adjust remaining", isPresented: $showAdjust) {
                TextField("Grams", text: $adjustText)
                    .keyboardType(.numberPad)
                Button("Save") { Task { await saveRemaining() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Set the remaining filament for this spool, in grams.")
            }
            .alert("Remove spool?", isPresented: $showDeleteConfirm) {
                Button("Remove", role: .destructive) { Task { await removeSpool() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(spool.displayLabel) will be removed from inventory.")
            }
        }
    }

    private var remainingGrams: Int {
        localRemaining ?? Int(spool.remainingGrams ?? 0)
    }

    private func saveRemaining() async {
        guard let grams = Int(adjustText.trimmingCharacters(in: .whitespaces)) else {
            errorMessage = "Enter a number in grams."
            return
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await api.updateSpoolRemaining(id: spool.id, grams: grams)
            localRemaining = max(0, grams)
            CompanionHaptics.success()
            onChanged()
        } catch {
            errorMessage = error.localizedDescription
            CompanionHaptics.warning()
        }
    }

    private func removeSpool() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await api.deleteSpool(id: spool.id)
            CompanionHaptics.success()
            onChanged()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            CompanionHaptics.warning()
        }
    }
}
