import SwiftUI
import KhaytCore

/// Jobs ▸ List (S1, Figma Qqxg4imtKVgC3TfNGcRGOk 90:768): a row per job, and
/// the chosen job's PAGE beside it.
///
/// The table answers "what is the state of every job"; the board answers
/// "where is work piling up". This answers "what do I do with THIS job" —
/// the page pins the one next step, named, and when it cannot be done it
/// stays where it is, disabled, with the reason beside it.
///
/// Six regions, in the order every app keeps: header, next step, stage
/// track, parts, money, activity. Parts and money are the inspector's own
/// sections (`JobDetail`), so the two cannot drift.
struct JobsList: View {
    @Bindable var shop: Shop

    /// The order work is done in: urgent, then due, then longest waiting.
    private var rows: [Order] { Shop.boardSorted(shop.shown) }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding(get: { shop.selection },
                                    set: { shop.selectJobs($0.map { [$0] } ?? []) })) {
                ForEach(rows) { job in
                    JobRow(job: job, shop: shop).tag(job.id)
                        .contextMenu { JobActions(shop: shop, job: job) }
                }
            }
            .listStyle(.inset)
            .frame(width: 300)
            Divider()
            Group {
                if let job = shop.selected {
                    JobPage(job: job, shop: shop)
                } else {
                    EmptyHere(title: shop.words.callIt("mac.no_job"),
                              message: shop.words.callIt("mac.no_job_hint"), mark: .jobs)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Khayt.ground)
        }
    }
}

