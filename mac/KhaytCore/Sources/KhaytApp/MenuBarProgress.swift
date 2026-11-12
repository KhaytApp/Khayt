import AppKit
import SwiftUI
import KhaytCore

/// What the menu bar item says about the floor: the ring, the figures, the
/// attention mark, and the order the fleet is listed in when it is opened.
///
/// ── ONE READING, NOT A SECOND POLLER ──────────────────────────────────────
///
/// Everything here is read off what the shop already holds — the poller's
/// readings (`PrinterWatch.heard`, the same grace the band and Next up give a
/// printer that missed a poll), `Shop.quiet` for why a machine is not
/// printing, and the dispatcher's own "bed not cleared since its last print"
/// (`lib/auto-dispatch.js`). Nothing in this file asks a printer anything, and
/// it is evaluated on the status item's existing 5 s tick and when the panel is
/// opened — never faster.
///
/// ── WHY THE RULES ARE PURE ────────────────────────────────────────────────
///
/// The status item is AppKit and its label cannot be looked at by a test. So
/// the decisions — which job leads, what the label says, which machine is
/// listed first — are functions of plain values, and `MenuBarProgressTests`
/// holds them.

/// What the status item shows. Mac-local, beside `mac.menuBar`.
enum MenuBarStyle: String, CaseIterable, Sendable {
    case ringAndFigures = "ringFigures"
    case ringOnly = "ring"
    case glyphOnly = "glyph"

    static let defaultsKey = "mac.menuBarStyle"

    /// Read straight from defaults, as `FloorStatus.wanted` is: AppKit, no view
    /// to invalidate.
    static var current: MenuBarStyle {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(MenuBarStyle.init(rawValue:)) ?? .ringAndFigures
    }

    var wordKey: String {
        switch self {
        case .ringAndFigures: "mac.mbp_style_ring_figures"
        case .ringOnly: "mac.mbp_style_ring"
        case .glyphOnly: "mac.mbp_style_glyph"
        }
    }
}

/// Why a machine wants a person to walk over.
enum FloorAttention: String, Sendable, Equatable {
    /// The printer reports a fault — the words `printer-alerts` calls an error
    /// (error, fault, halt, attention) plus a Bambu's FAILED.
    case fault
    /// Held part-way: somebody pressed Pause, or the firmware did.
    case paused
    /// The printing head has no filament (`filamentOut == true`). Wins over
    /// `paused`, because it says what to fetch.
    case runout
    /// Idle with the last print still on the plate: the dispatcher's
    /// `ad.bed_not_clear`.
    case bedNotClear

    var wordKey: String {
        switch self {
        case .fault: "mac.mbp_attn_fault"
        case .paused: "mac.mbp_attn_paused"
        case .runout: "mac.mbp_attn_runout"
        case .bedNotClear: "mac.mbp_attn_bed"
        }
    }
}

/// One machine, as the menu bar sees it.
struct FloorLine: Identifiable, Equatable, Sendable {
    /// The popover's order: problems first, then work in progress, then the
    /// quiet ones, and the ones that cannot be reached last.
    enum Rank: Int, Comparable, Sendable {
        case attention, printing, idle, offline
        static func < (a: Rank, b: Rank) -> Bool { a.rawValue < b.rawValue }
    }

    let id: String
    let name: String
    let rank: Rank
    let attention: FloorAttention?
    /// Laying plastic right now (`PrinterWatch.isPrinting`) — true for a print
    /// that is running out of filament too, which is still running.
    let printing: Bool
    /// 0...100, clamped: a printer reporting 5000 is not 5000% done.
    let progress: Int
    /// Seconds, only when the printer said and it is more than nothing.
    let left: Double?
    let filename: String
    /// Why it is not printing, for a quiet line (`Shop.Quiet`).
    let quiet: Shop.Quiet?

    // ── WHAT THE HERO CARD ADDED ──────────────────────────────────────────
    //
    // Each one nil or empty when nobody said, and each with a default, so a
    // line built the old way is still a line.

