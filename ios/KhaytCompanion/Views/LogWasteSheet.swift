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

    private var canSave: Bool { !material.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    V2FieldCard {
                        V2Field(label: L10n.tr("waste.material")) {
                            if materials.isEmpty {
                                // Falling back to free text beats blocking the log:
                                // a record with a typo is worth more than no record.
                                TextField("", text: $material, prompt: Text(verbatim: "PLA"))
                            } else {
                                V2Chips(options: materials, selection: $material) { $0 }
                                    .padding(.vertical, 4)
                            }
                        }
                        V2Field(label: L10n.tr("waste.failure_type")) {
                            V2Chips(options: failureTypes, selection: $failureType) { L10n.tr("waste.ft.\($0)") }
                                .padding(.vertical, 4)
                        }
                        V2Field(label: L10n.tr("waste.weight")) {
                            HStack(spacing: 6) {
                                TextField("", text: $weight, prompt: Text(verbatim: "0"))
                                    .keyboardType(.numberPad)
                                Text(L10n.tr("unit.g")).foregroundStyle(KhaytDesign.note)
                            }
                        }
                        V2Field(label: L10n.tr("waste.reason"), last: true) {
                            TextField("", text: $reason, axis: .vertical)
                                .lineLimit(1...3)
                        }
                    }
                    V2FieldCard {
                        Toggle(isOn: $deduct) {
                            Text(L10n.tr("waste.deduct"))
                                .font(.khayt(14.5, relativeTo: .subheadline))
                                .foregroundStyle(KhaytDesign.ink)
                        }
                        .tint(KhaytDesign.done)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 52)
                    }
                    V2Note(text: error ?? L10n.tr("waste.deduct.footer"),
                           tone: error == nil ? KhaytDesign.note : KhaytDesign.late)
                    V2PrimaryButton(title: L10n.tr("waste.save"), busy: isSaving, disabled: !canSave) {
                        Task { await save() }
                    }
                    .padding(.top, 4)
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(KhaytDesign.ground.ignoresSafeArea())
            .navigationTitle(L10n.tr("waste.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common.close")) { dismiss() }
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
