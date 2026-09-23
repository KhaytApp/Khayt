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
                Section(L10n.tr("spool.detail.filament")) {
                    if let hex = spool.colorHex {
                        LabeledContent(L10n.tr("spool.detail.color")) {
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
                    LabeledContent(L10n.tr("spool.detail.name"), value: spool.displayLabel)
                    if let brand = spool.brand, !brand.isEmpty {
                        LabeledContent(L10n.tr("field.brand"), value: brand)
                    }
                    if let material = spool.material, !material.isEmpty {
                        LabeledContent(L10n.tr("field.material"), value: material)
                    }
                }

                Section(L10n.tr("spool.detail.stock")) {
                    LabeledContent(L10n.tr("spool.detail.remaining"), value: "\(remainingGrams) g")
                    if spool.isLowStock && localRemaining == nil {
                        Label(L10n.tr("inventory.low_badge"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    // `spool.weight` is what is LEFT, not what it started as —
                    // the store keeps the full spool in `spoolWeight`. This
                    // printed the remaining grams under "Initial weight", so a
                    // 860 g spool of a 1 kg roll read 860 / 860: every spool in
                    // the shop looked unopened.
                    if let initial = spool.initialWeight {
                        LabeledContent(L10n.tr("spool.detail.initial"), value: "\(Int(initial)) g")
                    }
                    if let purchased = spool.purchasedAt {
                        LabeledContent(L10n.tr("spool.detail.purchased"), value: purchased)
                    }
                    Button {
                        adjustText = "\(remainingGrams)"
                        showAdjust = true
                    } label: {
                        Label(L10n.tr("spool.detail.adjust"), systemImage: "slider.horizontal.3")
                    }
                    .disabled(isWorking)
                }

                if spool.hasOptionalMeta {
                    Section(L10n.tr("spool.detail.label_info")) {
                        if let sku = spool.sku, !sku.isEmpty {
                            LabeledContent(L10n.tr("spool.form.sku"), value: sku)
                        }
                        if let lot = spool.lot, !lot.isEmpty {
                            LabeledContent(L10n.tr("spool.detail.lot"), value: lot)
                        }
                        if let p = spool.printTemp {
                            LabeledContent(L10n.tr("spool.detail.print_temp"), value: "\(p)°C")
                        }
                        if let b = spool.bedTemp {
                            LabeledContent(L10n.tr("spool.detail.bed_temp"), value: "\(b)°C")
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
                        Label(L10n.tr("spool.detail.remove"), systemImage: "trash")
                    }
                    .disabled(isWorking)
                }

                Section {
                    LabeledContent(L10n.tr("spool.detail.id"), value: spool.id)
                        .font(.caption)
                }
            }
            .navigationTitle(L10n.tr("spool.detail.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("common.done")) { dismiss() }
                }
            }
            .sheet(isPresented: $showWriteNFC) {
                WriteNFCTagSheet(draft: SpoolDraft.from(spool: spool))
            }
            .alert(L10n.tr("spool.detail.adjust"), isPresented: $showAdjust) {
                TextField(L10n.tr("spool.detail.grams"), text: $adjustText)
                    .keyboardType(.numberPad)
                Button(L10n.tr("common.save")) { Task { await saveRemaining() } }
                Button(L10n.tr("common.cancel"), role: .cancel) {}
            } message: {
                Text(L10n.tr("spool.detail.adjust.body"))
            }
            .alert(L10n.tr("spool.detail.remove_q"), isPresented: $showDeleteConfirm) {
                Button(L10n.tr("common.remove"), role: .destructive) { Task { await removeSpool() } }
                Button(L10n.tr("common.cancel"), role: .cancel) {}
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
            errorMessage = L10n.tr("spool.detail.grams_error")
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
