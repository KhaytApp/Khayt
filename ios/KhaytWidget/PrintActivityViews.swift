import ActivityKit
import SwiftUI
import UIKit

/// How a print looks on the Lock Screen and in the Dynamic Island.
///
/// Apart from `PrintActivityWidget` so the app compiles it too (every file in
/// this folder is in both targets unless the project excludes it), which is
/// what lets `PrintActivityLookTests` render each phase to a picture: the
/// simulator has no Lock Screen to photograph.
///
/// ── THE LOOK (Oct 2026) ──────────────────────────────────────────────────
///
/// The first version was the system's defaults throughout: a grey bar, a
/// headline-sized countdown beside the machine's name, and the widget's OLD
/// brand blue. On a real phone it read as unfinished. Now it is the app's own
/// palette (`KhaytDesign`'s v2 values, repeated here because the extension
/// cannot see the app's theme), the time left is the largest thing on it, the
/// clock time the print ends sits beside it, and the phase is a coloured pill:
/// printing is `hot`, paused `attention`, done `done`, failed `late` — the
/// app's stage colours, so a glance means the same thing in both places.
enum PrintActivityLook {
    static let brand = dynamic(light: 0x0B54AD, dark: 0x4591ED)
    static let hot = dynamic(light: 0xAF3E18, dark: 0xF0763D)
    static let done = dynamic(light: 0x1B5E4F, dark: 0x4FBFA0)
    static let attention = dynamic(light: 0x8A5A0B, dark: 0xE0A73C)
    static let late = dynamic(light: 0xBB2D44, dark: 0xF2564A)
    static let ink = dynamic(light: 0x1E1A15, dark: 0xF2EDE4)
    static let note = dynamic(light: 0x4F5B69, dark: 0x9EA7B3)
    static let surface = dynamic(light: 0xFBF9F5, dark: 0x201C17)
    static let track = dynamic(light: 0xE3DED3, dark: 0x3A342C)

    static func tone(_ phase: PrintActivityAttributes.ContentState.Phase) -> Color {
        switch phase {
        case .printing: hot
        case .paused: attention
        case .finished: done
        case .failed: late
        case .cancelled: note
        }
    }

