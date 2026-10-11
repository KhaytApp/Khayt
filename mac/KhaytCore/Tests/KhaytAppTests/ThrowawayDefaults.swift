import Foundation

/// A `UserDefaults` suite for one test, gone again afterwards — the domain AND
/// its file.
///
/// `removePersistentDomain(forName:)` empties the domain but cfprefsd keeps
/// the `~/Library/Preferences/<suite>.plist` it wrote, so every run of a test
/// that made a fresh `khayt-offsite-test-<UUID>` suite left one more file
/// behind: 104 of them on the developer's Mac by Oct 2026. `clear` removes the
/// domain, makes cfprefsd write that out NOW (so it cannot re-create the file
/// after it is deleted), then deletes the file.
enum ThrowawayDefaults {

    static func make(_ prefix: String) -> (suite: String, defaults: UserDefaults)? {
        let suite = "\(prefix)-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return nil }
        return (suite, defaults)
    }

    static func clear(_ suite: String, _ defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: suite)
        CFPreferencesAppSynchronize(suite as CFString)
        try? FileManager.default.removeItem(at: plist(suite))
    }

    static func plist(_ suite: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Preferences/\(suite).plist")
    }
}
