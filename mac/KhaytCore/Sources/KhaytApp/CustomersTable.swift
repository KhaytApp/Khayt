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
            // NO MAXIMUM, so the name takes the slack.
            //
            // Every column here was capped, and the five maxima add up to 720
            // points inside a pane that is eleven hundred wide — so the table
            // could never fill its own window and left a third of it blank
            // behind a trailing divider, which reads as a column somebody
            // forgot to finish. It is the only table in this app that does
            // that; the jobs, expenses, gift-card and catalogue tables all
            // leave their first column unbounded, and a customer's name is the
            // variable-length thing here in the same way.
            .width(min: 140, ideal: 210)

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
                    NothingMatched(shop: shop, mark: .clients)
                } else {
                    EmptyHere(title: shop.words.callIt("mac.no_customers"), message: shop.words.callIt("mac.no_customers_hint"), mark: .clients)
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

    /// The line being written in the communications log.
    @State private var newKind = "call"
    @State private var newNote = ""

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
                    LayerRule()
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
                        LayerRule()
                    } else if person.record == nil {
                        Label(shop.words.callIt("mac.no_record"), systemImage: "person.crop.circle.badge.questionmark")
                            .font(.caption).foregroundStyle(.secondary)
                        LayerRule()
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
                    LayerRule()
                    // What follows this customer into every job, and what has
                    // been said to them. Only for someone written down: a
                    // name on old jobs has no record to hold any of it.
                    if let record = person.record {
                        if !record.priceList.isEmpty {
                            DetailSection(shop.words.callIt("ce.price_list")) {
                                ForEach(record.priceList) { agreed in
                                    DetailLine(agreed.product, Money.text(agreed.price, shop.currency))
                                    if !agreed.note.isEmpty {
                                        Text(agreed.note).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            LayerRule()
                        }
                        if let schedule = record.standingOrder {
                            DetailSection(shop.words.callIt("mac.standing_order")) {
                                DetailLine(shop.words.callIt("rec.interval"),
                                           shop.words.callIt("rec.interval.\(schedule.interval)",
                                                             fallback: schedule.interval))
                                if let next = schedule.nextDue {
                                    DetailLine(shop.words.callIt("rec.next_due"), next, dim: schedule.paused)
                                }
                                if schedule.paused {
                                    Text(shop.words.callIt("rec.paused"))
                                        .font(.caption).foregroundStyle(Khayt.attention)
                                }
                            }
                            LayerRule()
                        }
                        // The log, when there is one — or when a line can be
                        // added. An empty heading over "nothing yet" on a book
                        // that cannot be written is a section that says
                        // nothing, twice.
                        if !record.commLog.isEmpty || shop.canMoveJobs {
                            communications(record)
                            LayerRule()
                        }
                    }
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
            EmptyHere(title: shop.words.callIt("mac.no_customer"), message: shop.words.callIt("mac.no_customer_hint"), mark: .clients)
        }
    }

    /// Calls, messages and meetings — newest first, and a line to add one.
    ///
    /// Written the moment it is added, not on a Save button: a note about a
    /// call is a fact when the call ends, and the other app writes it to the
    /// record straight away for the same reason. Two shapes are read (see
    /// `CommEntry`); one is written.
    @ViewBuilder
    private func communications(_ record: Client) -> some View {
        DetailSection(shop.words.callIt("ce.comm_log"), count: record.commLog.isEmpty ? nil : record.commLog.count) {
            if record.commLog.isEmpty {
                Text(shop.words.callIt("ce.comm_empty"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            // Positions, not ids: a quick note has no id of its own, and two
            // written in one second would share the stand-in.
            let lines = record.commLog.sorted { $0.at > $1.at }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(shop.words.callIt(line.wordKey)).font(.callout.weight(.medium))
                            Text(line.day).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                        }
                        Text(line.note).font(.callout).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if shop.canMoveJobs {
                        Button {
                            Task { await shop.removeCommunication(line, from: record.id) }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                            .help(shop.words.callIt("common.delete"))
                    }
                }
                .padding(.vertical, 2)
            }
            if shop.canMoveJobs {
                HStack(spacing: 6) {
                    Picker("", selection: $newKind) {
                        ForEach(CommEntry.kinds, id: \.self) { kind in
                            Text(shop.words.callIt(CommEntry.wordKey(for: kind))).tag(kind)
                        }
                    }
                    .labelsHidden().frame(width: 110)
                    TextField(shop.words.callIt("ce.comm_note_ph"), text: $newNote)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addNote(to: record) }
                    Button(shop.words.callIt("common.add")) { addNote(to: record) }
                        .disabled(newNote.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func addNote(to record: Client) {
        let note = newNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return }
        let line = CommEntry(id: Shop.uid("CMM"), kind: newKind, note: note, at: Date())
        newNote = ""
        Task { await shop.addCommunication(line, to: record.id) }
    }
}
