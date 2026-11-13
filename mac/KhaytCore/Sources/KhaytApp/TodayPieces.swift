import SwiftUI
import KhaytCore

// The pieces of the Today screen (`Dashboard.swift`).
//
// Everything here is drawing. Every figure it draws is handed in by the caller,
// from the same sources the dashboard has always used.

/// A job's stage, as the Today screen colours it.
///
/// The dot and the 14% tint carry the colour; the LABEL is always primary ink,
/// because a coloured word on a tint of itself fails contrast in half the
/// palette.
enum TodayStage {
    case printing, pending, quote, hold, collect, late, done, unpaid

    var color: Color {
        switch self {
        case .printing: Khayt.thread
        case .pending, .quote: Khayt.note
        case .hold: Khayt.hold
        case .collect: Khayt.collect
        case .late: Khayt.late
        case .done: Khayt.done
        case .unpaid: Khayt.attention
        }
    }
}

/// A capsule: the stage colour's tint, a dot in the stage colour, the label in
/// primary ink.
struct StatusPill: View {
    let label: String
    let stage: TodayStage
    var alive = false
    /// A job stage's own colour (`Stage.dot`), over the Today family's.
    var tint: Color? = nil

    private var color: Color { tint ?? stage.color }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
                .alive(alive)
            Text(verbatim: label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9).padding(.vertical, 3)
        // The thread has a wash of its own (the design's #FDF1DE / #3A2C14):
        // amber at 14% on a white card is not a pill at all.
        .background(color == Khayt.thread ? AnyShapeStyle(Khayt.threadWash)
                                          : AnyShapeStyle(color.opacity(0.14)), in: Capsule())
        .fixedSize()
    }
}

extension Stage {
    /// The redesign's colour for each stage, as the Board's column dots and
    /// the Jobs table's pills draw it: one per stage family.
    var dot: Color {
        switch self {
        case .quote, .pending: Khayt.note
        case .on_hold, .post, .qc: Khayt.hold
        case .printing: Khayt.thread
        case .completed: Khayt.collect
        case .shipped, .delivered: Khayt.done
        case .cancelled: Khayt.late
        }
    }
}

/// The small mono caps line that opens the header and every section: a thread
/// dash, then the words. The dash is a graphic and never text.
struct TodayEyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Khayt.thread).frame(width: 24, height: 2)
            Text(verbatim: text)
                .font(TypeScale.eyebrow(11))
                .textCase(.uppercase).tracking(Words.spaced(1.0))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// A section of the Today screen. Takes the arguments `DetailSection` takes so
/// the sections that were written for it did not have to change; the colour
/// arguments are accepted and ignored, because a header is now always the same
/// eyebrow and what is wrong is said by the rows.
struct TodaySection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, accent: Color? = nil, symbol: String? = nil,
         lead: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.title = title; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TodayEyebrow(title)
            content
        }
    }
}

extension View {
    /// The Today card: rounded 14, the surface colour, a hairline.
    func todayCard(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .background(Khayt.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Khayt.hairline, lineWidth: 1))
    }
}

/// One of the four figures across the top.
struct TodayStatCard: View {
    let label: String
    let value: String
    var detail: String?
    var detailColor: Color = Color.secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: label)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                .lineLimit(1)
            Text(verbatim: value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(.primary)
                .lineLimit(1).minimumScaleFactor(0.6)
            // Reserved even when empty so the four cards stay one height.
            Text(verbatim: detail ?? " ")
                .font(.system(size: 12)).foregroundStyle(detailColor)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .todayCard()
        .accessibilityElement(children: .combine)
    }
}

/// A 36 pt rounded tile holding a symbol on the wash of its own colour.
struct TodayTile: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A progress bar: amber thread on a recessed track. Amber means progress.
struct ThreadBar: View {
    let progress: Double

    var body: some View {
        Capsule().fill(Khayt.recessed)
            .frame(height: 6)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule().fill(Khayt.thread)
                        .frame(width: geo.size.width * min(1, max(0, progress)))
                        .growsToItsReading(progress, from: .leading)
                }
            }
            .accessibilityHidden(true)
    }
}

