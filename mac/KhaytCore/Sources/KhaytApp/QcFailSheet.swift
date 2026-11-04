import SwiftUI
import KhaytCore

/// What went wrong, and what it cost.
///
/// A job leaving inspection for anywhere but Completed **failed** it, and a
/// failure that is not written down is not counted as one — `computeQcMetrics`
/// counts only the orders it can answer for, so an unrecorded failure quietly
/// improves the shop's pass rate. Three records come out of this sheet: the
/// fields on the job, a defect, and a waste row.
///
/// The categories are the shared list, and they are the same ones the waste
/// screen labels and filters by. Inventing one here would put a value in
/// `failureType` that no screen can name.
struct QcFailSheet: View {
    /// How wide this sheet is. A CONSTANT rather than a number in the body,
    /// because `SnapshotTests` photographs the sheet at a size of its own and
    /// the two silently disagreed: the sheet grew and the picture kept the old
    /// width, so the render came back cropped down the middle with no failure.
    static let width: CGFloat = 380

    let shop: Shop
    let subject: Shop.PendingHold

    @State private var failureType = "other"
    @State private var reason = ""
    @State private var wasted = ""
    /// Who pays for a reprint, when QC is on: the shop (our defect — no
    /// charge) by default, as on the desktop.
    @State private var reprintCost = "shop"
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(shop.words.callIt("ord.qc_fail")).font(.headline)
            Text(subject.project).font(.callout).foregroundStyle(.secondary).lineLimit(1)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text(shop.words.callIt("mac.what_went_wrong")).foregroundStyle(.secondary)
                    Picker("", selection: $failureType) {
                        ForEach(Shop.failureTypes, id: \.self) { type in
                            Text(shop.words.callIt("waste.ft." + type)).tag(type)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text(shop.words.callIt("waste.reason")).foregroundStyle(.secondary)
                    TextField("", text: $reason)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .onSubmit { commit(shop.qcReprintFlow ? .reprint(cost: reprintCost) : nil) }
                }
                GridRow {
                    Text(shop.words.callIt("mac.wasted")).foregroundStyle(.secondary)
                    // Optional, and empty means none. A guessed weight becomes a
                    // guessed cost in the waste log, which is worse than a gap.
                    TextField("", text: $wasted)
                        .textFieldStyle(.roundedBorder)
                        .monospacedDigit()
                }
            }

            // THE GRAMS COME OFF THE SHELF. They did not use to — the waste row
            // recorded them and the inventory was left alone — so a shop's
            // stock read high by every failure it had ever had. Said here
            // because it is now a number that changes what the shop owns.
            //
            // Nothing pre-fills it on this app: reading what the printer got
            // through needs the poller, which lives in Khayt. A shop watching a
            // print fail knows roughly what was on the plate.
            Text(shop.words.callIt("qc.weight_typed"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // ── SCRAP OR REPRINT, WITH QC ON ──────────────────────────────
            //
            // The desktop's flow: the failed job is kept as a scrapped record
            // and a reprint is a NEW job linked to it, so the first-pass and
            // RMA figures can tell a reprint from a job right first time. With
            // QC off the job goes back to Pending, as it always has.
            if shop.qcReprintFlow {
                Divider()
                Text(shop.words.callIt("qc.after_fail_hint"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker(shop.words.callIt("qc.reprint_cost"), selection: $reprintCost) {
                    Text(shop.words.callIt("qc.cost_shop")).tag("shop")
                    Text(shop.words.callIt("qc.cost_billable")).tag("billable")
                }
            }

            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { shop.clearQuestion() }
                    .keyboardShortcut(.cancelAction)
                if shop.qcReprintFlow {
                    Button(shop.words.callIt("mac.qc_scrap"), role: .destructive) { commit(.scrap) }
                    Button(shop.words.callIt("qc.reprint")) { commit(.reprint(cost: reprintCost)) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(shop.words.callIt("ord.qc_fail"), role: .destructive) { commit(nil) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(18)
        .frame(width: Self.width)
        .onAppear { focused = true }
    }

    private func commit(_ next: Shop.QcNext?) {
        let id = subject.id
        let type = failureType
        let note = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let grams = Double(wasted.trimmingCharacters(in: .whitespaces)) ?? 0
        shop.clearQuestion()
        Task { await shop.recordQcFailure(id, failureType: type, reason: note, weight: grams, next: next) }
    }
}
