import Foundation
import UserNotifications

// Shared by the app and the KhaytAlerts notification service extension — one
// description of a print ending, one rule for its button, one wording — so an
// alert reads the same whether the app noticed the ending or Apple woke the
// extension with it. Nothing here may reach for the app's singletons: the
// extension has none of them. Text comes in through `tr`.

/// A print that has just stopped, as the Mac's `print-finished` event
/// describes it (payload v1, agreed with the Mac and Cloud lanes). The same
/// shape is built on the phone from the live readings, so there is one kind
/// of alert whichever way it was noticed.
struct PrintFinished: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable { case finished, failed, cancelled }

    var v: Int = 1
    var kind: String = "print-finished"
    var at: String
    var machineId: String
    var machineName: String?
    var orderId: String?
    var project: String?
    var client: String?
    var filename: String?
    var durationS: Double?
    var outcome: Outcome
    var photo: Bool = false
    /// The stage the Mac moved the job to on this edge, if it did — so the
    /// phone never moves it a second time. Nil today: the Mac records the
    /// end, it does not advance the job.
    var advancedTo: String?
}

/// What an alert offers, and the one move each makes.
///
/// Agreed with the Mac lane, and deliberately narrow:
/// - a print that FINISHED can go on to post-processing — the next stage;
/// - one that FAILED or was CANCELLED can be re-queued (back to pending);
/// - an order already COMPLETED can be marked shipped — `markShipped` works
///   from completed only, and a print that has just finished is not that.
/// A reprint of a print that came out fine is another copy of the job, not a
/// move of this one, and is not offered.
enum PrintAlertAction: String, CaseIterable {
    case moveToPost = "khayt.print.post"
    case reprint = "khayt.print.reprint"
    case markShipped = "khayt.print.shipped"

    var titleKey: String {
        switch self {
        case .moveToPost: return "alert.print.move_post"
        case .reprint: return "alert.print.reprint"
        case .markShipped: return "alert.print.mark_shipped"
        }
    }

    /// The category an alert carries decides its buttons.
    var category: String { rawValue + ".category" }

    static let infoCategory = "khayt.print.info"

    /// Which button, if any, for this ending of this job.
    static func offered(for event: PrintFinished, orderStatus: String?) -> PrintAlertAction? {
        guard event.orderId != nil, let status = orderStatus else { return nil }
        switch event.outcome {
        case .finished:
            if status == "completed" { return .markShipped }
            // Already moved (by the Mac, or by hand since): nothing to offer.
            if let advanced = event.advancedTo, advanced != "printing" { return nil }
            return status == "printing" ? .moveToPost : nil
        case .failed, .cancelled:
            return status == "printing" ? .reprint : nil
        }
    }

    /// Registered by the app; the extension only names one.
    static func categories(tr: (String) -> String) -> Set<UNNotificationCategory> {
        var out = Set(allCases.map { action in
            UNNotificationCategory(
                identifier: action.category,
                actions: [UNNotificationAction(identifier: action.rawValue, title: tr(action.titleKey),
                                               // It writes to the shop's book: not from a locked phone.
                                               options: [.authenticationRequired])],
                intentIdentifiers: [])
        })
        out.insert(UNNotificationCategory(identifier: infoCategory, actions: [], intentIdentifiers: []))
        return out
    }
}


/// The words of a print alert.
enum PrintAlertText {
    static func content(for event: PrintFinished, orderStatus: String?,
                        tr: (String) -> String) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        switch event.outcome {
        case .finished: c.title = tr("alert.print.finished")
        case .failed: c.title = tr("alert.print.failed")
        case .cancelled: c.title = tr("alert.print.cancelled")
        }
        let what = event.project ?? event.filename ?? tr("alert.print.a_job")
        var parts = [what]
        if let machine = event.machineName, !machine.isEmpty { parts.append(machine) }
        if let s = event.durationS, s >= 60 {
            let f = DateComponentsFormatter()
            f.allowedUnits = s >= 3600 ? [.hour, .minute] : [.minute]
            f.unitsStyle = .abbreviated
            if let t = f.string(from: s) { parts.append(t) }
        }
        c.body = parts.joined(separator: " · ")
        c.sound = .default
        c.threadIdentifier = "khayt.prints"
        let action = PrintAlertAction.offered(for: event, orderStatus: orderStatus)
        c.categoryIdentifier = action?.category ?? PrintAlertAction.infoCategory
        var info: [String: Any] = ["machineId": event.machineId, "outcome": event.outcome.rawValue]
        if let order = event.orderId { info["orderId"] = order }
        c.userInfo = info
        return c
    }

    /// Every key the alert uses — the extension carries its own copy of these,
    /// and a test holds the two copies to the same words.
    static let keys = ["alert.print.finished", "alert.print.failed", "alert.print.cancelled",
                       "alert.print.a_job", "alert.print.move_post", "alert.print.reprint",
                       "alert.print.mark_shipped", "PUSH_TITLE", "PUSH_PRINT_FINISHED"]
}
