import SwiftUI
import KhaytCore

/// What the job really took, asked at the moment the shop finds out.
///
/// ── WHY COMPLETION AND NOT LATER ──────────────────────────────────────────
///
/// `order-status.gate` has always returned `needsActuals` — true for exactly
/// one move, into `completed` — and nothing in this app read it. So a shop
/// could finish a job on the Mac and had no way to say what it cost: 42 sample
/// jobs and every real one carried an estimate and no actual, which leaves the
/// margin on every finished job as the figure that was quoted rather than the
/// one that happened.
///
/// ── AND WHY IT REPLACES THE QC SHEET RATHER THAN FOLLOWING IT ─────────────
///
/// Completing a job out of inspection already opened a sheet asking for QC
/// notes. Two sheets in a row for one action is a shop pressing Return twice
/// to get past a question it did not ask for, so this is one sheet that
/// carries both — the notes only when the job is actually leaving QC.
struct CompletionSheet: View {
    let shop: Shop
    let subject: Shop.PendingCompletion

    @State private var hours: String = ""
    @State private var grams: String = ""
    @State private var notes: String = ""
    @FocusState private var focused: Field?

    private enum Field { case hours, grams, notes }

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 14) {
            Text(words.callIt("act.title")).font(.headline)
            Text(subject.project).font(.callout).foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 14) {
                Figure(label: words.callIt("act.print_time"),
                       unit: words.callIt("common.hours"), quoted: words.callIt("act.est"),
                       estimate: subject.estHours, decimals: 1, text: $hours)
                    .focused($focused, equals: .hours)
                Figure(label: words.callIt("act.weight"),
                       unit: words.callIt("common.grams"), quoted: words.callIt("act.est"),
                       estimate: subject.estGrams, decimals: 0, text: $grams)
                    .focused($focused, equals: .grams)
            }

            // NOT "measured". These came off a keyboard, the record says so,
            // and the screens that need a measurement ignore them — so the
            // sheet says it too rather than letting a shop believe otherwise.
            //
            // Khayt's own `act.hint` says the rest — why a shop is being asked
            // and that the boxes are pre-filled — in nine languages. Written a
            // second time here it would be the same sentence in two, drifting.
            Text(words.callIt("act.hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(words.callIt("mac.completion_typed"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if subject.leavingQC {
                VStack(alignment: .leading, spacing: 4) {
                    Text(words.callIt("ord.qc_notes")).font(.caption).foregroundStyle(.secondary)
                    TextField("", text: $notes)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .notes)
                }
            }

            HStack {
                Spacer()
                Button(words.callIt("common.cancel")) { shop.clearQuestion() }
                    .keyboardShortcut(.cancelAction)
                Button(words.callIt("act.confirm"), action: commit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            // Pre-filled from the ESTIMATE, and that is a deliberate choice
            // with a cost. A shop that glances and confirms writes the estimate
            // back under a second name, and the variance it reports is zero.
            // The alternative — empty fields — makes the common case (the job
            // ran as quoted) into typing, and a dialog that is work to dismiss
            // is a dialog a shop learns to cancel.
            hours = Money.quantity(subject.estHours, decimals: 1)
            grams = Money.quantity(subject.estGrams, decimals: 0)
            focused = .hours
        }
    }

    private func commit() {
        let id = subject.id
        let leavingQC = subject.leavingQC
        let said = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        // The estimate when the box has been emptied or scribbled in: a job
        // completed with a blank weight would deduct nothing from the shelf.
        let h = Self.number(hours) ?? subject.estHours
        let g = Self.number(grams) ?? subject.estGrams
        shop.clearQuestion()
        Task {
            await shop.moveJob(id, to: .completed,
                               qcNotes: leavingQC ? said : nil,
                               actuals: .init(hours: h, grams: g))
        }
    }

    /// A typed figure, or nil. Grouping separators are stripped because the
    /// field is pre-filled WITH them — `1,528` came from this app's own
    /// formatter, and `Double("1,528")` is nil.
    static func number(_ text: String) -> Double? {
        let cleaned = text.filter { $0.isNumber || $0 == "." }
        guard let value = Double(cleaned), value >= 0 else { return nil }
        return value
    }

    /// One figure, with what was quoted for it underneath.
    private struct Figure: View {
        let label: String
        let unit: String
        /// "Estimated" — because a bare `23.9` under a box is a number a shop
        /// cannot identify, and the one thing it must be able to tell at a
        /// glance is what it is being asked to correct.
        let quoted: String
        let estimate: Double
        let decimals: Int
        @Binding var text: String

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(label) (\(unit))").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                // What was quoted, kept on screen. Without it the shop is being
                // asked to correct a number it cannot see.
                Text("\(quoted): \(Money.quantity(estimate, decimals: decimals))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
