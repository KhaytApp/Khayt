import SwiftUI
import WidgetKit
import KhaytWidgetData

/// What the desktop widgets draw.
///
/// In a library of its own rather than inside the extension so the tests can
/// draw it: an extension's views are otherwise seen only by the system, on a
/// desktop no test can photograph. `WidgetRenderTests` renders both widgets at
/// both sizes, in English and Arabic, light and dark.
///
/// The family is passed in rather than read from `\.widgetFamily`, which only
/// WidgetKit can set — a view that reads it draws as `systemSmall` everywhere
/// else, so the medium widget could never be rendered by anything but a Mac.
public enum WidgetFace: Sendable, CaseIterable {
    case printing, today, filament, upNext, glance

    /// The sizes each face is offered in — read by the extension's widgets and
    /// by `WidgetRenderTests`, so nothing is drawn at a size nobody can pick.
    public var families: [WidgetFamily] {
        switch self {
        case .printing, .today, .filament: [.systemSmall, .systemMedium]
        case .upNext: [.systemMedium, .systemLarge]
        case .glance: [.systemLarge]
        }
    }

    /// Where a tap on the widget, outside any row, opens the app.
    var screen: ShopWidgetSnapshot.Link {
        switch self {
        case .printing: .screen("machines")
        case .today: .screen("dashboard")
        case .filament: .screen("inventory")
        case .upNext: .screen("board")
        case .glance: .screen("dashboard")
        }
    }
}

/// A row that opens the app at itself. A small widget is one tap target by
/// rule (only `widgetURL` reaches it), so there a row is drawn as it is and
/// the whole widget opens its screen.
struct Tap<Content: View>: View {
    let link: ShopWidgetSnapshot.Link
    let family: WidgetFamily
    @ViewBuilder let content: Content
    @Environment(\.widgetRowLinks) private var links

    var body: some View {
        if family == .systemSmall || !links {
            content
        } else {
            Link(destination: link.url) { content }
        }
    }
}

extension EnvironmentValues {
    /// Whether rows are drawn as links. Always on the desktop. Off only in
    /// `WidgetRenderTests`, because `ImageRenderer` draws a `Link` as a
    /// placeholder, and a picture of placeholders reviews nothing.
    @Entry public var widgetRowLinks = true
}

public struct KhaytWidgetView: View {
    let face: WidgetFace
    let family: WidgetFamily
    let snapshot: ShopWidgetSnapshot?
    /// The timeline entry's moment — what "now" is for this drawing, which is
    /// not when the app wrote the file.
    let now: Date

    public init(face: WidgetFace, family: WidgetFamily, snapshot: ShopWidgetSnapshot?, now: Date = Date()) {
        self.face = face
        self.family = family
        self.snapshot = snapshot
        self.now = now
    }

    static let gregorian: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .autoupdatingCurrent
        return c
    }()

    public var body: some View {
        if let snapshot {
            Group {
                switch face {
                case .printing: PrintingView(snapshot: snapshot, family: family, now: now)
                case .today: TodayView(snapshot: snapshot, family: family, now: now)
                case .filament: FilamentView(snapshot: snapshot, family: family)
                case .upNext: UpNextView(snapshot: snapshot, family: family)
                case .glance: GlanceView(snapshot: snapshot, now: now)
                }
            }
            .widgetURL(face.screen.url)
            // The BOOK's language, which is the app's — not the Mac's. Western
            // digits in Arabic too, as everywhere in Khayt. And the BOOK's
            // calendar, which is Gregorian (`Calendar.book`): a Saudi Mac set
            // to Umm al-Qura drew a due date as "5 Jumada I" beside the app's
            // "17 Oct".
            .environment(\.locale, Locale(identifier: snapshot.language + "@calendar=gregorian;numbers=latn"))
            .environment(\.calendar, Self.gregorian)
            .environment(\.layoutDirection, snapshot.rightToLeft ? .rightToLeft : .leftToRight)
        } else {
            OpenKhayt()
        }
    }
}

struct OpenKhayt: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "Khayt").font(.headline)
            Text("widget.open_khayt", bundle: .main).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Printing now