    /// "Layer 212 of 330", when the printer reports both.
    var layer: Int? = nil
    var totalLayers: Int? = nil
    /// What is loaded, head by head, as hex colours, when the printer says.
    var loaded: [String] = []
    /// When the reading these figures came from was TAKEN. A missed poll
    /// rewrites `Reading.at`, so this is worked back to the last poll that
    /// answered (`FloorRead.lines`); the time left counts down from here.
    var readAt: Date? = nil
    /// When this machine's last print ended, as this run of the app saw it at
    /// the finish seam (`Shop.printFinished`). Nil for a machine that has not
    /// ended a print since the app opened.
    var endedAt: Date? = nil
    /// That print FINISHED (not failed, not cancelled), the machine is not in
    /// another job, and nobody has said the plate is clear since.
    var finished: Bool = false

    /// In a job right now, running or held: printing, paused, out of filament,
    /// or stopped by a fault part-way through. These are the lines the hero
    /// card is chosen from.
    var midPrint: Bool {
        if printing { return true }
        switch attention {
        case .paused, .runout: return true
        case .fault: return progress > 0 && progress < 100
        case .bedNotClear, nil: return false
        }
    }

    /// Finished and still on the plate: the finish seam said so, or the
    /// dispatcher did (`ad.bed_not_clear`).
    var isFinished: Bool { finished || attention == .bedNotClear }
}

@MainActor
enum FloorRead {

    // MARK: - States

    static func isPaused(_ state: String) -> Bool {
        ["paused", "pausing"].contains(state.lowercased())
    }

    /// `printer-alerts.isErrorState`'s words, and `print-finish-photo`'s
    /// FAILED: a Bambu that failed a print says `FAILED`, not error.
    static func isFault(_ state: String) -> Bool {
        let s = state.lowercased()
        return ["error", "fault", "halt", "attention", "fail"].contains { s.contains($0) }
    }

    /// What, if anything, this machine wants a person for.
    static func attention(_ status: KhaytEngine.PrinterStatus?, bedNotClear: Bool) -> FloorAttention? {
        if let status {
            let inJob = PrinterWatch.isPrinting(status.state) || isPaused(status.state)
            if inJob, status.filamentOut == true { return .runout }
            if isPaused(status.state) { return .paused }
            if isFault(status.state) { return .fault }
            if inJob { return nil }
        }
        // Only a machine that is not mid-job, and only one that answered: a
        // stale "bed not clear" about a printer now running must not win.
        return bedNotClear && status != nil ? .bedNotClear : nil
    }

    static func line(id: String, name: String, status: KhaytEngine.PrinterStatus?,
                     quiet: Shop.Quiet?, bedNotClear: Bool,
                     readAt: Date? = nil, ended: (at: Date, finished: Bool)? = nil,
                     bedClearedAt: Date? = nil) -> FloorLine {
        let attention = attention(status, bedNotClear: bedNotClear)
        let printing = status.map { PrinterWatch.isPrinting($0.state) } ?? false
        let rank: FloorLine.Rank
        if attention != nil { rank = .attention }
        else if printing { rank = .printing }
        else if status == nil, quiet == .notAnswering || quiet == .underService { rank = .offline }
        else { rank = .idle }
        let left = status?.timeRemaining.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        var line = FloorLine(id: id, name: name, rank: rank, attention: attention, printing: printing,
                             progress: min(100, max(0, status?.progress ?? 0)),
                             left: printing ? left : nil,
                             filename: status?.filename ?? "", quiet: status == nil ? quiet : nil)
        if let layers = status?.layers { line.layer = layers.current; line.totalLayers = layers.total }
        line.loaded = (status?.loaded ?? []).sorted { $0.slot < $1.slot }.map(\.hex)
        line.readAt = status == nil ? nil : readAt
        line.endedAt = ended?.at
        // Finished only while it is true: not once the machine is in another
        // job, not for a machine that stopped answering, and not after
        // somebody said the plate is clear.
        if let ended, ended.finished, status != nil, !line.midPrint {
            line.finished = bedClearedAt.map { $0 < ended.at } ?? true
        }
        return line
    }

