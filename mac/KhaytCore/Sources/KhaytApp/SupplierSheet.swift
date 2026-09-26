import SwiftUI
import KhaytCore

/// Who the shop buys from, on the screen where it decides what to buy.
///
/// ── WHY IT IS ON THE SHELF AND BELOW IT ───────────────────────────────────
///
/// The other app keeps suppliers on its Inventory tab, under the spools and the
/// consumables, and that is the right place: a supplier is a fact about the
/// rack — who to ring about it, how long they take, and what they quote — not a
/// screen a shop visits. It sits BELOW the grid for the same reason the cards
/// above it sit above: those answer what the shelf is doing today, and this is
/// the reference a shop opens once a quarter.
///
/// Shown even when the list is empty, which is the one thing the cards above it
/// do not do. A card that appeared only once there was a supplier would leave a
/// shop with no way to write down its first one.
struct SuppliersCard: View {
    @Bindable var shop: Shop

    private var rows: [Supplier] { shop.suppliers }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CapsLabel(shop.words.callIt("sup.title"), tint: Role.text3, size: 9)
                Spacer()
                Button(shop.words.callIt("mac.add_supplier")) {
                    shop.editingSupplier = Supplier.blank()
                }
                // Legible when it can be pressed, in dark mode too.
                .buttonStyle(WellButtonStyle())
                .disabled(!shop.canMoveJobs)
            }
            if rows.isEmpty {
                Text(shop.words.callIt("sup.empty"))
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(rows) { supplier in
                        Row(shop: shop, supplier: supplier)
                        if supplier.id != rows.last?.id { Divider() }
                    }
                }
            }
        }
    }

    /// One supplier: who they are, how long they take, and what they have cost.
    private struct Row: View {
        @Bindable var shop: Shop
        let supplier: Supplier

        var body: some View {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(supplier.name).lineLimit(1)
                    Text(said).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                // What they have cost, which is the figure a shop comparing
                // two suppliers is after. A supplier nobody has logged a
                // purchase against shows a dash rather than 0.00: nothing was
                // spent, which is not the same as spending nothing.
                Text(supplier.totalSpent > 0
                     ? Money.text(supplier.totalSpent, shop.currency)
                     : "—")
                    .font(.callout).monospacedDigit()
                Button(shop.words.callIt("common.edit")) {
                    shop.editingSupplier = supplier
                }
                .disabled(!shop.canMoveJobs)
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                guard shop.canMoveJobs else { return }
                shop.editingSupplier = supplier
            }
            .contextMenu {
                if shop.canMoveJobs {
                    Button(shop.words.callIt("common.edit")) {
                        shop.editingSupplier = supplier
                    }
                    Button(shop.words.callIt("sup.log_purchase")) {
                        shop.loggingPurchaseFor = supplier
                    }
                }
                // Reading the log is not a write, so it does not wait on
                // `canMoveJobs`: a read-only book can still say what it paid.
                Button(shop.words.callIt("sup.history")) {
                    shop.showingHistoryFor = supplier
                }
                if shop.canMoveJobs {
                    Divider()
                    Button(shop.words.callIt("common.delete"), role: .destructive) {
                        Task { await shop.deleteSupplier(supplier.id) }
                    }
                }
            }
        }

        /// The second line: what they sell, how long they take, and how many
        /// materials they have quoted a price for — which is the field that
        /// actually does something, because a quote is what a drafted order is
        /// priced at.
        private var said: String {
            var parts = [shop.words.callIt("sup.cat." + category)]
            if let days = supplier.leadDays {
                parts.append("\(days) " + shop.words.callIt("common.days"))
            }
            if !supplier.priceList.isEmpty {
                parts.append(shop.words.counting(supplier.priceList.count, "mac.quotes_word"))
            }
            if !supplier.phone.isEmpty { parts.append(supplier.phone) }
            return parts.joined(separator: " · ")
        }

        /// A category the picker does not have reads as `other` on screen and
        /// is left alone in the book — see `Supplier`.
        private var category: String {
            Supplier.categories.contains(supplier.category) ? supplier.category : "other"
        }
    }
}

/// Writing a supplier down, or correcting one.
///
/// ── THE PRICE LIST IS THE POINT ───────────────────────────────────────────
///
/// The rest of this form is a contact card. The price list is what `lib/
/// reorder.js` reads to decide what a drafted order costs: a quoted rate per
/// kilogram, divided by a thousand, in preference to dividing a spool's own
/// cost by its weight. Until this sheet existed the Mac could draft an order
/// priced off a quote and could not record one, so a shop that had negotiated
/// a better rate went on drafting orders at the old figure.
///
/// Per KILOGRAM, and labelled so, because that is the unit the shop is quoted
/// in and the unit the other app stores. The division into grams is the shared
/// rule's, and a form that asked for a price per gram would be inviting the
/// thousand-fold error `po-audit` exists to find.
struct SupplierSheet: View {
    /// See `NewJobSheet.width`: the snapshot photographs the sheet at this
    /// size, and a width typed twice is a picture cropped through the middle.
    static let width: CGFloat = 460

