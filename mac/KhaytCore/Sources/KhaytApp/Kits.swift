import SwiftUI
import KhaytCore

/// Several prints that are one object.
///
/// ── WHY THIS IS NOT THE ASSEMBLY SCREEN ───────────────────────────────────
///
/// Khayt already has assemblies, and they are a different thing: one ORDER
/// holding several parts plus bought-in components, gated on QC — something you
/// sell. A kit is a grouping ACROSS orders, over work already done. A figure
/// printed as Head, Hand, Body and Legs on four evenings is four print-log
/// entries, and "what did that figure cost me" was arithmetic across four rows
/// that nobody does.
///
/// Grouped rather than merged, and the reason is not tidiness: the actuals
/// (`actualPrintTime`, `actualWeight`) live on the ORDER and nowhere else. Four
/// jobs folded into one would replace four measured numbers with one, and those
/// four are exactly what the estimator calibrates its rate from.
///
/// ── EVERY TOTAL CARRIES ITS COUNT ─────────────────────────────────────────
///
/// `lib/print-kits.js` returns `measuredTime` and `measuredWeight` beside each
/// sum, and it says why: totalling `actualPrintTime` across entries where some
/// are null yields a figure that LOOKS like the kit's total and silently omits
/// whatever was never measured. The module refuses to do that, and a screen
/// that drew the total without the count would reintroduce the bug at the last
/// step. So "3 of 4 measured" is on the chip, in amber, whenever it is not all
/// of them.

// MARK: - The band above the book

/// One row of kits above the jobs table, shown only when the book has any.
///
/// A chip that merely states a total is decoration. Clicking one narrows the
/// book to that kit's jobs — "show me the four that made this figure" — which
/// is the question somebody reading the total is about to ask anyway.
struct KitBand: View {
    @Bindable var shop: Shop
    @State private var renaming: KhaytEngine.PrintKit?
    @State private var disbanding: KhaytEngine.PrintKit?

    var body: some View {
        if !shop.kits.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(shop.kits) { kit in
                        KitChip(shop: shop, kit: kit,
                                narrowed: shop.kitFilter == kit.id)
                            .onTapGesture {
                                shop.kitFilter = shop.kitFilter == kit.id ? nil : kit.id
                            }
                            .contextMenu {
                                Button(shop.words.callIt("mac.rename_kit")) { renaming = kit }
                                Button(shop.words.callIt("mac.disband_kit"), role: .destructive) {
                                    disbanding = kit
                                }
                                .disabled(!shop.canWrite)
                            }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.automatic)
            .background(.quaternary.opacity(0.25))
            .overlay(alignment: .bottom) { Divider() }
            .sheet(item: $renaming) { kit in
                RenameKit(shop: shop, kit: kit)
            }
            // The prints are not touched, so this is a confirmation and not a
            // warning — but it is still a write the shop did not obviously ask
            // for from a context menu, and a kit rebuilt by hand is four more
            // filings.
            .confirmationDialog(
                shop.words.callIt("mac.disband_kit_q", ["name": .string(disbanding?.name ?? "")]),
                isPresented: Binding(get: { disbanding != nil },
                                     set: { if !$0 { disbanding = nil } }),
                titleVisibility: .visible
            ) {
                Button(shop.words.callIt("mac.disband_kit"), role: .destructive) {
                    guard let kit = disbanding else { return }
                    Task {
                        if shop.kitFilter == kit.id { shop.kitFilter = nil }
                        await shop.disbandKit(kit.id)
                    }
                }
            } message: {
                Text(shop.words.callIt("mac.disband_kit_hint"))
            }
        }
    }
}

private struct KitChip: View {
    let shop: Shop
    let kit: KhaytEngine.PrintKit
    let narrowed: Bool

