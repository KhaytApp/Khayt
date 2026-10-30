import Foundation

/// The words live here, not in `KhaytModels.swift`, which must compile alone
/// for the contract check (see `LocalizationCompletenessTests`).
extension WaitingListItem {
    var displayTitle: String {
        let p = project?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (p?.isEmpty == false) ? p! : L10n.format("order.untitled", id)
    }
}
