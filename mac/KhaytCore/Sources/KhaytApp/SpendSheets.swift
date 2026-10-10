import SwiftUI
import KhaytCore

/// Recording an expense.
///
/// Five fields, because that is what Khayt's own form asks and what a shop
/// actually knows when it puts a receipt in. The record is built by
/// `lib/expense-book.js` from what is typed here, so an expense added on the
/// Mac is the same record Khayt would have written — the same trims, the same
/// category fallback, the same next-due date for a standing cost.
struct ExpenseSheet: View {
    /// See `NewJobSheet.width`: the snapshot photographs the sheet at this size.
    static let width: CGFloat = 420

    let shop: Shop
    @Environment(\.dismiss) private var dismiss

    @State private var amount: Double = 0
    /// Empty when the sheet was filled in from a receipt: a receipt does not
    /// say what the money was for, and a category picked for the person is
    /// one they file without ever choosing (alpha.63 review).
    @State private var category = "filament"
    @State private var date = Date()
    @State private var vatAmount: Double = 0
    @State private var note = ""
    @State private var orderId = ""
    @State private var recurring = ""
    /// What the note reads like, when the shared rule is confident enough to
    /// say. Held in state because the engine is an actor and a view cannot ask
    /// it a question while it is drawing.
    @State private var suggestion: String?
    /// Which supplier receipt this was read off, when it was — carried into
    /// the record so the same receipt scanned again is caught (ReceiptQr.swift).
    @State private var receiptRef = ""
    @FocusState private var focused: Bool

    /// Filled in from a receipt read off its QR, when there is one waiting —
    /// as the sheet's starting values, so the fields are right on the first
    /// frame rather than a frame after it.
    init(shop: Shop) {
        self.shop = shop
        if let read = shop.receiptPrefill {
            // To the halala: a QR may write six decimals, and the field shows two.
            _amount = State(initialValue: Self.halala(read.draft.amount))
            _vatAmount = State(initialValue: Self.halala(read.draft.vatAmount))
            if let day = Order.day(read.draft.date) { _date = State(initialValue: min(day, Date())) }
            _note = State(initialValue: Self.receiptNote(read, words: shop.words))
            _receiptRef = State(initialValue: read.draft.receiptRef)
            _category = State(initialValue: "")
        }
    }

    static func halala(_ x: Double) -> Double { (x * 100).rounded() / 100 }

    /// The note a receipt files under, in the shop's language: the supplier as
    /// the book names them (or the seller as the receipt does), and the VAT
    /// number. Built here, not taken from the shared rule's English note.
    static func receiptNote(_ read: KhaytEngine.ReceiptDraft, words: Words) -> String {
        words.callIt("mac.receipt_note", ["seller": .string(read.supplier?.name ?? read.sellerName),
                                          "vat": .string(read.vatNumber)])
    }

