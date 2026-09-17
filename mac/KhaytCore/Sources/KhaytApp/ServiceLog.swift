import SwiftUI
import KhaytCore

/// One service, as the book records it.
///
/// Kept deliberately small: the log is a flat list of `{ id, machineId, date,
/// note, cost }` shared with the other app, and a model here that invented
/// fields would be a model the other app's writer knows nothing about.
struct ServiceEntry: Identifiable, Hashable, Sendable {
    let id: String
    let machineId: String
    /// `YYYY-MM-DD`. A string, not a Date — the figures bucket by the text for
    /// the reason `lib/maintenance-cost.js` gives about timezones.
    let date: String
    let note: String
    let cost: Double

    init?(raw: [String: JSONValue]) {
        guard case .string(let id)? = raw["id"] else { return nil }
        self.id = id
        if case .string(let m)? = raw["machineId"] { machineId = m } else { machineId = "" }
        if case .string(let d)? = raw["date"] { date = d } else { date = "" }
        if case .string(let n)? = raw["note"] { note = n } else { note = "" }
        if case .number(let c)? = raw["cost"] { cost = c } else { cost = 0 }
    }
}

/// Changing the service log, as a rule rather than as a closure.
///
/// Both writers — ticking a scheduled task off, and writing a service down by
/// hand — put a row into the same list, and the shape of that row is a
/// contract with the other app, which reads these records back. Pulling it out
/// of the two store closures means the shape is decided once and can be tested
/// without a book on disk to write to.
enum ServiceLogEdit {

    /// The key the log lives under. `renderer/app-state.js` chose it; this is
    /// not free to differ.
    static let collection = "hub_maint_log_v1"

    /// A service, in the shape the other app writes and reads.
    ///
    /// `cost` is separate from `note` on purpose: a figure inside a sentence
    /// is a figure nothing can total.
    static func entry(machineId: String, day: String, note: String, cost: Double,
                      id: String) -> [String: JSONValue] {
        [
            "id": .string(id),
            "machineId": .string(machineId),
            "date": .string(day),
            // Never negative. A refund on a repair is not a negative service,
            // and a negative row would subtract from what a machine has cost.
            "cost": .number(max(0, cost)),
            "note": .string(note.trimmingCharacters(in: .whitespaces)),
        ]
    }

    /// Newest first, which is the order the log is read in and the order the
    /// other app writes it in.
    static func appending(_ entry: [String: JSONValue], to log: [JSONValue]) -> [JSONValue] {
        var next = log
        next.insert(.object(entry), at: 0)
        return next
    }

    /// Without the entry named. Everything else is untouched, including rows
    /// this app cannot read — a log written by a newer Khayt is still the
    /// shop's log.
    static func removing(_ entryId: String, from log: [JSONValue]) -> [JSONValue] {
        log.filter { row in
            if case .object(let o) = row, case .string(let id)? = o["id"] { return id != entryId }
            return true
        }
    }

    /// This machine's services, newest first.
    static func entries(of machineId: String, in log: [JSONValue]) -> [ServiceEntry] {
        log.compactMap { if case .object(let o) = $0 { return ServiceEntry(raw: o) } else { return nil } }
            .filter { $0.machineId == machineId }
            .sorted { $0.date > $1.date }
    }
}

/// What has been done to this machine, and what it cost.
///
/// ── THE SCHEDULE IS NOT THE HISTORY ───────────────────────────────────────
///
/// The section above this one says what the machine is DUE for. This says what
/// was actually done to it. They are different records and only the second is
/// evidence: a shop selling a printer, arguing a warranty claim, or deciding
/// whether a machine has become expensive to keep is reading this one.
///
/// It is also where every maintenance figure in the app comes from — the
/// machine P&L subtracts these costs, and the Reports chart totals them. Until
/// this existed the Mac could tick a task off and write nothing here, so a
/// shop that did its servicing on this app had no history of it and every one
/// of those figures read zero.
struct ServiceLog: View {
    let shop: Shop
    let machine: Machine
    /// How many to show before the section becomes a list nobody reads. The
    /// rest are still in the book and still in every figure.
    private static let shown = 6

    @State private var adding = false
    @State private var confirming: ServiceEntry?

    private var entries: [ServiceEntry] {
        ServiceLogEdit.entries(of: machine.id, in: shop.maintenanceRows)
    }

