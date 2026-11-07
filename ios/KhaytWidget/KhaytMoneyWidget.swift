import WidgetKit
import SwiftUI

/// The Money widget (small and medium): today's takings, what is owed and
/// how many spools are low, from the snapshot the app writes. The face is
/// `KhaytMoneyView` (MoneyWidgetViews.swift); this is its timeline.
///
/// No sample figures anywhere, not even in the gallery: with nothing written
/// the widget says how to get the figures, so invented money is never on a
/// Home Screen.
struct KhaytMoneyEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct KhaytMoneyProvider: TimelineProvider {
    func placeholder(in context: Context) -> KhaytMoneyEntry {
        KhaytMoneyEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (KhaytMoneyEntry) -> Void) {
        completion(KhaytMoneyEntry(date: Date(), snapshot: WidgetSnapshotStore.load()))
    }

    /// Now, and again the moment the figures turn old, so they grey on time
    /// with the app closed; then ask again in a quarter of an hour.
    func getTimeline(in context: Context, completion: @escaping (Timeline<KhaytMoneyEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetSnapshotStore.load()
        let entries = WidgetFreshness.entryDates(asOf: snapshot?.money?.asOf, now: now)
            .map { KhaytMoneyEntry(date: $0, snapshot: snapshot) }
        let next = now.addingTimeInterval(WidgetFreshness.staleAfter)
        completion(Timeline(entries: entries, policy: .after(max(next, entries.last?.date ?? next))))
    }
}

struct KhaytMoneyWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: KhaytMoneyEntry

    var body: some View {
        KhaytMoneyView(snapshot: entry.snapshot, now: entry.date,
                       size: family == .systemMedium ? .medium : .small)
    }
}

struct KhaytMoneyWidget: Widget {
    let kind = "KhaytMoneyWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: KhaytMoneyProvider()) { entry in
            KhaytMoneyWidgetView(entry: entry)
                .containerBackground(for: .widget) { PrintActivityLook.surface }
                // Home: the Pulse, where the same figures are.
                .widgetURL(URL(string: "khayt://screen/dashboard"))
        }
        .configurationDisplayName("Khayt Money")
        .description("Today's takings, what customers owe and low stock. Hidden while your iPhone is locked.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
