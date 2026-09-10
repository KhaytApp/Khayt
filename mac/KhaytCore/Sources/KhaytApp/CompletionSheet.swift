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
    /// Boxes the shop has typed in, so a late answer from the printer does not
    /// overwrite a figure under the cursor.
    @State private var touched: Set<Field> = []
    @FocusState private var focused: Field?

    private enum Field: Hashable { case hours, grams, notes }

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 14) {
            Text(words.callIt("act.title")).font(.headline)
            Text(subject.project).font(.callout).foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 14) {
                Figure(label: words.callIt("act.print_time"),
                       unit: words.callIt("common.hours"), quoted: words.callIt("act.est"),
                       estimate: subject.estHours, decimals: 1, text: $hours,
                       measured: subject.measured?.timeMeasured == true,
                       measuredWord: words.callIt("act.measured"))
                    .focused($focused, equals: .hours)
                    .onChange(of: hours) { _, _ in touched.insert(.hours) }
                Figure(label: words.callIt("act.weight"),
                       unit: words.callIt("common.grams"), quoted: words.callIt("act.est"),
                       estimate: subject.estGrams, decimals: 0, text: $grams,
                       measured: subject.measured?.weightMeasured == true,
                       measuredWord: words.callIt("act.measured"))
                    .focused($focused, equals: .grams)
                    .onChange(of: grams) { _, _ in touched.insert(.grams) }
            }

            // NOT "measured". These came off a keyboard, the record says so,
            // and the screens that need a measurement ignore them — so the
            // sheet says it too rather than letting a shop believe otherwise.
            //
            // Khayt's own `act.hint` says the rest — why a shop is being asked
            // and that the boxes are pre-filled WITH THE ESTIMATE — in nine
            // languages. Written a second time here it would be the same
            // sentence in two, drifting.
            //
            // AND NOT SHOWN WHEN A PRINTER SUPPLIED THE FIGURES, because then
            // the sentence is false: the boxes hold a measurement, the note
            // below says exactly that, and two lines contradicting each other
            // is worse than one missing.
            if subject.measured?.measured != true {
                Text(words.callIt("act.hint"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // WHICH PRINT THESE NUMBERS BELONG TO, when a printer supplied
            // them. A completion stays offerable for 24 hours, and a shop
            // running five-hour jobs back to back will have started another
            // long before that — so the figures on screen can belong to the
            // PREVIOUS print while wearing a "measured" label. Naming the file
            // is the difference between a claim and a checkable one.
            if let pre = subject.measured, pre.measured {
                Text(pre.filename.map {
                    words.callIt("act.from_printer_file",
                                 ["source": .string(pre.source ?? words.callIt("act.your_printer")),
                                  "file": .string($0)])
                } ?? words.callIt("act.from_printer",
                                  ["source": .string(pre.source ?? words.callIt("act.your_printer"))]))
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Khayt.done.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(words.callIt("mac.completion_typed"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
        .onAppear { fill() ; focused = .hours }
        // The printer's answer arrives after the sheet is already up — an
        // engine call, and a sheet that waited for one would be a click that
        // appears to have missed. Only overwrites a box the shop has not
        // touched: a figure being typed while the answer lands must not be
        // replaced under the cursor.
        .onChange(of: subject.measured) { _, _ in fill(onlyIfUntouched: true) }
    }

    private func fill(onlyIfUntouched: Bool = false) {
        // The measurement when there is one, and the ESTIMATE otherwise — which
        // is a deliberate choice with a cost: a shop that glances and confirms
        // writes the estimate back under a second name and reports a variance
        // of zero. Empty boxes would make the common case into typing, and a
        // dialog that is work to dismiss is one a shop learns to cancel.
        let time = Money.quantity(subject.measured?.timeH ?? subject.estHours, decimals: 1)
        let weight = Money.quantity(subject.measured?.weightG ?? subject.estGrams, decimals: 0)
        if !onlyIfUntouched || !touched.contains(.hours) { hours = time }
        if !onlyIfUntouched || !touched.contains(.grams) { grams = weight }
    }

    private func commit() {
        let id = subject.id
        let leavingQC = subject.leavingQC
        let said = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        // The estimate when the box has been emptied or scribbled in: a job
        // completed with a blank weight would deduct nothing from the shelf.
        let h = Self.number(hours) ?? subject.estHours
        let g = Self.number(grams) ?? subject.estGrams
        // ── WHOSE FIGURE IS THIS, AXIS BY AXIS ────────────────────────────
        //
        // Measured only where the printer reported that axis AND the shop left
        // the number alone. A figure that was typed over is a correction, and a
        // record that calls it a measurement is a wrong number trusted twice —
        // `Quoting` would then compare the shop's own guess against its own
        // estimate and report the variance as evidence.
        let pre = subject.measured
        let unchanged: (Double, Double?) -> Bool = { typed, offered in
            guard let offered else { return false }
            return abs(typed - offered) < 0.005
        }
        let instrument = pre?.source ?? "printer"
        shop.clearQuestion()
        Task {
            await shop.moveJob(id, to: .completed,
                               qcNotes: leavingQC ? said : nil,
                               actuals: .init(
                                hours: h, grams: g,
                                timeSource: (pre?.timeMeasured == true && unchanged(h, pre?.timeH))
                                    ? instrument : "manual",
                                weightSource: (pre?.weightMeasured == true && unchanged(g, pre?.weightG))
                                    ? instrument : "manual"))
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
        /// Whether a printer reported THIS axis. Said on the field rather than
        /// once for the sheet, because a mixed answer is the normal one: a
        /// PrusaLink box measures the duration and never the filament.
        let measured: Bool
        let measuredWord: String

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(label) (\(unit))").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                // What was quoted, kept on screen. Without it the shop is being
                // asked to correct a number it cannot see.
                HStack(spacing: 5) {
                    if measured {
                        Text(measuredWord)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Khayt.done)
                    }
                    Text("\(quoted): \(Money.quantity(estimate, decimals: decimals))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