    var body: some View {
        let r = kit.rollup
        HStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension")
                .foregroundStyle(narrowed ? AnyShapeStyle(Khayt.cyan) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(kit.name).font(.callout.weight(.medium)).lineLimit(1)
                    if kit.orphaned {
                        Text(shop.words.callIt("mac.kit_orphaned"))
                            .font(.caption2)
                            .foregroundStyle(Khayt.attention)
                            .help(shop.words.callIt("mac.kit_orphaned_help"))
                    }
                }
                HStack(spacing: 6) {
                    Text(shop.words.counting(r.jobs, "mac.jobs_word"))
                        .foregroundStyle(.secondary)
                    // THE COUNT BEHIND THE TOTAL. Only when it is not all of
                    // them — "4 of 4 measured" on every chip is noise, and
                    // noise is what teaches a shop to stop reading the line
                    // that matters.
                    if r.measuredTime < r.jobs {
                        Text(shop.words.callIt("mac.kit_measured",
                                               ["n": .number(Double(r.measuredTime)),
                                                "total": .number(Double(r.jobs))]))
                            .foregroundStyle(Khayt.attention)
                    }
                    Text(Money.quantity(r.actualHours) + " " + shop.words.callIt("common.hours"))
                    Text(Money.grams(r.actualGrams) + " g")
                    if r.mixedCurrency {
                        Text(shop.words.callIt("mac.kit_mixed_currency"))
                            .foregroundStyle(Khayt.attention)
                    } else if let cost = r.cost, cost > 0 {
                        Text(Money.text(cost, r.currency ?? shop.currency))
                    }
                    if let off = kit.accuracy?.time {
                        Text("\(off > 0 ? "+" : "")\(Money.quantity(off))% \(shop.words.callIt("mac.kit_vs_estimate"))")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
                .monospacedDigit()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(narrowed ? AnyShapeStyle(Khayt.cyan.opacity(0.14)) : AnyShapeStyle(.background))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(narrowed ? Khayt.cyan.opacity(0.55) : Color.secondary.opacity(0.22))
        )
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .help(kit.complete
              ? shop.words.callIt("mac.kit_all_measured")
              : shop.words.callIt("mac.kit_measured",
                                  ["n": .number(Double(kit.rollup.measuredTime)),
                                   "total": .number(Double(kit.rollup.jobs))]))
    }
}

// MARK: - The selected job's kit

/// Which kit this job belongs to, and what the whole object came to.
///
/// This is where a shop looking at one leg of a figure finds out what the
/// figure cost, which is the only reason kits exist.
struct KitSection: View {
    @Bindable var shop: Shop
    let job: Order
    @State private var naming = false

