import SwiftUI
import KhaytCore

/// A job's milestones: "Deposit 50%", then "On delivery 50%".
///
/// Each prints as a PROFORMA asking for that part (`Shop+Milestones.swift`);
/// the job's one tax invoice is not touched. The list is the book's
/// `milestoneInvoices`, the same shape the desktop writes, so a milestone made
/// in either app is here and there.
struct MilestonesSheet: View {
    @Bindable var shop: Shop
    let subject: Shop.PendingHold

    /// The job as it stands NOW: every action writes the book and reloads.
    private var job: Order? { shop.orders.first { $0.id == subject.id } }
    private var rows: [Milestone] { shop.milestones(of: subject.id) }
    private var currency: String {
        guard let job else { return shop.currency }
        return job.currency.isEmpty ? shop.currency : job.currency
    }
    private var price: Double { job?.price ?? 0 }

    @State private var label = ""
    @State private var percentage: Double = 50
    @State private var amount: Double = 0

    private var canAdd: Bool {
        shop.canMoveJobs && !label.trimmingCharacters(in: .whitespaces).isEmpty
            && percentage > 0 && amount > 0
    }

    var body: some View {
        SheetFrame(width: 560) {
            VStack(alignment: .leading, spacing: 4) {
                Text(shop.words.callIt("ord.milestone_invoices")).font(.headline)
                Text(subject.project).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(shop.words.callIt("mac.milestone_explain"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if rows.isEmpty {
                Text(shop.words.callIt("ord.no_milestones"))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(rows) { row in line(row) }
                }
            }

            Divider()
            adder

            if let problem = shop.moveProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } footer: {
            HStack {
                Spacer()
                Button(shop.words.callIt("common.close")) { shop.pendingMilestones = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .onAppear { amount = Milestones.amount(percent: percentage, of: price) }
    }

    /// One milestone: what it is called, its share and amount, when its
    /// proforma was last produced, and what can be done with it.
    private func line(_ row: Milestone) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label).lineLimit(1)
                if let day = row.issuedAt {
                    Text(shop.words.callIt("mac.milestone_printed_on", ["date": .string(day)]))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(shop.words.callIt("mac.milestone_not_printed"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(shop.words.callIt("mac.milestone_pct_value", ["pct": .string(Self.plain(row.percentage))]))
                .foregroundStyle(.secondary).monospacedDigit()
            Text(Money.text(row.amount, currency)).monospacedDigit()
            Button(shop.words.callIt("ord.gen_proforma")) {
                Task { await shop.showMilestoneProforma(subject.id, milestone: row.id) }
            }
            .controlSize(.small)
            .disabled(!shop.canMoveJobs)
            Button(role: .destructive) {
                Task { await shop.deleteMilestone(from: subject.id, milestone: row.id) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(shop.words.callIt("common.delete"))
            .accessibilityLabel(shop.words.callIt("common.delete"))
            .disabled(!shop.canMoveJobs)
        }
    }

    /// A new milestone. The amount starts as the percentage of the job's price
    /// and follows it while the percentage is edited; typing over it keeps what
    /// was typed.
    private var adder: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text(shop.words.callIt("ord.milestone_label")).foregroundStyle(.secondary)
                TextField("", text: $label).textFieldStyle(.roundedBorder)
            }
            GridRow {
                Text(shop.words.callIt("ord.milestone_pct")).foregroundStyle(.secondary)
                TextField("", value: $percentage,
                          format: .number.locale(Money.digits).precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder).monospacedDigit()
                    .onChange(of: percentage) { _, now in
                        amount = Milestones.amount(percent: now, of: price)
                    }
            }
            GridRow {
                Text(shop.words.callIt("ord.milestone_amount")).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    TextField("", value: $amount,
                              format: .number.locale(Money.digits).precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder).monospacedDigit()
                    Text(Money.mark(currency)).foregroundStyle(.secondary)
                }
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                Button(shop.words.callIt("mac.milestone_add")) {
                    let name = label
                    Task {
                        if await shop.addMilestone(to: subject.id, label: name,
                                                   percentage: percentage, amount: amount) {
                            label = ""
                        }
                    }
                }
                .disabled(!canAdd)
            }
        }
    }

    /// 50, not 50.0 — a percentage the way a person writes it.
    static func plain(_ n: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Money.digits
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }
}
