import SwiftUI
import UniformTypeIdentifiers
import KhaytCore

/// The book as a board: every open job, in the column its stage puts it in.
///
/// The table answers "what is the state of this job". The board answers "where
/// is the work piling up", which is the question a shop asks standing in the
/// middle of the room — and it is the one a list of forty rows sorted by date
/// cannot answer at a glance.
///
/// A CARD CAN BE MOVED NOW, and what moving it means is not written here. A
/// status change stamps the completion, deducts the filament and the packaging,
/// clears a hold and pushes the due date out by the days it waited, and fixes
/// the cost the job is judged on ever after. Those rules live in
/// `lib/order-status.js` and `lib/order-deduction.js` — the same JavaScript the
/// Electron app runs — and `Shop.moveJob` performs them. This file decides what
/// a person sees and nothing else.
///
/// A move that would send a webhook, a Telegram message, an email or a portal
/// refresh is REFUSED rather than half-made, and says which. None of those can
/// be sent from here and none of them can be sent afterwards.
struct Kanban: View {
    @Bindable var shop: Shop

    /// Seven columns, and all seven are here — which they were not. A job in QC
    /// or on hold had no column and therefore no card: it did not move to the
    /// end of the board, it vanished from it, and a board that silently omits
    /// the jobs somebody is waiting on is worse than no board.
    private var columns: [Stage] { Stage.boardColumns }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(columns) { stage in
                        Column(stage: stage, jobs: shop.board[stage] ?? [], shop: shop)
                    }
                }
                .padding(Metric.screen)
            }
            // Said out loud rather than filtered away. A job whose status has no
            // column is not on this board, and the board saying so is the
            // difference between a gap and a lie.
            if !shop.unplaced.isEmpty {
                Banner(text: shop.words.callIt("mac.board_unplaced",
                                               ["n": .number(Double(shop.unplaced.count))]),
                       symbol: "questionmark.circle", tint: .secondary)
            }
        }
        .background(Khayt.ground)
        .overlay {
            if shop.orders.isEmpty {
                EmptyHere(title: shop.words.callIt("mac.no_jobs"), mark: .board)
            } else if shop.matching(shop.orders).isEmpty {
                // Seven columns all saying "nothing here" is a board that looks
                // broken. It is a search that matched nothing, and it should say
                // which search.
                NothingMatched(shop: shop, mark: .board)
            }
        }
        // The same primary action the jobs table carries. A shop looking at a
        // board of work should be able to add to it from there.
        .toolbar { NewJobButton(shop: shop) }
    }
}

/// The two moves that ask a question first.
///
/// A hold wants to know why; a job leaving inspection wants to know that it
/// passed. Both answers are optional text and both are worth having — "waiting
/// on filament" three weeks later, and a pass rate computed over the whole
/// book rather than whatever happened to be recorded.
///
/// Return commits, Escape leaves the job where it is.
struct AskFirst: View {
    let shop: Shop
    let subject: Shop.PendingHold
    let kind: Kind
    @State private var answer = ""
    @FocusState private var focused: Bool

    enum Kind {
        case hold, qcPass

        var title: String { self == .hold ? "ord.hold_btn" : "ord.qc_pass" }
        var prompt: String { self == .hold ? "ord.hold_reason" : "ord.qc_notes" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(shop.words.callIt(kind.title)).font(.headline)
            Text(subject.project).font(.callout).foregroundStyle(.secondary).lineLimit(1)

            TextField(shop.words.callIt(kind.prompt), text: $answer)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(commit)

            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { shop.clearQuestion() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt(kind.title), action: commit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 340)
        .onAppear { focused = true }
    }

    private func commit() {
        let id = subject.id
        let said = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        shop.clearQuestion()
        Task {
            switch kind {
            case .hold: await shop.moveJob(id, to: .on_hold, holdReason: said)
            case .qcPass: await shop.moveJob(id, to: .completed, qcNotes: said)
            }
        }
    }
}

/// What the last move had to say, above whatever screen you are on.
///
/// A job on its way from one column to another.
///
/// A typed payload rather than a bare String: a board that accepted any dragged
/// text would move a job because someone dropped a word on it.
struct DraggedJob: Codable, Transferable {
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .khaytJob)
    }
}

