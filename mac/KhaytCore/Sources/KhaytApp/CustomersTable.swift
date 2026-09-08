import SwiftUI

/// The shop's customers, and what each of them owes.
struct CustomersTable: View {
    @Bindable var shop: Shop
    @SceneStorage("customers.columns") private var columns: TableColumnCustomization<Customer>
    @State private var order: [KeyPathComparator<Customer>] = [
        .init(\.owed, order: .reverse)
    ]

    private var rows: [Customer] { shop.shownCustomers.sorted(using: order) }

    var body: some View {
        Table(rows, selection: $shop.customerSelection, sortOrder: $order,
              columnCustomization: $columns) {
            TableColumn(shop.words.callIt("doc.client"), value: \.name) { person in
                HStack(spacing: 6) {
                    if person.overdueCount > 0 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Khayt.attention)
                            .help(shop.words.callIt("mac.overdue_jobs",
                                            ["n": .number(Double(person.overdueCount))]))
                    }
                    Text(person.name).lineLimit(1)
                }
            }
            // Every column is capped. Without a max the name column absorbs
            // all the slack, the table lays out wider than the space it has,
            // and the right-hand columns are clipped away rather than
            // compressed — Owed, the one this screen is sorted by, first.
            // Hard maxima, summing to well under the space the table has.
            // The table lays itself out wider than the pane it sits in — the
            // detail area is sized before the inspector takes its share — so
            // a column that stretches to fill goes under the inspector and is
            // simply gone. Owed, the column this screen is sorted by, went
            // first. Columns that stop short leave trailing space instead.
            .width(min: 140, ideal: 210, max: 300)

            TableColumn(shop.words.callIt("flow.owed"), value: \.owed) { person in
                if person.isSettled {
                    Text(shop.words.callIt("mac.settled"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    Text(Money.figure(person.owed))
                        .foregroundStyle(person.overdueCount > 0 ? AnyShapeStyle(Khayt.attention)
                                                                 : AnyShapeStyle(.primary))
                        .moneyStyle()
                }
            }
            .width(min: 96, ideal: 120, max: 150)
            .alignment(.trailing)
            TableColumn(shop.words.callIt("mac.jobs_count"), value: \.jobCount) { person in
                Text("\(person.jobCount)").moneyStyle()
            }
            .width(min: 48, ideal: 58, max: 70)
            .alignment(.trailing)

            TableColumn(shop.words.callIt("mac.open_count"), value: \.openCount) { person in
                // Zero is a full stop, not a number to read past. Dimming it
                // leaves the column scannable for the ones that are not zero.
                Text(person.openCount == 0 ? "—" : "\(person.openCount)")
                    .foregroundStyle(person.openCount == 0 ? AnyShapeStyle(.quaternary)
                                                           : AnyShapeStyle(.primary))
                    .moneyStyle()
            }
            .width(min: 48, ideal: 60, max: 70)
            .alignment(.trailing)

            TableColumn(shop.words.callIt("mac.last_job"), value: \.lastJobSort) { person in
                if let day = person.lastJob {
                    Text(day, format: .dateTime.day().month(.abbreviated).year())
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("—").foregroundStyle(.quaternary)
                }
            }
            .width(min: 90, ideal: 108, max: 130)

        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        // The app's ground shows through rather than the system's white — the
        // pane beside this one sits on it, and an opaque table drew a seam
        // down the middle of the window. The alternating row stripes are the
        // system's and still draw.
        .scrollContentBackground(.hidden)
        // Right-click. The two things there are to do to a customer: write them
        // down properly, and take a job for them.
        .contextMenu(forSelectionType: Customer.ID.self) { ids in
            if let id = ids.first, let person = shop.shownCustomers.first(where: { $0.id == id }),
               shop.canMoveJobs {
                Button(shop.words.callIt(person.record == nil
                                         ? "mac.write_them_down" : "mac.edit_customer")) {
                    shop.editingCustomer = person.record
                        ?? Shop.newCustomer().with(\.nameEn, person.name)
                }
            }
        } primaryAction: { ids in
            // Double-click edits them, which is what a double-click does to a
            // row everywhere else in this app.
            guard shop.canMoveJobs, let id = ids.first,
                  let person = shop.shownCustomers.first(where: { $0.id == id }) else { return }
            shop.editingCustomer = person.record ?? Shop.newCustomer().with(\.nameEn, person.name)
        }
        .overlay {
            if rows.isEmpty {
                if !shop.search.isEmpty {
                    ContentUnavailableView.search(text: shop.search)
                } else {
                    EmptyHere(title: shop.words.callIt("mac.no_customers"), message: shop.words.callIt("mac.no_customers_hint"))
                }
            }
        }
        .background(Khayt.ground)
    }
}

extension Customer {
    /// `Table` sorts on a comparable value, and `Date?` is not one. Absent dates
    /// sort oldest rather than crashing the column.
    var lastJobSort: Date { lastJob ?? .distantPast }
}

/// One customer: what they owe, and every job you have done for them.
struct CustomerInspector: View {
    let shop: Shop

