import AppIntents
import Foundation

/// "Khayt notifications" in a Focus: which kinds of shop news get through.
///
/// Apple's mechanism, not a setting of our own: the filter returns a
/// `notificationFilterPredicate`, and the SYSTEM holds back any Khayt
/// notification whose `filterCriteria` it does not match — local alerts and
/// pushes alike, since both are labelled (`NotificationKind`). A Sleep Focus
/// can let a failed print through and nothing else; a Work Focus everything.
struct ShopFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Khayt notifications"
    static let description: IntentDescription? = IntentDescription("Choose which shop notifications reach you in this Focus.")

    @Parameter(title: "Print finished or failed", default: true) var prints: Bool
    @Parameter(title: "New order requests", default: true) var requests: Bool
    @Parameter(title: "Queue, late jobs, low filament", default: false) var shop: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(Self.summary(allowed: allowed))")
    }

    var allowed: [String] {
        var out: [String] = []
        if prints { out.append(NotificationKind.print) }
        if requests { out.append(NotificationKind.intake) }
        if shop { out.append(NotificationKind.shop) }
        return out
    }

    var appContext: FocusFilterAppContext {
        FocusFilterAppContext(notificationFilterPredicate: Self.predicate(allowed: allowed))
    }

    func perform() async throws -> some IntentResult { .result() }

    /// The predicate the system evaluates against a notification's `filterCriteria`.
    static func predicate(allowed: [String]) -> NSPredicate {
        NSPredicate(format: "SELF IN %@", allowed)
    }

    static func summary(allowed: [String]) -> String {
        if allowed.isEmpty { return L10n.tr("focus.none") }
        return allowed.map { L10n.tr("focus.kind.\($0)") }.joined(separator: ", ")
    }
}