struct PrintingView: View {
    let snapshot: ShopWidgetSnapshot
    let family: WidgetFamily
    let now: Date

    /// Two rows on the small widget; two columns of two on the medium. Three
    /// stacked rows were measured overflowing the medium widget's 138pt of
    /// height (`WidgetRenderTests`), header and footer both clipped.
    private var shown: Int { family == .systemSmall ? 2 : 4 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Header(title: snapshot.word(.printingTitle), shop: snapshot.shopName,
                   count: snapshot.printing.isEmpty ? nil : snapshot.printing.count)
            if snapshot.printing.isEmpty {
                Spacer(minLength: 0)
                Text(snapshot.word(.nothingPrinting)).font(.callout.weight(.medium))
                Text(snapshot.machineCount == 0 ? snapshot.word(.noMachines) : snapshot.word(.idleMachines))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                let rows = Array(snapshot.printing.prefix(shown))
                if family == .systemSmall {
                    ForEach(rows) { PrinterRow(printer: $0, snapshot: snapshot, now: now) }
                } else {
                    Grid(horizontalSpacing: 14, verticalSpacing: 8) {
                        ForEach(0..<((rows.count + 1) / 2), id: \.self) { r in
                            GridRow {
                                Tap(link: .machine(rows[r * 2].id), family: family) {
                                    PrinterRow(printer: rows[r * 2], snapshot: snapshot, now: now)
                                }
                                if r * 2 + 1 < rows.count {
                                    Tap(link: .machine(rows[r * 2 + 1].id), family: family) {
                                        PrinterRow(printer: rows[r * 2 + 1], snapshot: snapshot, now: now)
                                    }
                                } else {
                                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                                }
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 4) {
                // Beside "+2 more" a small widget has room for the time only;
                // the word was cut to "Updat…".
                Updated(snapshot: snapshot,
                        timeOnly: family == .systemSmall && snapshot.printing.count > shown)
                Spacer(minLength: 4)
                if snapshot.printing.count > shown {
                    Text(verbatim: snapshot.word(.more)
                        .replacingOccurrences(of: "{n}", with: String(snapshot.printing.count - shown)))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct PrinterRow: View {
    let printer: ShopWidgetSnapshot.Printer
    let snapshot: ShopWidgetSnapshot
    let now: Date
    @Environment(\.colorScheme) private var scheme

    private var ink: Color { printer.paused ? Ink.attention.on(scheme) : Ink.hot.on(scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(printer.name).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 2)
                Text(verbatim: "\(printer.progress)%")
                    .font(.caption2.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(ink)
                    .widgetAccentable()
            }
            Bar(fraction: Double(printer.progress) / 100, ink: ink)
            Group {
                if printer.paused {
                    Text(snapshot.word(.paused))
                } else if let ends = printer.endsAt, ShopWidgetSnapshot.countsDown(to: ends, at: now) {
                    // Counts down on its own between reloads. Only while the
                    // finish is ahead: past it, `.relative` counts back UP, so
                    // a print the app has not been running to see finish read
                    // as hours still to go. The timeline has an entry at each
                    // finish (`FeedProvider`), so the row redraws without it.
                    Text(ends, style: .relative).monospacedDigit()
                } else {
                    Text(verbatim: " ")
                }
            }
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// A progress bar drawn, not a `ProgressView`: `ImageRenderer` draws a
/// `ProgressView` as a placeholder, so the bar the tests photograph would not
/// be the one the desktop shows. It fills from the LEADING edge — the right,
/// in Arabic.
struct Bar: View {
    let fraction: Double
    let ink: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(ink)
                    .frame(width: max(4, g.size.width * min(1, max(0, fraction))))
                    .widgetAccentable()
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Today

struct TodayView: View {
    let snapshot: ShopWidgetSnapshot
    let family: WidgetFamily
    let now: Date

    /// Yesterday's counts are not today's: past the day the app wrote them
    /// for, due and late are a dash until the app writes again. What is owed
    /// does not change at midnight, so it stays.
    private var dayOver: Bool { snapshot.dayIsOver(at: now) }
    private var due: String { dayOver ? "–" : String(snapshot.today.dueToday) }
    private var late: String { dayOver ? "–" : String(snapshot.today.overdue) }
    private var lateInk: Color? { !dayOver && snapshot.today.overdue > 0 ? Ink.late.on(scheme) : nil }
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Header(title: snapshot.word(.todayTitle), shop: snapshot.shopName, count: nil)
            if family == .systemSmall {
                Spacer(minLength: 0)
                Figure(value: due, label: snapshot.word(.dueToday), ink: nil)
                Figure(value: late, label: snapshot.word(.overdue), ink: lateInk)
                if let owed = snapshot.today.owed {
                    Figure(value: owed, label: snapshot.word(.owed), ink: nil)
                }
            } else {
                Spacer(minLength: 0)
                HStack(alignment: .top, spacing: 14) {
                    Figure(value: due, label: snapshot.word(.dueToday), ink: nil, big: true)
                    Figure(value: late, label: snapshot.word(.overdue), ink: lateInk, big: true)
                    if let owed = snapshot.today.owed {
                        Figure(value: owed, label: snapshot.word(.owed), ink: nil, big: true)
                    }
                    Spacer(minLength: 0)
                }
            }
            Spacer(minLength: 0)
            Updated(snapshot: snapshot)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct Figure: View {
    let value: String
    let label: String
    let ink: Color?
    var big = false

    var body: some View {
        if big {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: value).font(.title3.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(ink ?? .primary).lineLimit(1).minimumScaleFactor(0.6)
                Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 2)
                Text(verbatim: value).font(.callout.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(ink ?? .primary).lineLimit(1).minimumScaleFactor(0.6)
            }
        }
    }
}

// MARK: - Filament low

struct FilamentView: View {
    let snapshot: ShopWidgetSnapshot
    let family: WidgetFamily

    /// Three rows on the small widget; two columns of three on the medium.
    private var shown: Int { family == .systemSmall ? 3 : 6 }

    var body: some View {
        if let spools = snapshot.lowSpools {
            let total = snapshot.lowSpoolCount ?? spools.count
            VStack(alignment: .leading, spacing: 6) {
                Header(title: snapshot.word(.filamentTitle), shop: snapshot.shopName,
                       count: total == 0 ? nil : total, countInk: Ink.attention)
                if spools.isEmpty {
                    Spacer(minLength: 0)
                    Text(snapshot.word(.allStocked)).font(.callout.weight(.medium))
                    Spacer(minLength: 0)
                } else {
                    let rows = Array(spools.prefix(shown))
                    if family == .systemSmall {
                        ForEach(rows) { SpoolRow(spool: $0, snapshot: snapshot) }
                    } else {
                        TwoColumns(items: rows) { spool in
                            Tap(link: .spool(spool.id), family: family) { SpoolRow(spool: spool, snapshot: snapshot) }
                        }
                    }
                    Spacer(minLength: 0)
                }
                Footer(snapshot: snapshot, more: total - min(spools.count, shown),
                       timeOnly: family == .systemSmall && total > shown)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            OpenKhayt()
        }
    }
}

struct SpoolRow: View {
    let spool: ShopWidgetSnapshot.LowSpool
    let snapshot: ShopWidgetSnapshot
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Swatch.colour(spool.colour) ?? Color.secondary.opacity(0.4))
                .overlay(Circle().strokeBorder(.secondary.opacity(0.5), lineWidth: 0.5))
                .frame(width: 10, height: 10)
            Text(spool.name).font(.caption.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 2)
            Text(verbatim: snapshot.word(.grams).replacingOccurrences(of: "{n}", with: String(spool.gramsLeft)))
                .font(.caption2.weight(.semibold)).monospacedDigit()
                .foregroundStyle(Ink.attention.on(scheme)).lineLimit(1)
                .fixedSize()
        }
    }
}

/// A spool's own colour, from its "#RRGGBB".
enum Swatch {
    static func colour(_ hex: String?) -> Color? {
        guard let hex, hex.hasPrefix("#"), hex.count == 7, let v = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255, opacity: 1)
    }
}

// MARK: - Up next

struct UpNextView: View {
    let snapshot: ShopWidgetSnapshot
    let family: WidgetFamily

    /// Three rows on the medium widget, six on the large.
    private var shown: Int { family == .systemLarge ? 6 : 3 }

    var body: some View {
        if let jobs = snapshot.upNext {
            let total = snapshot.queuedCount ?? jobs.count
            VStack(alignment: .leading, spacing: family == .systemLarge ? 8 : 5) {
                Header(title: snapshot.word(.upNextTitle), shop: snapshot.shopName,
                       count: total == 0 ? nil : total, countInk: Ink.brand)
                if jobs.isEmpty {
                    Spacer(minLength: 0)
                    Text(snapshot.word(.queueEmpty)).font(.callout.weight(.medium))
                    Spacer(minLength: 0)
                } else {
                    ForEach(Array(jobs.prefix(shown))) { job in
                        Tap(link: .job(job.id), family: family) { JobRow(job: job, snapshot: snapshot) }
                        if family == .systemLarge, job.id != jobs.prefix(shown).last?.id { Divider() }
                    }
                    Spacer(minLength: 0)
                }
                Footer(snapshot: snapshot, more: total - min(jobs.count, shown), timeOnly: false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            OpenKhayt()
        }
    }
}

struct JobRow: View {
    let job: ShopWidgetSnapshot.QueuedJob
    let snapshot: ShopWidgetSnapshot
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: job.id).font(.caption2.weight(.semibold)).monospacedDigit()
                .foregroundStyle(.secondary).lineLimit(1).fixedSize()
            Text(job.title).font(.caption.weight(.semibold)).lineLimit(1)
            if job.urgent {
                Text(snapshot.word(.urgent)).font(.caption2.weight(.bold))
                    .foregroundStyle(Ink.hot.on(scheme)).lineLimit(1).fixedSize()
            }
            Spacer(minLength: 2)
            if let due = job.due {
                Text(due, format: .dateTime.day().month(.abbreviated))
                    .font(.caption2.weight(job.late ? .bold : .regular)).monospacedDigit()
                    .foregroundStyle(job.late ? Ink.late.on(scheme) : .secondary)
                    .lineLimit(1).fixedSize()
            }
        }
    }
}

// MARK: - Shop at a glance

/// The large widget: what is printing, today's figures and what is running
/// low, each the same drawing its own widget uses.
struct GlanceView: View {
    let snapshot: ShopWidgetSnapshot
    let now: Date
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Printing: two at most, side by side.
            VStack(alignment: .leading, spacing: 6) {
                Header(title: snapshot.word(.printingTitle), shop: snapshot.shopName,
                       count: snapshot.printing.isEmpty ? nil : snapshot.printing.count)
                if snapshot.printing.isEmpty {
                    Text(snapshot.word(.nothingPrinting)).font(.caption).foregroundStyle(.secondary)
                } else {
                    TwoColumns(items: Array(snapshot.printing.prefix(2))) { p in
                        Tap(link: .machine(p.id), family: .systemLarge) {
                            PrinterRow(printer: p, snapshot: snapshot, now: now)
                        }
                    }
                }
            }
            Divider()
            // Today: the medium widget's three figures.
            VStack(alignment: .leading, spacing: 4) {
                Header(title: snapshot.word(.todayTitle), shop: snapshot.shopName, count: nil)
                let over = snapshot.dayIsOver(at: now)
                HStack(alignment: .top, spacing: 14) {
                    Figure(value: over ? "–" : String(snapshot.today.dueToday),
                           label: snapshot.word(.dueToday), ink: nil, big: true)
                    Figure(value: over ? "–" : String(snapshot.today.overdue), label: snapshot.word(.overdue),
                           ink: !over && snapshot.today.overdue > 0 ? Ink.late.on(scheme) : nil, big: true)
                    if let owed = snapshot.today.owed {
                        Figure(value: owed, label: snapshot.word(.owed), ink: nil, big: true)
                    }
                    Spacer(minLength: 0)
                }
            }
            Divider()
            // Filament: three at most.
            VStack(alignment: .leading, spacing: 5) {
                let spools = snapshot.lowSpools ?? []
                let total = snapshot.lowSpoolCount ?? spools.count
                Header(title: snapshot.word(.filamentTitle), shop: snapshot.shopName,
                       count: total == 0 ? nil : total, countInk: Ink.attention)
                if spools.isEmpty {
                    Text(snapshot.word(.allStocked)).font(.caption).foregroundStyle(.secondary)
                } else {
                    TwoColumns(items: Array(spools.prefix(4))) { s in
                        Tap(link: .spool(s.id), family: .systemLarge) { SpoolRow(spool: s, snapshot: snapshot) }
                    }
                }
            }
            // Up next: three at most — the room the three above leave.
            if let jobs = snapshot.upNext {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    let total = snapshot.queuedCount ?? jobs.count
                    Header(title: snapshot.word(.upNextTitle), shop: snapshot.shopName,
                           count: total == 0 ? nil : total, countInk: Ink.brand)
                    if jobs.isEmpty {
                        Text(snapshot.word(.queueEmpty)).font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(jobs.prefix(3))) { job in
                            Tap(link: .job(job.id), family: .systemLarge) { JobRow(job: job, snapshot: snapshot) }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Updated(snapshot: snapshot)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Pieces

/// Items in two columns, row by row — the medium widget's layout. A lone last
/// item keeps its column's width rather than stretching across both.
struct TwoColumns<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    @ViewBuilder let cell: (Item) -> Cell

    var body: some View {
        Grid(horizontalSpacing: 14, verticalSpacing: 8) {
            ForEach(0..<((items.count + 1) / 2), id: \.self) { r in
                GridRow {
                    cell(items[r * 2])
                    if r * 2 + 1 < items.count {
                        cell(items[r * 2 + 1])
                    } else {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                }
            }
        }
    }
}

/// "Updated 9:52 AM" and, when the list was cut, "+2 more".
struct Footer: View {
    let snapshot: ShopWidgetSnapshot
    let more: Int
    let timeOnly: Bool

    var body: some View {
        HStack(spacing: 4) {
            Updated(snapshot: snapshot, timeOnly: timeOnly)
            Spacer(minLength: 4)
            if more > 0 {
                Text(verbatim: snapshot.word(.more).replacingOccurrences(of: "{n}", with: String(more)))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

struct Header: View {
    let title: String
    let shop: String
    let count: Int?
    var countInk = Ink.hot
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.caption.weight(.bold)).lineLimit(1)
                .foregroundStyle(Ink.brand.on(scheme)).widgetAccentable()
            if let count {
                Text(verbatim: String(count)).font(.caption.weight(.bold)).monospacedDigit()
                    .foregroundStyle(countInk.on(scheme)).widgetAccentable()
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct Updated: View {
    let snapshot: ShopWidgetSnapshot
    var timeOnly = false

    var body: some View {
        HStack(spacing: 3) {
            if !timeOnly { Text(snapshot.word(.updated)) }
            // The time, not a running "2 min, 0 sec": it is never wrong and
            // needs no redraw to stay right.
            Text(snapshot.writtenAt, style: .time)
        }
        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
    }
}

/// Khayt's colours, by role. The SAME values as `Khayt.brand`, `.hot`,
/// `.attention` and `.late` in the app's `Palette.swift` — this code cannot
/// import that file, so `WidgetExtensionTests` reads both and fails when they
/// part. Chosen by the widget's own colour scheme rather than a dynamic NSColor,
/// because a widget is drawn by the system, not by this process.
struct Ink {
    let light: UInt32
    let dark: UInt32

    static let brand = Ink(light: 0x0B54AD, dark: 0x4591ED)
    static let hot = Ink(light: 0xAF3E18, dark: 0xF0763D)
    static let attention = Ink(light: 0x8A5A0B, dark: 0xE0A73C)
    static let late = Ink(light: 0xBB2D44, dark: 0xF2564A)

    func on(_ scheme: ColorScheme) -> Color {
        let hex = scheme == .dark ? dark : light
        return Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255,
                     green: Double((hex >> 8) & 0xFF) / 255,
                     blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}