/// One job in the list: its name, who it is for, where it stands, when it is due.
private struct JobRow: View {
    let job: Order
    let shop: Shop

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(shop.shownTitle(of: job)).font(.body.weight(.medium)).lineLimit(1)
                Spacer(minLength: 4)
                JobPills(job: job, shop: shop, compact: true)
            }
            HStack(spacing: 6) {
                Text(job.client.isEmpty ? job.reference : job.client).lineLimit(1)
                Spacer(minLength: 4)
                if let due = JobPage.dayText(job.dueDate, words: shop.words) {
                    Text(due).monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

/// The stage pill in its tone, and the late pill beside it. One pill for the
/// stage — Paid once a handed-over job is settled — and red only for late.
struct JobPills: View {
    let job: Order
    let shop: Shop
    var compact = false

    var body: some View {
        let steps = shop.pageSteps(for: job)
        HStack(spacing: 6) {
            if let stage = Stage.of(job) {
                let paid = steps?.pill.stage == "paid"
                pill(shop.words.callIt(paid ? "mac.paid" : stage.key),
                     JobPage.tone(steps?.pill.tone, fallback: stage.dot))
            }
            if steps?.late ?? job.isOverdue() {
                pill(shop.words.callIt("mac.late"), Khayt.late)
            }
        }
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(compact ? .caption2.weight(.medium) : .caption.weight(.medium))
        }
        .padding(.horizontal, compact ? 6 : 8).padding(.vertical, compact ? 1 : 3)
        .background(color.opacity(0.14), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// One job, whole.
struct JobPage: View {
    let job: Order
    let shop: Shop
    @State private var split: TaxSplit?
    @State private var timeline: OrderTimeline?

    var body: some View {
        let steps = shop.pageSteps(for: job)
        VStack(spacing: 0) {
            // PINNED: the header and the next step never scroll away, down to
            // the smallest window (900 × 480).
            VStack(alignment: .leading, spacing: 10) {
                header
                NextStepBar(job: job, steps: steps, shop: shop)
            }
            .padding(Metric.screen)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Role.surf)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let track = steps?.track, !track.isEmpty {
                        StageTrack(nodes: track, held: Stage.of(job) == .on_hold, shop: shop)
                            .jobCard()
                    }
                    JobDetail(job: job, shop: shop, split: split, embedded: true)
                        .jobCard()
                    activity.jobCard()
                }
                .padding(Metric.screen)
            }
        }
        .task(id: job.id) { split = await shop.taxSplit(job.price) }
        .task(id: job.id + "|" + job.status) { timeline = await shop.timeline(job.id) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(shop.shownTitle(of: job))
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                    .help(job.project)
                    .lineLimit(2)
                JobPills(job: job, shop: shop)
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Text(job.reference).monospacedDigit().textSelection(.enabled)
                if !job.client.isEmpty { Text("·"); Text(job.client) }
                if let due = Self.dayText(job.dueDate, words: shop.words) {
                    Text("·")
                    Text(shop.words.callIt("queue.due", ["d": .string(due)]))
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    /// What happened to the job, newest first: each stage it reached and when.
    private var activity: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(shop.words.callIt("audit.btn"))
                .textCase(.uppercase)
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            let steps = (timeline?.steps ?? []).reversed()
            if steps.isEmpty {
                Text(shop.words.callIt("mac.nothing_here")).font(.callout).foregroundStyle(Khayt.faint)
            }
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(step.current ? Khayt.brand : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.stageWord(step.status, words: shop.words)).font(.callout)
                        if let note = step.note, !note.isEmpty {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if let when = Self.dayText(step.at, words: shop.words) {
                        Text(when).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Shared with the list and the track

    /// The rule's tone as a colour: steel waits, amber is being made, green
    /// is done, purple is held, grey is over.
    static func tone(_ tone: String?, fallback: Color) -> Color {
        switch tone {
        case "steel": Khayt.pending
        case "amber": Khayt.thread
        case "green": Khayt.done
        case "purple": Khayt.hold
        case "grey": Color.secondary
        default: fallback
        }
    }

    /// A stored day or timestamp as "14 Nov", in the shop's language; nil
    /// when there is none or it cannot be read.
    @MainActor
    static func dayText(_ stored: String?, words: Words) -> String? {
        guard let stored, !stored.isEmpty else { return nil }
        let date = Order.day(String(stored.prefix(10)))
            ?? (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(stored))
            ?? (try? Date.ISO8601FormatStyle().parse(stored))
        guard let date else { return nil }
        return words.say(date, .dateTime.day().month(.abbreviated))
    }

    /// A status as the shop reads it: the stage's own word where there is one.
    @MainActor
    static func stageWord(_ status: String, words: Words) -> String {
        if let stage = Stage(rawValue: status) { return words.callIt(stage.key) }
        return status
    }
}

/// The pinned next step: the ONE button, then what else is a click away.
///
/// Never hidden (S1 rule 2). When it cannot be done — production paused, a
/// WIP limit, a book this person may not change — it is disabled and the
/// reason is the line under it. A job with nothing left says so.
struct NextStepBar: View {
    let job: Order
    let steps: KhaytEngine.NextSteps?
    let shop: Shop

    var body: some View {
        let offered = ([steps?.primary].compactMap { $0 } + (steps?.secondary ?? []))
            .filter { Shop.stepTitleKey($0.code) != nil }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if offered.isEmpty {
                    Text(shop.words.callIt("mac.jp_nothing_next"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(offered.enumerated()), id: \.offset) { index, step in
                    let first = index == 0 && step == steps?.primary
                    let button = Button(shop.words.callIt(Shop.stepTitleKey(step.code) ?? "")) {
                        shop.takeStep(step, on: job)
                    }
                    .disabled(shop.stepRefusal(step) != nil)
                    if first {
                        button.buttonStyle(.borderedProminent).controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                    } else {
                        button.buttonStyle(.bordered).controlSize(.large)
                    }
                }
                Spacer(minLength: 0)
            }
            // Why the first step cannot be done, said at the control.
            if let first = offered.first, let why = shop.stepRefusal(first) {
                Label(why, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Where the job is on its way out of the door: done · current · to do.
///
/// A job on hold stands at the stage it was held from, in the hold colour; a
/// shipped job stands at the end, named Shipped, until it is handed over.
struct StageTrack: View {
    let nodes: [KhaytEngine.NextSteps.TrackNode]
    var held = false
    let shop: Shop

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(nodes.enumerated()), id: \.offset) { index, node in
                VStack(spacing: 5) {
                    HStack(spacing: 0) {
                        line(index == 0 ? .clear : color(nodes[index - 1], next: node))
                        dot(node)
                        line(index == nodes.count - 1 ? .clear : color(node, next: nodes[index + 1]))
                    }
                    Text(JobPage.stageWord(node.stage, words: shop.words))
                        .font(node.state == "current" ? .caption.weight(.semibold) : .caption)
                        .foregroundStyle(node.state == "todo" ? Color.secondary : Color.primary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text(JobPage.dayText(node.at, words: shop.words) ?? " ")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(JobPage.stageWord(node.stage, words: shop.words))
                .accessibilityValue(JobPage.dayText(node.at, words: shop.words) ?? "")
                .accessibilityAddTraits(node.state == "current" ? .isSelected : [])
            }
        }
    }

    private var live: Color { held ? Khayt.hold : Khayt.thread }

    /// The line between two nodes is drawn in once the work has passed it.
    private func color(_ a: KhaytEngine.NextSteps.TrackNode, next b: KhaytEngine.NextSteps.TrackNode) -> Color {
        a.state != "todo" && b.state != "todo" ? live : Color.secondary.opacity(0.25)
    }

    private func line(_ color: Color) -> some View {
        Rectangle().fill(color).frame(height: 2).frame(maxWidth: .infinity)
    }

    @ViewBuilder private func dot(_ node: KhaytEngine.NextSteps.TrackNode) -> some View {
        switch node.state {
        case "done": Circle().fill(live).frame(width: 9, height: 9)
        case "current":
            Circle().fill(live).frame(width: 13, height: 13)
                .overlay(Circle().stroke(live.opacity(0.3), lineWidth: 4))
        default: Circle().stroke(Color.secondary.opacity(0.45), lineWidth: 1.5).frame(width: 9, height: 9)
        }
    }
}

private extension View {
    /// One of the page's cards.
    func jobCard() -> some View {
        self.padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Role.surf, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
