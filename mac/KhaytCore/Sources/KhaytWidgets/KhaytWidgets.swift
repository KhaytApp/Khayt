import SwiftUI
import WidgetKit
import KhaytWidgetData
import KhaytWidgetViews

// ── THE ENTRY POINT IS `@main`, THE OPPOSITE OF THE QUICK LOOK EXTENSIONS ───
//
// The thumbnail and preview extensions must have NO Swift entry point, because
// ExtensionKit runs one if it finds it and never reaches their principal class
// (see `KhaytThumbnail/Entry.swift`). A widget extension is the other way
// round: its extension point PROHIBITS a principal class
// (`NSExtensionPrincipalClassProhibited`, in `lsregister -dump`), and what
// starts it is the `WidgetBundle`'s own `main`. Apple's Calculator widget has
// exactly that — an `LC_MAIN` and a `__swift5_entry` section — and
// `WidgetExtensionTests` holds this binary to the same shape.
//
// What the widgets DRAW is in `KhaytWidgetViews`, where the tests can render
// it. This file is only what WidgetKit needs to find and feed them.

@main
struct KhaytWidgets: WidgetBundle {
    var body: some Widget {
        PrintingNowWidget()
        TodayWidget()
        FilamentWidget()
        UpNextWidget()
        GlanceWidget()
    }
}

// MARK: - Where the figures come from

/// The snapshot the app last left in the group container, or nil.
///
/// The group is read from this bundle's Info.plist, where `make-app.sh` wrote
/// the one it signed with. A build with no group — an ad-hoc one — finds
/// nothing, and the widget says "Open Khayt".
enum Feed {
    static var directory: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: ShopWidgetSnapshot.groupInfoKey) as? String,
              !group.isEmpty else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    static func load() -> ShopWidgetSnapshot? {
        directory.flatMap(ShopWidgetSnapshot.read(in:))
    }

    /// What the widget gallery shows before a shop has written anything, in
    /// the Mac's own language, from this extension's strings.
    static var gallery: ShopWidgetSnapshot {
        let now = Date()
        let words = Dictionary(uniqueKeysWithValues: ShopWidgetSnapshot.Word.allCases.map { w in
            (w.rawValue, Bundle.main.localizedString(forKey: "widget.word.\(w.rawValue)", value: nil, table: nil))
        })
        let first = Bundle.main.preferredLocalizations.first ?? "en"
        let rtl = first.hasPrefix("ar")
        return ShopWidgetSnapshot(
            writtenAt: now, shopName: "Khayt",
            language: rtl ? "ar" : "en", rightToLeft: rtl, words: words,
            printing: [
                .init(id: "a", name: "Bambu Lab P1S", progress: 62, endsAt: now.addingTimeInterval(5_340), paused: false),
                .init(id: "b", name: "Prusa MK4S", progress: 28, endsAt: now.addingTimeInterval(9_180), paused: false),
            ],
            machineCount: 3,
            today: .init(dueToday: 3, overdue: 1, owed: "1,240.00"),
            lowSpools: [
                .init(id: "s1", name: "PLA Basic · Black", colour: "#1C1C1C", gramsLeft: 120),
                .init(id: "s2", name: "PETG · Orange", colour: "#F0763D", gramsLeft: 180),
            ],
            lowSpoolCount: 2,
            upNext: [
                .init(id: "ORD-01012", title: "Desk organiser", due: now, late: false, urgent: true),
                .init(id: "ORD-01013", title: "Lamp shade", due: now.addingTimeInterval(86_400), late: false, urgent: false),
                .init(id: "ORD-01014", title: "Cable clips ×40", due: now.addingTimeInterval(172_800), late: false, urgent: false),
            ],
            queuedCount: 3)
    }
}

struct FeedEntry: TimelineEntry {
    let date: Date
    let snapshot: ShopWidgetSnapshot?
}

struct FeedProvider: TimelineProvider {
    func placeholder(in context: Context) -> FeedEntry {
        FeedEntry(date: Date(), snapshot: Feed.gallery)
    }

    func getSnapshot(in context: Context, completion: @escaping (FeedEntry) -> Void) {
        // The gallery shows what the widget looks like with a shop in it, even
        // on a Mac whose book is empty — an empty preview sells nothing.
        let snap = Feed.load() ?? (context.isPreview ? Feed.gallery : nil)
        completion(FeedEntry(date: Date(), snapshot: snap))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FeedEntry>) -> Void) {
        // The app reloads the timeline itself whenever the figures change. The
        // quarter-hour is only so "Updated …" and a stale print catch up when
        // the app is not running to say so.
        let now = Date()
        let snap = Feed.load()
        // An entry at each moment the drawing changes on its own: a print's
        // estimated finish (its countdown stops) and the end of the shop's day
        // (today's counts become a dash). See `KhaytWidgetView.now`.
        var moments = (snap?.printing.compactMap(\.endsAt) ?? []) + [snap?.dayEnds].compactMap { $0 }
        moments = moments.filter { $0 > now }.sorted()
        let entries = [FeedEntry(date: now, snapshot: snap)]
            + moments.prefix(8).map { FeedEntry(date: $0, snapshot: snap) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
    }
}

/// `\.widgetFamily` read here, where WidgetKit sets it, and handed down.
struct Face: View {
    let face: WidgetFace
    let entry: FeedEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        KhaytWidgetView(face: face, family: family, snapshot: entry.snapshot, now: entry.date)
            .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - The widgets

/// One face, one kind. The sizes come from the face (`WidgetFace.families`),
/// which is what the render tests draw, so the two cannot disagree.
@MainActor
private func configuration(_ face: WidgetFace, kind: String, name: LocalizedStringKey,
                           description: LocalizedStringKey) -> some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: FeedProvider()) { entry in
        Face(face: face, entry: entry)
    }
    .configurationDisplayName(Text(name))
    .description(Text(description))
    .supportedFamilies(face.families)
}

struct PrintingNowWidget: Widget {
    var body: some WidgetConfiguration {
        configuration(.printing, kind: "app.khayt.mac.printing",
                      name: "widget.printing.name", description: "widget.printing.description")
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        configuration(.today, kind: "app.khayt.mac.today",
                      name: "widget.today.name", description: "widget.today.description")
    }
}

struct FilamentWidget: Widget {
    var body: some WidgetConfiguration {
        configuration(.filament, kind: "app.khayt.mac.filament",
                      name: "widget.filament.name", description: "widget.filament.description")
    }
}

struct UpNextWidget: Widget {
    var body: some WidgetConfiguration {
        configuration(.upNext, kind: "app.khayt.mac.upnext",
                      name: "widget.upnext.name", description: "widget.upnext.description")
    }
}

struct GlanceWidget: Widget {
    var body: some WidgetConfiguration {
        configuration(.glance, kind: "app.khayt.mac.glance",
                      name: "widget.glance.name", description: "widget.glance.description")
    }
}
