import SwiftUI
import KhaytCore

/// One of the shop's staff: `store.operators[]`.
///
/// `{ id: 'OP-…', name, role, roleKey, hourlyRate, active, pinHash? }`, written
/// by both apps. Read from the raw row and edited in place (`Shop.writeOperator`)
/// so what this app does not show — the other app's `pinHash`, `rev` — is never
/// rebuilt away. `pinHash` is deliberately not even read here.
struct ShopOperator: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// The job title the shop typed — "Senior technician". Display only.
    let role: String
    /// The access level the other app's operator lock reads: one of `roles`.
    /// Nil on a record written before levels existed.
    let roleKey: String?
    let hourlyRate: Double
    /// Absent means active, as the other app reads it.
    let active: Bool

    /// `lib/rbac.js` ROLES, most privileged first. `OperatorsTests` holds the
    /// two lists together.
    static let roles = ["owner", "manager", "operator", "viewer"]

    /// What the editor writes.
    struct Fields: Equatable, Sendable {
        var name: String
        var role: String
        var roleKey: String
        var hourlyRate: Double
        var active: Bool
    }

    init?(row: JSONValue) {
        guard case .object(let r) = row, case .string(let id)? = r["id"], !id.isEmpty else { return nil }
        func text(_ v: JSONValue?) -> String { if case .string(let s)? = v { return s }; return "" }
        self.id = id
        self.name = text(r["name"])
        self.role = text(r["role"])
        if case .string(let key)? = r["roleKey"], Self.roles.contains(key) { roleKey = key } else { roleKey = nil }
        switch r["hourlyRate"] {
        case .number(let n)? where n.isFinite: hourlyRate = max(0, n)
        case .string(let s)?: hourlyRate = Double(s).flatMap { $0.isFinite ? max(0, $0) : nil } ?? 0
        default: hourlyRate = 0
        }
        if case .bool(false)? = r["active"] { active = false } else { active = true }
    }

    /// The level the other app shows for a record with none: `roleFromLegacy`
    /// with the lock off, which reads the typed title.
    var shownRoleKey: String {
        if let roleKey { return roleKey }
        let s = role.trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty || s.contains("admin") { return "owner" }
        if s.contains("manager") { return "manager" }
        if s.contains("view") || s.contains("read") { return "viewer" }
        return "operator"
    }

    var fields: Fields {
        Fields(name: name, role: role, roleKey: shownRoleKey, hourlyRate: hourlyRate, active: active)
    }
}

/// Hours an operator logged against a job: `store.timeEntries[]`.
struct TimeEntry: Identifiable, Hashable, Sendable {
    let id: String
    let orderId: String
    let operatorId: String
    /// The name when the time was logged — kept for somebody since removed.
    let operatorName: String
    let hours: Double
    /// `hours × rate`, frozen when it was logged.
    let cost: Double
    let date: String
    let notes: String
    let createdAt: String

    init?(row: JSONValue) {
        guard case .object(let r) = row, case .string(let id)? = r["id"], !id.isEmpty else { return nil }
        func text(_ v: JSONValue?) -> String { if case .string(let s)? = v { return s }; return "" }
        func number(_ v: JSONValue?) -> Double {
            switch v {
            case .number(let n)? where n.isFinite: return n
            case .string(let s)?: return Double(s).flatMap { $0.isFinite ? $0 : nil } ?? 0
            default: return 0
            }
        }
        self.id = id
        orderId = text(r["orderId"])
        operatorId = text(r["operatorId"])
        operatorName = text(r["operatorName"])
        hours = number(r["hours"])
        let rate = number(r["hourlyRate"])
        cost = r["cost"] == nil || r["cost"] == .null ? hours * rate : number(r["cost"])
        date = text(r["date"])
        notes = text(r["notes"])
        createdAt = text(r["createdAt"])
    }
}