    /// Attention, printing (soonest finish first; a print that does not say
    /// how long goes after those that do, the furthest along first), idle (a
    /// finished plate before an empty one), offline. Ties keep the book's
    /// order — the order the shop put its machines in.
    static func sorted(_ lines: [FloorLine]) -> [FloorLine] {
        lines.enumerated().sorted { a, b in
            if a.element.rank != b.element.rank { return a.element.rank < b.element.rank }
            if a.element.rank == .printing {
                switch (a.element.left, b.element.left) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil) where a.element.progress != b.element.progress:
                    return a.element.progress > b.element.progress
                default: break
                }
            }
            if a.element.rank == .idle, a.element.finished != b.element.finished { return a.element.finished }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// The machines on the floor, sorted. Retired ones are not on it.
    @MainActor
    static func lines(_ shop: Shop) -> [FloorLine] {
        let bed = Set((shop.dispatch?.waiting ?? []).filter { $0.blocked == "ad.bed_not_clear" }.map(\.machineId))
        return sorted(shop.machinesInUse.map { machine in
            let status = shop.printers.heard(machine.id)
            let ended = shop.lastPrintEndedAt[machine.id].map {
                (at: $0, finished: shop.lastPrintEnded[machine.id]?.outcome == "finished")
            }
            return line(id: machine.id, name: machine.name, status: status,
                        quiet: status == nil ? shop.quiet(machine) : nil,
                        bedNotClear: bed.contains(machine.id),
                        readAt: shop.printers.readings[machine.id].map(goodAt),
                        ended: ended, bedClearedAt: shop.bedClearedAt(machine.id))
        })
    }

    /// When the status a reading carries was really taken. A failed poll
    /// writes a new `at` and carries the last good status along, so the status
    /// is older than `at` by one poll interval for every miss.
    static func goodAt(_ reading: PrinterWatch.Reading) -> Date {
        reading.at.addingTimeInterval(-Double(reading.consecutiveFailures) * pollEvery)
    }

    /// `PrinterWatch.every`, in seconds.
    static var pollEvery: TimeInterval {
        let c = PrinterWatch.every.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }

    // MARK: - The time left, between readings

    /// The time left NOW, and whether that is a reading or an estimate.
    struct LeftNow: Equatable, Sendable {
        var seconds: Double
        var estimate: Bool
    }

    /// A reading older than this is an estimate.
    ///
    /// TWO POLL INTERVALS. The poller asks every ten seconds
    /// (`PrinterWatch.every`), so a healthy printer's reading is at most ten
    /// seconds old plus the moment the sweep takes to reach it. Past twenty
    /// seconds at least one poll was missed or failed, and the figure on the
    /// card is this Mac's own subtraction rather than something the printer
    /// said recently. It keeps counting until `PrinterWatch.heard` gives the
    /// printer up (three misses), when the line stops being a print at all.
    static var estimateAfter: TimeInterval { 2 * pollEvery }

    /// Count the last reading's time left down to now. NO PRINTER IS ASKED:
    /// the panel is drawn between polls from the reading it already has.
    /// Never below zero, and a clock that reads earlier than the reading (a
    /// time change) counts as no time passed rather than adding any.
    static func leftNow(left: Double, readAt: Date?, now: Date) -> LeftNow {
        guard let readAt else { return LeftNow(seconds: max(0, left), estimate: false) }
        let age = max(0, now.timeIntervalSince(readAt))
        return LeftNow(seconds: max(0, left - age), estimate: age > estimateAfter)
    }

    // MARK: - The hero