    var body: some View {
        let words = shop.words
        let rows = entries
        DetailSection(words.callIt("maint.title")) {
            VStack(alignment: .leading, spacing: 7) {
                if rows.isEmpty {
                    Text(words.callIt("maint.empty"))
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(rows.prefix(Self.shown)) { entry in
                        Row(shop: shop, entry: entry) { confirming = entry }
                    }
                    if rows.count > Self.shown {
                        // Said rather than hidden: a shop that has serviced a
                        // machine thirty times should not read six and think
                        // that is all of them.
                        Text(words.callIt("mac.sl_more",
                                          ["n": .number(Double(rows.count - Self.shown))]))
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    // What this machine has cost so far, over everything in the
                    // log rather than the six drawn — the total of a visible
                    // subset is a figure that looks checkable and is not.
                    let spent = rows.reduce(0) { $0 + $1.cost }
                    if spent > 0 {
                        Divider()
                        HStack {
                            Text(words.callIt("mac.sl_total")).foregroundStyle(.secondary)
                            Spacer()
                            Text(Money.text(spent, shop.currency)).monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
                Button(words.callIt("mac.sl_add")) { adding = true }
                    .buttonStyle(.borderless).font(.caption)
                    // A sample book is not the shop's to write to.
                    .disabled(!shop.canMoveJobs)
            }
        }
        .sheet(isPresented: $adding) {
            ServiceEntrySheet(shop: shop, machine: machine)
        }
        .confirmationDialog(shop.words.callIt("common.delete") + "?",
                            isPresented: Binding(get: { confirming != nil },
                                                 set: { if !$0 { confirming = nil } }),
                            presenting: confirming) { entry in
            Button(shop.words.callIt("common.delete"), role: .destructive) {
                Task { await shop.deleteServiceEntry(entry.id) }
            }
        } message: { entry in
            Text(entry.note)
        }
    }

    private struct Row: View {
        let shop: Shop
        let entry: ServiceEntry
        let remove: () -> Void
        @State private var hovering = false

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.date)
                    .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                    .frame(width: 78, alignment: .leading)
                Text(entry.note.isEmpty ? shop.words.callIt("mac.unnamed") : entry.note)
                    .font(.callout).lineLimit(1)
                Spacer(minLength: 6)
                // A service with no price on it is not a free service — it is
                // one nobody has typed a figure for. A dash says that; a zero
                // would claim it cost nothing.
                Text(entry.cost > 0 ? Money.short(entry.cost, shop.currency) : "—")
                    .font(.callout).monospacedDigit()
                    .foregroundStyle(entry.cost > 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .opacity(hovering ? 1 : 0)
                .disabled(!shop.canMoveJobs)
                .accessibilityLabel(shop.words.callIt("common.delete"))
            }
            .contentShape(.rect)
            .onHover { hovering = $0 }
        }
    }
}

/// Writing down a service that has just been done.
struct ServiceEntrySheet: View {
    let shop: Shop
    let machine: Machine
    @Environment(\.dismiss) private var dismiss

    @State private var day = Date()
    @State private var note = ""
    @State private var cost: Double = 0
    @State private var alsoAnExpense = false

    static let width: CGFloat = 400

    private var canSave: Bool { !note.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        let words = shop.words
        SheetFrame(width: Self.width) {
            Text(words.callIt("mac.sl_add")).font(.headline)
            Text(machine.name).font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text(words.callIt("maint.date")).foregroundStyle(.secondary)
                    // Never in the future: a service is something that has been
                    // done, and a date after today is a typo every time.
                    DatePicker("", selection: $day, in: ...Date(), displayedComponents: .date)
                        .labelsHidden()
                }
                GridRow {
                    Text(words.callIt("maint.note")).foregroundStyle(.secondary)
                    TextField(words.callIt("mach.log_service"), text: $note)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text(words.callIt("maint.cost")).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        TextField("", value: $cost, format: .number.precision(.fractionLength(2)))
                            .textFieldStyle(.roundedBorder).monospacedDigit().frame(width: 110)
                        Text(Money.mark(shop.currency)).foregroundStyle(.secondary)
                    }
                }
            }
            // ── AND WHETHER IT IS ALSO AN EXPENSE ─────────────────────────
            //
            // Off by default, and asked rather than decided: this machine's
            // profit already has its servicing subtracted, so booking the
            // repair as an expense as well charges the shop twice. Which the
            // shop wants depends on how it keeps its books.
            Toggle(words.callIt("mac.sl_as_expense"), isOn: $alsoAnExpense)
                .disabled(cost <= 0)
            Text(words.callIt("mac.sl_as_expense_why"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } footer: {
            HStack {
                Spacer()
                Button(words.callIt("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(words.callIt("common.save")) {
                    let entry = (day, note, cost, alsoAnExpense)
                    dismiss()
                    Task {
                        await shop.addServiceEntry(machineId: machine.id, date: entry.0,
                                                   note: entry.1, cost: entry.2,
                                                   alsoAnExpense: entry.3)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
    }
}
