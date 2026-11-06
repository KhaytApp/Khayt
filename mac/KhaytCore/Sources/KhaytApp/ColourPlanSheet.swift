import SwiftUI
import KhaytCore

/// "Plan Colours" on a library model: each colour the file needs, on a spool
/// the shop owns, with its grams, its cost, how close the spool's colour is,
/// and how the spools load into an AMS — the desktop's planner
/// (`renderer/color-planner.js`), in its words (`plan.*`).
///
/// Every figure is `lib/color-plan.js` through the engine: the starting spool
/// (the one saved last time while it is still on the shelf, else the nearest
/// colour by CIEDE2000), the cost per gram, the slot map. Saving writes the
/// record's `colorPlan` — `[{hex, filamentId, grams}]`, the desktop's own
/// shape — through the library's write chain, and the calculator and "Quote
/// This Model" then cost the model on those spools (`CalculatorModel.fill`).
///
/// The desktop's modal also pushes a part onto its calculator's build. The
/// Mac's calculator already fills itself from the saved plan when the model
/// is picked, so this saves and stops there rather than keeping a second way
/// for a model's colours to reach a price.
struct ColourPlanSheet: View {
    @Bindable var shop: Shop
    let file: LibraryFile
    @Environment(\.dismiss) private var dismiss

    @State private var plan: [KhaytEngine.ColourPlanRow] = []
    @State private var summary: KhaytEngine.ColourPlanSummary?
    @State private var closeness: [String] = []
    @State private var slots = 4
    @State private var problem: String?
    @State private var loaded = false

    /// The desktop modal's own title: the planner, then the model.
    private var heading: String { [shop.words.callIt("plan.title"), file.title].joined(separator: " — ") }

    /// Spools with a colour the planner can compare — its candidates.
    private var candidates: [Spool] { shop.spools.filter { Swatch.rgb(fromHex: $0.color) != nil } }

