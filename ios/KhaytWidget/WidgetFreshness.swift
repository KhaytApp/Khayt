import SwiftUI
import WidgetKit

/**
 * How old a widget's figures are, and when they count as old.
 *
 * Compiled into the widget AND the app (the `KhaytWidget` folder is shared,
 * see the project's exception sets), so the app's tests hold the rule and
 * render the label. Each target compiles it against its own `WidgetSnapshot`.
 *
 * A widget only knows what the app last wrote: when the phone has not opened
 * Khayt for an hour, the queue counts and the money are an hour old, and
 * nothing on them said so. Now each widget shows the age, live, and greys
 * its figures once they are older than `staleAfter`.
 */
enum WidgetFreshness {
    /// About two health polls missed many times over: the app polls every
    /// half-minute while open, so anything past this is from an app that is
    /// no longer running.
    static let staleAfter: TimeInterval = 15 * 60

    /// How old the snapshot's figures are: the older of what the data is as
    /// of (`updatedAt`, the book's age when the shop is out of reach) and when
    /// the app wrote it. A snapshot from before `writtenAt` has `updatedAt`.
    static func asOf(_ snapshot: WidgetSnapshot) -> Date {
        guard let written = snapshot.writtenAt else { return snapshot.updatedAt }
        return min(snapshot.updatedAt, written)
    }

    static func isStale(_ asOf: Date, now: Date) -> Bool {
        now.timeIntervalSince(asOf) > staleAfter
    }

    /// The moments a timeline needs an entry for: now, and the moment the
    /// figures turn old (so they grey without the app running).
    static func entryDates(asOf: Date?, now: Date) -> [Date] {
        guard let asOf else { return [now] }
        let turns = asOf.addingTimeInterval(staleAfter + 1)
        return turns > now ? [now, turns] : [now]
    }

    /// The opacity of figures that may no longer be true.
    static func opacity(stale: Bool) -> Double { stale ? 0.45 : 1 }
}

/// "5 min ago", counting by itself, and amber with a clock once old.
struct WidgetAgeLabel: View {
    let asOf: Date
    let now: Date
    var size: CGFloat = 10

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let stale = WidgetFreshness.isStale(asOf, now: now)
        HStack(spacing: 3) {
            Image(systemName: stale ? "clock.badge.exclamationmark" : "clock")
                .font(.system(size: size - 1, weight: .semibold))
            // The system's own relative wording, live: it ticks on the Home
            // Screen without the app writing anything.
            Text(.currentDate, format: .reference(to: asOf, allowedFields: [.day, .hour, .minute], maxFieldCount: 1))
                .font(PrintActivityLook.text(size, .medium).monospacedDigit())
        }
        .foregroundStyle(renderingMode == .fullColor
                         ? (stale ? PrintActivityLook.attention : PrintActivityLook.note)
                         : Color.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

/// The app's digits rule on the widget: 0–9 in every language (Saudi phones
/// read Western digits on money; `L10n.latinDigits` in the app).
struct WidgetLatinDigits: ViewModifier {
    @Environment(\.locale) private var locale

    func body(content: Content) -> some View {
        var parts = Locale.Components(locale: locale)
        parts.numberingSystem = Locale.NumberingSystem("latn")
        return content.environment(\.locale, Locale(components: parts))
    }
}
