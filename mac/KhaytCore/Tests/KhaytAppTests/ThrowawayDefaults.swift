import Foundation

/// A `UserDefaults` suite for one test that leaves nothing in
/// `~/Library/Preferences`.
///
/// A suite NAMED `khayt-offsite-test-<UUID>` is a file in the user's
/// Preferences folder, and `removePersistentDomain(forName:)` does not take
/// it away: cfprefsd writes the emptied domain back out, sometimes after the
/// test has deleted the file — under a full run's load, every time. 104 such
/// files had piled up on the developer's Mac by Oct 2026.
///
/// So the suite is an ABSOLUTE PATH inside a temp folder of its own (which
/// CFPreferences accepts for an unsandboxed process): whatever cfprefsd writes,
/// and whenever, lands there, and the folder goes when the test is done.
enum ThrowawayDefaults {

    struct Suite {
        let name: String
        let folder: URL
        let defaults: UserDefaults
    }

    static func make(_ prefix: String) -> Suite? {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "khayt-defaults-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
        else { return nil }
        let name = folder.appending(path: "\(prefix)-\(UUID().uuidString).plist").path
        guard let defaults = UserDefaults(suiteName: name) else { return nil }
        return Suite(name: name, folder: folder, defaults: defaults)
    }

    static func clear(_ suite: Suite) {
        suite.defaults.removePersistentDomain(forName: suite.name)
        CFPreferencesAppSynchronize(suite.name as CFString)
        try? FileManager.default.removeItem(at: suite.folder)   // scratch
    }
}
