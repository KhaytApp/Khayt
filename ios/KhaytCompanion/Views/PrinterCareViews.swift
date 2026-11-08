import SwiftUI

/// Printer care on the phone: a machine's care tasks, and the parts the shop
/// will need for them. The rules are `CareRules` (the shared JavaScript's,
/// ported and parity-tested); the writes are `BookWriter.markCareTaskDone`
/// and `deferCareTask`. Care plans are SET UP on the computer — the phone
/// shows them and ticks them off, and says so when a machine has none.

/// Words and figures every care screen shares.
enum CareWords {
    static func status(_ s: String) -> String { L10n.tr("care.status." + s) }

    static func colour(_ s: String) -> Color {
        switch s {
        case "overdue": return KhaytDesign.late
        case "due": return KhaytDesign.attention
        case "warning": return KhaytDesign.note
        default: return KhaytDesign.done
        }
    }

    static func figure(_ v: Double) -> String {
        // Isolated, so a figure inside Arabic text keeps its place.
        "\u{2068}" + abs(v).rounded().formatted(.number.locale(L10n.locale).grouping(.never)) + "\u{2069}"
    }

    /// "Every 500 h · 90 days".
    static func every(_ t: CareBook.Task) -> String? {
        var parts: [String] = []
        if let h = t.intervalHours { parts.append(L10n.format("care.hours", figure(h))) }
        if let d = t.intervalDays { parts.append(L10n.format("care.days", figure(d))) }
        return parts.isEmpty ? nil : L10n.format("care.every", parts.joined(separator: " · "))
    }

    /// "120 h left" / "8 days over" — the clock that is closest.
    static func left(_ t: CareBook.Task) -> String? {
        var lines: [(String, Double)] = []
        if let h = t.status.hoursRemaining, let i = t.intervalHours, i > 0 {
            lines.append((h >= 0 ? L10n.format("care.hours_left", figure(h)) : L10n.format("care.hours_over", figure(h)), h / i))
        }
        if let d = t.status.daysRemaining, let i = t.intervalDays, i > 0 {
            lines.append((d >= 0 ? L10n.format("care.days_left", figure(d)) : L10n.format("care.days_over", figure(d)), d / i))
        }
        return lines.min { $0.1 < $1.1 }?.0
    }

    static func part(_ id: String) -> String {
        let key = "care.part." + id
        let found = L10n.tr(key)
        return found == key ? id : found
    }

    static func quantity(_ q: Double) -> String {
        "\u{00D7}" + q.formatted(.number.locale(L10n.locale).precision(.fractionLength(0...1)))
    }

    static func day(_ iso: String) -> String {
        guard let ms = CareRules.parseISO(iso) else { return iso }
        let d = Date(timeIntervalSince1970: ms / 1000)
        return "\u{2068}" + d.formatted(.dateTime.day().month(.abbreviated).year().locale(L10n.locale)) + "\u{2069}"
    }

    static func orderBy(_ row: CareRules.BuyRow) -> String {
        row.late ? L10n.tr("care.parts.late") : L10n.format("care.parts.order_by", day(row.orderBy))
    }

    static func taskName(_ name: String) -> String { name.isEmpty ? L10n.tr("care.unnamed") : name }

    /// The list as plain text, for Share.
    static func text(_ rows: [CareRules.BuyRow], shop: String) -> String {
        var lines = [L10n.tr("care.parts.title") + (shop.isEmpty ? "" : " \u{2014} " + shop), ""]
        for r in rows {
            lines.append(part(r.partId) + " " + quantity(r.qty) + " \u{2014} " + r.machineName + ", "
                         + taskName(r.taskName) + " \u{2014} " + orderBy(r) + "; "
                         + L10n.format("care.parts.due", day(r.dueAt)))
        }
        return lines.joined(separator: "\n")
    }
}

/// The row under a machine card that opens its care page. A machine with
/// something due or overdue says so, in a small coloured line — modest on
/// purpose: it is a nudge, not an alarm.
struct MachineCareLink: View {
    let name: String
    let machineId: String
    let care: CareBook
    let reload: () async -> Void

