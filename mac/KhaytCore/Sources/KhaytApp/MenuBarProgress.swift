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
                     quiet: Shop.Quiet?, bedNotClear: Bool) -> FloorLine {
        let attention = attention(status, bedNotClear: bedNotClear)
        let printing = status.map { PrinterWatch.isPrinting($0.state) } ?? false
        let rank: FloorLine.Rank
        if attention != nil { rank = .attention }
        else if printing { rank = .printing }
        else if status == nil, quiet == .notAnswering || quiet == .underService { rank = .offline }
        else { rank = .idle }
        let left = status?.timeRemaining.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return FloorLine(id: id, name: name, rank: rank, attention: attention, printing: printing,
                         progress: min(100, max(0, status?.progress ?? 0)),
                         left: printing ? left : nil,
                         filename: status?.filename ?? "", quiet: status == nil ? quiet : nil)
    }

    /// Attention, printing (soonest finish first; a print that does not say
    /// how long goes after those that do), idle, offline. Ties keep the
    /// book's order — the order the shop put its machines in.
    static func sorted(_ lines: [FloorLine]) -> [FloorLine] {
        lines.enumerated().sorted { a, b in
            if a.element.rank != b.element.rank { return a.element.rank < b.element.rank }
            if a.element.rank == .printing {
                switch (a.element.left, b.element.left) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// The machines on the floor, sorted. Retired ones are not on it.
    @MainActor
    static func lines(_ shop: Shop) -> [FloorLine] {
        let bed = Set((shop.dispatch?.waiting ?? []).filter { $0.blocked == "ad.bed_not_clear" }.map(\.machineId))
        return sorted(shop.machinesInUse.map { machine in
            let status = shop.printers.heard(machine.id)
            return line(id: machine.id, name: machine.name, status: status,
                        quiet: status == nil ? shop.quiet(machine) : nil,
                        bedNotClear: bed.contains(machine.id))
        })
    }

    // MARK: - The label

    /// What the status item draws: a ring (nil = the nozzle), the text beside
    /// it, and whether to mark it for attention.
    struct Label: Equatable, Sendable {
        var ring: Double?
        var text: String
        var attention: Bool
    }

    /// The job the label leads with: the print that finishes soonest, and how
    /// many others are running beside it.
    static func lead(_ lines: [FloorLine]) -> (line: FloorLine, others: Int)? {
        let running = sorted(lines.filter(\.printing).map {
            // Ranked as printing whatever their attention, so a runout mid-print
            // is still ordered by when it finishes.
            FloorLine(id: $0.id, name: $0.name, rank: .printing, attention: $0.attention,
                      printing: true, progress: $0.progress, left: $0.left,
                      filename: $0.filename, quiet: nil)
        })
        guard let first = running.first else { return nil }
        return (first, running.count - 1)
    }

    @MainActor
    static func label(_ lines: [FloorLine], style: MenuBarStyle, words: Words) -> Label {
        let attention = lines.contains { $0.attention != nil }
        guard style != .glyphOnly, let lead = lead(lines) else {
            return Label(ring: nil, text: "", attention: attention)
        }
        let ring = Double(lead.line.progress) / 100
        guard style == .ringAndFigures else { return Label(ring: ring, text: "", attention: attention) }
        var text = figures(progress: lead.line.progress, left: lead.line.left, words: words)
        if lead.others > 0 {
            text += " " + words.callIt("mac.mbp_more", ["n": .string(words.numeral(lead.others))])
        }
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
enum StatusGlyph {
    static let size = NSSize(width: 18, height: 18)

    static func image(ring: Double?, attention: Bool) -> NSImage {
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

/// A small progress ring for the popover's rows.
struct ProgressRing: View {
    let value: Double
    let tint: Color
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.22), lineWidth: 2.5)
            Circle().trim(from: 0, to: min(1, max(0, value)))
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        // Progress runs clockwise in every language.
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }
}