extension Color {
    /// `#RRGGBB` as the shop typed it for a loaded spool; nil when it is not one.
    init?(todayHex raw: String?) {
        guard var hex = raw?.trimmingCharacters(in: .whitespaces), !hex.isEmpty else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let v = Int(hex, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}

/// The jobs due in the next seven days, worked out once per draw of the screen.
@MainActor
struct TodayDue {
    let week: [Order]
    let today: Int

    /// Stages a job is no longer due in. `shipped` and `delivered` are date
    /// stamps on a completed job, but an older book can carry them as the status.
    static let closed: Set<String> = ["completed", "shipped", "delivered", "cancelled"]

    /// Open jobs only: a finished, cancelled or voided one is not due.
    init(shop: Shop, now: Date = Date()) {
        let cal = Calendar.book
        let start = cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: 7, to: start) ?? start
        var picked: [(Date, Order)] = []
        var dueToday = 0
        for order in shop.orders {
            guard !Self.closed.contains(order.status), !order.voided,
                  let due = Order.day(order.dueDate), due >= start, due < end,
                  shop.inSite(order) else { continue }
            picked.append((due, order))
            if due == start, order.status != "quote" { dueToday += 1 }
        }
        week = picked.sorted { $0.0 < $1.0 }.map(\.1)
        today = dueToday
    }
}

/// The right-hand column's list.
struct DueThisWeek: View {
    let shop: Shop
    let due: TodayDue

    private static let most = 8

    var body: some View {
        let shown = due.week.prefix(Self.most)
        TodaySection(shop.words.callIt("mac.due_this_week")) {
            if due.week.isEmpty {
                Text(shop.words.callIt("mac.due_none"))
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .todayCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(shown) { order in
                        Row(order: order, shop: shop)
                        if order.id != shown.last?.id || due.week.count > Self.most { LayerRule() }
                    }
                    if due.week.count > Self.most {
                        Text(shop.words.callIt("mac.attn_more",
                                               ["n": .number(Double(due.week.count - Self.most))]))
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                }
                .todayCard(padding: 12)
            }
        }
    }

    private struct Row: View {
        let order: Order
        let shop: Shop

        private var date: Date? { Order.day(order.dueDate) }
        private var isToday: Bool { date.map { Calendar.book.isDateInToday($0) } ?? false }

        private var stage: (TodayStage, String) {
            let w = shop.words
            if order.isLateResolved == true { return (.late, w.callIt("mac.late_tile")) }
            switch order.status {
            case "printing": return (.printing, w.callIt("queue.printing"))
            case "quote": return (.quote, w.callIt("queue.quote"))
            case "on_hold": return (.hold, w.callIt("queue.on_hold"))
            case "post": return (.pending, w.callIt("queue.post"))
            case "qc": return (.pending, w.callIt("queue.qc"))
            default: return (.pending, w.callIt("queue.pending"))
            }
        }