extension UTType {
    /// Declared in the bundle's Info.plist so the drag is this app's own and
    /// nothing else on the Mac claims to understand it.
    static let khaytJob = UTType(exportedAs: "app.khayt.mac.job")
}

// NOT PHOTOGRAPHED, and it was tried both ways. `ImageRenderer` draws nothing
// inside a `ScrollView` and the columns live in one, so a picture of the board
// is a picture of the ground colour; rendering one column alone gets
// `ImageRenderer`'s refusal placeholder instead, because `.lane()` is a
// material. The window capture loses SwiftUI's own drawing. So the treatment
// below is the CONSERVATIVE one — a tint outline on what will accept, a recede
// on what will not — rather than anything whose reading has to be judged by eye.
private struct Column: View {
    let stage: Stage
    let jobs: [Order]
    let shop: Shop
    @State private var isTarget = false
    @Environment(\.accessibilityReduceMotion) private var reduced

    /// Why this column would refuse the card currently in the air, or nil.
    private var refusal: String? { shop.dragRefusal(stage) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The stage's own colour, and only when the column has something
            // in it: a warm heading over an empty column says a machine is
            // working when none is, and a green one over no delivered jobs
            // says work went out that did not.
            //
            // This asked `stage == .printing` before, so the board knew about
            // exactly one of the nine states it draws. `Stage.tint` answers for
            // all of them and returns nil for the five that are simply the
            // ordinary course of a job.
            let tint: Color? = jobs.isEmpty ? nil : stage.tint
            let style = tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary)
            HStack(spacing: 6) {
                Image(systemName: stage.symbol).foregroundStyle(style)
                Text(shop.words.callIt(stage.key)).font(.headline)
                Spacer(minLength: 6)
                Text("\(jobs.count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(style)
            }
            .padding(.horizontal, 4)

            if jobs.isEmpty {
                // An empty column keeps its width and says so. A board whose
                // columns collapse as work moves is a board you cannot learn.
                Text(shop.words.callIt("mac.nothing_here"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
            } else {
                ForEach(jobs) { job in
                    JobCard(job: job, shop: shop)
                }
            }
        }
        // Narrow enough that seven columns are a short scroll rather than a
        // long one, wide enough for a two-line job name.
        .frame(width: 196, alignment: .leading)
        .lane()
        // WHERE THE CARD IN THE AIR MAY GO — shown positively.
        //
        // The columns that would TAKE it outline themselves the moment it is
        // picked up; the ones that would refuse recede and say why on hover.
        // Outlining the refusals instead was the first draft and it is the
        // wrong way round: it puts the eye on what cannot be done and paints a
        // full column as an alarm, when a full column is a shop working.
        .opacity(refusal == nil ? 1 : 0.5)
        .overlay {
            // Outlined while a card is over it, as before — and now also while
            // a card is in the air and this column would have it. A permanently
            // outlined column reads as selected, so neither happens at rest.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.tint, lineWidth: 2)
                .opacity(shop.canMoveJobs && refusal == nil
                         && (isTarget || shop.draggingJob != nil) ? 1 : 0)
        }
        // The reason, on the column it is about, and only while it is under the
        // pointer. Seven columns each carrying a sentence is a board nobody can
        // read; one is an answer.
        .overlay(alignment: .top) {
            if let refusal, isTarget {
                Text(refusal)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
                    .padding(6)
                    .transition(.opacity)
            }
        }
        .dropDestination(for: DraggedJob.self) { dropped, _ in
            guard let job = dropped.first else { return false }
            // A card dropped back where it started is not a move. Performing it
            // would stamp a status history entry and a revision for nothing.
            guard Stage.of(job: job.id, in: shop) != stage else { return false }
            // Refused BEFORE the move is attempted, now that the answer is
            // already here. `moveJob` asks the rules again and refuses again —
            // this does not replace that, it stops the drop looking accepted.
            guard shop.dragRefusal(stage) == nil else { return false }
            // A hold asks why first — it is the one move whose reason a shop
            // will want three weeks later. Every other move just happens.
            if let ask = shop.questionFor(job.id, moving: stage) { ask(); return true }
            Task { await shop.moveJob(job.id, to: stage) }
            return true
        } isTargeted: { isTarget = $0 }
        .animation(.easeOut(duration: 0.12), value: isTarget)
        .animation(Motion.of(Motion.hover, unless: reduced), value: refusal == nil)
    }
}

private extension Stage {
    /// The stage a job is in right now, by id.
    @MainActor
    static func of(job id: String, in shop: Shop) -> Stage? {
        shop.orders.first { $0.id == id }.flatMap(Stage.of)
    }
}

private struct JobCard: View {
    let job: Order
    let shop: Shop

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 7) {
                // The board is the screen people stand in front of, and a
                // column of cards is scanned rather than read. A picture of the
                // thing is found faster than its name — and the picture is
                // already in the library, on a job that says which model it is.
                if let thumb = shop.modelThumbnail(for: job) {
                    Thumbnail(source: thumb)
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                VStack(alignment: .leading, spacing: 2) {
                    // Baseline-aligned, so the flag sits beside the first word
                    // rather than floating at the middle of a title that wrapped.
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        if job.priority {
                            Image(systemName: "flag.fill").font(.caption2)
                                .foregroundStyle(Khayt.attention)
                        }
                        Text(job.project).font(.callout.weight(.medium)).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !job.client.isEmpty {
                        Text(job.client).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    // What it is being printed in, in the shop's own words.
                    let colours = shop.partColours(of: job)
                    if !colours.isEmpty {
                        Text(colours.prefix(2).joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            }
            HStack(spacing: 6) {
                if let due = Order.day(job.dueDate) {
                    // Said in words as well as colour — this is the line that
                    // decides whether someone gets a phone call today.
                    Label(due.formatted(.dateTime.day().month(.abbreviated)),
                          systemImage: job.isOverdue() ? "exclamationmark.triangle" : "calendar")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(job.isOverdue() ? AnyShapeStyle(Khayt.attention) : AnyShapeStyle(.tertiary))
                }
                Spacer(minLength: 4)
                if !job.isSettled {
                    Text(Money.figure(job.owed))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        // Late first, then flagged — a job can be both, and "late" is the one
        // that decides what happens next. Neither is said by colour alone: the
        // date already wears a warning triangle and the flag is a flag.
        .card(rail: job.isOverdue() ? Khayt.late : (job.priority ? Khayt.attention : nil),
              padding: 9)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            // The board is for seeing; the table is for reading one job. A tap
            // takes you there rather than opening a panel the board has no room
            // for.
            shop.selection = job.id
            shop.shelf = .jobs(nil)
        }
        .help(job.id)
        // A read-only book is not draggable at all. Offering the gesture and
        // then refusing every drop teaches nothing except that the app is
        // unreliable.
        .modifier(Draggable(enabled: shop.canMoveJobs, id: job.id, shop: shop))
    }
}

/// `.draggable` applied only where the book can actually be changed.
private struct Draggable: ViewModifier {
    let enabled: Bool
    let id: String
    let shop: Shop

    /// Evaluated at the START of a drag, not at draw time. Anything here that
    /// ran per-frame would ask the engine on every redraw of the board.
    private func payload() -> DraggedJob {
        shop.beganDragging(id)
        return DraggedJob(id: id)
    }

    func body(content: Content) -> some View {
        if enabled {
            // `draggable` takes an AUTOCLOSURE, so `payload()` runs when the
            // drag begins rather than when the card is drawn — which is the
            // only hook SwiftUI offers for "a card was picked up", and the
            // moment the columns need to know which job is in the air.
            content.draggable(payload())
        } else {
            content
        }
    }
}