    static func symbol(_ phase: PrintActivityAttributes.ContentState.Phase) -> String {
        switch phase {
        case .printing: "printer.fill"
        case .paused: "pause.circle.fill"
        case .finished: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle.fill"
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        func rgb(_ v: UInt32) -> UIColor {
            UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                    blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        return Color(UIColor { $0.userInterfaceStyle == .dark ? rgb(dark) : rgb(light) })
    }
}

/// The Lock Screen (and StandBy, and iPhone Duo's outer display).
struct PrintActivityLockScreen: View {
    let attributes: PrintActivityAttributes
    let state: PrintActivityAttributes.ContentState
    /// Where the words are looked up: the extension's own table. A parameter
    /// only so the app's tests can point it there too.
    var bundle: Bundle = .main

    private var tone: Color { PrintActivityLook.tone(state.phase) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "printer.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(PrintActivityLook.brand, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(attributes.machineName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(PrintActivityLook.ink)
                        .lineLimit(1)
                    if let job = state.job {
                        Text(PrintActivityText.jobTitle(job))
                            .font(.system(size: 12.5))
                            .foregroundStyle(PrintActivityLook.note)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                PrintPhasePill(phase: state.phase, bundle: bundle)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                PrintHeadline(state: state, bundle: bundle)
                    .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(PrintActivityLook.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                PrintEnds(state: state, bundle: bundle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(PrintActivityLook.note)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                PrintBar(state: state)
                if PrintActivityText.showsPercent(state.phase) {
                    Text(verbatim: PrintActivityText.percent(state.progress))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(tone)
                        .fixedSize()
                }
            }
        }
    }
}

/// The phase, as a small coloured pill.
struct PrintPhasePill: View {
    let phase: PrintActivityAttributes.ContentState.Phase
    var bundle: Bundle = .main

    var body: some View {
        let tone = PrintActivityLook.tone(phase)
        HStack(spacing: 4) {
            Image(systemName: PrintActivityLook.symbol(phase)).font(.system(size: 10, weight: .bold))
            PrintActivityText.phase(phase, bundle: bundle)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(tone)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(tone.opacity(0.16), in: Capsule())
        .fixedSize()
    }
}

/// The big figure: the time left while printing — counted down by the
/// system from the end date, so it keeps going with the app closed — and
/// otherwise what became of the print.
struct PrintHeadline: View {
    let state: PrintActivityAttributes.ContentState
    var bundle: Bundle = .main

    var body: some View {
        switch state.phase {
        case .printing:
            if let end = state.endsAt, end > Date() {
                PrintTimeLeft(end: end)
            } else {
                Text(verbatim: PrintActivityText.percent(state.progress))
            }
        case .paused:
            Text("Paused at \(PrintActivityText.percent(state.progress))", bundle: bundle)
        case .finished: Text("Ready to collect", bundle: bundle)
        case .failed: Text("Print failed", bundle: bundle)
        case .cancelled: Text("Print stopped", bundle: bundle)
        }
    }
}

/// The time left, counted down by the system to the minute. The Lock Screen
/// stops ticking seconds while it sleeps and draws a seconds timer as
/// "1:11:--", so this one never asks for seconds.
struct PrintTimeLeft: View {
    let end: Date
    var body: some View {
        Text(.currentDate, format: .timer(countingDownIn: Date()..<end, showsHours: true,
                                          maxFieldCount: 2, maxPrecision: .seconds(60)))
            .modifier(WesternDigits())
    }
}

/// Western digits in Arabic too, as everywhere in Khayt. The system draws
/// these figures in the phone's own locale, which in Arabic writes ٠–٩.
struct WesternDigits: ViewModifier {
    @Environment(\.locale) private var locale
    func body(content: Content) -> some View {
        content.environment(\.locale, PrintActivityText.latinDigits(locale))
    }
}

/// When it ends, as a clock time — only while that is still ahead.
struct PrintEnds: View {
    let state: PrintActivityAttributes.ContentState
    var bundle: Bundle = .main

    var body: some View {
        if state.phase == .printing, let end = state.endsAt, end > Date() {
            Text("Ends \(Text(end, style: .time))", bundle: bundle)
                .modifier(WesternDigits())
        }
    }
}

/// The bar fills by itself between the start and end dates while printing —
/// the system's own `ProgressView(timerInterval:)`, the only bar that keeps
/// moving with the app closed. Otherwise it is drawn here, standing at what
/// the printer last reported (full once the print is done), in the phase's
/// colour.
struct PrintBar: View {
    let state: PrintActivityAttributes.ContentState

    var body: some View {
        if state.phase == .printing, let range = PrintActivityText.barRange(state) {
            ProgressView(timerInterval: range, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                .progressViewStyle(.linear)
                .tint(PrintActivityLook.tone(state.phase))
                .scaleEffect(x: 1, y: 1.6, anchor: .center)
        } else {
            let fraction = Double(PrintActivityText.shownProgress(state)) / 100
            GeometryReader { box in
                ZStack(alignment: .leading) {
                    Capsule().fill(PrintActivityLook.track)
                    Capsule().fill(PrintActivityLook.tone(state.phase))
                        .frame(width: max(6, box.size.width * fraction))
                }
            }
            .frame(height: 6)
        }
    }
}

/// Small words and figures the views share.
enum PrintActivityText {
    /// `base` with 0–9 digits; month names and plural rules stay its own.
    /// The same rule as the app's `L10n.latinDigits`, which the widget cannot see.
    static func latinDigits(_ base: Locale) -> Locale {
        var parts = Locale.Components(locale: base)
        parts.numberingSystem = Locale.NumberingSystem("latn")
        return Locale(components: parts)
    }

    /// The span the system's self-filling bar runs over while printing. The
    /// start is put back so the bar stands at the reported percent now:
    /// `startedAt` is when the phone first SAW the print, so a print first seen
    /// at 45% would otherwise draw an empty bar beside "45%".
    static func barRange(_ state: PrintActivityAttributes.ContentState,
                         now: Date = Date()) -> ClosedRange<Date>? {
        guard state.phase == .printing, let end = state.endsAt, end > now else { return nil }
        let done = Double(min(99, max(0, state.progress))) / 100
        var start = now.addingTimeInterval(-end.timeIntervalSince(now) * done / (1 - done))
        if done == 0, let seen = state.startedAt, seen < now { start = seen }
        return start...end
    }

    /// Western digits in both languages, as everywhere else in Khayt.
    static func percent(_ n: Int) -> String { "\(min(100, max(0, n)))%" }

    /// A finished print is whole, whatever the printer's last report said
    /// (they often stop reporting at 98 or 99).
    static func shownProgress(_ state: PrintActivityAttributes.ContentState) -> Int {
        state.phase == .finished ? 100 : min(100, max(0, state.progress))
    }

    /// The figure beside the bar: while printing, and where a failed print
    /// got to. Paused says it in the headline already; done is whole.
    static func showsPercent(_ phase: PrintActivityAttributes.ContentState.Phase) -> Bool {
        phase == .printing || phase == .failed
    }

    /// A printer's file name, made readable: the extension and the slicer's
    /// underscores go, so `Dragon_0.2mm_PLA.gcode` reads `Dragon 0.2mm PLA`.
    static func jobTitle(_ file: String) -> String {
        var name = file
        for ext in [".gcode.3mf", ".gcode", ".bgcode", ".3mf"] where name.lowercased().hasSuffix(ext) {
            name = String(name.dropLast(ext.count))
            break
        }
        let readable = name.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        return readable.isEmpty ? file : readable
    }

    static func phase(_ phase: PrintActivityAttributes.ContentState.Phase, bundle: Bundle) -> Text {
        switch phase {
        case .printing: Text("Printing", bundle: bundle)
        case .paused: Text("Paused", bundle: bundle)
        case .finished: Text("Done", bundle: bundle)
        case .failed: Text("Failed", bundle: bundle)
        case .cancelled: Text("Cancelled", bundle: bundle)
        }
    }
}
