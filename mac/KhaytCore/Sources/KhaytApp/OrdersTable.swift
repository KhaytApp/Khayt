import SwiftUI

/// The book. A real `Table`, which means AppKit's column resizing, column
/// reordering, click-to-sort, type-select, and rows that stay put under the
/// keyboard — none of which the web version manages convincingly.
struct OrdersTable: View {
    @Bindable var shop: Shop
    // Sort order and column layout both survive a relaunch. A Mac table whose
    // columns snap back to the developer's idea of the right ones every morning
    // is a table nobody bothers to arrange.
    @SceneStorage("jobs.sort") private var storedSort = "date:down"
    @SceneStorage("jobs.columns") private var columns: TableColumnCustomization<Order>
    @State private var order: [KeyPathComparator<Order>] = [
        .init(\.date, order: .reverse)
    ]
    /// Whether the one-time look at the book has already happened.
    ///
    /// STORED BESIDE THE COLUMNS, not in `@State`. As view state it reset on
    /// every launch, so the hiding ran again each time the window opened —
    /// re-hiding a column the shop had deliberately put back, which is exactly
    /// the behaviour the note below calls worse than never hiding anything.
    @SceneStorage("jobs.columnsChosen") private var decided = false

    private var rows: [Order] { shop.shown.sorted(using: order) }

    /// A COLUMN OF DASHES IS NOT A COLUMN.
    ///
    /// A shop whose jobs are auto-logged from its printers names no customer
    /// and promises no date on any of them, and this table gave two of its six
    /// columns to saying so on every row — on the book this app was written
    /// against, four of the six carried nothing at all.
    ///
    /// HIDDEN, not removed — and it stays that way now the app's floor is 26
    /// and a conditional column is available. Hiding is the better answer on
    /// its own merits: the column is in the header's own menu, so a shop that wants it
    /// back can have it and the choice sticks. Only ever done ONCE, the first
    /// time a book is opened — after that the customization is the shop's, and
    /// a screen that keeps re-hiding a column somebody deliberately showed is
    /// worse than one that never hid it.
    private func hideWhatThisBookDoesNotUse() {
        guard !decided else { return }
        decided = true
        if !shop.anyJobHasAClient { columns[visibility: "client"] = .hidden }
        if !shop.anyJobHasADueDate { columns[visibility: "due"] = .hidden }
    }

