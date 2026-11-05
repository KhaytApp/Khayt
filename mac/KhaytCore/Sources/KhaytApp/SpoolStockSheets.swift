import SwiftUI
import KhaytCore

// MARK: - Adjust stock

/// Grams put on a spool or taken off it by hand, with the reason — and the
/// last few corrections, so a shop counting its rack can see what it said
/// before.
///
/// The desktop's Stock Adjustment, through the same rule
/// (`lib/spool-edit.js` `adjustStock`): the row it writes to `adjustments`
/// is the row the other app writes and shows.
struct StockAdjustSheet: View {
    @Bindable var shop: Shop
    let spool: Spool
    @State private var add = true
    @State private var amount: Double = 0
    @State private var reason = ""
    @State private var problem: String?
    @State private var saving = false
    @FocusState private var focused: Bool

    /// The desktop shows the newest five.
    static let shownHistory = 5

    private var history: [Shop.SpoolLogRow] {
        Array(shop.spoolLog(spool.id, "adjustments").prefix(Self.shownHistory))
    }

    var body: some View {
        SheetFrame(width: 440) {
            VStack(alignment: .leading, spacing: 4) {
                Text(shop.words.callIt("inv.adjust_title")).font(.headline)
                Text(spool.label(shop.words, unit: shop.unit(of: spool))).font(.callout)
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text(shop.words.callIt("inv.current_stock")).foregroundStyle(.secondary)
                    Text(Quantity.say(spool.weight ?? 0, shop.unit(of: spool), shop.words))
                        .monospacedDigit().fontWeight(.semibold)
                }
                GridRow {
                    Color.clear.frame(width: 0, height: 0)
                    Picker("", selection: $add) {
                        Text(shop.words.callIt("inv.adj_add")).tag(true)
                        Text(shop.words.callIt("inv.adj_remove")).tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                GridRow {
                    Text(shop.words.callIt("inv.adj_amount")).foregroundStyle(.secondary)
                    TextField("", value: $amount, format: .number.locale(Money.digits).precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder).monospacedDigit().frame(width: 120)
                        .focused($focused)
                }
                GridRow {
                    Text(shop.words.callIt("inv.adj_reason")).foregroundStyle(.secondary)
                    TextField("", text: $reason).textFieldStyle(.roundedBorder)
                }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Khayt.attention).font(.callout)
            }
            DetailSection(shop.words.callIt("inv.adj_history")) {
                if history.isEmpty {
                    Text(shop.words.callIt("mac.adj_none")).font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(history) { row in
                        HStack(spacing: 10) {
                            Text(row.date.isEmpty ? "\u{2014}" : row.date)
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 84, alignment: .leading)
                            let added = row.text("type") == "add"
                            Text(verbatim: (added ? "+" : "\u{2212}")
                                 + Quantity.say(row.number("amount") ?? 0, shop.unit(of: spool), shop.words))
                                .monospacedDigit()
                                .foregroundStyle(added ? Khayt.done : Khayt.attention)
                            Text(row.text("reason")).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        } footer: {
            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { shop.adjustingSpool = nil }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("common.save"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(amount <= 0 || saving || !shop.canMoveJobs)
            }
        }
        .onAppear { focused = true }
    }

    private func save() {
        saving = true
        Task {
            problem = await shop.adjustStock(spool.id, add: add, amount: amount, reason: reason)
            saving = false
            if problem == nil { shop.adjustingSpool = nil }
        }
    }
}

// MARK: - Drying log

/// When a spool was dried, how hot and for how long — the desktop's Drying
/// Log, written through the same drying rule as "Dried today"
/// (`FilamentDryness.recordDrying`), so the shelf's verdict clears either way.
struct DryingLogSheet: View {
    @Bindable var shop: Shop
    let spool: Spool
    @State private var date = Date()
    @State private var tempC: Double = 0
    @State private var hours: Double = 0
    @State private var notes = ""
    @State private var problem: String?
    @State private var saving = false
    /// The session chosen for Delete, held until the shop answers.
    @State private var deleting: Shop.SpoolLogRow?

    private var log: [Shop.SpoolLogRow] { shop.spoolLog(spool.id, "dryingLog") }

    var body: some View {
        SheetFrame(width: 520) {
            VStack(alignment: .leading, spacing: 4) {
                Text(shop.words.callIt("inv.dry_log")).font(.headline)
                Text(spool.label(shop.words, unit: shop.unit(of: spool))).font(.callout)
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text(shop.words.callIt("inv.dry_date")).foregroundStyle(.secondary)
                    DatePicker("", selection: $date, in: ...Date(), displayedComponents: .date)
                        .labelsHidden().fixedSize()
                }
                GridRow {
                    Text(shop.words.callIt("inv.dry_temp")).foregroundStyle(.secondary)
                    TextField("65", value: SpoolSheet.blankWhenZero($tempC),
                              format: .number.locale(Money.digits).precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder).monospacedDigit().frame(width: 90)
                }
                GridRow {
                    Text(shop.words.callIt("inv.dry_duration")).foregroundStyle(.secondary)
                    TextField("4", value: SpoolSheet.blankWhenZero($hours),
                              format: .number.locale(Money.digits).precision(.fractionLength(0...1)))
                        .textFieldStyle(.roundedBorder).monospacedDigit().frame(width: 90)
                }
                GridRow {
                    Text(shop.words.callIt("common.notes")).foregroundStyle(.secondary)
                    TextField(shop.words.callIt("common.optional"), text: $notes).textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Spacer()
                Button(shop.words.callIt("inv.dry_add"), action: add)
                    .disabled(saving || !shop.canMoveJobs)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Khayt.attention).font(.callout)
            }
            Divider()
            if log.isEmpty {
                Text(shop.words.callIt("mac.dry_none"))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(log) { row in
                        HStack(spacing: 10) {
                            Text(row.date).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 84, alignment: .leading)
                            Text(row.number("tempC").map { Money.quantity($0, decimals: 0) + "\u{00B0}C" } ?? "\u{2014}")
                                .monospacedDigit().frame(width: 60, alignment: .leading)
                            Text(row.number("durationH").map { Money.quantity($0, decimals: 1) + " " + shop.words.callIt("unit.h") } ?? "\u{2014}")
                                .monospacedDigit().frame(width: 60, alignment: .leading)
                            Text(row.text("notes")).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 0)
                            Button(role: .destructive) { deleting = row } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless)
                                .help(shop.words.callIt("common.delete"))
                                .disabled(!shop.canMoveJobs)
                        }
                        .padding(.vertical, 5)
                        Divider()
                    }
                }
            }
        } footer: {
            HStack {
                Spacer()
                Button(shop.words.callIt("common.close")) { shop.dryingLogFor = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .askFirst($deleting,
                  title: { _ in shop.words.callIt("common.delete") + "?" },
                  message: { $0.date },
                  confirm: shop.words.callIt("common.delete"),
                  cancel: shop.words.callIt("common.cancel")) { row in
            Task { problem = await shop.deleteDrying(spool.id, entryId: row.id) }
        }
    }

    private func add() {
        saving = true
        Task {
            problem = await shop.markDried(spool.id, on: Shop.today(date),
                                           tempC: tempC > 0 ? tempC : nil,
                                           hours: hours > 0 ? hours : nil, notes: notes)
            saving = false
            if problem == nil { tempC = 0; hours = 0; notes = "" }
        }
    }
}

// MARK: - Transfer between locations

/// Stock moved to another of the shop's sites. All of it moves the spool;
/// less splits it, and a new spool stands at the destination — the
/// desktop's Transfer, through the same rule (`lib/spool-edit.js`
/// `transferStock`).
struct TransferStockSheet: View {
    @Bindable var shop: Shop
    let spool: Spool
    @State private var dest = ""
    @State private var qty: Double = 0
    @State private var problem: String?
    @State private var saving = false

    private var have: Double { (spool.weight ?? 0).rounded() }

    var body: some View {
        SheetFrame(width: 440) {
            VStack(alignment: .leading, spacing: 4) {
                Text(shop.words.callIt("inv.transfer_title")).font(.headline)
                Text(spool.label(shop.words, unit: shop.unit(of: spool))).font(.callout)
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text(shop.words.callIt("inv.transfer_from")).foregroundStyle(.secondary)
                    Text(shop.locationName(spool.locationId) ?? shop.words.callIt("inv.location_unassigned"))
                        .fontWeight(.semibold)
                }
                GridRow {
                    Text(shop.words.callIt("inv.current_stock")).foregroundStyle(.secondary)
                    Text(Quantity.say(have, shop.unit(of: spool), shop.words)).monospacedDigit()
                }
                GridRow {
                    Text(shop.words.callIt("inv.transfer_to")).foregroundStyle(.secondary)
                    Picker("", selection: $dest) {
                        Text(shop.words.callIt("inv.location_unassigned")).tag("")
                        ForEach(shop.locations) { loc in Text(loc.name).tag(loc.id) }
                    }
                    .labelsHidden().fixedSize()
                }
                GridRow {
                    Text(shop.words.callIt("inv.transfer_qty")).foregroundStyle(.secondary)
                    TextField("", value: $qty, format: .number.locale(Money.digits).precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder).monospacedDigit().frame(width: 120)
                }
            }
            Text(shop.words.callIt("inv.transfer_split_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Khayt.attention).font(.callout)
            }
        } footer: {
            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { shop.transferringSpool = nil }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("inv.transfer_confirm"), action: move)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || !shop.canMoveJobs)
            }
        }
        .onAppear {
            qty = have
            // The first site that is not where it already is.
            let here = spool.locationId ?? ""
            dest = here.isEmpty ? (shop.locations.first?.id ?? "") : ""
        }
    }

    private func move() {
        saving = true
        Task {
            problem = await shop.transferStock(spool.id, to: dest, qty: qty)
            saving = false
            if problem == nil { shop.transferringSpool = nil }
        }
    }
}
