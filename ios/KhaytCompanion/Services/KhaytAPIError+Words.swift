import Foundation

/// The companion's API errors, in the language the app is set to.
///
/// Kept out of `KhaytModels.swift` on purpose — see the note on `KhaytAPIError`.
extension KhaytAPIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notConfigured: return L10n.tr("error.not_configured")
        case .invalidURL: return L10n.tr("error.invalid_url")
        case .unauthorized: return L10n.tr("error.unauthorized")
        case .server(let msg): return msg
        case .transport(let err): return err.localizedDescription
        }
    }
}
