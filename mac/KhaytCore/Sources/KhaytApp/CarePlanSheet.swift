import SwiftUI
import AppKit
import KhaytCore

/// "Apply care plan…" — a maker's maintenance schedule for this machine's
/// brand and model, from the shared catalogue (`lib/care-plans.js`).
///
/// Shows what the plan would add and which tasks the machine already has
/// before anything is written. An existing task keeps its own interval unless
/// the shop ticks the box that says otherwise; nothing is marked done.
struct CarePlanSheet: View {
    let shop: Shop
    let machine: Machine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var plans: [KhaytEngine.CarePlan] = []
    @State private var brand = ""
    @State private var planId = ""
    @State private var comparison: KhaytEngine.CarePlanComparison?
    @State private var usePlanIntervals = false
    @State private var started = false

    static let width: CGFloat = 460

    private var brands: [String] {
        var out: [String] = []
        for p in plans where !out.contains(p.brand) { out.append(p.brand) }
        return out
    }

    private var chosen: KhaytEngine.CarePlan? { plans.first { $0.id == planId } }

    var body: some View {
        let words = shop.words
        SheetFrame(width: Self.width) {
            Text(words.callIt("mac.cp_title")).font(.headline)
            Text(machine.name).font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text(words.callIt("mac.cp_brand")).foregroundStyle(.secondary)
                    Picker("", selection: $brand) {
                        ForEach(brands, id: \.self) { Text(verbatim: $0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                GridRow {
                    Text(words.callIt("mac.cp_model")).foregroundStyle(.secondary)
                    Picker("", selection: $planId) {
                        ForEach(plans.filter { $0.brand == brand }) { Text(verbatim: $0.model).tag($0.id) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            if let plan = chosen {
                source(plan)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(plan.tasks) { task in
                        line(task, have: comparison.map { c in
                            c.same.contains { $0.task.id == task.id } || c.differ.contains { $0.task.id == task.id }
                        } ?? false)
                    }
                }
                .card(padding: 10)
                if let comparison, !comparison.differ.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(words.callIt("mac.cp_differ_title")).font(.callout)
                        ForEach(comparison.differ, id: \.recordId) { m in
                            Text(verbatim: "\u{2022} " + shop.careTaskName(m.task.id) + ": "
                                 + every(m.hadHours ?? 0, m.hadDays ?? 0) + " \u{2192} "
                                 + every(m.task.intervalHours, m.task.intervalDays))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle(words.callIt("mac.cp_use_plan"), isOn: $usePlanIntervals)
                        Text(words.callIt("mac.cp_differ_keep"))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } footer: {
            HStack {
                if let comparison, comparison.add.isEmpty,
                   comparison.differ.isEmpty || !usePlanIntervals {
                    Text(words.callIt("mac.cp_nothing")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(words.callIt("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(words.callIt("mac.cp_apply_btn")) {
                    let id = planId
                    let confirm = usePlanIntervals ? (comparison?.differ.map(\.recordId) ?? []) : []
                    dismiss()
                    Task { await shop.applyCarePlan(id, to: machine, confirm: confirm) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen == nil || !shop.canMoveJobs)
            }
        }
        .task {
            guard !started, let engine = shop.engine else { return }
            started = true
            plans = (try? await engine.carePlans()) ?? []
            let kind = shop.kind(of: machine)?.kind
            let guess = try? await engine.matchCarePlan(vendor: machine.vendor,
                                                        model: machine.printerModelName,
                                                        name: machine.name)
            let first = plans.first { $0.id == guess }
                ?? plans.first { kind == nil || $0.kind == kind } ?? plans.first
            brand = first?.brand ?? ""
            planId = first?.id ?? ""
        }
        .onChange(of: brand) { _, next in
            if chosen?.brand != next { planId = plans.first { $0.brand == next }?.id ?? "" }
        }
        .task(id: planId) {
            comparison = nil
            guard !planId.isEmpty, let engine = shop.engine else { return }
            comparison = try? await engine.compareCarePlan(
                tasks: shop.maintTaskRows, machineId: machine.id, planId: planId,
                names: shop.careTaskNames(plans))
        }
    }

    @ViewBuilder private func source(_ plan: KhaytEngine.CarePlan) -> some View {
        if plan.source == "starter" {
            Text(shop.words.callIt("mac.cp_source_starter"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let url = URL(string: plan.source) {
            HStack(spacing: 6) {
                Text(shop.words.callIt("mac.cp_source")).font(.caption).foregroundStyle(.secondary)
                Button(shop.words.callIt("mac.cp_open_source")) { openURL(url) }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }

    private func line(_ task: KhaytEngine.CarePlan.Task, have: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(shop.careTaskName(task.id)).font(.callout)
                if !task.parts.isEmpty {
                    Text(shop.words.callIt("mac.cp_parts_used", ["parts": .string(
                        task.parts.map { shop.carePartName($0.id) }.joined(separator: ", "))]))
                        .font(.caption2).foregroundStyle(Khayt.faint)
                }
                if task.source == "starter" {
                    Text(shop.words.callIt("mac.cp_task_starter"))
                        .font(.caption2).foregroundStyle(Khayt.faint)
                }
            }
            Spacer(minLength: 6)
            Text(verbatim: every(task.intervalHours, task.intervalDays))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            if have {
                Image(systemName: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel(shop.words.callIt("mac.cp_have"))
                    .help(shop.words.callIt("mac.cp_have"))
            }
        }
    }

    private func every(_ hours: Double, _ days: Double) -> String {
        var parts: [String] = []
        if hours > 0 { parts.append(Upkeep.amount(hours, shop, "common.hours_short")) }
        if days > 0 { parts.append(Upkeep.amount(days, shop, "common.days")) }
        return parts.isEmpty ? "\u{2014}" : parts.joined(separator: " \u{00B7} ")
    }
}

/// The button on the machine card's schedule.
struct ApplyCarePlan: View {
    let shop: Shop
    let machine: Machine
    @State private var open = false

    var body: some View {
        Button(shop.words.callIt("mac.cp_apply")) { open = true }
            .buttonStyle(.borderless).font(.caption)
            .disabled(!shop.canMoveJobs)
            .shopSheet(isPresented: $open) { CarePlanSheet(shop: shop, machine: machine) }
    }
}

/// Parts to buy for the maintenance coming up, earliest order-by first. Copies
/// and prints like the Inventory shopping list; orders nothing.
struct PartsBuyListSheet: View {
    @Bindable var shop: Shop
    let request: PartsBuyListRequest
    @State private var copied = false

    var body: some View {
        let words = shop.words
        SheetFrame(width: 520) {
            Text(words.callIt("mac.pb_title")).font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(request.rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: shop.carePartName(row.partId) + " "
                                 + PartsBuyListText.quantity(row.qty))
                            Text(verbatim: row.machineName + " \u{00B7} " + PartsBuyListText.task(row, shop: shop))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(verbatim: PartsBuyListText.orderBy(row, words))
                                .font(.callout.weight(row.late ? .semibold : .regular))
                                .foregroundStyle(row.late ? AnyShapeStyle(Khayt.attention) : AnyShapeStyle(.primary))
                            Text(verbatim: PartsBuyListText.due(row, words))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .card(padding: 10)
            Text(words.callIt("mac.pb_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } footer: {
            HStack {
                Button(words.callIt(copied ? "mac.copied" : "mac.pb_copy")) {
                    shop.copyPartsList(request)
                    copied = true
                }
                Button(words.callIt("common.print")) {
                    let html = PartsBuyListText.html(request, shop: shop)
                    shop.pendingPartsList = nil
                    shop.pendingPrintedPage = PrintedPageRequest(title: request.title, html: html)
                }
                Spacer()
                Button(words.callIt("common.close")) { shop.pendingPartsList = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}