    /// Add is open once there is an amount and a category.
    var canAdd: Bool { amount > 0 && !category.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(shop.words.callIt("exp.add_title")).font(.headline)
            if !receiptRef.isEmpty {
                // Filled in, not filed: the receipt says what was paid, not
                // what for, so the category is still the person's to choose.
                Text(shop.words.callIt("mac.receipt_from"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // A ZATCA receipt is in riyals; a shop that keeps its books in
                // another currency is told, not converted for.
                if shop.currency != "SAR" {
                    Text(shop.words.callIt("mac.receipt_sar", ["currency": .string(shop.currency)]))
                        .font(.callout).foregroundStyle(Khayt.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text(shop.words.callIt("exp.amount")).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        TextField("", value: $amount, format: .number.precision(.fractionLength(0...2)))
                            .textFieldStyle(.roundedBorder).monospacedDigit()
                            .focused($focused)
                            .onSubmit(commit)
                        Text(Money.mark(shop.currency)).foregroundStyle(.secondary)
                    }
                }
                // THE TAX ON THE RECEIPT, not a rate. A supplier's invoice
                // states an amount, rates differ line by line, and an import or
                // an exempt purchase carries none — so the shop copies the
                // figure in front of it rather than answering a question about
                // percentages. Left at zero it changes nothing, which is what
                // every expense recorded before this one does.
                //
                // Only for a registered shop: one that cannot reclaim the tax
                // has no use for the field, and every riyal on the receipt is
                // its cost.
                if shop.reclaimsTax {
                    GridRow {
                        Text(shop.words.callIt("exp.vat_paid")).foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            TextField("", value: $vatAmount,
                                      format: .number.precision(.fractionLength(0...2)))
                                .textFieldStyle(.roundedBorder).monospacedDigit()
                            Text(Money.mark(shop.currency)).foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        Color.clear.frame(height: 0)
                        Text(shop.words.callIt("exp.vat_paid_hint"))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                GridRow {
                    Text(shop.words.callIt("exp.category")).foregroundStyle(.secondary)
                    Picker("", selection: $category) {
                        if category.isEmpty { Text("—").tag("") }
                        ForEach(Shop.expenseCategories, id: \.self) { c in
                            Label(shop.words.callIt("exp.cat." + c), systemImage: Expenses.symbol(c)).tag(c)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text(shop.words.callIt("exp.date")).foregroundStyle(.secondary)
                    // No future date: an expense is recorded when it is spent,
                    // and one dated next week is a plan, not a cost.
                    DatePicker("", selection: $date, in: ...Date(), displayedComponents: .date)
                        .labelsHidden()
                }
                GridRow {
                    Text(shop.words.callIt("exp.note")).foregroundStyle(.secondary)
                    TextField(shop.words.callIt("exp.note_ph"), text: $note)
                        .textFieldStyle(.roundedBorder)
                }
                // ── WHAT THE RECEIPT READS LIKE ───────────────────────────
                //
                // Offered, never applied. The keyword list is short on
                // purpose, and a form that quietly re-filed what the shop had
                // already chosen would be wrong in its own books without ever
                // saying so. The other app puts the same suggestion under the
                // same field, and it is the same rule answering.
                if let suggestion, suggestion != category {
                    GridRow {
                        Color.clear.frame(height: 0)
                        HStack(spacing: 6) {
                            Text(shop.words.callIt("exp.suggested") + ":")
                                .font(.caption).foregroundStyle(.secondary)
                            Button(shop.words.callIt("exp.cat." + suggestion)) {
                                category = suggestion
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            Spacer(minLength: 0)
                        }
                    }
                }
                GridRow {
                    Text(shop.words.callIt("exp.recurring")).foregroundStyle(.secondary)
                    Picker("", selection: $recurring) {
                        Text("—").tag("")
                        Text(shop.words.callIt("exp.recurring_monthly")).tag("monthly")
                        Text(shop.words.callIt("exp.recurring_quarterly")).tag("quarterly")
                        Text(shop.words.callIt("exp.recurring_annually")).tag("annually")
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text(shop.words.callIt("exp.order_ref")).foregroundStyle(.secondary)
                    // Typed, not picked: a shop links an expense to a job it
                    // has in front of it, and a picker of every job it has ever
                    // taken is a worse way to find one than typing the number.
                    TextField(shop.words.callIt("exp.order_ref_ph"), text: $orderId)
                        .textFieldStyle(.roundedBorder).monospacedDigit()
                }
            }

            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("exp.add_btn"), action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(18)
        .frame(width: Self.width)
        .onAppear {
            focused = true
            // Taken: the next "Add expense" is a typed one.
            shop.receiptPrefill = nil
        }
        // Re-asked as the note is typed, which is when the answer can change.
        // `.task(id:)` cancels the one in flight, so a shop typing quickly asks
        // once rather than once per keystroke.
        .task(id: note) {
            suggestion = await shop.categoryFor(note)
        }
    }

    private func commit() {
        guard canAdd else { return }
        let input: [String: JSONValue] = [
            "amount": .number(amount),
            // Never more than what was paid, and never negative: the rule
            // clamps it too, but a figure typed here goes into the book and the
            // book is read by two apps.
            "vatAmount": .number(shop.reclaimsTax ? min(max(0, vatAmount), amount) : 0),
            "category": .string(category),
            "date": .string(Shop.today(date)),
            "note": .string(note),
            "orderId": .string(orderId),
            "recurring": .string(recurring),
            "receiptRef": .string(receiptRef),
        ]
        dismiss()
        Task { await shop.addExpense(input) }
    }
}

/// Logging a failed print.
///
/// The cost is worked out from the spool the material came off, the moment a
/// material and a weight are both there — a figure a shop can correct rather
/// than one it has to look up. Deducting is on by default, because the grams
/// are gone whether or not anybody writes it down.
struct WasteSheet: View {
    /// See `NewJobSheet.width`: the snapshot photographs the sheet at this size.
    static let width: CGFloat = 460

    let shop: Shop
    @Environment(\.dismiss) private var dismiss

    @State private var material = ""
    @State private var failureType = "bed_adhesion"
    @State private var weight: Double = 0
    @State private var cost: Double = 0
    @State private var reason = ""
    @State private var date = Date()
    @State private var deduct = true
    @State private var machineId = ""
    @State private var orderId = ""
    @FocusState private var focused: Bool

    /// Jobs a print can have failed on: anything still in the works, and the
    /// job whose print just stopped (the finish seam names it).
    private var jobs: [Order] {
        let open: Set<String> = ["pending", "on_hold", "printing", "post", "qc"]
        return shop.orders.filter { open.contains($0.status) || $0.id == orderId }
    }

    /// The materials on the shelf, once each — a shop picks what it wasted,
    /// and two spools of PLA are one choice.
    private var materials: [String] {
        var seen = Set<String>()
        return shop.spools.map(\.material).filter { seen.insert($0).inserted && !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(shop.words.callIt("waste.add")).font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text(shop.words.callIt("waste.material")).foregroundStyle(.secondary)
                    Picker("", selection: $material) {
                        ForEach(materials, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text(shop.words.callIt("mac.failure_category")).foregroundStyle(.secondary)
                    Picker("", selection: $failureType) {
                        ForEach(Shop.failureTypes, id: \.self) { ft in
                            Text(shop.words.callIt("waste.ft." + ft)).tag(ft)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text(shop.words.callIt("waste.weight")).foregroundStyle(.secondary)
                    TextField("", value: $weight, format: .number.precision(.fractionLength(0...1)))
                        .textFieldStyle(.roundedBorder).monospacedDigit()
                        .focused($focused)
                }
                GridRow {
                    Text(shop.words.callIt("waste.est_cost")).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        TextField("", value: $cost, format: .number.precision(.fractionLength(0...2)))
                            .textFieldStyle(.roundedBorder).monospacedDigit()
                        Text(Money.mark(shop.currency)).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text(shop.words.callIt("waste.date")).foregroundStyle(.secondary)
                    DatePicker("", selection: $date, in: ...Date(), displayedComponents: .date)
                        .labelsHidden()
                }
                GridRow {
                    Text(shop.words.callIt("waste.reason")).foregroundStyle(.secondary)
                    TextField(shop.words.callIt("waste.reason_ph"), text: $reason)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text(shop.words.callIt("mac.waste_job")).foregroundStyle(.secondary)
                    Picker("", selection: $orderId) {
                        Text(shop.words.callIt("mac.waste_no_job")).tag("")
                        ForEach(jobs) { Text($0.project.isEmpty ? $0.id : $0.project).tag($0.id) }
                    }
                    .labelsHidden()
                    .help(shop.words.callIt("mac.waste_job_help"))
                    .onChange(of: orderId) { _, id in
                        // The job knows its machine; the shop should not have
                        // to say it twice.
                        if let m = shop.orders.first(where: { $0.id == id })?.machineId, !m.isEmpty {
                            machineId = m
                        }
                    }
                }
                GridRow {
                    Text(shop.words.callIt("waste.printer")).foregroundStyle(.secondary)
                    Picker("", selection: $machineId) {
                        Text(shop.words.callIt("mach.unassigned")).tag("")
                        ForEach(shop.machines) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                }
            }

            Toggle(shop.words.callIt("waste.deduct_inv"), isOn: $deduct)

            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("waste.log_btn"), action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(material.isEmpty)
            }
        }
        .padding(18)
        .frame(width: Self.width)
        .onAppear {
            if material.isEmpty { material = materials.first ?? "" }
            // The print that just stopped, when the finish seam could name its
            // job: the likeliest thing a shop opening this sheet is logging.
            if orderId.isEmpty, let failed = shop.lastFailedJob() {
                orderId = failed.orderId
                machineId = failed.machineId
            }
            focused = true
        }
        // The shelf already knows what a gram of this costs, so the figure is
        // filled in rather than asked for. Typed over freely: a spool bought at
        // a different price is the shop's to say.
        .task(id: material + "/" + String(weight)) { await priceIt() }
    }

    private func priceIt() async {
        guard let engine = shop.engine, !material.isEmpty, weight > 0 else { return }
        if let worked = try? await engine.wasteCost(material: material, grams: weight,
                                                    inventory: shop.inventoryRows,
                                                    reclaimsTax: shop.reclaimsTax), worked > 0 {
            cost = (worked * 100).rounded() / 100
        }
    }

    private func commit() {
        guard !material.isEmpty else { return }
        let input: [String: JSONValue] = [
            "material": .string(material),
            "failureType": .string(failureType),
            "weight": .number(weight),
            "cost": .number(cost),
            "reason": .string(reason),
            "date": .string(Shop.today(date)),
            "machineId": .string(machineId),
            "orderId": .string(orderId),
            "deduct": .bool(deduct),
        ]
        dismiss()
        Task { await shop.logWaste(input) }
    }
}