    var body: some View {
        let kit = shop.kit(of: job.id)
        DetailSection(shop.words.callIt("mac.kit")) {
            HStack(alignment: .firstTextBaseline) {
                Menu {
                    ForEach(shop.kits) { k in
                        Button {
                            Task { await shop.fileJobs([job.id], inKitNamed: k.name) }
                        } label: {
                            if k.id == kit?.id { Label(k.name, systemImage: "checkmark") }
                            else { Text(k.name) }
                        }
                    }
                    if !shop.kits.isEmpty { Divider() }
                    Button(shop.words.callIt("mac.new_kit")) { naming = true }
                    if kit != nil {
                        Button(shop.words.callIt("mac.remove_from_kit")) {
                            Task { await shop.unfileJobs([job.id]) }
                        }
                    }
                } label: {
                    Label(kit?.name ?? shop.words.callIt("mac.no_kit"),
                          systemImage: "puzzlepiece.extension")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!shop.canWrite)
            }
            if let kit {
                let r = kit.rollup
                // The count is on the label, not hidden in a tooltip: a total
                // that omits an unmeasured job is the failure this whole
                // module is built to avoid.
                DetailLine(shop.words.counting(r.jobs, "mac.jobs_word"),
                           r.measuredTime == r.jobs
                           ? shop.words.callIt("mac.kit_all_measured")
                           : shop.words.callIt("mac.kit_measured",
                                               ["n": .number(Double(r.measuredTime)),
                                                "total": .number(Double(r.jobs))]),
                           warn: r.measuredTime < r.jobs)
                DetailLine(shop.words.callIt("common.hours"), Money.quantity(r.actualHours) + " " + shop.words.callIt("common.hours"))
                DetailLine(shop.words.callIt("mac.filament"), Money.grams(r.actualGrams) + " g")
                if r.mixedCurrency {
                    DetailLine(shop.words.callIt("mac.cost"),
                               shop.words.callIt("mac.kit_mixed_currency"), warn: true)
                } else if let cost = r.cost {
                    DetailLine(shop.words.callIt("mac.cost"),
                               Money.text(cost, r.currency ?? shop.currency))
                }
                if let off = kit.accuracy?.time {
                    DetailLine(shop.words.callIt("mac.kit_vs_estimate"),
                               "\(off > 0 ? "+" : "")\(Money.quantity(off))%",
                               warn: abs(off) >= 25)
                }
                if kit.orphaned {
                    Text(shop.words.callIt("mac.kit_orphaned_help"))
                        .font(.caption)
                        .foregroundStyle(Khayt.attention)
                }
            }
        }
        .sheet(isPresented: $naming) {
            NameAKit(shop: shop, jobs: [job.id], suggestion: job.project)
        }
    }
}

// MARK: - Naming one

/// Naming a new kit, and the near-miss question.
///
/// A name one edit from a kit that already exists is far more often a slip than
/// a second kit, and the cost of being wrong is asymmetric: a wrongly-merged
/// job is one click to pull back out, while a silently split rollup looks
/// correct and is never noticed. So it is ASKED — never assumed, because "Leg
/// L" and "Leg R" are one edit apart and genuinely different.
struct NameAKit: View {
    let shop: Shop
    let jobs: [Order.ID]
    let suggestion: String

    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @State private var near: [KhaytEngine.NearKitName] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(shop.words.callIt("mac.kit_name_title"))
                    .font(.headline)
                Text(shop.words.callIt("mac.kit_name_hint"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField(shop.words.callIt("mac.kit_name_field"), text: $typed)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { Task { await ask() } }
            if let first = near.first {
                // The near-miss, asked rather than decided.
                VStack(alignment: .leading, spacing: 8) {
                    Text(shop.words.callIt("mac.kit_near_q", ["name": .string(first.name)]))
                        .font(.callout.weight(.medium))
                    Text(shop.words.callIt("mac.kit_near_hint", ["typed": .string(clean)]))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(shop.words.callIt("mac.kit_use_existing",
                                                 ["name": .string(first.name)])) {
                            file(as: first.name)
                        }
                        .keyboardShortcut(.defaultAction)
                        Button(shop.words.callIt("mac.kit_make_new", ["typed": .string(clean)])) {
                            file(as: clean)
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
            }
            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if near.isEmpty {
                    Button(shop.words.callIt("mac.file_it")) { Task { await ask() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(clean.isEmpty)
                }
            }
        }
        .padding(18)
        .frame(width: 360)
        .onAppear { typed = suggestion; focused = true }
    }

    private var clean: String { typed.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Look for a near miss first. An exact match needs no question at all —
    /// `resolveKitName` treats it as that kit, which is the whole point.
    private func ask() async {
        guard !clean.isEmpty else { return }
        let hits = await shop.nearKits(clean)
        if hits.isEmpty { file(as: clean) } else { near = hits }
    }

    private func file(as name: String) {
        dismiss()
        Task { await shop.fileJobs(jobs, inKitNamed: name) }
    }
}

/// Renaming one — which also ADOPTS an orphan.
///
/// A kit whose definition was deleted still groups its jobs, and until this
/// existed there was no way back: the jobs were stuck in something unnameable.
struct RenameKit: View {
    let shop: Shop
    let kit: KhaytEngine.PrintKit

    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(shop.words.callIt("mac.rename_kit")).font(.headline)
            TextField(shop.words.callIt("mac.kit_name_field"), text: $typed)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(save)
            if kit.orphaned {
                Text(shop.words.callIt("mac.kit_orphaned_help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("common.save"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 330)
        .onAppear { typed = kit.name; focused = true }
    }

    private func save() {
        let clean = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        dismiss()
        Task { await shop.renameKit(kit.id, to: clean) }
    }
}