    var body: some View {
        let w = shop.words
        VStack(alignment: .leading, spacing: 12) {
            Text(heading).font(.title3.weight(.semibold)).lineLimit(1)
            if loaded && problem == nil {
                Text(w.callIt("mac.cpl_used_by")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // A 3MF can carry many colours: the rows scroll inside a
                // capped height rather than growing the sheet off a laptop.
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        table
                        slotMap
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 520)
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(Khayt.attention)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(w.callIt("mr.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(w.callIt("mac.cpl_save")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!loaded || problem != nil || !shop.canWrite)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 420)
        .task { await start() }
        .task(id: plan) { await recompute() }
    }

    private var table: some View {
        let w = shop.words
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text(w.callIt("plan.colour")).font(.caption.weight(.semibold))
                Text(w.callIt("plan.filament")).font(.caption.weight(.semibold))
                Text(w.callIt("plan.grams")).font(.caption.weight(.semibold))
                Text(w.callIt("plan.cost")).font(.caption.weight(.semibold))
            }
            ForEach(plan.indices, id: \.self) { i in
                GridRow {
                    HStack(spacing: 6) {
                        Swatch(rgb: Swatch.rgb(fromHex: plan[i].hex), size: 18)
                        Text(plan[i].hex.uppercased()).font(.caption.monospaced())
                        Text(plan[i].label).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Picker("", selection: Binding(get: { plan[i].filamentId }, set: { plan[i].filamentId = $0 })) {
                            Text(w.callIt("plan.unassigned")).tag("")
                            ForEach(candidates) { s in
                                Text(shop.spoolName(s)).tag(s.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 220)
                        if let de = summary?.rows[safe: i]?.deltaE {
                            Text(Self.deltaE(de))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(colour(for: closeness[safe: i] ?? ""))
                                .help(w.callIt(Self.closenessKey(closeness[safe: i] ?? "")))
                        }
                    }
                    TextField("", value: Binding(get: { plan[i].grams }, set: { plan[i].grams = max(0, $0.isFinite ? $0 : 0) }),
                              format: .number.precision(.fractionLength(0...1)).locale(Money.digits))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text(summary?.rows[safe: i]?.cost.map { Money.short($0, shop.currency) } ?? "—")
                        .font(.callout.monospacedDigit())
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            GridRow {
                HStack(spacing: 6) {
                    Text(w.callIt("plan.total")).font(.callout.weight(.semibold))
                    if file.swaps > 0 {
                        Text("· ↔ \(w.numeral(file.swaps)) \(w.callIt("plib.swaps"))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("")
                Text(PrintFigures.weight(summary?.totalGrams ?? 0, w)).font(.callout.monospacedDigit())
                Text(Money.short(summary?.totalCost ?? 0, shop.currency)).font(.callout.weight(.semibold).monospacedDigit())
            }
        }
    }

    static func deltaE(_ v: Double) -> String { "ΔE " + String(format: "%.1f", v) }

    static func closenessKey(_ band: String) -> String {
        switch band {
        case "good": "mac.cpl_good"
        case "ok": "mac.cpl_ok"
        default: "mac.cpl_far"
        }
    }

    private func colour(for band: String) -> Color {
        switch band {
        case "good": Khayt.done
        case "ok": Khayt.attention
        default: Khayt.late
        }
    }

    @ViewBuilder private var slotMap: some View {
        let w = shop.words
        if let summary, !summary.slots.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(w.callIt("plan.slotmap_head")).font(.caption.weight(.semibold))
                FlowLayout(spacing: 8) {
                    ForEach(Array(summary.slots.enumerated()), id: \.offset) { i, id in
                        let spool = shop.spools.first { $0.id == id }
                        HStack(spacing: 4) {
                            Text(w.callIt("mac.cpl_slot", ["n": .string(w.numeral(i + 1))])).font(.caption.weight(.semibold))
                            Swatch(rgb: Swatch.rgb(fromHex: spool?.color), size: 14)
                            Text(spool.map(shop.spoolName) ?? "?").font(.caption)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(i >= slots ? Khayt.attention.opacity(0.12) : Color.primary.opacity(0.06)))
                    }
                }
                Text(summary.overflow == 0
                     ? w.callIt("plan.slot_single", ["n": .string(w.numeral(summary.slots.count))])
                     : w.callIt("plan.slot_over", ["max": .string(w.numeral(slots)), "rest": .string(w.numeral(summary.overflow))]))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func start() async {
        let w = shop.words
        guard let engine = shop.engine else { problem = w.callIt("plan.no_colours"); return }
        let record = shop.fileRecord(file.id) ?? [:]
        var colours: [JSONValue] = []
        if case .array(let c)? = record["colors"] { colours = c }
        var saved: [JSONValue] = []
        if case .array(let s)? = record["colorPlan"] { saved = s }
        guard file.palette.contains(where: { ($0.hex ?? "").isEmpty == false }) else {
            problem = w.callIt("plan.no_colours"); loaded = true; return
        }
        guard !candidates.isEmpty else { problem = w.callIt("plan.no_filaments"); loaded = true; return }
        do {
            plan = try await engine.initialColourPlan(colours: colours, saved: saved, inventory: shop.inventoryRows)
            slots = (try? await engine.amsSlots()) ?? 4
            loaded = true
        } catch {
            problem = shop.said(error)
            loaded = true
        }
    }

    private func recompute() async {
        guard let engine = shop.engine, !plan.isEmpty else { return }
        guard let s = try? await engine.summariseColourPlan(plan, inventory: shop.inventoryRows) else { return }
        var bands: [String] = []
        for row in s.rows { bands.append((try? await engine.colourCloseness(row.deltaE)) ?? "") }
        summary = s
        closeness = bands
    }

    private func save() {
        guard plan.contains(where: { !$0.filamentId.isEmpty && $0.grams > 0 }) else {
            problem = shop.words.callIt("plan.assign_first")
            return
        }
        // The book's shape, `lib/color-plan.js` toSaved: {hex, filamentId, grams}.
        let rows: [JSONValue] = plan.map { .object(["hex": .string($0.hex), "filamentId": .string($0.filamentId),
                                                    "grams": .number($0.grams)]) }
        if shop.editFiles([file.id], named: shop.words.callIt("plan.title"), change: { record in
            record["colorPlan"] = .array(rows)
        }) {
            dismiss()
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
