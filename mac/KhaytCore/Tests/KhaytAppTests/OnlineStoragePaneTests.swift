import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Settings › Online storage, rebuilt around Google Drive (alpha.54 report:
/// "the tab switched to storage bucket, and the gdrive tab doesn't really look
/// that good or understandable").
@MainActor
struct OnlineStoragePaneTests {

    /// The shop's settings on the day of the report, secrets stood in for.
    /// There is NO `s3` block — that absence is what the flip turned on.
    static let shopsBook: [String: JSONValue] = [
        "printLibrary": .object([
            "gdrive": .object([
                "enabled": .bool(true),
                "clientId": .string("123-khayt.apps.googleusercontent.com"),
                "clientSecret": .string("__enc__secret"),
                "refreshToken": .string("__enc__token"),
                "folderName": .string("Auto_Copied_Shared"),
                "folderId": .string(""),
            ]),
            "tier": .object(["enabled": .bool(true), "keepDays": .number(90)]),
        ]),
    ]

    /// The same library as a `printLibrary` block, for pictures.
    static var connectedLibrary: [String: JSONValue] {
        if case .object(let l)? = shopsBook["printLibrary"] { return l }
        return [:]
    }

    static func bucket(enabled: Bool) -> JSONValue {
        .object([
            "enabled": .bool(enabled), "provider": .string("r2"),
            "endpoint": .string("https://acc.r2.cloudflarestorage.com"), "bucket": .string("lib"),
            "accessKeyId": .string("k"), "secretAccessKey": .string("__enc__s"),
        ])
    }

    static func with(_ library: [String: JSONValue]) -> [String: JSONValue] {
        ["printLibrary": .object(library)]
    }

    @Test("REGRESSION: a connected Drive with no bucket shows as Drive, not \"A storage bucket\"")
    func connectedDriveIsDrive() {
        #expect(CloudLibrary.remoteInUse(Self.shopsBook) == .drive)
        #expect(!CloudLibrarySettings.opensOnBucket(Self.shopsBook))
        #expect(CloudLibrary.driveConnected(Self.shopsBook))
        // And the pane itself no longer decides from its own form defaults.
        let pane = try? QuoteSheetStatusTests.source("CloudLibrarySettings.swift")
        #expect(pane?.contains("&& !d.backsUp") == false)
        #expect(pane?.contains("CloudLibrary.remoteInUse") == true)
    }

    @Test("the shop's options read as they are stored: copy on, move after 90 days, its own folder")
    func shopsOptions() {
        let o = CloudLibrary.options(Self.shopsBook)
        #expect(o == .init(backsUp: true, tierOn: true, keepDays: 90))
        #expect(CloudLibrary.driveFolder(Self.shopsBook) == "Auto_Copied_Shared")
    }

    @Test("nothing set up: Google Drive is the default, and its folder is Khayt's")
    func driveIsTheDefault() {
        #expect(CloudLibrary.remoteInUse([:]) == .none)
        #expect(!CloudLibrarySettings.opensOnBucket([:]))
        #expect(CloudLibrary.driveFolder([:]) == "Khayt print library")
        // Drive switched on but never signed in is not "in use" either.
        let unsigned = Self.with(["gdrive": .object(["enabled": .bool(true), "clientId": .string("x")])])
        #expect(CloudLibrary.remoteInUse(unsigned) == .none)
        #expect(!CloudLibrarySettings.opensOnBucket(unsigned))
    }

    @Test("a bucket in use is shown in Drive's place, in the same order the library picks its remote")
    func bucketOrder() {
        var lib: [String: JSONValue] = ["s3": Self.bucket(enabled: true)]
        #expect(CloudLibrary.remoteInUse(Self.with(lib)) == .bucket)
        #expect(CloudLibrarySettings.opensOnBucket(Self.with(lib)))
        // Both on: the bucket wins, as in `CloudLibrary.config` and the other app.
        if case .object(let l)? = Self.shopsBook["printLibrary"] { lib["gdrive"] = l["gdrive"] }
        #expect(CloudLibrary.remoteInUse(Self.with(lib)) == .bucket)
        // The bucket kept but not backing up: the connected Drive is used.
        lib["s3"] = Self.bucket(enabled: false)
        #expect(CloudLibrary.remoteInUse(Self.with(lib)) == .drive)
        // A half-typed bucket (no secret) is not a bucket.
        let half = Self.with(["s3": .object(["enabled": .bool(true), "bucket": .string("lib")])])
        #expect(CloudLibrary.remoteInUse(half) == .none)
    }

    @Test("the folder name: typed wins, a blank field keeps the shop's name, and empty becomes Khayt's")
    func folderName() {
        #expect(CloudLibrary.folderToWrite(typed: " Prints ", stored: .string("Auto_Copied_Shared")) == "Prints")
        #expect(CloudLibrary.folderToWrite(typed: "", stored: .string("Auto_Copied_Shared")) == "Auto_Copied_Shared")
        #expect(CloudLibrary.folderToWrite(typed: "  ", stored: nil) == "Khayt print library")
        #expect(CloudLibrary.folderToWrite(typed: "", stored: .string(" ")) == "Khayt print library")
    }

    @Test("options on a Drive book: Drive's own switch and the tier, and no bucket invented")
    func applyOnDrive() {
        var root: [String: JSONValue] = ["settings": .object(Self.shopsBook)]
        CloudLibrary.applyOptions(.init(backsUp: false, tierOn: true, keepDays: 180), to: &root)
        guard case .object(let settings)? = root["settings"] else { Issue.record("no settings"); return }
        #expect(CloudLibrary.options(settings) == .init(backsUp: false, tierOn: true, keepDays: 180))
        #expect(CloudLibrary.remoteInUse(settings) == .drive, "turning the copy off must not stop using Drive")
        guard case .object(let lib)? = settings["printLibrary"] else { Issue.record("no library"); return }
        #expect(lib["s3"] == nil)
        guard case .object(let gd)? = lib["gdrive"] else { Issue.record("no gdrive"); return }
        #expect(gd["backUpNew"] == .bool(false))
        #expect(gd["folderName"] == .string("Auto_Copied_Shared"))
        #expect(gd["refreshToken"] == .string("__enc__token"))
        #expect(!CloudLibrary.driveBacksUp(gd))
        #expect(CloudLibrary.driveBacksUp([:]), "absent is on: Drive has always copied new models")
    }

    @Test("options on a bucket book: the bucket's own switch")
    func applyOnBucket() {
        var root: [String: JSONValue] = ["settings": .object(Self.with(["s3": Self.bucket(enabled: true)]))]
        CloudLibrary.applyOptions(.init(backsUp: true, tierOn: false, keepDays: 30), to: &root)
        guard case .object(let settings)? = root["settings"],
              case .object(let lib)? = settings["printLibrary"],
              case .object(let s3)? = lib["s3"] else { Issue.record("no s3"); return }
        #expect(s3["enabled"] == .bool(true))
        #expect(lib["gdrive"] == nil)
        #expect(CloudLibrary.options(settings) == .init(backsUp: true, tierOn: false, keepDays: 30))
    }

    @Test("options reach the file through the book's writer")
    func applyReachesDisk() async throws {
        let url = try SettingsReachDiskTests.scratchBook()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            var settings = Shop.settings(root)
            settings["printLibrary"] = Self.shopsBook["printLibrary"]
            root["settings"] = .object(settings)
        }
        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            CloudLibrary.applyOptions(.init(backsUp: true, tierOn: false, keepDays: 60), to: &root)
        }
        let settings = try SettingsReachDiskTests.settingsOnDisk(url)
        #expect(CloudLibrary.options(settings) == .init(backsUp: true, tierOn: false, keepDays: 60))
        #expect(CloudLibrary.remoteInUse(settings) == .drive)
    }

    @Test("off-site backup: Drive is suggested, never switched to over a destination the shop chose")
    func offsiteSuggestsDrive() {
        typealias S = OffsiteBackupState.Settings
        // The shop's: an iCloud Drive folder, switched on.
        let icloud = S(enabled: true, destination: .folder, folderPath: "/Users/x/Library/Mobile Documents/com~apple~CloudDocs/Khayt Backups")
        #expect(OffsiteBackupState.suggestsDrive(icloud, driveConnected: true))
        #expect(OffsiteBackupState.adoptingDrive(icloud, driveConnected: true) == icloud)
        // Nothing ever chosen: Drive is simply the default.
        #expect(OffsiteBackupState.adoptingDrive(S(), driveConnected: true).destination == .drive)
        #expect(!OffsiteBackupState.suggestsDrive(S(), driveConnected: true))
        // Drive not connected: nothing offered, nothing changed.
        #expect(!OffsiteBackupState.suggestsDrive(icloud, driveConnected: false))
        #expect(OffsiteBackupState.adoptingDrive(S(), driveConnected: false) == S())
        // Already Drive: nothing to offer.
        #expect(!OffsiteBackupState.suggestsDrive(S(enabled: true, destination: .drive), driveConnected: true))
    }
}