    var body: some View {
        let tasks = care.tasks(for: machineId)
        let needing = tasks.filter(\.needsCare)
        let worst = needing.first?.status.status
        NavigationLink {
            MachineCarePage(name: name, machineId: machineId, reload: reload)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver").foregroundStyle(KhaytDesign.note)
                Text(L10n.tr("care.title")).foregroundStyle(KhaytDesign.ink)
                Spacer(minLength: 0)
                if let worst {
                    HStack(spacing: 5) {
                        Circle().fill(CareWords.colour(worst)).frame(width: 6, height: 6)
                        Text(L10n.format("care.needs", needing.count))
                            .foregroundStyle(CareWords.colour(worst))
                    }
                    .font(.khayt(12.5, .semibold, relativeTo: .caption))
                }
                Image(systemName: "chevron.forward")
                    .font(.caption).foregroundStyle(KhaytDesign.note)
            }
            .font(.khayt(14, .medium, relativeTo: .subheadline))
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
    }
}

/// A machine's page for its care: the Care card.
struct MachineCarePage: View {
    @EnvironmentObject private var api: KhaytAPIClient
    let name: String
    let machineId: String
    var reload: () async -> Void = {}

    @State private var care = CareBook()
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if loaded {
                    CareCard(machineId: machineId, care: care) { await refresh() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 18)
        }
        .scrollIndicators(.hidden)
        .refreshable { await refresh() }
        .khaytScreen(title: name)
        .task { await refresh() }
    }

    private func refresh() async {
        care = await api.printerCare() ?? CareBook()
        loaded = true
        await reload()
    }
}

/// The Care card: the machine's tasks, worst first, each with its status
/// and what is left, and Done / Not needed.
struct CareCard: View {
    @EnvironmentObject private var api: KhaytAPIClient
    let machineId: String
    let care: CareBook
    let changed: () async -> Void

    @State private var working: String?
    @State private var problem: String?

