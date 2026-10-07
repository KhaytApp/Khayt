import SwiftUI
import KhaytCore

/// The kiosk: every machine at once, for a screen across the shop.
///
/// A window of its own rather than a mode of the Machines screen, because it
/// is put somewhere else — a TV on the wall, a second display by the printers
/// — and left there, full screen, while the shop's own window carries on being
/// used. What each card says is `lib/kiosk.js`, the rule the desktop's board
/// draws its kiosk from; this only draws it, larger.
///
/// ── WHAT IT READS ─────────────────────────────────────────────────────────
///
/// The same printer readings as the machine band (`Shop.liveReadings`), so a
/// printer the Machines screen calls "not answering" is not "printing" here.
/// Where a printer says how far along it is, the card shows that; where it
/// does not, the clock against the job's estimate, and the caption under the
/// bar says which.
///
/// ── THE LAYOUT IS A FIXED GRID, NOT A LAZY ONE ────────────────────────────
///
/// Every card is on screen at once and nothing scrolls: a kiosk nobody can
/// touch that hides a machine below the fold has hidden it for good. So the
/// columns are worked out from the count (`KioskGrid.shape`) and the cards
/// share the window evenly. Not `LazyVGrid(.adaptive)`, which chose its column
/// count from a width that depended on its column count — one of the two shapes
/// that has hung this app's layout before.
struct KioskWindow: View {
    /// Named once, because the scene and the menu item must agree.
    static let id = "kiosk"

    let shop: Shop

