import SwiftUI
import KhaytCore

/// A job's due date, how urgent it is, and — when the number changed on the
/// phone — what it costs.
///
/// Three fields, not thirty. These are the ones a shop floor actually adjusts
/// — "it slipped a week", "this one first", "we agreed 1,800 in the end" — and
/// the ones whose changes Khayt writes into the job's edit history, because
/// they are what a customer can be told a different answer about later. The
/// price box is empty until typed in: empty means the price stands.
///
/// Everything else the order editor writes is left exactly as it was. That is
/// the shared rule's guarantee, not this sheet's promise: `applyEdit` touches
/// only the fields it is handed.
struct EditJobSheet: View {
    /// How wide this sheet is. A CONSTANT rather than a number in the body,
    /// because `SnapshotTests` photographs the sheet at a size of its own and
    /// the two silently disagreed: the sheet grew and the picture kept the old
    /// width, so the render came back cropped down the middle with no failure.
    /// 460, and the number is the segmented control's doing.
    ///
    /// At 360 the Grid gave the picker its ideal width and the label column
    /// whatever was left, which was about fifty points — so "Mark as priority /
    /// urgent" came out one or two characters to a line, seven lines tall, in
    /// the shipping English app. The labels are `fixedSize` now so the column
    /// is measured from the text rather than from the leftovers, and the sheet
    /// is wide enough to hold both. Arabic is the tighter of the two.
    static let width: CGFloat = 460

    let shop: Shop
    let subject: Shop.PendingHold

    @State private var hasDueDate = false
    @State private var dueDate = Date()
    @State private var priority = "normal"
    /// A new total, as typed. Empty is "leave it".
    @State private var priceText = ""
    @State private var started = false
    /// A test, a gift, something for the shop itself. See `lib/business-scope.js`.
    @State private var nonBusiness = false

    private var job: Order? { shop.orders.first { $0.id == subject.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(shop.words.callIt("mac.edit_job")).font(.headline)
            Text(subject.project).font(.callout).foregroundStyle(.secondary).lineLimit(1)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text(shop.words.callIt("doc.due")).foregroundStyle(.secondary)
                        .fixedSize()
                    // A job with no due date is a real answer, so the sheet has
                    // to be able to say it — a date picker alone cannot.
                    Toggle(isOn: $hasDueDate) {
                        if hasDueDate {
                            DatePicker("", selection: $dueDate, displayedComponents: .date)
                                .labelsHidden()
                        } else {
                            Text(shop.words.callIt("mac.no_due_date")).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                GridRow {
                    Text(shop.words.callIt("oe.priority")).foregroundStyle(.secondary)
                        .fixedSize()
                    Picker("", selection: $priority) {
                        ForEach(Shop.priorityLevels, id: \.self) { level in
                            Text(shop.words.callIt(Self.wordFor(level))).tag(level)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                GridRow {
                    Text(shop.words.callIt("common.total")).foregroundStyle(.secondary)
                        .fixedSize()
                    HStack(spacing: 8) {
                        if let job {
                            Text(Money.text(job.price, shop.currency)).monospacedDigit()
                        }
                        Text(shop.words.callIt("pe.price_override")).foregroundStyle(.secondary)
                        TextField(shop.words.callIt("pe.price_override_ph"), text: $priceText)
                            .textFieldStyle(.roundedBorder).frame(width: 90).monospacedDigit()
                    }
                }
            }

            // In the other app's words, which the shared catalogue has in every
            // language: it leaves the money, and it does not pretend the print
            // never ran.
            VStack(alignment: .leading, spacing: 2) {
                Toggle(shop.words.callIt("oe.non_business"), isOn: $nonBusiness)
                    .toggleStyle(.checkbox)
                Text(shop.words.callIt("oe.non_business_hint"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { shop.clearQuestion() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("common.save"), action: commit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: Self.width)
        .onAppear {
            guard !started else { return }
            started = true
            if let day = Order.day(job?.dueDate) {
                hasDueDate = true
                dueDate = day
            }
            priority = shop.priorityOf(job)
            nonBusiness = job?.nonBusiness == true
        }
    }

    /// Khayt names the two raised levels and not the ordinary one, so this app
    /// supplies only the word Khayt has never needed.
    static func wordFor(_ level: String) -> String {
        switch level {
        case "urgent": "ord.priority_urgent"
        case "high": "ord.priority_high"
        default: "mac.priority_normal"
        }
    }

    private func commit() {
        let id = subject.id
        let when = hasDueDate ? dueDate : nil
        let level = priority
        let typed = priceText.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        let price = typed.isEmpty ? nil : Double(typed).map { max(0, $0) }
        let wasNonBusiness = job?.nonBusiness == true
        let nowNonBusiness = nonBusiness
        shop.clearQuestion()
        Task {
            await shop.editJob(id, dueDate: when, priorityLevel: level, price: price)
            // Only when it changed: an edit that did not touch it writes nothing.
            if nowNonBusiness != wasNonBusiness { await shop.setNonBusiness(id, nowNonBusiness) }
        }
    }
}
