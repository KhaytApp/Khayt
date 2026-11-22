import CoreSpotlight
import Foundation
import UserNotifications
#if canImport(WidgetKit)
import WidgetKit
#endif

/// What a shop leaves on the phone OUTSIDE the book and the cache — and
/// what unpairing has to take with it.
///
/// `ConnectionSettings.unpair` deletes the PIN, the book, the cache and the
/// library's pictures. A phone unpaired that way still showed the shop's jobs
/// in Spotlight, its alerts in the feed and Notification Centre, its queue on
/// the Home Screen widget, and kept the invoices it had shared and the model
/// files it had quoted in its temporary folder. Each is the shop's, and each
/// outlived the pairing. They are gathered here, because each lives with a
/// different framework, and a list kept in one place is the one that gets
/// extended when the next one appears.
@MainActor
enum ShopTraces {
    /// The temporary folders the app writes a shop's papers into:
    /// `InvoicePage.pdfFile` and `QuotedFile.copy`.
    nonisolated static let tempPrefixes = ["khayt-paper-", "quote-"]

    static func forget() {
        // Spotlight: every job, from this shop or the sample one.
        JobSearch.forget()
        // The feed of what happened.
        ShopFeed.shared.clear()
        // The Home Screen widget's copy of the queue and the prints.
        WidgetSnapshotStore.clear()
        // Alerts already shown, and the ones scheduled to be.
        let centre = UNUserNotificationCenter.current()
        centre.removeAllDeliveredNotifications()
        centre.removeAllPendingNotificationRequests()
        // Shared invoices and quoted model files.
        removeTempCopies()
    }

    /// Delete the shop's papers and quoted files from `dir`. Returns how many
    /// folders went. Anything else in the temporary folder is not ours to touch.
    @discardableResult
    nonisolated static func removeTempCopies(in dir: URL = FileManager.default.temporaryDirectory) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? []
        var removed = 0
        for name in names where tempPrefixes.contains(where: { name.hasPrefix($0) }) {
            if (try? FileManager.default.removeItem(at: dir.appending(path: name))) != nil { removed += 1 }
        }
        return removed
    }
}
