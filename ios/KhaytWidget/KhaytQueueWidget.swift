import WidgetKit
import SwiftUI

private extension Color {
    /// Khayt indigo brand (matches the app AccentColor).
    static let khaytBrand = Color(red: 0.31, green: 0.357, blue: 0.949)
}

struct KhaytQueueEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct KhaytQueueProvider: TimelineProvider {
    private var sample: WidgetSnapshot {
        WidgetSnapshot(
            shopName: "Tuwaiq 3D", queued: 8, printing: 2, post: 1, qc: 3,
            completedToday: 5, connected: true, updatedAt: Date(),
            prints: [
                WidgetPrint(id: "M1", name: "Bambu Lab X1C", progress: 62, eta: "1h 29m"),
                WidgetPrint(id: "M2", name: "Prusa MK4S", progress: 28, eta: "2h 33m")
            ]
        )
    }

    func placeholder(in context: Context) -> KhaytQueueEntry {
        KhaytQueueEntry(date: Date(), snapshot: sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (KhaytQueueEntry) -> Void) {
        let snap = context.isPreview ? sample : (WidgetSnapshotStore.load() ?? sample)
        completion(KhaytQueueEntry(date: Date(), snapshot: snap))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<KhaytQueueEntry>) -> Void) {
        let entry = KhaytQueueEntry(date: Date(), snapshot: WidgetSnapshotStore.load())
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct KhaytQueueWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: KhaytQueueEntry

    var body: some View {
        switch family {
        case .accessoryRectangular:
            accessory
        case .systemMedium:
            medium
        default:
            small
        }
    }

    // MARK: small

    private var small: some View {
        Group {
            if let s = entry.snapshot {
                VStack(alignment: .leading, spacing: 6) {
                    header(s)
                    Spacer(minLength: 0)
                    if let top = s.prints?.first {
                        printRow(top, compact: true)
                    } else {
                        HStack(spacing: 12) {
                            metric("Queue", s.queued)
                            metric("Print", s.printing)
                            metric("Done", s.completedToday)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(statusLine(s))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                empty
            }
        }
    }

    // MARK: medium

    private var medium: some View {
        Group {
            if let s = entry.snapshot {
                VStack(alignment: .leading, spacing: 8) {
                    header(s)
                    HStack(spacing: 16) {
                        metric("Queue", s.queued)
                        metric("Printing", s.printing)
                        metric("QC", s.qc)
                        metric("Done", s.completedToday)
                    }
                    Divider()
                    let prints = s.prints ?? []
                    if prints.isEmpty {
                        Text(s.connected ? "Nothing printing right now" : "Offline")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(prints.prefix(2)) { printRow($0, compact: false) }
                    }
                    Spacer(minLength: 0)
                }
            } else {
                empty
            }
        }
    }

    // MARK: accessory (lock screen)

    private var accessory: some View {
        Group {
            if let top = entry.snapshot?.prints?.first {
                VStack(alignment: .leading, spacing: 2) {
                    Text(top.name).font(.headline).lineLimit(1)
                    ProgressView(value: Double(top.progress), total: 100)
                    Text("\(top.progress)%" + (top.eta.map { " · \($0)" } ?? ""))
                        .font(.caption2)
                }
            } else if let s = entry.snapshot {
                VStack(alignment: .leading) {
                    Text("Khayt").font(.headline)
                    Text("\(s.queued) queued · \(s.printing) printing").font(.caption2)
                }
            } else {
                Text("Khayt").font(.headline)
            }
        }
    }

    // MARK: pieces

    private func header(_ s: WidgetSnapshot) -> some View {
        HStack {
            Text(s.shopName).font(.caption.bold()).lineLimit(1)
            Spacer()
            Circle()
                .fill(s.connected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
        }
    }

    private func printRow(_ p: WidgetPrint, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(p.name)
                    .font(compact ? .caption2.bold() : .caption.bold())
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(p.progress)%")
                    .font(.caption2.bold().monospacedDigit())
                    .foregroundStyle(Color.khaytBrand)
            }
            ProgressView(value: Double(min(100, max(0, p.progress))), total: 100)
                .tint(.khaytBrand)
            if !compact, let eta = p.eta {
                Text("ETA \(eta)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// `LocalizedStringKey`, not `String`: a `Text(String)` is shown as written,
    /// and these labels were English on an Arabic phone.
    private func metric(_ label: LocalizedStringKey, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.title3.bold())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func statusLine(_ s: WidgetSnapshot) -> LocalizedStringKey {
        s.connected ? "LAN connected" : "Offline"
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Khayt").font(.headline)
            Text("Open app on shop Wi‑Fi")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct KhaytQueueWidget: Widget {
    let kind = "KhaytQueueWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: KhaytQueueProvider()) { entry in
            KhaytQueueWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Khayt Queue")
        .description("Queue counts and live print progress from your desktop.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

@main
struct KhaytWidgetBundle: WidgetBundle {
    var body: some Widget {
        KhaytQueueWidget()
    }
}

/// Duplicate for the widget target — keep in sync with the app `WidgetSnapshotStore`.
enum WidgetSnapshotStore {
    static let appGroupID = "group.com.khaytapp.companion"
    private static let key = "khayt.widget.snapshot"

    static func load() -> WidgetSnapshot? {
        guard let data = UserDefaults(suiteName: appGroupID)?.data(forKey: key),
              let snap = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return nil }
        return snap
    }
}

struct WidgetPrint: Codable, Identifiable {
    var id: String
    var name: String
    var progress: Int
    var eta: String?
}

struct WidgetSnapshot: Codable {
    var shopName: String
    var queued: Int
    var printing: Int
    var post: Int
    var qc: Int
    var completedToday: Int
    var connected: Bool
    var updatedAt: Date
    var prints: [WidgetPrint]?
}