    @Bindable var shop: Shop
    /// The supplier as the form has it. A copy: nothing reaches the book until
    /// Save.
    @State private var draft: Supplier
    @State private var lead: String
    @State private var problem: String?
    @FocusState private var focused: Bool

    /// Whether this is a correction or a new one. The ID decides: a supplier
    /// the book has one of has one, and `Supplier.blank()` has none. A second
    /// piece of state saying the same thing is a second thing to get wrong.
    private var existing: Bool { !draft.id.isEmpty }

    init(shop: Shop, supplier: Supplier) {
        self.shop = shop
        _draft = State(initialValue: supplier)
        _lead = State(initialValue: supplier.leadDays.map(String.init) ?? "")
    }

    var body: some View {
        SheetFrame(width: Self.width) {
            Text(shop.words.callIt(existing ? "mac.edit_supplier" : "mac.add_supplier"))
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text(shop.words.callIt("sup.name")).foregroundStyle(.secondary)
                    TextField(shop.words.callIt("sup.name_ph"), text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                }
                GridRow {
                    Text(shop.words.callIt("sup.category")).foregroundStyle(.secondary)
                    Picker("", selection: $draft.category) {
                        ForEach(Supplier.categories, id: \.self) { key in
                            Text(shop.words.callIt("sup.cat." + key)).tag(key)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text(shop.words.callIt("sup.phone")).foregroundStyle(.secondary)
                    TextField("+966…", text: $draft.phone).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text(shop.words.callIt("sup.lead_time")).foregroundStyle(.secondary)
                    // TEXT, not a number field bound to an Int. A lead time a
                    // shop has never measured is BLANK, and a numeric field
                    // has no way to be blank: it would say 0 days, which reads
                    // as "arrives the same day".
                    TextField(shop.words.callIt("common.days"), text: $lead)
                        .textFieldStyle(.roundedBorder)
                        .monospacedDigit()
                }
                GridRow {
                    Text(shop.words.callIt("sup.website")).foregroundStyle(.secondary)
                    TextField("https://…", text: $draft.website).textFieldStyle(.roundedBorder)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(shop.words.callIt("sup.price_list")).font(.callout)
                ForEach($draft.priceList) { $quote in
                    HStack(spacing: 6) {
                        TextField(shop.words.callIt("sup.price_material_ph"),
                                  text: $quote.material)
                            .textFieldStyle(.roundedBorder)
                        TextField("0", value: $quote.pricePerKg,
                                  format: .number.precision(.fractionLength(0...2)))
                            .textFieldStyle(.roundedBorder)
                            .monospacedDigit()
                            .frame(width: 90)
                        // The MARK, not the code: every other money field on
                        // this app draws the riyal glyph, and a sheet that
                        // says "SAR" beside one figure and ﷼ beside the next
                        // reads as two different currencies.
                        Text(Money.mark(shop.currency))
                            .font(.caption).foregroundStyle(.secondary)
                        Button {
                            draft.priceList.removeAll { $0.id == quote.id }
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(shop.words.callIt("common.delete"))
                    }
                }
                Button(shop.words.callIt("sup.add_price")) {
                    draft.priceList.append(Supplier.Quote(material: "", pricePerKg: 0))
                }
                .buttonStyle(.borderless)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(shop.words.callIt("common.notes")).foregroundStyle(.secondary)
                TextField("", text: $draft.notes, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
            }

            // What deleting one does NOT do, said where a shop can read it
            // before it deletes. Orders keep the supplier's name because that
            // is what was true when they were raised.
            if existing, draft.purchaseCount > 0 {
                Text(shop.words.callIt("mac.supplier_kept_history",
                                       ["n": .number(Double(draft.purchaseCount))]))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } footer: {
            HStack {
                if existing {
                    Button(shop.words.callIt("common.delete"), role: .destructive) {
                        let id = draft.id
                        Task {
                            await shop.deleteSupplier(id)
                            close()
                        }
                    }
                }
                Spacer()
                Button(shop.words.callIt("common.cancel"), action: close)
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("common.save"), action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { focused = true }
    }

    private func close() {
        shop.editingSupplier = nil
    }

    private func commit() {
        var wanted = draft
        // Blank means the shop has not said, which is null in the book — not
        // zero, and not the figure that happened to be there before.
        let typed = Int(lead.trimmingCharacters(in: .whitespaces))
        wanted.leadDays = (typed ?? 0) > 0 ? typed : nil
        Task {
            await shop.saveSupplier(wanted)
            if let said = shop.moveProblem { problem = said }
        }
    }
}