    var body: some View {
        if let person = shop.selectedCustomer {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(person.name)
                            .font(.title3.weight(.semibold))
                            .textSelection(.enabled)
                        // One is one. `counting` is the same rule the window's
                        // subtitle uses, so a shop is not told "1 jobs" here
                        // and "1 job" there.
                        Text(shop.words.counting(person.jobCount, "mac.jobs_word"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if shop.canMoveJobs {
                            Button(shop.words.callIt(person.record == nil
                                                     ? "mac.write_them_down" : "mac.edit_customer")) {
                                // Someone who exists only as a name on old jobs
                                // gets a real record, pre-filled with the name
                                // those jobs already call them.
                                shop.editingCustomer = person.record
                                    ?? Shop.newCustomer().with(\.nameEn, person.name)
                            }
                            .buttonStyle(.link)
                            .font(.callout)
                        }
                    }
                    Divider()
                    // What the shop actually wrote down. Absent entirely before
                    // this app read the `clients` collection, so a customer's
                    // phone number lived only in the Electron window.
                    //
                    // THREE STATES, NOT TWO. There is the customer nobody has
                    // written down, the one written down with a phone number,
                    // and — the one this got wrong — the one written down as a
                    // name and nothing else. That last is ordinary, and it took
                    // the second branch: an empty CLIENT heading, which reads
                    // as a screen that failed to load (the same rule the
                    // machine card states). Told to take the first branch
                    // instead it would say "Not written down yet" about
                    // somebody who is.
                    if let record = person.record, record.hasContactDetails {
                        DetailSection(shop.words.callIt("doc.client")) {
                            if !record.phone.isEmpty {
                                DetailLine(shop.words.callIt("ce.phone"), record.phone)
                            }
                            if !record.email.isEmpty {
                                DetailLine(shop.words.callIt("ce.email"), record.email)
                            }
                            if !record.vat.isEmpty {
                                DetailLine(shop.words.callIt("ce.vat"), record.vat)
                            }
                            if !record.cr.isEmpty {
                                DetailLine(shop.words.callIt("ce.cr"), record.cr)
                            }
                            if !record.notes.isEmpty {
                                Text(record.notes).font(.callout).textSelection(.enabled)
                            }
                        }
                        Divider()
                    } else if person.record == nil {
                        Label(shop.words.callIt("mac.no_record"), systemImage: "person.crop.circle.badge.questionmark")
                            .font(.caption).foregroundStyle(.secondary)
                        Divider()
                    }
                    DetailSection(shop.words.callIt("mac.money")) {
                        DetailLine(shop.words.callIt("mac.billed"), Money.text(person.billed, shop.currency))
                        DetailLine(shop.words.callIt("mac.paid"), Money.text(person.paid, shop.currency), dim: true)
                        DetailLine(shop.words.callIt("flow.owed"), Money.text(person.owed, shop.currency),
                                   strong: !person.isSettled, warn: person.overdueCount > 0)
                        if person.overdueCount > 0 {
                            DetailLine(shop.words.callIt("mac.past_due"), "\(person.overdueCount)", warn: true)
                        }
                    }
                    Divider()
                    DetailSection(shop.words.callIt("mac.jobs_count")) {
                        ForEach(person.orders.sorted { ($0.day ?? .distantPast) > ($1.day ?? .distantPast) }) { job in
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(job.project).lineLimit(1)
                                    HStack(spacing: 4) {
                                        if let stage = Stage.of(job) {
                                            Text(shop.words.callIt(stage.key))
                                        }
                                        Text("·")
                                        Text(job.id)
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 8)
                                Text(Money.figure(job.isSettled ? job.price : job.owed))
                                    .font(.callout)
                                    .monospacedDigit()
                                    .foregroundStyle(job.isSettled ? AnyShapeStyle(.tertiary)
                                                                   : AnyShapeStyle(.primary))
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .padding(16)
            }
        } else {
            EmptyHere(title: shop.words.callIt("mac.no_customer"), message: shop.words.callIt("mac.no_customer_hint"))
        }
    }
}
