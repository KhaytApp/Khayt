import SwiftUI
import KhaytCore

/// What could run together on one plate.
///
/// ── WHY A SHOP WITH ONE PRINTER NEEDS THIS MOST ───────────────────────────
///
/// The scheduler answers "which printer takes this job", which a shop with one
/// machine already knows. This answers "what can I run in the same session" —
/// and that is where a small shop's hours actually go. Khayt has had it since
/// 3.0 as the Batch Print Planner; this app had no answer to it at all.
///
/// Nothing here is packed in Swift. `lib/plate-nesting.js` groups by material
/// first — filaments cannot be mixed on one FDM plate — then fills by print
/// time, and hands back a job too big for a plate on a plate of its own,
/// flagged rather than dropped. This screen ticks jobs, sets the two limits,
/// and draws what comes back.
///
/// It writes nothing. A plate is a way of running the work, not a field on a
/// record, and the other app does not write one either.
struct BatchSheet: View {
    @Bindable var shop: Shop

    private var candidates: [Order] { shop.batchCandidates }

    var body: some View {
        // `SheetFrame`: this lists the shop's own jobs and then a plate per
        // group, and a sheet cannot be moved off its own buttons.
        SheetFrame(width: 560) {
            VStack(alignment: .leading, spacing: 4) {
                Text(shop.words.callIt("batch.title")).font(.headline)
                Text(shop.words.counting(candidates.count, "mac.jobs_word"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            if candidates.isEmpty {
                // Not a fault: a shop with nothing waiting has nothing to plan.
                EmptyHere(title: shop.words.callIt("batch.no_orders"),
                          message: shop.words.callIt("mac.nothing_to_plan_why"),
                          mark: .board) {}
            } else {
                limits
                Divider()
                jobs
                if let problem = shop.batchProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if shop.batchIdle {
                    Text(shop.words.callIt("batch.select_hint"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let plan = shop.batchPlates { plates(plan) }
            }
        } footer: {
            HStack {
                Spacer()
                Button(shop.words.callIt("common.close")) { shop.planningBatch = false }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("batch.suggest")) {
                    Task { await shop.planBatch() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(candidates.isEmpty)
            }
        }
    }

    /// What one plate will take. Two numbers, because those are the two a
    /// plate actually runs out of: hours on the machine, and filament.
    private var limits: some View {
        HStack(spacing: 16) {
            LabelledField(label: shop.words.callIt("batch.max_hours"),
                          value: $shop.batchMaxHours)
            LabelledField(label: shop.words.callIt("batch.max_grams"),
                          value: $shop.batchMaxGrams)
            Spacer()
            if !shop.batchChosen.isEmpty {
                Text(shop.words.callIt("batch.selected",
                                       ["n": .number(Double(shop.batchChosen.count))]))
                    .font(.caption).foregroundStyle(.secondary)
                Button(shop.words.callIt("batch.clear_sel")) { shop.batchChosen = [] }
                    .font(.caption)
            }
        }
    }

    /// Every job that could go on a plate, with what it would take.
    ///
    /// Ticking none means all of them, which is the other app's reading and
    /// the more useful default: a shop that wants everything planned should
    /// not have to tick everything first.
    private var jobs: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(candidates) { job in
                let takes = Shop.plateJob(job)
                Toggle(isOn: Binding(
                    get: { shop.batchChosen.contains(job.id) },
                    set: { on in
                        if on { shop.batchChosen.insert(job.id) }
                        else { shop.batchChosen.remove(job.id) }
                    })) {
                        HStack(spacing: 8) {
                            Text(takes.project).lineLimit(1)
                            Spacer(minLength: 8)
                            if !takes.material.isEmpty {
                                Text(takes.material).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(hoursAndGrams(takes))
                                .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                        }
                    }
                    .toggleStyle(.checkbox)
                Divider()
            }
        }
    }

    /// The proposal.
    private func plates(_ plan: KhaytEngine.PlatePlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(shop.words.callIt("batch.plates_n",
                                   ["n": .number(Double(plan.totalPlates))]))
                .font(.callout).foregroundStyle(.secondary)
            ForEach(Array(plan.plates.enumerated()), id: \.offset) { index, plate in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(shop.words.callIt("batch.plate") + " \(index + 1)")
                            .fontWeight(.semibold)
                        if !plate.material.isEmpty {
                            Text("· " + plate.material).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(plateTotals(plate))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Text(plate.jobs.map(\.project).joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if plate.oversize {
                        // A job that will not fit a plate on its own. Said out
                        // loud: the rule flags it rather than dropping it, and
                        // a planner that hid it would be worse than none.
                        Label(shop.words.callIt("batch.oversize"),
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(Khayt.attention)
                    }
                }
                .card(rail: plate.oversize ? Khayt.attention : nil)
            }
        }
    }

    /// "12.5 hours · 340 g" — the shop's own words for hours and for grams.
    ///
    /// Never "12.5h · 340g": those letters are English, and this panel is read
    /// in Arabic on the same Mac.
    ///
    /// ── AND NEVER `mac.grams_left` ────────────────────────────────────────
    ///
    /// That string says "{n} g LEFT" — it is about what remains on a spool,
    /// not about what a job weighs. Borrowed here it read "23.7 hrs ·
    /// 2190.6000000000004 g left" against a job, which is a sentence about the
    /// wrong subject AND raw float noise. Found by photographing the sheet; no
    /// test can see a caption that is grammatical, translated and about
    /// something else.
    private func weight(_ grams: Double) -> String {
        // Whole grams. A plate is planned to the gram at best, and 0.1 g of
        // float residue is not a measurement.
        String(Int(grams.rounded())) + " " + shop.words.callIt("common.grams")
    }

    private func hours(_ value: Double) -> String {
        String(format: "%.1f ", value) + shop.words.callIt("common.hours")
    }

    private func hoursAndGrams(_ job: KhaytEngine.PlateJob) -> String {
        hours(job.hours) + " · " + weight(job.grams)
    }

    private func plateTotals(_ plate: KhaytEngine.PlatePlan.Plate) -> String {
        hours(plate.hours) + " · " + weight(plate.grams)
    }
}

/// A number with a caps label over it, the way the sheets that ask for two
/// figures side by side already do.
private struct LabelledField: View {
    let label: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("", value: $value, format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .frame(width: 90)
        }
    }
}
