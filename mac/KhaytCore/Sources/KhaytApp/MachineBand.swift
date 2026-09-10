import SwiftUI
import KhaytCore

/// The next 48 hours on the machines, drawn.
///
/// ── WHY A BAND AND NOT FOUR MORE NUMBERS ──────────────────────────────────
///
/// The first question a shop asks in the morning is "when is that machine
/// free". Every screen in this app answered it with a figure — `free at 10:56`
/// — and a figure has to be read, held and compared against two others. A gap
/// on a band is *seen*. Nothing else on this screen changes what the app knows;
/// it changes how long it takes to know it.
///
/// ── FORTY-EIGHT HOURS, NOT A DAY ──────────────────────────────────────────
///
/// A day is the obvious window and it is the wrong one. This shop's own museum
/// replica is a FORTY-TWO HOUR print. A 07:00–19:00 band cannot draw it, so it
/// would be clipped at the edge — and a bar drawn to the edge of a chart looks
/// exactly like a bar that ends there. Two days holds the longest job the shop
/// actually runs, and anything still longer says so in words.
///
/// The rule is `lib/machine-band.js`. Nothing here decides anything: this file
/// turns minutes into rectangles.
struct MachineBandView: View {
    let shop: Shop
    let band: KhaytEngine.MachineBand

    // ── A PRINT FARM, NOT THREE PRINTERS ──────────────────────────────────
    //
    // Built at three machines, this row is 46 points tall with two lines of
    // text inside every block. Ten machines is 560 points of band before the
    // cards start, which is the whole window; twenty is unusable. A shop with
    // twenty printers is exactly the shop this screen is FOR.
    //
    // So the band has two densities and picks one. Above four machines the rows
    // halve, the blocks keep their name and drop their second line, and the two
    // fixed columns narrow — the track, which is the part carrying the
    // information, keeps everything they give up.
    private var compact: Bool { band.rows.count > 4 }
    private var rowHeight: CGFloat { compact ? 24 : 46 }

    /// The name column, and the free-time column at the end. Fixed, so every
    /// row's track starts and ends on the same two verticals — a Gantt whose
    /// lanes do not line up is a picture of nothing.
    private var nameWidth: CGFloat { compact ? 126 : 168 }
    private var freeWidth: CGFloat { compact ? 104 : 152 }

    /// Past this many rows the band scrolls rather than growing. Eight is what
    /// fits above the cards on the smallest window this app opens at; a farm
    /// scrolls its machines the way it scrolls its jobs.
    private static let rowsBeforeScrolling = 8

    /// Is there anything on this band to look at?
    ///
    /// Not "are there machines" — are there machines whose hours Khayt can
    /// actually tell you. With none, the band drew three empty lanes, a ruler
    /// and a legend for four marks that never appeared: four hundred points of
    /// furniture saying "no" three times. It says it once instead, in a
    /// sentence, with what to do about it.
    private var hasSomethingToShow: Bool { band.countedMachines > 0 }

    var body: some View {
        if hasSomethingToShow { full } else { nothingYet }
    }

