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
/// printing is `live` green (the 2026 redesign), paused `attention`, done `done`, failed `late` — the
/// app's stage colours, so a glance means the same thing in both places.
enum PrintActivityLook {
    static let brand = dynamic(light: 0x216DCA, dark: 0x4C97F0)
    static let live = dynamic(light: 0x13803F, dark: 0x34D27A)
    /// Done and paid are green on every app (Turki, Nov 11); the light value
    /// is the readable green, not the Mac's graphic #1BB55C (2.9:1 as text).
    static let done = dynamic(light: 0x13803F, dark: 0x34D27A)
    static let attention = dynamic(light: 0x8A5A0B, dark: 0xE0A73C)
    static let late = dynamic(light: 0xBB2D44, dark: 0xF2564A)
    static let ink = dynamic(light: 0x101417, dark: 0xEAF2FB)
    static let note = dynamic(light: 0x5A636D, dark: 0x8AA4C2)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x0D2444)
    static let track = dynamic(light: 0xE3E6E8, dark: 0x1F3A5E)
    /// Progress only, never text (the redesign's rule): the amber thread.
    static let thread = dynamic(light: 0xF2A541, dark: 0xF2A541)

    // ── Type (Nov 2026) ── the website's faces, bundled in the extension
    // (ios/KhaytWidget/Fonts, UIAppFonts in its Info.plist) because a widget
    // cannot use the fonts the app registers. Fixed sizes, as the system
    // ones they replace were. A face that fails to load falls back to the
    // system font, so nothing goes blank.

    /// Hanken Grotesk: names, labels, pills. Regular, Medium or SemiBold
    /// (bolder asks get SemiBold, the heaviest the extension carries).
    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        if arabic { return .custom(arabicName(weight), fixedSize: size) }
        let name = switch weight {
        case .regular, .light, .thin, .ultraLight: "HankenGrotesk-Regular"
        case .medium: "HankenGrotesk-Medium"
        default: "HankenGrotesk-SemiBold"
        }
        return .custom(name, fixedSize: size)
    }

    /// Archivo Bold: the big figure (time left, counts).
    static func display(_ size: CGFloat) -> Font {
        .custom(arabic ? "IBMPlexSansArabic-Bold" : "Archivo-Bold", fixedSize: size)
    }

    /// IBM Plex Sans Arabic: every face when the widget speaks Arabic (Turki,
    /// Nov 11: one Arabic font on every app). A widget draws in the phone's
    /// own language, which is the extension bundle's chosen localization.
    static var arabic: Bool { Bundle.main.preferredLocalizations.first?.hasPrefix("ar") == true }

    static func arabicName(_ weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black: "IBMPlexSansArabic-Bold"
        case .semibold: "IBMPlexSansArabic-SemiBold"
        case .medium: "IBMPlexSansArabic-Medium"
        default: "IBMPlexSansArabic-Regular"
        }
    }

    /// JetBrains Mono Medium: figures only (percents, counts' labels in
    /// Latin). It has no Arabic, and Arabic set in a mono fallback is spaced
    /// letter by letter, so anything with words ("Ends 9:18") is `text`.
    static func mono(_ size: CGFloat) -> Font { .custom("JetBrainsMono-Medium", fixedSize: size) }

    /// The faces the extension bundles, by PostScript name.
    static let faces = ["Archivo-Bold", "HankenGrotesk-Regular", "HankenGrotesk-Medium",
                        "HankenGrotesk-SemiBold", "JetBrainsMono-Medium",
                        "IBMPlexSansArabic-Regular", "IBMPlexSansArabic-Medium",
                        "IBMPlexSansArabic-SemiBold", "IBMPlexSansArabic-Bold"]

    static func tone(_ phase: PrintActivityAttributes.ContentState.Phase) -> Color {
        switch phase {
        // Printing is amber on every app (Turki, Nov 11). As TEXT that is the
        // warn amber; the bar uses `bar(_:)`, the graphic thread amber.
        case .printing: attention
        case .paused: attention
        case .finished: done
        case .failed: late
        case .cancelled: note
        }
    }

    /// The progress bar's colour: amber thread while printing (the same bar
    /// as the app and the widget), the phase's tone otherwise.
    static func bar(_ phase: PrintActivityAttributes.ContentState.Phase) -> Color {
        phase == .printing ? thread : tone(phase)
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
                        .font(PrintActivityLook.text(15, .semibold))
                        .foregroundStyle(PrintActivityLook.ink)
                        .lineLimit(1)
                    if let job = state.job {
                        Text(PrintActivityText.jobTitle(job))
                            .font(PrintActivityLook.text(12.5))
                            .foregroundStyle(PrintActivityLook.note)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                PrintPhasePill(phase: state.phase, bundle: bundle)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                PrintHeadline(state: state, bundle: bundle)
                    .font(PrintActivityLook.display(34).monospacedDigit())
                    .foregroundStyle(PrintActivityLook.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                PrintEnds(state: state, bundle: bundle)
                    .font(PrintActivityLook.text(13, .medium).monospacedDigit())
                    .foregroundStyle(PrintActivityLook.note)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                PrintBar(state: state)
                if PrintActivityText.showsPercent(state.phase) {
                    Text(verbatim: PrintActivityText.percent(state.progress))
                        .font(PrintActivityLook.mono(13))
                        .foregroundStyle(tone)
                        .fixedSize()
                }
            }
            // An ended print's one next step, as its alert offers it.
            if let move = PrintActivityText.move(state.phase) {
                Button(intent: PrintActivityMoveIntent(machineId: attributes.machineId, move: move)) {
                    Text(PrintActivityText.moveTitle(move, bundle: bundle))
                        .font(PrintActivityLook.text(14, .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(tone)
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
                .font(PrintActivityLook.text(12, .semibold))
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
                .tint(PrintActivityLook.bar(state.phase))
                .scaleEffect(x: 1, y: 1.6, anchor: .center)
        } else {
            let fraction = Double(PrintActivityText.shownProgress(state)) / 100
            GeometryReader { box in
                ZStack(alignment: .leading) {
                    Capsule().fill(PrintActivityLook.track)
                    Capsule().fill(PrintActivityLook.bar(state.phase))
                        .frame(width: max(6, box.size.width * fraction))
                }
            }
            .frame(height: 6)
        }
    }
}

/// Small words and figures the views share.
enum PrintActivityText {
    /// The move a Live Activity offers for an ended print: post-processing
    /// for a finished one, the queue again for one that failed or was
    /// cancelled — nil while it runs.
    static func move(_ phase: PrintActivityAttributes.ContentState.Phase) -> String? {
        switch phase {
        case .finished: return "post"
        case .failed, .cancelled: return "reprint"
        case .printing, .paused: return nil
        }
    }

    static func moveTitle(_ move: String, bundle: Bundle = .main) -> String {
        move == "post" ? String(localized: "Move to post-processing", bundle: bundle)
                       : String(localized: "Print it again", bundle: bundle)
    }

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