    @State private var cards: [KhaytEngine.KioskCard] = []
    @State private var minute = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            if shop.machines.isEmpty {
                ContentUnavailableView(shop.words.callIt("kiosk.no_machines"),
                                       systemImage: "printer")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                KioskBoard(cards: cards, shop: shop)
            }
        }
        .background(Role.bg)
        .frame(minWidth: 640, minHeight: 400)
        .environment(\.layoutDirection, shop.words.isRTL ? .rightToLeft : .leftToRight)
        .task(id: signature) {
            cards = await shop.kiosk() ?? []
        }
        .task {
            // Once a minute regardless: the clock-based bars and the time in the
            // header move with it even when no printer says anything new.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                minute &+= 1
            }
        }
    }

    /// What the cards were computed FROM. The band's signature covers what the
    /// printers said; the orders' hash covers a job moved on the board.
    private var signature: String {
        "\(shop.bandSignature)#\(minute)#\(shop.orders.hashValue)#\(shop.machines.count)"
    }

    private var header: some View {
        HStack {
            Text(shop.shopName)
                .font(.title2.weight(.semibold))
            Spacer()
            // On the minute rather than on the refresh tick, which started
            // whenever the window did and would run up to a minute behind.
            TimelineView(.everyMinute) { context in
                Text(shop.words.say(context.date, .dateTime.hour().minute()))
                    .font(.title2.monospacedDigit())
                    .foregroundStyle(Role.text2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Role.surf2)
    }
}

/// The cards, laid out to fill whatever they are given. Apart from the window
/// so it can be photographed: `ImageRenderer` runs no tasks, and the window
/// loads its cards in one.
struct KioskBoard: View {
    let cards: [KhaytEngine.KioskCard]
    let shop: Shop

    var body: some View {
        GeometryReader { geo in
            let shape = KioskGrid.shape(count: cards.count, in: geo.size)
            let scale = KioskGrid.scale(for: geo.size, shape: shape)
            Grid(horizontalSpacing: 16 * scale, verticalSpacing: 16 * scale) {
                ForEach(KioskGrid.rows(cards, columns: shape.columns), id: \.self) { row in
                    GridRow {
                        ForEach(row) { card in
                            KioskCardView(card: card, shop: shop, scale: scale)
                        }
                        // A short last row keeps its cards the size of the
                        // rest rather than stretching across.
                        ForEach(0..<(shape.columns - row.count), id: \.self) { _ in
                            Color.clear
                        }
                    }
                }
            }
            .padding(16 * scale)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// How many columns and rows a kiosk of `count` cards is laid out in.
enum KioskGrid {
    struct Shape: Equatable { let columns: Int; let rows: Int }

    /// The column count whose cards come out closest to a card's own shape
    /// (a little wider than tall) in this window.
    static func shape(count: Int, in size: CGSize) -> Shape {
        guard count > 0 else { return Shape(columns: 1, rows: 1) }
        let target: CGFloat = 1.4
        var best = Shape(columns: 1, rows: count)
        var bestMiss = CGFloat.infinity
        for columns in 1...count {
            let rows = (count + columns - 1) / columns
            let w = size.width / CGFloat(columns), h = size.height / CGFloat(rows)
            guard w > 0, h > 0 else { continue }
            let miss = abs(log((w / h) / target))
            if miss < bestMiss { bestMiss = miss; best = Shape(columns: columns, rows: rows) }
        }
        return best
    }

    /// How much bigger than a laptop's card each card is drawn. A 360-point
    /// cell is 1; a TV's cells are several times that, and type sized for a
    /// desk cannot be read from across a room.
    static func scale(for size: CGSize, shape: Shape) -> CGFloat {
        let cell = min(size.width / CGFloat(shape.columns), size.height / CGFloat(shape.rows) * 1.4)
        return min(3, max(0.75, cell / 360))
    }

    static func rows(_ cards: [KhaytEngine.KioskCard], columns: Int) -> [[KhaytEngine.KioskCard]] {
        guard columns > 0 else { return [] }
        return stride(from: 0, to: cards.count, by: columns).map {
            Array(cards[$0..<min($0 + columns, cards.count)])
        }
    }
}

/// One machine.
/// A length of time as the kiosk spells it: "5h 40m", "5س 40د".
///
/// Not `Hours.spell`'s "5:40". That reads fine on the machine band, up close
/// and under a ruler of clock times; on a screen across the shop, under the
/// header's clock, "about 18:04 to print" reads as six in the evening. The
/// units say which it is. Latin digits, as everywhere else in the app.
enum KioskTime {
    static func spell(_ minutes: Double, _ language: String) -> String {
        let whole = max(0, Int(saturating: minutes.rounded()))
        return Duration.seconds(whole * 60).formatted(
            .units(allowed: [.hours, .minutes], width: .narrow, zeroValueUnits: .hide)
                .locale(Locale(identifier: language + "@numbers=latn")))
    }
}

struct KioskCardView: View {
    let card: KhaytEngine.KioskCard
    let shop: Shop
    let scale: CGFloat

    private var words: Words { shop.words }

    /// The palette's own sentences, as the board uses them: printing is "hot",
    /// held wants a person, and the ordinary course of a job is ordinary text.
    private var stateTint: Color {
        switch card.state {
        case "printing", "busy": Khayt.hot
        case "on_hold": Khayt.attention
        case "idle": Role.text3
        default: Role.text2
        }
    }

    /// The border: the state, unless the printer has stopped answering.
    private var tint: Color { card.offline ? Khayt.late : stateTint }

    private var stateWord: String {
        switch card.state {
        case "idle": words.callIt("kiosk.idle")
        case "busy": words.callIt("ad.busy")
        default: words.callIt("queue." + card.state, fallback: card.state)
        }
    }

    /// The job's title as every other screen draws it — a hash a printer
    /// named its upload is not a title — and the shop's word for a print with
    /// no name rather than the desktop's "Walk-in customer" in its place.
    private var title: String {
        if let job = shop.orders.first(where: { $0.id == card.orderId }) {
            let shown = shop.shownTitle(of: job)
            if !shown.isEmpty { return shown }
        }
        return card.project.isEmpty ? words.callIt("mac.untitled_print") : card.project
    }

    private var clientName: String {
        if !card.clientId.isEmpty, let named = shop.clientNames[card.clientId], !named.name.isEmpty {
            return named.name
        }
        return card.clientLabel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2 * scale) {
                    Text(card.name)
                        .font(.system(size: 26 * scale, weight: .bold))
                        .lineLimit(1)
                    if !card.model.isEmpty {
                        Text(card.model)
                            .font(.system(size: 14 * scale))
                            .foregroundStyle(Role.text3)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                // A machine with nothing booked that does not answer is NOT
                // ANSWERING, and only that: "Idle" beside it read, across a
                // room, as two contradicting answers. A machine with a job
                // keeps its state here and says it is silent below.
                if card.offline && card.state == "idle" {
                    chip(words.callIt("ad.no_reading"), Khayt.late)
                } else {
                    chip(stateWord, stateTint)
                }
            }
            if card.offline && card.state != "idle" {
                chip(words.callIt("ad.no_reading"), Khayt.late)
            }
            // No spacer here. One pushed the job to the foot of the card and
            // left a band of nothing under the machine's name; the job reads
            // as the machine's own line now, and the spare room is below it.
            if card.state == "busy" {
                Text(words.callIt("mac.kiosk_unbooked"))
                    .font(.system(size: 18 * scale))
                    .foregroundStyle(Role.text2)
            } else if !card.orderId.isEmpty {
                Text(title)
                    .font(.system(size: 30 * scale, weight: .semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                if !clientName.isEmpty {
                    Label(clientName, systemImage: "person")
                        .font(.system(size: 16 * scale))
                        .foregroundStyle(Role.text2)
                        .lineLimit(1)
                }
            }
            if let pct = card.pct {
                progress(pct)
            } else if let total = card.totalHours, total > 0 {
                Text(words.callIt("mac.kiosk_total", ["time": .string(Figure.isolated(KioskTime.spell(total * 60, words.language)))]))
                    .font(.system(size: 16 * scale).monospacedDigit())
                    .foregroundStyle(Role.text2)
            }
            if let due = Order.day(card.dueDate) {
                Label(words.callIt("mac.kiosk_due",
                                   ["date": .string(words.say(due, .dateTime.day().month(.abbreviated)))]),
                      systemImage: "calendar")
                    .font(.system(size: 15 * scale))
                    // Past it, in the palette's word for late.
                    .foregroundStyle(due < Calendar.book.startOfDay(for: Date()) ? Khayt.late : Role.text2)
            }
        }
        .padding(18 * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Role.surf, in: RoundedRectangle(cornerRadius: 14 * scale))
        .overlay {
            RoundedRectangle(cornerRadius: 14 * scale)
                .strokeBorder(tint, lineWidth: card.state == "idle" ? 1 : 3 * scale)
        }
        .accessibilityElement(children: .combine)
    }

    private func chip(_ text: String, _ colour: Color) -> some View {
        Text(text)
            .font(.system(size: 14 * scale, weight: .semibold))
            .padding(.horizontal, 10 * scale)
            .padding(.vertical, 4 * scale)
            .foregroundStyle(colour)
            .background(colour.opacity(0.14), in: Capsule())
            .lineLimit(1)
            .fixedSize()
    }

    private func progress(_ pct: Double) -> some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            // Drawn rather than a `ProgressView`: the control's height cannot be
            // set, and stretching it with `scaleEffect` does not move the
            // layout, so a bar tall enough to read across a room overlapped the
            // line under it. The fill scales from the LEADING edge, which
            // follows the writing direction — an Arabic bar fills from the right.
            // And it is a gauge (`growsToItsReading`): it travels to a new
            // reading rather than jumping, which on a screen nobody touches is
            // the only sign the printer said something.
            Capsule()
                .fill(Role.line2)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(tint)
                        .scaleEffect(x: min(1, max(0, pct / 100)), y: 1, anchor: .leading)
                        .growsToItsReading(pct, from: .leading)
                }
                .frame(height: 10 * scale)
                .padding(.vertical, 4 * scale)
            HStack(spacing: 6 * scale) {
                Text("\(Int(pct.rounded()))%")
                    .font(.system(size: 22 * scale, weight: .bold).monospacedDigit())
                if card.overrunMinutes > 0 {
                    Text(words.callIt("mac.kiosk_over", ["time": .string(Figure.isolated(KioskTime.spell(card.overrunMinutes, words.language)))]))
                        .foregroundStyle(Khayt.late)
                } else if let left = card.remainingMinutes {
                    Text(left > 0
                         ? words.callIt("mac.kiosk_left", ["time": .string(Figure.isolated(KioskTime.spell(left, words.language)))])
                         : words.callIt("kiosk.done"))
                        .foregroundStyle(Role.text2)
                }
                Spacer(minLength: 0)
                Text(words.callIt(card.source == "printer" ? "mac.kiosk_from_printer" : "mac.kiosk_estimated"))
                    .font(.system(size: 12 * scale))
                    .foregroundStyle(Role.text3)
            }
            .font(.system(size: 18 * scale).monospacedDigit())
        }
    }
}
