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
public enum WidgetFace: Sendable {
    case printing, today
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

    public var body: some View {
        if let snapshot {
            Group {
                switch face {
                case .printing: PrintingView(snapshot: snapshot, family: family, now: now)
                case .today: TodayView(snapshot: snapshot, family: family, now: now)
                }
            }
            // The BOOK's language, which is the app's — not the Mac's. Western
            // digits in Arabic too, as everywhere in Khayt.
            .environment(\.locale, Locale(identifier: snapshot.language + "@numbers=latn"))
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
                                PrinterRow(printer: rows[r * 2], snapshot: snapshot, now: now)
                                if r * 2 + 1 < rows.count {
                                    PrinterRow(printer: rows[r * 2 + 1], snapshot: snapshot, now: now)
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

// MARK: - Pieces

struct Header: View {
    let title: String
    let shop: String
    let count: Int?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.caption.weight(.bold)).lineLimit(1)
                .foregroundStyle(Ink.brand.on(scheme)).widgetAccentable()
            if let count {
                Text(verbatim: String(count)).font(.caption.weight(.bold)).monospacedDigit()
                    .foregroundStyle(Ink.hot.on(scheme)).widgetAccentable()
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