    var body: some View {
        let tasks = care.tasks(for: machineId)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.tr("care.title"))
                    .font(.khayt(17, .semibold, relativeTo: .headline))
                    .foregroundStyle(KhaytDesign.ink)
                Spacer()
            }
            .padding(.bottom, 10)
            if tasks.isEmpty {
                Text(L10n.tr("care.none"))
                    .font(.khayt(14, relativeTo: .subheadline))
                    .foregroundStyle(KhaytDesign.note)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if tasks.contains(where: \.hoursUnknown) {
                    Text(L10n.tr("care.hours_unknown"))
                        .font(.khayt(12.5, relativeTo: .caption))
                        .foregroundStyle(KhaytDesign.attention)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                }
                ForEach(Array(tasks.enumerated()), id: \.element.id) { i, task in
                    if i > 0 { Divider().overlay(KhaytDesign.hairline) }
                    row(task)
                }
            }
            if let problem {
                Text(problem)
                    .font(.khayt(12.5, relativeTo: .caption))
                    .foregroundStyle(KhaytDesign.late)
                    .padding(.top, 8)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(KhaytDesign.hairline, lineWidth: 1))
    }

    @ViewBuilder
    private func row(_ task: CareBook.Task) -> some View {
        let tone = CareWords.colour(task.status.status)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(CareWords.taskName(task.name))
                        .font(.khayt(15, .semibold, relativeTo: .body))
                        .foregroundStyle(KhaytDesign.ink)
                    if let every = CareWords.every(task) {
                        Text(every)
                            .font(.khayt(12, relativeTo: .caption))
                            .foregroundStyle(KhaytDesign.note)
                    }
                    if task.status.deferred {
                        Text(L10n.tr("care.deferred"))
                            .font(.khayt(12, relativeTo: .caption))
                            .foregroundStyle(KhaytDesign.note)
                    }
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(CareWords.status(task.status.status))
                        .font(.khayt(12, .semibold, relativeTo: .caption))
                        .foregroundStyle(task.status.status == "ok" ? KhaytDesign.ink : tone)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(tone.opacity(0.14), in: Capsule())
                    if let left = CareWords.left(task) {
                        Text(left)
                            .font(.khayt(12.5, .medium, relativeTo: .caption).monospacedDigit())
                            .foregroundStyle(KhaytDesign.note)
                    }
                }
            }
            HStack(spacing: 8) {
                action(L10n.tr("care.done"), prominent: task.needsCare, task: task) {
                    try await api.markCareTaskDone(taskId: task.id)
                }
                // As on the Mac: only once the task is asking for attention.
                if task.status.status != "ok" {
                    action(L10n.tr("care.not_needed"), prominent: false, task: task) {
                        try await api.deferCareTask(taskId: task.id)
                    }
                    .accessibilityHint(L10n.tr("care.not_needed.help"))
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 10)
    }

    private func action(_ title: String, prominent: Bool, task: CareBook.Task,
                        _ run: @escaping () async throws -> Void) -> some View {
        Button {
            working = task.id
            problem = nil
            Task {
                do { try await run() } catch { problem = error.localizedDescription }
                working = nil
                await changed()
            }
        } label: {
            Text(title)
                .font(.khayt(13.5, .semibold, relativeTo: .subheadline))
                .foregroundStyle(prominent ? KhaytDesign.onBrand : KhaytDesign.brand)
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .background(prominent ? KhaytDesign.brand : KhaytDesign.brand.opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(working != nil || task.hoursUnknown)
        .opacity(working != nil || task.hoursUnknown ? 0.5 : 1)
    }
}

/// Parts to buy: every care-plan part falling due in the next 90 days, by the
/// date to order it, with a Share of the list as text.
struct PartsToBuyPage: View {
    @EnvironmentObject private var api: KhaytAPIClient
    @EnvironmentObject private var settings: ConnectionSettings
    @State private var rows: [CareRules.BuyRow] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if loaded && rows.isEmpty {
                    Text(L10n.tr("care.parts.none"))
                        .font(.khayt(14, relativeTo: .subheadline))
                        .foregroundStyle(KhaytDesign.note)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 44)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                            if i > 0 { Divider().overlay(KhaytDesign.hairline) }
                            line(row)
                        }
                    }
                    .padding(.horizontal, 16)
                    .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(KhaytDesign.hairline, lineWidth: 1))
                    Text(L10n.tr("care.parts.hint"))
                        .font(.khayt(12, relativeTo: .caption))
                        .foregroundStyle(KhaytDesign.note)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 18)
        }
        .scrollIndicators(.hidden)
        .refreshable { await load() }
        .khaytScreen(title: L10n.tr("care.parts.title"))
        .toolbar {
            if !rows.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: CareWords.text(rows, shop: settings.shopLabel)) {
                        Label(L10n.tr("care.parts.share"), systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        rows = await api.printerCare()?.buyList ?? []
        loaded = true
    }

    private func line(_ row: CareRules.BuyRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(CareWords.part(row.partId))
                        .font(.khayt(15, .semibold, relativeTo: .body))
                        .foregroundStyle(KhaytDesign.ink)
                    Text(CareWords.quantity(row.qty))
                        .font(.khayt(13.5, .medium, relativeTo: .subheadline).monospacedDigit())
                        .foregroundStyle(KhaytDesign.note)
                }
                Text(row.machineName + " \u{00B7} " + CareWords.taskName(row.taskName))
                    .font(.khayt(12.5, relativeTo: .caption))
                    .foregroundStyle(KhaytDesign.note)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(CareWords.orderBy(row))
                    .font(.khayt(13, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(row.late ? KhaytDesign.late : KhaytDesign.ink)
                Text(L10n.format("care.parts.due", CareWords.day(row.dueAt)))
                    .font(.khayt(12, relativeTo: .caption))
                    .foregroundStyle(KhaytDesign.note)
            }
            .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}