    /// The line the panel's large card is given, or nil when no machine is in
    /// a job (the empty state takes its place).
    ///
    /// Among the lines that are mid-print: the ones PRINTING and saying how
    /// long, soonest finish first; then every other one (a print that does not
    /// say how long, and a print that is paused, out of filament or stopped by
    /// a fault, which has no finish to wait for) by highest progress. Ties
    /// keep the book's order. A stopped print is eligible like any other, and
    /// its card leads with the action that resolves it.
    static func hero(_ lines: [FloorLine]) -> FloorLine? {
        asRunning(lines.filter(\.midPrint)).first.flatMap { first in lines.first { $0.id == first.id } }
    }

    /// Ranked as printing whatever their attention, so a runout mid-print is
    /// still ordered by when it finishes.
    private static func asRunning(_ lines: [FloorLine]) -> [FloorLine] {
        sorted(lines.map {
            var line = FloorLine(id: $0.id, name: $0.name, rank: .printing, attention: $0.attention,
                                 printing: $0.printing, progress: $0.progress, left: $0.left,
                                 filename: $0.filename, quiet: nil)
            line.readAt = $0.readAt
            return line
        })
    }

    // MARK: - The finish moment

    /// How long a finished print's card holds its green wash in the open
    /// panel before it settles to an ordinary "Finished" row.
    static let cardHold: TimeInterval = 6
    /// How long the status item shows the ring with a tick. Longer than the
    /// card: the item is redrawn on a five-second tick and glanced at, not
    /// watched.
    static let iconHold: TimeInterval = 30

    /// Which machines have just finished, and until when each holds its green.
    ///
    /// NOT A SECOND EDGE DETECTOR. What "finished" means is decided once, at
    /// the finish seam (`Shop.printFinished`), and reaches a line as
    /// `finished`. This only notices a line TURNING finished between two looks
    /// at the floor, so a machine that was already finished when the panel
    /// opened, or one seen for the first time, is not a moment.
    static func justFinished(previous: [FloorLine], current: [FloorLine], now: Date) -> [String: Date] {
        let was = Dictionary(previous.map { ($0.id, $0.finished) }, uniquingKeysWith: { a, _ in a })
        var out: [String: Date] = [:]
        for line in current where line.finished && was[line.id] == false {
            out[line.id] = now.addingTimeInterval(cardHold)
        }
        return out
    }

    // MARK: - The label

    /// What the status item draws: a ring (nil = the nozzle), the text beside
    /// it, and whether to mark it for attention.
    struct Label: Equatable, Sendable {
        var ring: Double?
        var text: String
        var attention: Bool
        /// A print has just finished: the ring is closed with a tick in it.
        var tick: Bool = false
    }

    /// The job the label leads with: the print that finishes soonest, and how
    /// many others are running beside it.
    static func lead(_ lines: [FloorLine]) -> (line: FloorLine, others: Int)? {
        let running = asRunning(lines.filter(\.printing))
        guard let first = running.first else { return nil }
        return (first, running.count - 1)
    }

    /// What the status item draws.
    ///
    /// - nothing printing: the nozzle;
    /// - one print: its ring and "64%";
    /// - two or more: the ring of the one finishing soonest and HOW MANY are
    ///   printing ("2"). It used to read "64% · 1h 02m +2", which is three
    ///   figures in a menu bar and pushed other items off a small screen; the
    ///   time is one click away, said twice, in the panel;
    /// - a print finished less than `iconHold` ago (`tickUntil`): a closed
    ///   ring with a tick, then back to whichever of the above is true;
    /// - a machine wants somebody: the mark, in every state and style.
    ///
    /// `now` is handed in, never read here, so the expiry can be tested.
    @MainActor
    static func label(_ lines: [FloorLine], style: MenuBarStyle, words: Words,
                      tickUntil: Date? = nil, now: Date = .distantPast) -> Label {
        let attention = lines.contains { $0.attention != nil }
        guard style != .glyphOnly else { return Label(ring: nil, text: "", attention: attention) }
        if let tickUntil, now < tickUntil {
            return Label(ring: 1, text: "", attention: attention, tick: true)
        }
        guard let lead = lead(lines) else { return Label(ring: nil, text: "", attention: attention) }
        let ring = Double(lead.line.progress) / 100
        guard style == .ringAndFigures else { return Label(ring: ring, text: "", attention: attention) }
        let text = lead.others > 0
            ? words.numeral(lead.others + 1)
            : words.callIt("mac.mbp_pct", ["pct": .string(words.numeral(lead.line.progress))])
        return Label(ring: ring, text: text, attention: attention)
    }

