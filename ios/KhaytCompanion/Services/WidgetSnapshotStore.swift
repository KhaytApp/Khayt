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
    var writtenAt: Date?   // when the app wrote it; optional so older snapshots still decode
    var money: WidgetMoney?   // the Money widget's figures; nil = nothing to show (no book, sample shop)
}

/// The Money widget's figures, worked out by the app from its own rules
/// (`WidgetFigures`) and only drawn by the widget. The texts are written the
/// way Home writes them, so the widget never formats or adds up money itself.
struct WidgetMoney: Codable, Equatable {
    var takingsToday: Double   // End of Day's "Earned today": net revenue of today's finished jobs
    var owed: Double           // Pulse's Owed (`owedByOrder` over open jobs)
    var unpaid: Int            // jobs that owe
    var lowStock: Int          // spools at or under their reorder point (`ReorderRules.isLowStock`)
    var currency: String?
    var takingsText: String
    var owedText: String
    var mark: String           // the currency's mark, or "" when the shop has none
    var asOf: Date             // how old the figures are (the book's age when offline)
}

enum WidgetSnapshotStore {
    static let appGroupID = "group.com.khaytapp.companion"
    static let widgetKind = "KhaytQueueWidget"
    static let moneyWidgetKind = "KhaytMoneyWidget"
    private static let key = "khayt.widget.snapshot"

    static func save(_ snapshot: WidgetSnapshot, now: Date = Date()) {
        var snapshot = snapshot
        snapshot.writtenAt = now
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults(suiteName: appGroupID)?.set(data, forKey: key)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        WidgetCenter.shared.reloadTimelines(ofKind: moneyWidgetKind)
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