        var body: some View {
            HStack(spacing: 10) {
                chip
                VStack(alignment: .leading, spacing: 2) {
                    Text(order.project.isEmpty ? order.reference : order.project)
                        .font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(order.client).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(verbatim: Money.short(order.price, order.currency))
                        .font(.system(size: 13, weight: .medium)).monospacedDigit()
                    StatusPill(label: stage.1, stage: stage.0, alive: stage.0 == .printing)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                shop.shelf = .jobs(nil)
                shop.selection = order.id
            }
        }

        private var chip: some View {
            let words = shop.words
            return VStack(spacing: 1) {
                if isToday {
                    Text(words.callIt("mac.today_chip"))
                } else if let date {
                    Text(words.say(date, .dateTime.weekday(.abbreviated)))
                    Text(words.say(date, .dateTime.day()))
                }
            }
            .font(TypeScale.eyebrow(10))
            .textCase(.uppercase).foregroundStyle(.primary)
            .frame(width: 46, height: 36)
            .background(isToday ? Khayt.threadWash : Khayt.recessed,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

/// One card per machine on the floor: what it is doing, for whom, how far.
struct MachineCards: View {
    let shop: Shop

    /// The printing job of each machine, built once for the draw.
    private static func printingJobs(_ shop: Shop) -> [String: Order] {
        var jobs: [String: Order] = [:]
        for order in shop.orders where order.status == "printing" {
            if let id = order.machineId, jobs[id] == nil { jobs[id] = order }
        }
        return jobs
    }

    var body: some View {
        let machines = shop.siteMachinesInUse
        if !machines.isEmpty {
            let jobs = Self.printingJobs(shop)
            TodaySection(shop.words.callIt("mac.on_machines")) {
                // A plain stack, not a grid: an adaptive grid inside this
                // screen's ScrollView is a sizing loop.
                VStack(spacing: 10) {
                    ForEach(machines) { machine in
                        Card(machine: machine, job: jobs[machine.id], shop: shop)
                    }
                }
            }
        }
    }

    private struct Card: View {
        let machine: Machine
        let job: Order?
        let shop: Shop
        @State private var hovering = false

        private var status: KhaytEngine.PrinterStatus? { shop.printers.readings[machine.id]?.status }
        private var printing: Bool { PrinterWatch.isPrinting(status?.state ?? "") }

        var body: some View {
            let words = shop.words
            let quiet = shop.quiet(machine)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(machine.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    pill(quiet)
                    Spacer(minLength: 8)
                    dots
                }
                if printing, let status {
                    Text(detailLine(status))
                        .font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 10) {
                        ThreadBar(progress: Double(status.progress) / 100)
                        Text(verbatim: words.numeral(status.progress) + "%")
                            .font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                            .contentTransition(.numericText())
                        if let left = status.timeRemaining, left > 0 {
                            Text(words.callIt("mac.eta") + " " + PrinterWatch.spell(left, words))
                                .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                } else if let line = quietLine(quiet) {
                    // Why it is quiet, in the one rule's words (`Shop.quiet`) —
                    // but not the pill's word again: "Under service" sat in the
                    // pill and on the line below it (beta.19). Under service
                    // says the shop's own reason instead, when it gave one.
                    Text(line)
                        .font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .todayCard(padding: 14)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(hovering ? Khayt.brand.opacity(0.35) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { shop.shelf = .machines }
            .help(machine.name)
        }

        /// The line under a quiet machine's name, or nil when the pill has
        /// already said all there is.
        private func quietLine(_ quiet: Shop.Quiet) -> String? {
            let words = shop.words
            switch quiet {
            case .underService:
                return machine.underServiceReason
            case .idle, .notAnswering:
                return nil
            case .noProtocol:
                return words.callIt("mac.cannot_ask")
            default:
                return words.callIt(quiet.wordKey)
            }
        }

        @ViewBuilder private func pill(_ quiet: Shop.Quiet) -> some View {
            let words = shop.words
            if printing {
                StatusPill(label: words.callIt("queue.printing"), stage: .printing, alive: true)
            } else {
                switch quiet {
                case .idle: StatusPill(label: words.callIt("mac.idle"), stage: .pending)
                case .notAnswering: StatusPill(label: words.callIt(quiet.wordKey), stage: .late)
                case .underService: StatusPill(label: words.callIt(quiet.wordKey), stage: .hold)
                default: EmptyView()
                }
            }
        }

        /// The job and its customer; the file name when the book has no job.
        private func detailLine(_ status: KhaytEngine.PrinterStatus) -> String {
            if let job {
                let name = job.project.isEmpty ? job.reference : job.project
                return job.client.isEmpty ? name : name + " · " + job.client
            }
            return status.filename.isEmpty ? shop.words.callIt("mac.live") : status.filename
        }

        /// The colours the shop says are loaded.
        private var dots: some View {
            HStack(spacing: 4) {
                ForEach(Array((machine.loaded ?? []).enumerated()), id: \.offset) { _, slot in
                    if let color = Color(todayHex: slot.hex) {
                        Circle().fill(color).frame(width: 12, height: 12)
                            .overlay(Circle().strokeBorder(Khayt.hairline, lineWidth: 1))
                            .help(slot.material ?? "")
                    }
                }
            }
        }
    }
}