    /// "64% · 1h 02m", or "64%" when the printer does not say how long.
    @MainActor
    static func figures(progress: Int, left: Double?, words: Words) -> String {
        let pct = words.numeral(progress)
        guard let left else { return words.callIt("mac.mbp_pct", ["pct": .string(pct)]) }
        return words.callIt("mac.mbp_figures", ["pct": .string(pct), "left": .string(duration(left, words))])
    }

    /// `1h 02m` — minutes padded so the width does not jump at 1h 9m → 1h 10m —
    /// `14m`, or under a minute. In the shop's numerals.
    @MainActor
    static func duration(_ seconds: Double, _ words: Words) -> String {
        let total = Int(saturating: seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60
        if hours > 0 {
            let m = minutes.formatted(.number.locale(words.locale).grouping(.never)
                .precision(.integerLength(2...)))
            return words.callIt("mac.mbp_hm", ["h": .string(words.numeral(hours)), "m": .string(m)])
        }
        if minutes > 0 { return words.callIt("mac.mbp_m", ["m": .string(words.numeral(minutes))]) }
        return words.callIt("mac.dur_under_1m")
    }

    /// The clock time a print finishes, in the book's calendar and this Mac's
    /// time zone (`Words.say` pins `Calendar.book`). The weekday is added only
    /// when it is not today.
    @MainActor
    static func finishes(_ left: Double, now: Date, words: Words) -> String {
        let at = now.addingTimeInterval(left)
        let sameDay = Calendar.book.isDate(at, inSameDayAs: now)
        let time = sameDay ? words.say(at, .dateTime.hour().minute())
                           : words.say(at, .dateTime.weekday(.abbreviated).hour().minute())
        return words.callIt("mac.mbp_done_at", ["time": .string(time)])
    }

    // MARK: - What the panel says

    /// "2 printing · next free 4:35 pm", or "Nothing on the beds". From the
    /// lines, so the header and the cards under it cannot disagree.
    @MainActor
    static func headline(_ lines: [FloorLine], now: Date, words: Words) -> String {
        let running = lines.filter(\.printing)
        guard !running.isEmpty else {
            // A print held part-way is not "nothing on the beds": say what
            // holds it, in the words its card uses.
            if let held = hero(lines)?.attention { return words.callIt(held.wordKey) }
            return words.callIt("mac.nothing_printing")
        }
        let count = words.counting(running.count, "mac.printing_count")
        let soonest = running.compactMap { line in
            line.left.map { leftNow(left: $0, readAt: line.readAt, now: now).seconds }
        }.min()
        guard let soonest else { return count }
        let at = now.addingTimeInterval(soonest)
        let time = Calendar.book.isDate(at, inSameDayAs: now)
            ? words.say(at, .dateTime.hour().minute())
            : words.say(at, .dateTime.weekday(.abbreviated).hour().minute())
        return count + " · " + words.callIt("mac.mbh_next_free_at", ["time": .string(time)])
    }

    /// "1h 12m left", or "about 1h 12m left" when the reading is old.
    @MainActor
    static func leftPhrase(_ left: LeftNow, words: Words) -> String {
        words.callIt(left.estimate ? "mac.mbh_left_est" : "mac.mbp_left",
                     ["left": .string(duration(left.seconds, words))])
    }

    /// What VoiceOver reads for one machine, as ONE sentence: "Snapmaker U1,
    /// printing Drone arm v4, 64 percent, 1 hour 12 minutes left, done at
    /// 4:35 pm". The card is a ring, three sizes of text and a row of dots;
    /// read piece by piece that is nine stops for one fact.
    @MainActor
    static func spoken(_ line: FloorLine, job: String, now: Date, words: Words) -> String {
        var parts = [line.name]
        if let attention = line.attention, attention != .bedNotClear {
            parts.append(words.callIt(attention.wordKey))
            if !job.isEmpty { parts.append(job) }
        } else if line.printing {
            parts.append(job.isEmpty ? words.callIt("mac.printing")
                                     : words.callIt("mac.mbh_vo_printing", ["job": .string(job)]))
        } else if line.isFinished {
            parts.append(words.callIt("mac.mbh_finished"))
            if !job.isEmpty { parts.append(job) }
        } else {
            parts.append(words.callIt("mac.idle"))
        }
        if line.midPrint {
            parts.append(words.callIt("mac.mbh_vo_percent", ["pct": .string(words.numeral(line.progress))]))
        }
        if line.printing, let left = line.left {
            let live = leftNow(left: left, readAt: line.readAt, now: now)
            let long = live.seconds < 60
                ? words.callIt("mac.dur_under_1m")
                : Duration.seconds(Int(live.seconds)).formatted(
                    .units(allowed: [.hours, .minutes], width: .wide).locale(words.locale))
            parts.append(words.callIt(live.estimate ? "mac.mbh_left_est" : "mac.mbp_left", ["left": .string(long)]))
            parts.append(finishes(live.seconds, now: now, words: words))
        }
        return parts.joined(separator: words.language == "ar" ? "، " : ", ")
    }

    // MARK: - What could start

    /// The job the empty panel offers: "Next up: Turbine bracket, due today."
    struct NextJob: Equatable, Sendable {
        enum Due: Equatable, Sendable { case none, today, on(Date) }
        let id: String
        let name: String
        let due: Due
    }

    /// The dispatcher's first proposal when it has one (`Shop.dispatch`, the
    /// plan "Next up" on the Machines screen already shows); otherwise the
    /// waiting job (pending or queued) due soonest, one with no due date after
    /// those that have one, ties in the book's order. Nil when nothing waits.
    static func nextUp(_ orders: [Order], proposed: [String], today: Date) -> NextJob? {
        func job(_ order: Order) -> NextJob {
            let day = Order.day(order.dueDate)
            let due: NextJob.Due = day.map { Calendar.book.isDate($0, inSameDayAs: today) ? .today : .on($0) } ?? .none
            return NextJob(id: order.id, name: order.project.isEmpty ? order.id : order.project, due: due)
        }
        let waiting = orders.filter { $0.status == "pending" || $0.status == "queued" }
        for id in proposed {
            if let order = waiting.first(where: { $0.id == id }) { return job(order) }
        }
        return waiting.enumerated().min { a, b in
            switch (Order.day(a.element.dueDate), Order.day(b.element.dueDate)) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map { job($0.element) }
    }

    @MainActor
    static func nextUpLine(_ next: NextJob, words: Words) -> String {
        let name = JSONValue.string(Figure.isolated(next.name))
        switch next.due {
        case .none: return words.callIt("mac.mbh_next_up", ["job": name])
        case .today: return words.callIt("mac.mbh_next_up_today", ["job": name])
        case .on(let day):
            return words.callIt("mac.mbh_next_up_due",
                                ["job": name, "date": .string(words.say(day, .dateTime.day().month(.abbreviated)))])
        }
    }

    // MARK: - Which job

    /// The job each running or held print belongs to, by the rule the finish
    /// photo already uses (`print-finish-photo.jobFor`): only when the book
    /// names it without guessing. Nothing at all for somebody who may not see
    /// jobs, or while nobody is signed in (`goToKinds`).
    @MainActor
    static func jobs(_ shop: Shop, lines: [FloorLine]) async -> [String: Order] {
        guard shop.goToKinds.contains(.job), let engine = shop.engine else { return [:] }
        var out: [String: Order] = [:]
        for line in lines where line.printing || line.attention == .paused || line.attention == .runout {
            guard let id = (try? await engine.printFinishJob(printLog: shop.orderRows, machineId: line.id,
                                                             filename: line.filename)) ?? nil,
                  let order = shop.orders.first(where: { $0.id == id }) else { continue }
            out[line.id] = order
        }
        return out
    }

    /// "ORD-01024 · Museum replica · Najd Architects" — the customer only for
    /// somebody who may see customers, and never an erased one.
    @MainActor
    static func jobLine(_ order: Order, shop: Shop) -> String {
        var parts = [order.id]
        if !order.project.isEmpty { parts.append(order.project) }
        if shop.goToKinds.contains(.customer), !order.clientErased, !order.client.isEmpty {
            parts.append(order.client)
        }
        return parts.map(Figure.isolated).joined(separator: " · ")
    }
}

/// The status item's picture, drawn as a TEMPLATE image.
///
/// Apple's HIG (The menu bar ▸ Menu bar extras): "Both interface icons and
/// symbols use black and clear colors to define their shapes; the system can
/// apply other colors to the black areas in each image so it looks good on both
/// dark and light menu bars, and when your menu bar extra is selected." And
/// `NSImage.isTemplate`: template images "should consist of only black and
/// clear colors", with alpha allowed. Neither offers a coloured accent, so the
/// attention mark is a SHAPE — a solid dot cut out of the glyph's corner — not
/// a colour. It follows the light, dark and tinted menu bars like the rest.
@MainActor
enum StatusGlyph {
    static let size = NSSize(width: 18, height: 18)

    /// Every picture the item has drawn, kept. A ring comes in whole percents
    /// (`FloorRead.label` divides an `Int`), so there are at most a hundred and
    /// one rings, each with or without the mark, the tick and the nozzle: a
    /// few hundred 18-point drawings at the very most, and in practice the
    /// handful a print passes through. The item's redraw is then a dictionary
    /// lookup, and the same picture is the same object.
    private static var drawn: [Key: NSImage] = [:]
    private struct Key: Hashable { let ring: Int?; let attention: Bool; let tick: Bool }

    static func image(ring: Double?, attention: Bool, tick: Bool = false) -> NSImage {
        let key = Key(ring: ring.map { Int((min(1, max(0, $0)) * 100).rounded()) }, attention: attention, tick: tick)
        if let had = drawn[key] { return had }
        let image = draw(ring: key.ring.map { Double($0) / 100 }, attention: attention, tick: tick)
        drawn[key] = image
        return image
    }

    private static func draw(ring: Double?, attention: Bool, tick: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            if let ring {
                let centre = CGPoint(x: rect.midX, y: rect.midY)
                let radius: CGFloat = 6.4
                ctx.setLineWidth(2.2)
                // The track, faint; then the done part, solid, from twelve
                // o'clock clockwise (flipped: y runs down, so clockwise is +).
                ctx.setAlpha(0.3)
                ctx.addArc(center: centre, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
                ctx.strokePath()
                ctx.setAlpha(1)
                let done = min(1, max(0, ring))
                if done > 0 {
                    ctx.setLineCap(.round)
                    ctx.addArc(center: centre, radius: radius, startAngle: -.pi / 2,
                               endAngle: -.pi / 2 + .pi * 2 * done, clockwise: false)
                    ctx.strokePath()
                }
                if tick {
                    // Just finished: a tick inside the closed ring. A shape,
                    // like the attention mark, because a template has no green.
                    ctx.setLineWidth(1.7)
                    ctx.setLineCap(.round)
                    ctx.setLineJoin(.round)
                    ctx.move(to: CGPoint(x: centre.x - 2.9, y: centre.y + 0.2))
                    ctx.addLine(to: CGPoint(x: centre.x - 0.8, y: centre.y + 2.4))
                    ctx.addLine(to: CGPoint(x: centre.x + 3.0, y: centre.y - 2.2))
                    ctx.strokePath()
                }
            } else {
                // The app's own nozzle, as it always was.
                let path = NozzleShape().path(in: CGRect(x: 3.5, y: 1.5, width: 11, height: 15)).cgPath
                ctx.setLineWidth(1.5)
                ctx.setLineJoin(.round)
                ctx.addPath(path)
                ctx.strokePath()
            }
            if attention {
                let dot = CGPoint(x: rect.maxX - 3.5, y: 3.5)
                // A clear moat first, so the dot reads apart from the ring.
                ctx.setBlendMode(.clear)
                ctx.fillEllipse(in: CGRect(x: dot.x - 4.5, y: dot.y - 4.5, width: 9, height: 9))
                ctx.setBlendMode(.normal)
                ctx.fillEllipse(in: CGRect(x: dot.x - 3, y: dot.y - 3, width: 6, height: 6))
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Monospaced digits at the menu bar's own size, so "9%" → "10%" and a
    /// minute ticking over do not shuffle every item to its left.
    static var font: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
    }
}

/// A progress ring: the panel's small ones and the hero card's large one.
///
/// ── MOTION, AND ONLY WHILE SOMEBODY IS LOOKING ───────────────────────────
///
/// The ring eases to each new reading (`Motion.progress`, about a second),
/// and a printing ring has a slow, faint pulse: a thin halo outside it that
/// breathes with `Alive`, the one repeating movement this app has and the one
/// it keeps for a print running right now. The ring itself never fades; a
/// figure that dims every second is a figure that is harder to read. Both
/// live in a view that exists only while the panel is open
/// (`FloorStatus.toggle` builds it on opening and drops it on closing), so
/// nothing animates behind a closed menu bar item. With Reduce Motion there
/// is no halo and a value changes at once; with Increase Contrast the track
/// is solid rather than a tint of the ring.
struct ProgressRing: View {
    let value: Double
    let tint: Color
    var size: CGFloat = 16
    var line: CGFloat = 2.5
    /// The slow pulse, for a print that is running.
    var pulses = false
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            if pulses && !reduced {
                Circle().stroke(tint.opacity(0.4), lineWidth: max(1, line / 4))
                    .padding(-(line / 2 + max(2, line / 3)))
                    .alive()
            }
            Circle().stroke(contrast == .increased ? AnyShapeStyle(Color.primary.opacity(0.55))
                                                   : AnyShapeStyle(tint.opacity(0.22)),
                            lineWidth: line)
            Circle().trim(from: 0, to: min(1, max(0, value)))
                .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Motion.of(Motion.progress, unless: reduced), value: value)
        }
        .frame(width: size, height: size)
        // Progress runs clockwise in every language.
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }
}

/// The finish chime: one soft system sound when a print finishes.
///
/// A SETTING, AND OFF UNLESS SWITCHED ON. A Mac that makes a noise nobody
/// asked for in a shop, an office or a bedroom is a Mac whose owner goes
/// looking for what to uninstall. Mac-local like `mac.menuBar`: whether this
/// Mac chimes is not the shop's business and does not follow the book around.
/// A system sound, so no audio file ships with the app.
@MainActor
enum FinishChime {
    static let defaultsKey = "mac.menuBarChime"
    static let sound = "Glass"

    static var wanted: Bool { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? false }

    /// Play it if the setting is on. Returns whether it was played. `play` is
    /// the seam the tests count through; the app passes nothing.
    @discardableResult
    static func ring(wanted: Bool = FinishChime.wanted,
                     play: (String) -> Void = { NSSound(named: NSSound.Name($0))?.play() }) -> Bool {
        guard wanted else { return false }
        play(sound)
        return true
    }
}
