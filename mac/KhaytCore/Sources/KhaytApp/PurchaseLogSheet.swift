import SwiftUI
import KhaytCore

/// What the shop bought from a supplier, and what it paid.
///
/// ── WHY THE UNIT IS A FIELD AND NOT AN ASSUMPTION ─────────────────────────
///
/// The same word — "PLA" — is attached to a spool bought for 75 and, a month
/// later, to a kilogram bought for 22. `lib/supplier-prices.js` exists because
/// putting both on one trend line says the shop's PLA got cheaper when it did
/// nothing of the sort, and the unit is what tells them apart. A form that
/// left it out would write a log that cannot honestly be compared, which is
/// worse than one nobody fills in.
///
/// The material is free text on purpose, as it is in the other app: it is what
/// the supplier's invoice calls the stuff, and forcing it onto the shelf's own
/// list would either refuse a purchase or quietly re-label it.
struct PurchaseLogSheet: View {
    @Bindable var shop: Shop
    let supplier: Supplier

    @State private var date = Date()
    @State private var amount: Double = 0
    @State private var item = ""
    @State private var notes = ""
    @State private var unitPrice: Double = 0
    @State private var quantity: Double = 1
    @State private var unit = "spool"
    @State private var material = ""
    @State private var problem: String?
    @FocusState private var focused: Bool

    /// The units the other app offers, in its order. Not translated there and
    /// not here: they are the words that go into the book, and a unit stored
    /// in one language is a unit the other app cannot group by.
    static let units = ["spool", "kg", "g", "L", "piece", "roll", "box"]

    var body: some View {
        SheetFrame(width: 460) {
            VStack(alignment: .leading, spacing: 4) {
                Text(shop.words.callIt("sup.log_purchase")).font(.headline)
                Text(supplier.name).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text(shop.words.callIt("sup.purchase_date")).foregroundStyle(.secondary)
                    // No future date, for the reason the expense sheet gives:
                    // a purchase dated next week is a plan, not a spend.
                    DatePicker("", selection: $date, in: ...Date(), displayedComponents: .date)
                        .labelsHidden()
                }
                GridRow {
                    Text(shop.words.callIt("sup.purchase_amount")).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        TextField("", value: $amount, format: .number.precision(.fractionLength(0...2)))
                            .textFieldStyle(.roundedBorder).monospacedDigit()
                            .focused($focused)
                        Text(Money.mark(shop.currency)).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text(shop.words.callIt("sup.purchase_item")).foregroundStyle(.secondary)
                    TextField(shop.words.callIt("sup.purchase_item_ph"), text: $item)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text(shop.words.callIt("sup.material_type")).foregroundStyle(.secondary)
                    TextField("PLA, PETG, Resin…", text: $material)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text(shop.words.callIt("sup.quantity")).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        TextField("", value: $quantity, format: .number.precision(.fractionLength(0...2)))
                            .textFieldStyle(.roundedBorder).monospacedDigit()
                            .frame(width: 90)
                        Picker("", selection: $unit) {
                            ForEach(Self.units, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        Spacer(minLength: 0)
                    }
                }
                GridRow {
                    Text(shop.words.callIt("sup.unit_price")).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        TextField("", value: $unitPrice,
                                  format: .number.precision(.fractionLength(0...2)))
                            .textFieldStyle(.roundedBorder).monospacedDigit()
                        Text(Money.mark(shop.currency)).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text(shop.words.callIt("common.notes")).foregroundStyle(.secondary)
                    TextField(shop.words.callIt("sup.purchase_notes_ph"), text: $notes)
                        .textFieldStyle(.roundedBorder)
                }
            }

            // What the price per unit works out at, when the shop has given a
            // quantity and not a unit price. Said rather than written: the
            // figure the price history compares is the one in the book, and
            // filling a field the shop did not fill is how a guess becomes a
            // fact.
            if unitPrice <= 0, amount > 0, quantity > 0 {
                Text(shop.words.callIt("mac.works_out_at") + " "
                     + Money.text((amount / quantity * 100).rounded() / 100, shop.currency)
                     + "/" + unit)
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } footer: {
            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { shop.loggingPurchaseFor = nil }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("common.save"), action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(amount <= 0)
            }
        }
        .onAppear { focused = true }
    }

    private func commit() {
        guard amount > 0 else {
            problem = shop.words.callIt("sup.amount_required"); return
        }
        var entry: [String: JSONValue] = [
            "date": .string(Shop.today(date)),
            "amount": .number((amount * 100).rounded() / 100),
            "item": .string(item.trimmingCharacters(in: .whitespacesAndNewlines)),
            "notes": .string(notes.trimmingCharacters(in: .whitespacesAndNewlines)),
            // The other app writes `|| 1`, so a quantity of nothing is one of
            // whatever the unit is rather than a division by zero downstream.
            "quantity": .number(quantity > 0 ? quantity : 1),
            "unit": .string(unit),
            "materialType": .string(material.trimmingCharacters(in: .whitespaces)),
        ]
        // NULL when the shop did not say, which is what the other app writes
        // (`parseFloat(...) || null`) — and what `supplier-prices` reads as
        // "work it out from the amount and the quantity".
        entry["unitPrice"] = unitPrice > 0 ? .number(unitPrice) : .null
        let id = supplier.id
        Task {
            await shop.logPurchase(entry, against: id)
            if shop.moveProblem == nil { shop.loggingPurchaseFor = nil }
            else { problem = shop.moveProblem }
        }
    }
}

/// What a supplier has been bought from, newest first.
///
/// Read-only, like the other app's: the log is a record of what happened, and
/// a row in it is corrected by writing the correction down rather than by
/// editing history.
struct PurchaseHistorySheet: View {
    @Bindable var shop: Shop
    let supplier: Supplier

    var body: some View {
        SheetFrame(width: 520) {
            VStack(alignment: .leading, spacing: 4) {
                Text(supplier.name).font(.headline)
                Text(shop.words.callIt("sup.history"))
                    .font(.callout).foregroundStyle(.secondary)
            }

            if supplier.purchases.isEmpty {
                Text(shop.words.callIt("sup.history_empty"))
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(supplier.purchases) { bought in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(bought.date.isEmpty ? "—" : bought.date)
                                .font(.caption).foregroundStyle(.secondary)
                                .monospacedDigit().frame(width: 84, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                // A DASH, not the field's own label. Drawing
                                // "Item / Description" where the shop typed
                                // nothing puts the question on screen as
                                // though it were the answer.
                                Text(bought.item.isEmpty ? "—" : bought.item)
                                    .lineLimit(1)
                                    .foregroundStyle(bought.item.isEmpty ? .secondary : .primary)
                                if let said = bought.said {
                                    Text(said).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            Text(Money.text(bought.amount, shop.currency))
                                .monospacedDigit()
                        }
                        .padding(.vertical, 7)
                        if bought.id != supplier.purchases.last?.id { Divider() }
                    }
                }
                Divider()
                HStack {
                    Text(shop.words.callIt("sup.hist_total")).foregroundStyle(.secondary)
                    Spacer()
                    Text(Money.text(supplier.totalSpent, shop.currency))
                        .monospacedDigit().fontWeight(.semibold)
                }
                .padding(.top, 4)
            }
        } footer: {
            HStack {
                Spacer()
                Button(shop.words.callIt("common.close")) { shop.showingHistoryFor = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}
