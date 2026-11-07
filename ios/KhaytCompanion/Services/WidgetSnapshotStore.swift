import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// A single active print for the live widget.
struct WidgetPrint: Codable, Identifiable {
    var id: String          // stable machine id
    var name: String
    var progress: Int       // 0–100
    var eta: String?        // formatted "2h 14m"
}

/// Data shared with the Khayt home screen widget (App Group).
struct WidgetSnapshot: Codable {
    var shopName: String
    var queued: Int
    var printing: Int
    var post: Int
    var qc: Int
    var completedToday: Int
    var connected: Bool
    var updatedAt: Date
    var prints: [WidgetPrint]?   // optional for backward-compatible decoding
}

enum WidgetSnapshotStore {
    static let appGroupID = "group.com.khaytapp.companion"
    static let widgetKind = "KhaytQueueWidget"
    private static let key = "khayt.widget.snapshot"

    static func save(_ snapshot: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults(suiteName: appGroupID)?.set(data, forKey: key)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        #endif
    }

    /// Unpairing: the widgets stop showing the shop at once.
    static func clear() {
        UserDefaults(suiteName: appGroupID)?.removeObject(forKey: key)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    static func load() -> WidgetSnapshot? {
        guard let data = UserDefaults(suiteName: appGroupID)?.data(forKey: key),
              let snap = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return nil }
        return snap
    }
}