/// A line of parts — a typed job title, an access level, a rate — that reads
/// in the shop's direction whatever script each part is in.
///
/// A title typed in English led the line, so in Arabic the whole line took
/// its direction from it and came out back to front. Each part is isolated and
/// the line anchored with a mark in the shop's own direction.
@MainActor enum StaffLine {
    static func join(_ parts: [String], language: String) -> String {
        let parts = parts.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "" }
        let anchor = Direction.rtlLanguages.contains(language) ? "\u{200F}" : "\u{200E}"
        return anchor + parts.map(Figure.isolated).joined(separator: " · ")
    }
}

/// What the staff cards are recomputed on: the people, the hours, who each
/// job is on, and how much book there is.
struct StaffKey: Equatable {
    let operators: [JSONValue]
    let entries: [JSONValue]
    let assigned: [String]
    let books: Int
}

// MARK: - Settings → Operations

/// The shop's staff, listed on the Operations pane.
///
/// Its own Section and NOT part of the pane's draft, for the reason
/// `LocationsSection` gives: an operator is a record, written when saved.
/// The operator LOCK (a PIN to switch between people, and what each level may
/// open) is the other app's and is not here — this edits who the staff are,
/// not who may do what.
struct OperatorsSection: View {
    @Bindable var shop: Shop
    @State private var editing: EditingOperator?
    @State private var deleting: ShopOperator?

    /// The sheet's subject — an existing operator, or a new one.
    struct EditingOperator: Identifiable {
        let id: String
        let original: ShopOperator?
    }

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 8) {
            Text(words.callIt("op.title")).font(.headline)
            Text(words.callIt("mac.operators_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if shop.operators.isEmpty {
                Text(words.callIt("mac.no_operators"))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(shop.operators) { op in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(op.name)
                                if !op.active {
                                    Text(words.callIt("op.inactive"))
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            let detail = StaffLine.join(
                                [op.role,
                                 words.callIt("role." + op.shownRoleKey),
                                 op.hourlyRate > 0
                                    ? Money.text(op.hourlyRate, shop.currency) + " / " + words.callIt("unit.h")
                                    : ""],
                                language: words.language)
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        Spacer()
                        Button(words.callIt("common.edit")) {
                            editing = EditingOperator(id: op.id, original: op)
                        }
                        .disabled(!shop.canWrite)
                        Button(words.callIt("common.delete"), role: .destructive) { deleting = op }
                            .disabled(!shop.canWrite)
                    }
                    Divider()
                }
            }

            // An icon, not the catalogue's "+ " prefix: a literal plus is a
            // character, and in Arabic it sat on the far side of the words.
            Button {
                editing = EditingOperator(id: "new", original: nil)
            } label: {
                Label(words.callIt("mac.operator_add"), systemImage: "plus")
            }
            .disabled(!shop.canWrite)
            .help(shop.canWrite ? words.callIt("mac.operators_hint") : words.callIt("mac.move_sample"))
        }
        .sheet(item: $editing) { subject in
            OperatorEditor(shop: shop, original: subject.original)
        }
        .confirmationDialog(
            deleteQuestion,
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { op in
            Button(keepsWork(op) ? words.callIt("op.deactivate") : words.callIt("common.delete"),
                   role: .destructive) {
                Task { await shop.deleteOperator(op.id) }
            }
            Button(words.callIt("common.cancel"), role: .cancel) {}
        } message: { _ in
            Text(words.callIt("mac.operator_delete_hint"))
        }
    }

    /// Whether the rule will keep this person (inactive) rather than remove
    /// them — said BEFORE, so the button says what it does.
    private func keepsWork(_ op: ShopOperator) -> Bool {
        shop.orders.contains { $0.operatorId == op.id }
            || shop.timeEntryRows.contains { Shop.plainString(Shop.asObject($0)?["operatorId"]) == op.id }
    }

    private var deleteQuestion: String {
        guard let op = deleting else { return "" }
        let words = shop.words
        guard keepsWork(op) else {
            return words.callIt("mac.operator_delete_confirm", ["name": .string(op.name)])
        }
        let jobs = shop.orders.filter { $0.operatorId == op.id }.count
        let entries = shop.timeEntryRows.filter {
            Shop.plainString(Shop.asObject($0)?["operatorId"]) == op.id
        }.count
        return words.callIt("op.deactivate_confirm",
                            ["name": .string(op.name), "jobs": .number(Double(jobs)),
                             "entries": .number(Double(entries))])
    }
}