    /// One line, in the band's own frame, so the screen keeps its shape.
    private var nothingYet: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "clock.badge.questionmark")
                .font(.title3).foregroundStyle(Khayt.attention)
            VStack(alignment: .leading, spacing: 3) {
                Text(shop.words.callIt("mac.band_none"))
                    .font(.callout.weight(.semibold))
                Text(shop.words.callIt("mac.band_none_why"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Khayt.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Khayt.hairline, lineWidth: 1))
    }

    private var full: some View {
        VStack(spacing: 0) {
            header
            LayerRule()
            ticks
            if band.rows.count > Self.rowsBeforeScrolling {
                ScrollView {
                    VStack(spacing: 0) { rows }
                }
                // Eight rows' worth, so the band never takes more of the window
                // than the machines below it.
                .frame(maxHeight: CGFloat(Self.rowsBeforeScrolling) * (rowHeight + 25))
            } else {
                rows
            }
            LayerRule()
            whyBlank
            legend
        }
        .background(Khayt.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Khayt.hairline, lineWidth: 1))
    }

    @ViewBuilder private var rows: some View {
        ForEach(band.rows) { row in
            LayerRule()
            Row(row: row, band: band, shop: shop, compact: compact, height: rowHeight,
                nameWidth: nameWidth, freeWidth: freeWidth)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(shop.words.callIt("mac.band_title"))
                .font(.headline)
            Text(shop.words.callIt("mac.band_sub", ["hours": .number(band.hours)]))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            // Only when there IS one. A permanent caveat is furniture; one that
            // appears the morning a printer stops is a thing you read.
            if band.unknownMachines > 0 {
                Label(shop.words.callIt("mac.band_over", [
                    "counted": .number(Double(band.countedMachines)),
                    "silent": .number(Double(band.unknownMachines)),
                ]), systemImage: "questionmark.circle")
                    .font(.caption).foregroundStyle(Khayt.attention)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// Every six hours, plus the date where a day turns over.
    private var ticks: some View {
        // The SAME geometry as a row, gutters included. It was the two widths
        // without them, so the ruler sat ten points left of its own gridlines
        // and every label named a time one tick along from the line under it.
        HStack(spacing: 0) {
            Color.clear.frame(width: nameWidth + 10)
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    ForEach(Self.tickMinutes(band), id: \.self) { minute in
                        let x = geo.size.width * (minute / band.minutes)
                        Text(Self.clock(band, minute))
                            .font(.caption2).monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                            // First and last hug their edges; the rest centre on
                            // the tick, or the row's ends lose their labels.
                            .alignmentGuide(.leading) { d in
                                minute == 0 ? 0 : (minute >= band.minutes ? d.width : d.width / 2)
                            }
                            .offset(x: x)
                    }
                }
            }
            .frame(height: 15)
            Color.clear.frame(width: freeWidth + 10)
        }
        .padding(.horizontal, 14).padding(.top, 7).padding(.bottom, 3)
    }

    /// Why some lanes are empty, said once rather than per row.
    ///
    /// TWO DIFFERENT SENTENCES, and telling them apart is the whole point of
    /// knowing a machine's kind. A printer that is not answering is a fault. A
    /// laser cutter is not answering because nothing in this app can ask one —
    /// it is working perfectly and Khayt has no protocol for it. They look
    /// identical on a status panel and mean opposite things, so both appear
    /// when both apply.
    @ViewBuilder private var whyBlank: some View {
        let blank = band.rows.filter { $0.blocks.isEmpty }
        let noProtocol = blank.contains { shop.machineKinds[$0.machineId]?.polled == false }
        let noAnswer = blank.contains { shop.machineKinds[$0.machineId]?.polled != false }
        if noProtocol || noAnswer {
            VStack(alignment: .leading, spacing: 2) {
                if noAnswer {
                    Text(shop.words.callIt("mac.band_cannot_ask"))
                }
                if noProtocol {
                    Text(shop.words.callIt("mac.band_no_protocol"))
                }
            }
            .font(.caption2).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.top, 6)
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            Key(fill: Khayt.hot.opacity(0.16), line: Khayt.hot,
                text: shop.words.callIt("mac.band_printing"))
            Key(fill: Khayt.surface, line: Khayt.hairline, dashed: true,
                text: shop.words.callIt("mac.band_queued"))
            Key(fill: Khayt.attention.opacity(0.16), line: Khayt.attention,
                text: shop.words.callIt("mac.band_blocked"))
            // ONLY WHEN THERE IS ONE. A key for a block this shop never draws
            // is a line of legend explaining something that is not on screen,
            // and the row is already four items and a total wide.
            if band.downMinutes > 0 {
                Key(fill: Khayt.note.opacity(0.10), line: Khayt.note,
                    text: shop.words.callIt("mac.band_down"))
            }
            HStack(spacing: 5) {
                Rectangle().fill(Khayt.note).frame(width: 13, height: 1)
                Text(shop.words.callIt("mac.band_free")).font(.caption2)
            }
            Spacer()
            Text(Self.sum(band, shop.words))
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Khayt.recessed)
    }

    private struct Key: View {
        let fill: Color, line: Color
        var dashed = false
        let text: String
        var body: some View {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(fill)
                    .frame(width: 13, height: 9)
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(
                        line, style: StrokeStyle(lineWidth: 1, dash: dashed ? [2, 2] : [])))
                Text(text).font(.caption2)
            }
        }
    }

    // MARK: - One machine

    private struct Row: View {
        let row: KhaytEngine.MachineBand.Row
        let band: KhaytEngine.MachineBand
        let shop: Shop
        let compact: Bool
        let height: CGFloat
        let nameWidth: CGFloat
        let freeWidth: CGFloat

        var body: some View {
            HStack(alignment: .top, spacing: 0) {
                // Compact puts the state dot beside the name instead of under
                // it: a farm reads down a column of names, and a two-line name
                // cell doubles the height of every row to say one word.
                Group {
                    if compact {
                        HStack(spacing: 6) {
                            Circle().fill(stateInk).frame(width: 6, height: 6)
                            Text(row.name).font(.caption.weight(.semibold)).lineLimit(1)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.name).font(.callout.weight(.semibold)).lineLimit(1)
                            HStack(spacing: 5) {
                                Circle().fill(stateInk).frame(width: 7, height: 7)
                                Text(shop.words.callIt("mac.band_state_\(row.state)"))
                                    .font(.caption).foregroundStyle(stateInk)
                            }
                        }
                    }
                }
                .frame(width: nameWidth, alignment: .leading)
                .padding(.vertical, compact ? 7 : 12).padding(.trailing, 10)

                track
                    .padding(.vertical, compact ? 7 : 12)

                VStack(alignment: .trailing, spacing: 2) {
                    if row.known {
                        Text(Hours.spell(row.freeMinutes))
                            .font((compact ? Font.callout : .title3).weight(.semibold)).monospacedDigit()
                            .foregroundStyle(row.freeMinutes <= 0 ? Khayt.attention : Khayt.note)
                        if !compact {
                            Text(shop.words.callIt("mac.band_free_in", ["hours": .number(band.hours)]))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    } else {
                        // The honest answer, and the reason the totals below are
                        // over fewer machines than the shop owns.
                        Text("—").font(.title3.weight(.semibold)).foregroundStyle(.tertiary)
                        Text(shop.words.callIt(
                            shop.machineKinds[row.machineId]?.polled == false
                                ? "mac.band_not_asked" : "mac.band_unknown"))
                            .font(.caption2)
                            // Amber says "go and look". A machine Khayt simply
                            // cannot ask is not a problem, so it is not amber.
                            .foregroundStyle(shop.machineKinds[row.machineId]?.polled == false
                                             ? AnyShapeStyle(.tertiary)
                                             : AnyShapeStyle(Khayt.attention))
                            .multilineTextAlignment(.trailing)
                    }
                }
                .frame(width: freeWidth, alignment: .trailing)
                .padding(.vertical, compact ? 7 : 12).padding(.leading, 10)
            }
            .padding(.horizontal, 14)
        }

        private var stateInk: Color {
            if !row.known { return Khayt.attention }
            switch row.state {
            case "printing": return Khayt.hot
            case "queued": return .secondary
            case "down": return Khayt.note
            default: return Khayt.note
            }
        }

        private var track: some View {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .topLeading) {
                    // The hours, so a block's length can be read off the grid
                    // rather than guessed against the labels at the top.
                    ForEach(MachineBandView.tickMinutes(band).dropFirst().dropLast(), id: \.self) { m in
                        Rectangle().fill(Khayt.hairline).frame(width: 1)
                            .offset(x: w * (m / band.minutes))
                    }

                    if row.known {
                        ForEach(row.blocks.filter { !$0.beyond && $0.minutes > 0 }) { block in
                            Block(block: block, shop: shop, compact: compact)
                                .frame(width: max(2, w * (block.minutes / band.minutes)), height: height)
                                .offset(x: w * (block.startMinute / band.minutes))
                        }
                        // A dimension line across each gap, labelled. It is the
                        // answer to the question, so it is drawn rather than
                        // left as the absence of a block.
                        ForEach(row.gaps.indices, id: \.self) { i in
                            let gap = row.gaps[i]
                            Dimension(text: Hours.spell(gap.minutes), compact: compact)
                                .frame(width: w * (gap.minutes / band.minutes), height: height)
                                .offset(x: w * (gap.startMinute / band.minutes))
                        }
                    }
                    // NOTHING here for a machine with no blocks.
                    //
                    // There used to be a sentence — "printing something Khayt
                    // cannot time — nothing here is a guess" — drawn across the
                    // lane. Three unpollable machines meant the same sixty
                    // characters three times, starting at x=0 where the red
                    // now-bar is, so the first letter was under it and the
                    // hour grid ran through the words. It read as a broken
                    // screen rather than as an explanation.
                    //
                    // The row already says "no estimate" at its right-hand end.
                    // The reason is said ONCE, under the band, where a sentence
                    // has room to be a sentence — see `whyBlank`.

                    // Now. Always at zero — the window starts at this moment —
                    // and drawn anyway, because a band with no now-line reads as
                    // a plan rather than as the next two days.
                    Rectangle().fill(Khayt.hot).frame(width: 2, height: height + 8).offset(y: -4)
                }
                .frame(height: height)
            }
            .frame(height: height)
        }
    }

    // MARK: - One block

    private struct Block: View {
        let block: KhaytEngine.MachineBand.Block
        let shop: Shop
        let compact: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(block.title.isEmpty ? shop.words.callIt("mac.unnamed") : block.title)
                    .font(.caption.weight(.semibold)).foregroundStyle(ink).lineLimit(1)
                // The second line goes first when there is no room for it. It
                // is the detail; the name is the thing being looked for. Both
                // stay in the tooltip either way.
                if !compact {
                    Text(sub).font(.caption2).monospacedDigit()
                        .foregroundStyle(block.kind == "blocked"
                                         ? AnyShapeStyle(Khayt.attention) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 7).padding(.vertical, compact ? 3 : 5)
            .background(fill, in: RoundedRectangle(cornerRadius: 3))
            .overlay(shape)
            .help(block.title + " · " + sub)
        }

        /// A cut end is DASHED, and it is the whole reason this reads honestly:
        /// a rectangle that stops at the edge of the window and one that ends
        /// there are the same rectangle otherwise.
        private var shape: some View {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(line, style: StrokeStyle(
                    lineWidth: 1, dash: block.projected && block.kind != "blocked" ? [3, 2] : []))
                .overlay(alignment: .leading) {
                    if block.clippedStart { Rectangle().fill(line).frame(width: 2) }
                }
                .overlay(alignment: .trailing) {
                    if block.clippedEnd { Rectangle().fill(line).frame(width: 2) }
                }
        }

        private var ink: Color {
            switch block.kind {
            case "printing": return Khayt.hot
            case "blocked": return Khayt.attention
            default: return .primary
            }
        }
        private var line: Color {
            switch block.kind {
            case "printing": return Khayt.hot
            case "blocked": return Khayt.attention
            // A MACHINE THE SHOP TOOK OUT OF SERVICE ON PURPOSE. Not warm —
            // nothing is happening — and not an alarm either: booking a belt
            // change is the shop working, and painting it like a fault would
            // teach a shop to avoid recording one.
            case "down": return Khayt.note
            default: return Khayt.hairline
            }
        }
        private var fill: Color {
            switch block.kind {
            case "printing": return Khayt.hot.opacity(0.13)
            case "blocked": return Khayt.attention.opacity(0.13)
            case "down": return Khayt.note.opacity(0.10)
            default: return Khayt.recessed
            }
        }

        /// What the block says under its name: the shortage if it has one, the
        /// overrun if it has one, and its length otherwise.
        private var sub: String {
            // A maintenance window has no order behind it, so it says what it
            // is — and the shop's own note is the block's title, which may be
            // empty. "Maintenance · 4 h" is still an answer; a blank block is
            // not.
            if block.kind == "down" {
                return shop.words.callIt("mac.band_down") + " · " + Hours.spell(block.minutes)
            }
            if let short = block.shortfall {
                return shop.words.callIt("mac.band_short", [
                    "grams": .number(short.short), "material": .string(short.material),
                ])
            }
            if block.clippedEnd {
                return shop.words.callIt("mac.band_past", [
                    "hours": .string(Hours.spell(block.afterMinutes)),
                ])
            }
            if block.clippedStart {
                return shop.words.callIt("mac.band_before", [
                    "hours": .string(Hours.spell(block.beforeMinutes)),
                ])
            }
            return Hours.spell(block.minutes)
        }
    }

    /// A leader line with the figure in the middle of it, the way free space is
    /// dimensioned on a drawing rather than left blank.
    private struct Dimension: View {
        let text: String
        let compact: Bool
        var body: some View {
            HStack(spacing: 4) {
                Rectangle().fill(Khayt.note).frame(width: 1, height: compact ? 8 : 11)
                Rectangle().fill(Khayt.note).frame(height: 1)
                Text(text).font(.caption2).monospacedDigit().foregroundStyle(Khayt.note)
                    .fixedSize().layoutPriority(1)
                Rectangle().fill(Khayt.note).frame(height: 1)
                Rectangle().fill(Khayt.note).frame(width: 1, height: compact ? 8 : 11)
            }
            .padding(.horizontal, 3)
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Reading the band

    /// Where the six-hourly marks fall, in minutes from the start of the window.
    ///
    /// SNAPPED TO THE CLOCK, not spaced from now. Marks every six hours from
    /// the moment the band opens gave a ruler reading 17:47, 23:47, 05:47 —
    /// truthful, unreadable, and it hid midnight, which is the one boundary a
    /// shop plans an overnight run around. These land on 18:00, 00:00, 06:00,
    /// at their real distance from now, so the first gap is shorter than the
    /// rest and says so by being shorter.
    static func tickMinutes(_ band: KhaytEngine.MachineBand) -> [Double] {
        let start = Date(timeIntervalSince1970: band.from / 1000)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let parts = cal.dateComponents([.hour, .minute], from: start)
        let into = Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
        var first = (360 - into.truncatingRemainder(dividingBy: 360))
        if first >= 360 { first = 0 }
        return stride(from: first, to: band.minutes, by: 360).map { $0 }
    }

    /// The wall clock at that many minutes into the window.
    static func clock(_ band: KhaytEngine.MachineBand, _ minute: Double) -> String {
        let at = Date(timeIntervalSince1970: band.from / 1000 + minute * 60)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        // Midnight is called out, because it is the boundary a shop plans an
        // unattended overnight run around and "00:00" alone reads as a time
        // rather than as the end of the day.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let h = cal.component(.hour, from: at), m = cal.component(.minute, from: at)
        if h == 0 && m == 0 {
            f.dateFormat = "EEE"
            return f.string(from: at)
        }
        f.dateFormat = "HH:mm"
        return f.string(from: at)
    }

    /// The per-machine free hours, added up in front of the reader.
    ///
    /// The mockup this came from printed a free-hours total that did not match
    /// the rows above it, which is the failure a summary line exists to make
    /// impossible. So up to four machines it is written as the sum —
    /// `28:00 + 42:42 + 6:00 = 76:42` — and a shop can check it by eye.
    ///
    /// A FARM CANNOT. Ten terms is not an arithmetic a reader verifies; it is a
    /// wall of figures that hides the total at the end of it. Past four the
    /// line says the total and what it is over, and the checking moves to the
    /// column of per-machine figures already running down the right edge.
    static func sum(_ band: KhaytEngine.MachineBand, _ words: Words) -> String {
        let known = band.rows.filter(\.known)
        guard !known.isEmpty else { return "" }
        let total = Hours.spell(band.freeMinutes)
        if known.count > 4 {
            return words.callIt("mac.band_free_across",
                                ["hours": .string(total), "n": .number(Double(known.count))])
        }
        let parts = known.map { Hours.spell($0.freeMinutes) }
        let joined = parts.count > 1 ? parts.joined(separator: " + ") + " = " + total : total
        return joined + " " + words.callIt("mac.band_free")
    }
}

/// Hours and minutes, as a shop says them: `42:00`, `5:08`.
///
/// NOT `Duration`, which is Swift's own type. Naming it that shadowed the
/// standard library inside this module and broke `Task.sleep(for: .seconds(…))`
/// in a file nothing here had touched — the error pointed at `PrinterWatch`,
/// which was innocent.
enum Hours {
    static func spell(_ minutes: Double) -> String {
        let whole = max(0, Int(minutes.rounded()))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
