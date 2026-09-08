import SwiftUI
import KhaytCore

/// Where the waiting work should go — proposed, not done.
///
/// ── WHY A PANEL AND NOT A BUTTON THAT JUST DOES IT ────────────────────────
///
/// `lib/scheduling.js` is assistive by design and says so at the top of the
/// file: it computes a proposal and writes nothing, because the operator stays
/// in control. A shop that walks in to find its queue rearranged overnight has
/// been given a worse tool than one that walks in to find a suggestion.
///
/// So this shows every proposed move with the reason the module gave for it,
/// and the work it could not place with the reason for that — which is often
/// the more useful half. "No compatible printer" against a resin job is the
/// screen telling a shop what its fleet cannot do.
///
/// Nothing here is written by this app in Swift. The printer, the queue
/// position and the wording of every reason come from the same module the
/// Electron kanban has used since 3.0.
struct ScheduleSheet: View {
    @Bindable var shop: Shop

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 560, height: 460)
        .background(Khayt.ground)
        .task { if shop.schedulePlan == nil && shop.scheduleProblem == nil {
            await shop.proposeSchedule()
        } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(shop.words.callIt("sched.suggest_title"))
                .font(.headline)
            Text(shop.words.counting(shop.schedulableRows.count, "mac.jobs_word")
                 + " · " + shop.words.counting(shop.machines.count, "mac.machines_count"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metric.pane)
    }

    @ViewBuilder private var content: some View {
        if let problem = shop.scheduleProblem {
            // A refusal keeps the system's warning glyph rather than a drawing:
            // this is the app saying it cannot do the thing.
            ContentUnavailableView(problem, systemImage: "exclamationmark.triangle")
                .frame(maxHeight: .infinity)
        } else if let plan = shop.schedulePlan {
            ScrollView {
                VStack(alignment: .leading, spacing: Metric.gap) {
                    if plan.assignments.isEmpty {
                        Text(shop.words.callIt("sched.none"))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 24)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(plan.assignments.enumerated()), id: \.offset) { _, a in
                                row(a)
                                if a.orderId != plan.assignments.last?.orderId { Divider() }
                            }
                        }
                        .card(padding: 0)
                    }

                    if !plan.unassignable.isEmpty {
                        DetailSection(shop.words.callIt("sched.unassignable")) {
                            VStack(spacing: 0) {
                                ForEach(Array(plan.unassignable.enumerated()), id: \.offset) { _, u in
                                    refused(u)
                                    if u.orderId != plan.unassignable.last?.orderId { Divider() }
                                }
                            }
                            .card(rail: Khayt.attention, padding: 0)
                        }
                    }
                }
                .padding(Metric.pane)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ a: KhaytEngine.SchedulePlan.Assignment) -> some View {
        let said = shop.scheduleRow(a)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(said.job).fontWeight(.medium).lineLimit(1)
                if !said.why.isEmpty {
                    Text(said.why).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            // How long until it would come off, which is the figure a shop
            // actually schedules around.
            Text(finish(a.projectedFinishMins))
                .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
            Image(systemName: "arrow.forward").font(.caption2).foregroundStyle(.tertiary)
            Text(said.machine).fontWeight(.semibold).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func refused(_ u: KhaytEngine.SchedulePlan.Unplaceable) -> some View {
        HStack(spacing: 10) {
            Text(shop.orders.first { $0.id == u.orderId }?.project ?? u.orderId)
                .fontWeight(.medium).lineLimit(1)
            Spacer(minLength: 8)
            Text(u.reason ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    /// How long until it comes off, in hours.
    ///
    /// NOT "3 h 06 m". Those two letters are English, and this panel is read in
    /// Arabic on the same Mac — which is what the guard on spelled-out units
    /// caught. The catalogue has a word for hours and none for minutes, so this
    /// says hours to one decimal, the same way the shop's own job line does.
    private func finish(_ mins: Double) -> String {
        return String(format: "%.1f ", mins / 60) + shop.words.callIt("common.hours")
    }

    private var footer: some View {
        HStack {
            if let applied = shop.scheduleApplied {
                Text(shop.words.callIt("sched.applied") + " · \(applied)")
                    .font(.caption).foregroundStyle(Khayt.done)
            }
            Spacer()
            Button(shop.words.callIt("common.cancel")) { shop.schedulingWork = false }
                .keyboardShortcut(.cancelAction)
            Button(shop.words.callIt("sched.apply")) {
                Task { await shop.applySchedule(); shop.schedulingWork = false }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!(shop.schedulePlan.map { !$0.assignments.isEmpty } ?? false)
                      || !shop.canMoveJobs)
        }
        .padding(Metric.pane)
    }
}
