import SwiftUI

/**
 * Log a failed print without leaving the machine.
 *
 * Waste is recorded where it happens or it is not recorded at all, and
 * unrecorded waste is exactly the number a shop most needs — it is the
 * difference between a job that looked profitable and one that was. The desktop
 * has a perfectly good waste form; it is just at the other end of the workshop,
 * and the moment for logging a failure is while you are holding it.
 *
 * The material list comes from the shop's own inventory rather than free text,
 * because a waste entry has to reconcile against a spool to be costed, and
 * "PLA " with a trailing space does not.
 */
struct LogWasteSheet: View {
    @EnvironmentObject private var api: KhaytAPIClient
    @Environment(\.dismiss) private var dismiss

    /// Pre-selected when opened from a machine, so the common path is one field.
    var machineId: String?

    @State private var spools: [InventorySpool] = []
    @State private var material = ""
    @State private var failureType = "other"
    @State private var weight = ""
    @State private var reason = ""
    @State private var deduct = true

    @State private var isSaving = false
    @State private var error: String?

    // The desktop's own vocabulary. Free text here would make the failure-type
    // breakdown — the whole reason to categorise — unusable.
    private let failureTypes = ["warping", "adhesion", "clog", "layer_shift", "power", "other"]

    private var materials: [String] {
        Array(Set(spools.compactMap { $0.material }.filter { !$0.isEmpty })).sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.tr("waste.what")) {
                    if materials.isEmpty {
                        // Falling back to free text beats blocking the log: a
                        // record with a typo is worth more than no record.
                        TextField(L10n.tr("waste.material"), text: $material)
                    } else {
                        Picker(L10n.tr("waste.material"), selection: $material) {
                            Text("—").tag("")
                            ForEach(materials, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Picker(L10n.tr("waste.failure_type"), selection: $failureType) {
                        ForEach(failureTypes, id: \.self) { Text(L10n.tr("waste.ft.\($0)")).tag($0) }
                    }
                    HStack {
                        Text(L10n.tr("waste.weight"))
                        Spacer()
                        TextField("0", text: $weight)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 90)
                        Text(L10n.tr("unit.g")).foregroundStyle(KhaytDesign.textMuted)
                    }
                }
                Section(L10n.tr("waste.why")) {
                    TextField(L10n.tr("waste.reason"), text: $reason, axis: .vertical)
                        .lineLimit(1...3)
                }
                Section(footer: Text(L10n.tr("waste.deduct.footer"))) {
                    Toggle(L10n.tr("waste.deduct"), isOn: $deduct)
                }
                if let error {
                    Section {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(KhaytDesign.danger)
                    }
                }
            }
            .khaytForm()
            .navigationTitle(L10n.tr("waste.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common.close")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("waste.save")) { Task { await save() } }
                        .disabled(isSaving || material.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .task { await loadSpools() }
        }
    }

    private func loadSpools() async {
        spools = (try? await api.fetchInventory()) ?? []
        if material.isEmpty { material = materials.first ?? "" }
    }

    private func save() async {
        isSaving = true
        error = nil
        defer { isSaving = false }

        let grams = Double(weight.trimmingCharacters(in: .whitespaces)) ?? 0
        let entry = WasteEntry(
            material: material.trimmingCharacters(in: .whitespaces),
            failureType: failureType,
            // Cost is left to the desktop rather than guessed here: it depends on
            // which spool this came off, and a wrong number in the waste report
            // is worse than a blank one.
            weight: grams,
            cost: 0,
            reason: reason.trimmingCharacters(in: .whitespaces),
            notes: "",
            machineId: machineId,
            deduct: deduct && grams > 0
        )
        do {
            try await api.logWaste(entry)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
