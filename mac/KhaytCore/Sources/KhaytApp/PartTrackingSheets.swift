import SwiftUI
import KhaytCore

/// Which parts of an open job have already gone to the customer — the
/// desktop's partial delivery (`openPartialDeliveryModal`). One tick per part;
/// Save writes `parts[i].delivered` through `Shop.setPartsDelivered`.
struct PartsDeliveredSheet: View {
    let shop: Shop
    let job: Order
    @Environment(\.dismiss) private var dismiss
    @State private var ticked: [Bool] = []
    @State private var saving = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(shop.words.callIt("ord.partial_delivery")).font(.title3.weight(.semibold))
            Text(shop.words.callIt("mac.parts_delivered_hint"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(job.parts.enumerated()), id: \.offset) { i, part in
                    Toggle(isOn: binding(i)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(part.name).lineLimit(1)
                            if !part.material.isEmpty {
                                Text(part.material).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }

            Text(shop.words.callIt("ord.parts_delivered", [
                "done": .number(Double(ticked.filter { $0 }.count)),
                "total": .number(Double(job.parts.count)),
            ]))
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()

            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("common.save")) {
                    saving = true
                    let asked = ticked
                    Task {
                        let wrote = await shop.setPartsDelivered(job.id, delivered: asked)
                        saving = false
                        if wrote { dismiss() } else { problem = shop.moveProblem }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || !shop.canMoveJobs || ticked.count != job.parts.count)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { ticked = job.parts.map(\.delivered) }
    }

    private func binding(_ i: Int) -> Binding<Bool> {
        Binding(get: { ticked.indices.contains(i) ? ticked[i] : false },
                set: { if ticked.indices.contains(i) { ticked[i] = $0 } })
    }
}

/// One part of a job, picked for a spool switch.
struct SpoolSwitchTarget: Identifiable {
    /// The part's position in the job — the desktop addresses parts the same
    /// way, since a part written by its calculator has no id of its own.
    let id: Int
    let part: Order.Part
    let partCount: Int
}

/// A part's print that finished on another roll — the desktop's spool switch
/// (`openSpoolSwitchModal`). Pick the roll and the grams it gave; Save takes
/// them off that roll and records them on the part, in one write.
struct SpoolSwitchSheet: View {
    let shop: Shop
    let job: Order
    let target: SpoolSwitchTarget
    @Environment(\.dismiss) private var dismiss
    @State private var spoolId: String?
    @State private var grams = ""
    @State private var saving = false
    @State private var problem: String?

    private var amount: Double? {
        let typed = grams.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let n = Double(typed), n.isFinite, n > 0 else { return nil }
        return n
    }

    var body: some View {
        let stocked = shop.spoolsForSwitch()
        VStack(alignment: .leading, spacing: 14) {
            Text(shop.words.callIt("ord.spool_switch")).font(.title3.weight(.semibold))
            Text(verbatim: target.part.material.isEmpty
                 ? target.part.name : "\(target.part.name) · \(target.part.material)")
                .font(.callout).foregroundStyle(.secondary)

            if stocked.isEmpty {
                Text(shop.words.callIt("mac.spool_switch_none"))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("", selection: $spoolId) {
                    Text(shop.words.callIt("mac.spool_switch_pick")).tag(String?.none)
                    ForEach(stocked) { spool in
                        Text(spool.label(shop.words, unit: shop.unit(of: spool)))
                            .tag(String?.some(spool.id))
                    }
                }
                .labelsHidden()
                TextField(shop.words.callIt("mac.grams"), text: $grams)
                    .textFieldStyle(.roundedBorder).frame(width: 120).monospacedDigit()
            }

            Text(shop.words.callIt("mac.spool_switch_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("ord.add_spool")) {
                    guard let spoolId, let amount else { return }
                    saving = true
                    Task {
                        let wrote = await shop.addSpoolSwitch(job.id, partIndex: target.id,
                                                              partCount: target.partCount,
                                                              spoolId: spoolId, grams: amount)
                        saving = false
                        if wrote { dismiss() } else { problem = shop.moveProblem }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || spoolId == nil || amount == nil || !shop.canSwitchSpools)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

extension Shop {
    /// May this window record a spool switch: a job edit that draws stock.
    var canSwitchSpools: Bool { canMoveJobs && lockAllows("inventory", "edit") }
}