    var body: some View {
        Table(rows, selection: $shop.selection, sortOrder: $order,
              columnCustomization: $columns) {
            TableColumn(shop.words.callIt("mac.job"), value: \.project) { job in
                HStack(spacing: 8) {
                    if job.priority {
                        Image(systemName: "flag.fill")
                            .foregroundStyle(Khayt.attention)
                            .help(shop.words.callIt("mac.is_urgent"))
                    }
                    // WHAT IT LOOKED LIKE. A shop scanning this table is
                    // looking for the thing it made, and the picture was in the
                    // library all along — every other screen showed it and this
                    // one, the one people live in, did not. Absent for a job
                    // that never named a model, and the row simply starts at
                    // its title, so a book with no links is not a column of
                    // grey squares.
                    if let thumb = shop.modelThumbnail(for: job) {
                        Thumbnail(source: thumb)
                            .frame(width: 20, height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    // ONE LINE, NOT TWO.
                    //
                    // The name over the order number made every row 55pt tall,
                    // so a 900pt window showed twelve jobs where the same table
                    // ruled at 28 shows twenty-two. This is the screen a shop
                    // lives in, and the thing it wants from it is to see the
                    // work — the number is a reference you read once you have
                    // found the row, not something you scan down.
                    Text(job.project).lineLimit(1)
                    Text(job.id)
                        .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                        .layoutPriority(-1).lineLimit(1)
                    // The colours it was printed in, as WORDS — the shop's own,
                    // which is how it would be asked for over the counter. Not
                    // swatches: nothing here maps "sand" to a colour, and a
                    // guess would be this app's opinion of a physical thing.
                    ForEach(shop.partColours(of: job).prefix(2), id: \.self) { colour in
                        Text(colour)
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Khayt.recessed, in: Capsule())
                            .foregroundStyle(.secondary)
                            .lineLimit(1).layoutPriority(-1)
                    }
                }
            }
            .width(min: 200, ideal: 280)

            // A COLUMN OF DASHES IS NOT A COLUMN.
            //
            // A shop whose jobs are auto-logged from its printers has no
            // customer and no promised date on any of them, and this table gave
            // two of its six columns to saying so on every row — for the shop
            // whose own book this is, four columns of the six carried nothing.
            // The column comes back the moment one job has a client, because
            // the test is the data rather than a setting somebody has to find.
            TableColumn(shop.words.callIt("doc.client"), value: \.client) { job in
                Text(job.client.isEmpty ? "—" : job.client)
                    .foregroundStyle(job.client.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
            }
            .width(min: 120, ideal: 180)
            .customizationID("client")

            TableColumn(shop.words.callIt("mac.stage"), value: \.status) { job in
                if let s = Stage.of(job) {
                    // Colour only where the stage means something the palette
                    // has a word for — see `Stage.tint`. On a book whose jobs
                    // are all delivered this column is still one colour, and
                    // that is the honest answer rather than a decorated one.
                    // A DOT AND THE WORD, not an icon and the word.
                    //
                    // The same borrowed symbol repeated down forty-two rows
                    // carries one bit the word beside it already carries, and
                    // costs the height that made this table 55pt a row. A dot
                    // in the stage's own colour scans as well and takes 6pt.
                    HStack(spacing: 6) {
                        Circle()
                            .fill(s.tint ?? Color.secondary)
                            .frame(width: 6, height: 6)
                        Text(shop.words.callIt(s.key))
                            .foregroundStyle(s.tint.map(AnyShapeStyle.init)
                                             ?? AnyShapeStyle(.secondary))
                            .lineLimit(1)
                    }
                } else {
                    Text(job.status).foregroundStyle(.tertiary)
                }
            }
            .width(min: 100, ideal: 130)

            TableColumn(shop.words.callIt("doc.due")) { job in
                DueDate(words: shop.words, job: job)
            }
            .width(min: 78, ideal: 96)
            .customizationID("due")

            TableColumn(shop.words.callIt("common.total"), value: \.price) { job in
                Text(Money.figure(job.price)).moneyStyle()
            }
            .width(min: 80, ideal: 100)
            .alignment(.trailing)

            TableColumn(shop.words.callIt("flow.owed"), value: \.owed) { job in
                Owed(job: job, words: shop.words)
            }
            .width(min: 96, ideal: 120)
            .alignment(.trailing)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        // The app's ground shows through rather than the system's white — the
        // pane beside this one sits on it, and an opaque table drew a seam
        // down the middle of the window. The alternating row stripes are the
        // system's and still draw.
        .scrollContentBackground(.hidden)
        // After the book is loaded, not while it is empty: asked of a shop with
        // no orders yet, every column looks unused and all of them would go.
        .onChange(of: shop.orders.isEmpty) { _, empty in
            if !empty { hideWhatThisBookDoesNotUse() }
        }
        .onAppear { if !shop.orders.isEmpty { hideWhatThisBookDoesNotUse() } }
        // Right-click, which every other table in this app already answered and
        // the one holding the shop's jobs did not. Same actions as the Job
        // menu, reached where the hand already is.
        .contextMenu(forSelectionType: Order.ID.self) { ids in
            if let id = ids.first, let job = shop.orders.first(where: { $0.id == id }) {
                JobActions(shop: shop, job: job)
            }
        } primaryAction: { ids in
            // Double-click opens what a double-click opens everywhere else
            // here: the thing itself.
            if let id = ids.first { shop.showInvoice(id) }
        }
        .overlay {
            if rows.isEmpty { EmptyBook(shop: shop) }
        }
        .background(Khayt.ground)
        .toolbar { NewJobButton(shop: shop) }
    }
}

/// Taking a job, where a shop can see it.
///
/// The machines, spools, expense and waste screens all put their own "+" in the
/// toolbar. The screen holding the shop's ACTUAL WORK had none: ⌘N and the File
/// menu were the only ways in, so somebody who had not read the menus could not
/// take a job at all.
///
/// NO `.buttonStyle(.borderedProminent)`, AND THAT WAS MEASURED.
///
/// The HIG says to use a prominent style for a key action, and I put one here
/// first. On macOS 26 it renders the item PALE and breaks it out of the shared
/// capsule the system draws around a toolbar group — the plus looked disabled
/// beside an enabled Details button, which is how it was noticed. The same
/// guidance says why, two paragraphs up: "Reduce the use of toolbar backgrounds
/// and tinted controls. Any custom backgrounds and appearances you use might
/// overlay or interfere with background effects that the system provides", and
/// "prefer system-provided symbols without borders … the section provides a
/// visible container".
///
/// So: a plain symbol, and the system groups and styles it. Checked by
/// rendering all three versions and comparing the crops — with the style, and
/// then with `.disabled` alone, to be sure which of the two was doing it.
struct NewJobButton: ToolbarContent {
    let shop: Shop

    var body: some ToolbarContent {
        ToolbarItem {
            Button(shop.words.callIt("mac.new_job"), systemImage: "plus") {
                shop.takingAJob = true
            }
            .disabled(!shop.canMoveJobs)
            .help(shop.words.callIt("mac.new_job"))
        }
    }
}

/// What can be done to a job, wherever it is asked for.
///
/// The Job menu's items are built with the menu bar and their titles are frozen
/// there (see `ModelMenu`); these are built fresh each time the menu opens, so
/// they can say which job they are about.
struct JobActions: View {
    let shop: Shop
    let job: Order

    var body: some View {
        Button(shop.words.callIt("mac.edit_job")) {
            shop.pendingEdit = Shop.PendingHold(id: job.id, project: job.project)
        }
        .disabled(!shop.canMoveJobs)
        Button(shop.words.callIt("pay.modal_title")) {
            shop.pendingPayment = Shop.PendingHold(id: job.id, project: job.project)
        }
        .disabled(!shop.canMoveJobs)
        Button(shop.words.callIt("ord.hold_btn")) {
            shop.pendingHold = Shop.PendingHold(id: job.id, project: job.project)
        }
        .disabled(!shop.canMoveJobs || job.status == "on_hold")
        Divider()
        Button(shop.words.callIt("queue.delivered")) {
            Task { await shop.markDelivered(job.id) }
        }
        .disabled(!shop.canMoveJobs || job.status != "completed" || job.deliveredAt != nil)
        Divider()
        // Not gated on the book being ours: showing a shop what it would hand a
        // customer changes nothing, and refusing to draw the sample's invoice
        // would hide the thing this app is for.
        Button(shop.words.callIt("doc.invoice")) { shop.showInvoice(job.id) }
    }
}

/// A due date, or nothing.
///
/// Late is stated in words rather than by colour alone — a colour-only signal is
/// unreadable to a good number of people, and this is the cell that decides
/// whether someone gets a phone call today.
private struct DueDate: View {
    let words: Words
    let job: Order

    var body: some View {
        if let due = Order.day(job.dueDate) {
            let late = job.isOverdue()
            Text(due, format: .dateTime.day().month(.abbreviated))
                .monospacedDigit()
                .foregroundStyle(late ? AnyShapeStyle(Khayt.attention) : AnyShapeStyle(.secondary))
                .help(late
                      ? words.callIt("mac.overdue_unpaid")
                      : words.callIt("mac.due_on",
                                     ["date": .string(due.formatted(date: .abbreviated, time: .omitted))]))
        } else {
            Text("—").foregroundStyle(.quaternary)
        }
    }
}

/// What is still owed on this job, and how far through paying the customer is.
///
/// The one piece of decoration in the table, and it is carrying information: the
/// bar is the fraction already paid. A shop scanning this column can see at a
/// glance the difference between a job with a deposit down and one that has not
/// paid a riyal — which the number alone does not tell you without the total
/// next to it.
private struct Owed: View {
    let job: Order
    let words: Words

    private var paidFraction: Double {
        guard job.price > 0 else { return 0 }
        return min(1, max(0, job.paidAmount / job.price))
    }

    var body: some View {
        if job.isSettled {
            Text(words.callIt("mac.settled"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .trailing, spacing: 3) {
                Text(Money.figure(job.owed))
                    .monospacedDigit()
                Capsule()
                    .fill(.quaternary)
                    .frame(height: 2)
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            Capsule()
                                .fill(job.isOverdue() ? AnyShapeStyle(Khayt.attention) : AnyShapeStyle(.tint))
                                .frame(width: geo.size.width * paidFraction)
                        }
                    }
                    .help(paidFraction > 0
                          ? words.callIt("mac.pct_paid",
                                         ["n": .number((paidFraction * 100).rounded())])
                          : words.callIt("mac.nothing_paid"))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

private struct EmptyBook: View {
    let shop: Shop

    var body: some View {
        if let problem = shop.problem {
            // DELIBERATELY the system's component and its warning octagon. A
            // book that would not open is a FAILURE, not an empty screen, and
            // the drawn nozzle that says "nothing here yet" would say the
            // wrong thing about it cheerfully.
            ContentUnavailableView {
                Label(shop.words.callIt("mac.book_wont_open"), systemImage: "exclamationmark.octagon")
            } description: {
                Text(problem)
            }
        } else if !shop.search.isEmpty {
            ContentUnavailableView.search(text: shop.search)
        } else if shop.stage != nil {
            EmptyHere(title: shop.words.callIt("mac.nothing_at_stage"), message: shop.words.callIt("mac.stage_hint"), mark: .jobs)
        } else {
            EmptyHere(title: shop.words.callIt("mac.no_jobs"), mark: .jobs)
        }
    }
}