/// Name, job title, access level, rate, active. Five fields: it fits any
/// screen without scrolling.
struct OperatorEditor: View {
    let shop: Shop
    let original: ShopOperator?
    @Environment(\.dismiss) private var dismiss
    @State private var fields = ShopOperator.Fields(name: "", role: "", roleKey: "operator",
                                                    hourlyRate: 0, active: true)

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 14) {
            Text(words.callIt(original == nil ? "mac.operator_new" : "mac.operator_edit"))
                .font(.headline)
            Form {
                TextField(words.callIt("op.name"), text: $fields.name)
                TextField(words.callIt("op.role"), text: $fields.role)
                Picker(words.callIt("op.access_level"), selection: $fields.roleKey) {
                    ForEach(ShopOperator.roles, id: \.self) { key in
                        Text(words.callIt("role." + key)).tag(key)
                    }
                }
                // Said, because nothing on this Mac changes with it: the level
                // is what the other app's operator lock lets a person do.
                .help(words.callIt("mac.operator_access_hint"))
                Text(words.callIt("mac.operator_access_hint"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField(words.callIt("op.hourly_rate") + " (" + shop.currency + ")",
                          value: $fields.hourlyRate, format: .number)
                    .help(words.callIt("mac.operator_rate_hint"))
                Toggle(words.callIt("mac.operator_active"), isOn: $fields.active)
            }
            .formStyle(.grouped)
            if let problem = shop.moveProblem {
                Text(problem).font(.callout).foregroundStyle(Khayt.late)
            }
            HStack {
                Spacer()
                Button(words.callIt("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(words.callIt("common.save")) {
                    Task {
                        await shop.saveOperator(id: original?.id, fields, opened: original?.fields)
                        if shop.moveProblem == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(fields.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            if let original { fields = original.fields }
            shop.moveProblem = nil
        }
    }
}

// MARK: - On a job

/// Who did this job, and the hours logged on it.
///
/// Drawn for a shop with staff, or for a job that names somebody or carries
/// time — never an empty picker on every job of a one-person shop.
struct JobStaffSection: View {
    let shop: Shop
    let job: Order
    @State private var logging = false
    @State private var deletingEntry: TimeEntry?

    static func shows(_ shop: Shop, _ job: Order) -> Bool {
        !shop.operators.isEmpty || job.operatorId != nil || !shop.timeEntries(for: job.id).isEmpty
    }

    var body: some View {
        let words = shop.words
        let entries = shop.timeEntries(for: job.id)
        DetailSection(words.callIt("time.operator")) {
            Picker(words.callIt("op.assigned"), selection: Binding(
                get: { job.operatorId ?? "" },
                set: { picked in
                    Task { await shop.setJobOperator(job.id, picked.isEmpty ? nil : picked) }
                })
            ) {
                Text(words.callIt("op.unassigned")).tag("")
                ForEach(shop.activeOperators) { op in
                    Text(op.role.isEmpty ? op.name : op.name + " · " + op.role).tag(op.id)
                }
                // The job's own operator when they are no longer offered —
                // inactive, or gone. Without it the picker would show nobody
                // and the shop would think the job had never been assigned.
                if let id = job.operatorId, !shop.activeOperators.contains(where: { $0.id == id }) {
                    Text(shop.operatorLabel(id) ?? id).tag(id)
                }
            }
            .disabled(!shop.canWrite)

            if entries.isEmpty {
                Text(words.callIt("mac.no_time_logged"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(StaffLine.join([Money.quantity(entry.hours, decimals: 1) + " "
                                                 + words.callIt("unit.h"), name(entry)],
                                                language: words.language))
                                .font(.callout)
                            let day = Order.day(entry.date)
                                .map { words.say($0, .dateTime.day().month(.abbreviated).year()) } ?? entry.date
                            Text(StaffLine.join([day, entry.notes], language: words.language))
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Text(Money.text(entry.cost, shop.currency))
                            .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        if shop.canWrite {
                            Button {
                                deletingEntry = entry
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help(words.callIt("common.delete"))
                        }
                    }
                }
                let hours = entries.reduce(0) { $0 + $1.hours }
                let cost = entries.reduce(0) { $0 + $1.cost }
                Text(words.callIt("time.total_hours") + ": " + Money.quantity(hours, decimals: 1) + " "
                     + words.callIt("unit.h") + " · " + Money.text(cost, shop.currency))
                    .font(.caption.weight(.semibold))
            }
            if shop.canWrite, !shop.activeOperators.isEmpty {
                Button(words.callIt("mac.log_time")) { logging = true }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
        .sheet(isPresented: $logging) {
            LogTimeSheet(shop: shop, job: job)
        }
        // Asked first, like every removal: an entry is labour cost on the
        // book, and a trash button beside it is one stray click away.
        .askFirst($deletingEntry,
                  title: { shop.words.callIt("mac.delete_product_q",
                                             ["name": .string(Money.quantity($0.hours, decimals: 1) + " "
                                                              + shop.words.callIt("unit.h") + " · " + name($0))]) },
                  message: { _ in shop.words.callIt("mac.operator_delete_hint") },
                  confirm: shop.words.callIt("common.delete"),
                  cancel: shop.words.callIt("common.cancel")) { entry in
            Task { await shop.deleteTimeEntry(entry.id) }
        }
    }

    private func name(_ entry: TimeEntry) -> String {
        if let op = shop.shopOperator(entry.operatorId) { return op.name }
        return entry.operatorName.isEmpty ? shop.words.callIt("an.op_removed") : entry.operatorName
    }
}

/// Operator, hours, day, notes — the other app's "Log Work Time".
struct LogTimeSheet: View {
    let shop: Shop
    let job: Order
    @Environment(\.dismiss) private var dismiss
    @State private var operatorId = ""
    @State private var hours: Double = 1
    @State private var day = Date()
    @State private var notes = ""

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 14) {
            Text(words.callIt("time.log_title")).font(.headline)
            Text(shop.shownTitle(of: job)).font(.callout).foregroundStyle(.secondary)
                .lineLimit(1)
            Form {
                Picker(words.callIt("time.operator"), selection: $operatorId) {
                    ForEach(shop.activeOperators) { op in
                        Text(op.role.isEmpty ? op.name : op.name + " · " + op.role).tag(op.id)
                    }
                }
                TextField(words.callIt("time.hours"), value: $hours, format: .number)
                DatePicker(words.callIt("time.date"), selection: $day, displayedComponents: .date)
                TextField(words.callIt("time.notes"), text: $notes, axis: .vertical)
                    .lineLimit(1...3)
            }
            .formStyle(.grouped)
            if let problem = shop.moveProblem {
                Text(problem).font(.callout).foregroundStyle(Khayt.late)
            }
            HStack {
                Spacer()
                Button(words.callIt("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(words.callIt("common.save")) {
                    Task {
                        await shop.logTime(jobId: job.id, operatorId: operatorId, hours: hours,
                                           day: Calendar.book.dayString(day), notes: notes)
                        if shop.moveProblem == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(operatorId.isEmpty || !(hours > 0))
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            // The job's own operator when they are active, else the first.
            let active = shop.activeOperators
            operatorId = active.first { $0.id == job.operatorId }?.id ?? active.first?.id ?? ""
            shop.moveProblem = nil
        }
    }
}

// MARK: - Reports

/// Per person: the jobs they finished, the waste on their jobs, and how close
/// their printer-measured prints came to the estimate. `lib/operators.js`.
struct OperatorPerformanceCard: View {
    let shop: Shop
    let report: KhaytEngine.OperatorPerformance

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 10) {
            Text(words.callIt("an.operator_title"))
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase).tracking(0.6)
                .foregroundStyle(Khayt.brand)
            Text(words.callIt("mac.staff_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text(words.callIt("op.name"))
                    Text(words.callIt("an.op_jobs")).gridColumnAlignment(.trailing)
                    Text(words.callIt("an.op_waste_amount")).gridColumnAlignment(.trailing)
                    Text(words.callIt("an.op_accuracy")).gridColumnAlignment(.trailing)
                }
                .font(.caption).foregroundStyle(.secondary)
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(report.rows) { row in
                    GridRow {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.known ? row.name : words.callIt("an.op_removed"))
                                .foregroundStyle(row.known ? .primary : .secondary)
                                .lineLimit(1)
                            let sub = StaffLine.join(
                                [row.role, row.known && !row.active ? words.callIt("op.inactive") : ""],
                                language: words.language)
                            if !sub.isEmpty {
                                Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Text("\(row.jobs)").monospacedDigit()
                        Group {
                            if row.wasteEntries > 0 {
                                Text(Money.quantity(row.wasteGrams, decimals: 0) + " " + words.callIt("unit.g")
                                     + " · " + Money.text(row.wasteCost, shop.currency))
                                    .foregroundStyle(Khayt.late)
                            } else {
                                Text("0").foregroundStyle(.secondary)
                            }
                        }
                        .monospacedDigit()
                        Group {
                            if let pct = row.accuracyPct {
                                Text(Money.quantity(pct, decimals: 1) + "% "
                                     + words.callIt("an.op_scored", ["n": .number(Double(row.scored))]))
                            } else {
                                Text("—").foregroundStyle(.secondary)
                            }
                        }
                        .monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
    }
}

/// The hours the staff logged, what they cost, and what the work earned per
/// hour. `lib/operators.js`.
struct OperatorTimeCard: View {
    let shop: Shop
    let report: KhaytEngine.OperatorTime

    var body: some View {
        let words = shop.words
        let h = words.callIt("unit.h")
        VStack(alignment: .leading, spacing: 12) {
            Text(words.callIt("time.analytics_title"))
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase).tracking(0.6)
                .foregroundStyle(Khayt.brand)
            Text(words.callIt("mac.labour_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 28) {
                figure(Money.quantity(report.totals.hours, decimals: 1) + " " + h, words.callIt("time.total_hours"))
                figure(Money.text(report.totals.cost, shop.currency), words.callIt("time.total_cost"))
                figure(report.totals.avgHoursPerOrder.map { Money.quantity($0, decimals: 1) + " " + h } ?? "—",
                       words.callIt("time.avg_per_order"))
            }
            Text(words.callIt("time.by_operator")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text(words.callIt("time.operator"))
                    Text(words.callIt("time.hours")).gridColumnAlignment(.trailing)
                    Text(words.callIt("time.cost")).gridColumnAlignment(.trailing)
                    Text(words.callIt("time.orders")).gridColumnAlignment(.trailing)
                    Text(words.callIt("time.rev_per_hour")).gridColumnAlignment(.trailing)
                }
                .font(.caption).foregroundStyle(.secondary)
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(report.operators) { row in
                    GridRow {
                        Text(row.name.isEmpty ? words.callIt("an.op_removed") : row.name)
                            .foregroundStyle(row.known ? .primary : .secondary)
                            .lineLimit(1)
                        Text(Money.quantity(row.hours, decimals: 1) + " " + h).monospacedDigit()
                        Text(Money.text(row.cost, shop.currency)).monospacedDigit()
                        Text("\(row.orders)").monospacedDigit()
                        Text(row.revenuePerHour.map { Money.text($0, shop.currency) } ?? "—")
                            .monospacedDigit()
                            .foregroundStyle(row.revenuePerHour == nil ? .secondary : .primary)
                    }
                    .font(.callout)
                }
            }
            if !report.topOrders.isEmpty {
                Text(words.callIt("time.top_orders")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.top, 4)
                ForEach(report.topOrders) { top in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(top.project.isEmpty ? top.orderId : top.project).lineLimit(1)
                        Spacer()
                        Text(top.operators.joined(separator: words.language == "ar" ? "، " : ", "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(Money.quantity(top.hours, decimals: 1) + " " + h)
                            .monospacedDigit().fontWeight(.semibold)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
