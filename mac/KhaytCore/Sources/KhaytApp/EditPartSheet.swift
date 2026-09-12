import SwiftUI
import KhaytCore

/// Correcting one part of a job.
///
/// ── WHY THIS EXISTS ────────────────────────────────────────────────────────
///
/// Parts were read-only on this app. A weight typed wrong when the job was
/// taken stayed wrong: the only way to fix it was to open the job in the other
/// Khayt, which a shop running on the Mac does not have in front of it.
///
/// ── AND WHY IT RE-COSTS RATHER THAN LETTING THE PRICE BE TYPED ─────────────
///
/// The cost is not a field. A part that weighs 40 g rather than 30 g costs more
/// to make, and a screen that let both be typed independently would let a shop
/// record a job whose parts do not add up to its own total. So the figures a
/// shop knows — what it weighs, how long it took, how many — are asked for, and
/// the price follows from the shared cost model.
struct EditPartSheet: View {
    let shop: Shop
    let orderId: Order.ID
    let part: Order.Part
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var grams: String = ""
    @State private var hours: String = ""
    @State private var qty: Int = 1
    @State private var spoolId: String?
    /// What the library file says, once it has been asked. Nil until then, and
    /// nil forever for a part that was never linked to one.
    @State private var suggestion: KhaytEngine.PartFromFile?
    @State private var preview: KhaytEngine.CostedPart?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(shop.words.callIt("mac.edit_part")).font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 10) {
                TextField(shop.words.callIt("mac.a_part"), text: $name)
                    .textFieldStyle(.roundedBorder)

                Picker("", selection: $spoolId) {
                    Text(shop.words.callIt("mac.filament")).tag(String?.none)
                    ForEach(shop.spools) { spool in
                        Text(spool.label(shop.words, unit: shop.unit(of: spool)))
                            .tag(String?.some(spool.id))
                    }
                }
                .labelsHidden()

                HStack(spacing: 8) {
                    // Short prompts inside the fields, as the new-job sheet
                    // does: three numbers on one line is the shape of the
                    // question, and a label each would take the width the
                    // numbers need.
                    TextField(shop.words.callIt("mac.grams"), text: $grams)
                        .textFieldStyle(.roundedBorder).frame(width: 90).monospacedDigit()
                    TextField(shop.words.callIt("mac.hours"), text: $hours)
                        .textFieldStyle(.roundedBorder).frame(width: 90).monospacedDigit()
                    Stepper("× \(qty)", value: $qty, in: 1...999).monospacedDigit().fixedSize()
                }

                // Only where the part is linked to a library model AND that
                // model has something to say. A button that answers "nothing to
                // fill in" is a button that teaches people not to press it.
                if let suggestion, suggestion.printWeight != nil || suggestion.printTime != nil {
                    fill(suggestion)
                }
            }

            if let preview { costLine(preview) }

            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("common.save")) {
                    saving = true
                    Task {
                        await shop.editPart(orderId, partId: part.id, name: name,
                                            spoolId: spoolId,
                                            grams: Double(grams) ?? 0,
                                            hours: Double(hours) ?? 0, qty: qty)
                        saving = false
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || !shop.canMoveJobs)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task {
            name = part.name
            grams = Self.number(part.printWeight)
            qty = max(1, part.qty)
            spoolId = shop.spools.first { $0.material == part.material }?.id
            hours = Self.number(await shop.partHours(orderId, partId: part.id) ?? 0)
            suggestion = await shop.partSuggestion(fileId: part.printFileId)
        }
        // Re-costed as the figures change, so the price on the button is the
        // price that will be written rather than the one it had on open.
        .task(id: "\(grams)|\(hours)|\(qty)|\(spoolId ?? "")") {
            preview = await shop.costedPart(spoolId: spoolId, grams: Double(grams) ?? 0,
                                            hours: Double(hours) ?? 0, qty: qty)
        }
    }

    /// What the file says, and a way to take it.
    ///
    /// It shows both figures rather than filling silently: the part may have
    /// been corrected on purpose, and overwriting a deliberate figure with a
    /// slicer's estimate without showing both is the app being confident about
    /// something only the shop knows.
    @ViewBuilder private func fill(_ s: KhaytEngine.PartFromFile) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(said(s)).font(.caption).foregroundStyle(.secondary)
                if !s.missing.isEmpty {
                    Text(s.missing.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 6)
            Button(shop.words.callIt("mac.fill_from_file")) {
                if let g = s.printWeight { grams = Self.number(g) }
                if let h = s.printTime { hours = Self.number(h) }
            }
            .font(.caption)
        }
        .padding(.top, 2)
    }

    /// The file's figures, written here rather than taken from `describe`.
    ///
    /// `lib/part-from-print-file.js` composes that sentence in English, and this
    /// app is read in Arabic too — so the FIGURES cross and the line is built
    /// against the locale. The provenance words (`slicer`, `setup`) are the
    /// rule's own and are not re-derived.
    private func said(_ s: KhaytEngine.PartFromFile) -> String {
        var bits: [String] = []
        if let g = s.printWeight {
            bits.append("\(Self.number(g)) \(shop.words.callIt("common.grams"))")
        }
        if let h = s.printTime {
            bits.append("\(Self.number(h)) \(shop.words.callIt("common.hours_short"))")
        }
        if let setup = s.setupName, !setup.isEmpty { bits.append(setup) }
        return bits.joined(separator: " · ")
    }

    /// What it will cost once saved.
    ///
    /// The total only. The cost model splits into material, machine, labour and
    /// the failure allowance, and no screen on this app has ever shown that
    /// split — putting it here first would mean inventing four locale words for
    /// a figure nobody asked this sheet for. The total is what changes when a
    /// weight is corrected, and it is what the shop acts on.
    private func costLine(_ costed: KhaytEngine.CostedPart) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(shop.words.callIt("mac.cost")).font(.caption).foregroundStyle(.secondary)
            Text(Money.text(costed.cost * Double(qty), shop.currency)).moneyStyle()
            Spacer()
        }
        .padding(.top, 2)
    }

    /// Whole numbers stay whole. "40 g" is a weight; "40.0 g" reads as a
    /// measurement of something that is not.
    static func number(_ v: Double) -> String {
        let whole = v.rounded()
        return abs(v - whole) < 0.005
            ? String(Int(whole))
            : String(format: "%.2f", v).replacingOccurrences(of: "0$", with: "",
                                                             options: .regularExpression)
    }
}
