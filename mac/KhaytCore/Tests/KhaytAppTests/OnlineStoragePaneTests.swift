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
        #expect(s3["backUpNew"] == .bool(true))
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

    // MARK: - "Keep a copy" off must never switch the library to Drive

    /// Both remotes set up, secrets in the clear so `config` opens them here
    /// with no Keychain (a value without the seal marker is used as is).
    static let plainBucket: [String: JSONValue] = [
        "enabled": .bool(true), "provider": .string("r2"),
        "endpoint": .string("https://acc.r2.cloudflarestorage.com"), "bucket": .string("lib"),
        "accessKeyId": .string("k"), "secretAccessKey": .string("s"),
    ]
    static let plainDrive: [String: JSONValue] = [
        "enabled": .bool(true), "clientId": .string("123-khayt.apps.googleusercontent.com"),
        "clientSecret": .string(""), "refreshToken": .string("tok"), "folderName": .string("Prints"),
    ]

    static func settings(_ root: [String: JSONValue]) -> [String: JSONValue] {
        if case .object(let s)? = root["settings"] { return s }
        return [:]
    }
    static func library(_ settings: [String: JSONValue]) -> [String: JSONValue] {
        if case .object(let l)? = settings["printLibrary"] { return l }
        return [:]
    }

    /// Where `config` would send a new model, and whether it would copy it.
    static func sends(_ settings: [String: JSONValue]) async -> (drive: Bool, copies: Bool)? {
        guard let c = await CloudLibrary.config(settings: settings, build: nil) else { return nil }
        return (c.isDrive, c.backsUp)
    }

    @Test("REGRESSION: Drive connected, bucket saved over it, copy turned off — the bucket stays, nothing goes to Drive")
    func copyOffKeepsTheBucket() async {
        // Drive connected first, then Advanced › Use a storage bucket › Save.
        var lib: [String: JSONValue] = ["gdrive": .object(Self.plainDrive)]
        CloudLibrary.saveBucket(.init(provider: "r2", endpoint: "https://acc.r2.cloudflarestorage.com", bucket: "lib",
                                      region: "", prefix: "", accessKeyId: "k"),
                                sealedSecret: "s", in: &lib)
        var root: [String: JSONValue] = ["settings": .object(Self.with(lib))]
        #expect(CloudLibrary.remoteInUse(Self.settings(root)) == .bucket)
        #expect(await Self.sends(Self.settings(root))?.drive == false)
        #expect(await Self.sends(Self.settings(root))?.copies == true, "a bucket saved for the first time copies")

        CloudLibrary.applyOptions(.init(backsUp: false, tierOn: false, keepDays: 90), to: &root)
        let after = Self.settings(root)
        #expect(CloudLibrary.remoteInUse(after) == .bucket)
        #expect(await CloudLibrary.remoteInUse(after, build: nil) == .bucket)
        #expect(CloudLibrary.options(after).backsUp == false)
        let sent = await Self.sends(after)
        #expect(sent?.drive == false, "turning the copy off moved the library to Google Drive")
        #expect(sent?.copies == false)
        // Drive's own switch was not touched.
        guard case .object(let gd)? = Self.library(after)["gdrive"] else { Issue.record("no gdrive"); return }
        #expect(gd["backUpNew"] == nil)
        #expect(gd["refreshToken"] == .string("tok"), "Drive stays signed in")
    }

    @Test("REGRESSION: a book saved before the fix (bucket AND Drive both enabled) — copy off keeps the bucket")
    func copyOffOnAnOldBook() async {
        var root: [String: JSONValue] = [
            "settings": .object(Self.with(["s3": .object(Self.plainBucket), "gdrive": .object(Self.plainDrive)])),
        ]
        #expect(CloudLibrary.remoteInUse(Self.settings(root)) == .bucket)
        CloudLibrary.applyOptions(.init(backsUp: false, tierOn: false, keepDays: 90), to: &root)
        let after = Self.settings(root)
        #expect(CloudLibrary.remoteInUse(after) == .bucket)
        #expect(await Self.sends(after)?.drive == false)
        #expect(await Self.sends(after)?.copies == false)
        guard case .object(let s3)? = Self.library(after)["s3"] else { Issue.record("no s3"); return }
        #expect(s3["enabled"] == .bool(true), "enabled chooses the remote; the copy switch is backUpNew")
    }

    @Test("switching to Drive and back does not flip either one's copy switch")
    func switchingKeepsEachSwitch() async {
        var lib: [String: JSONValue] = ["s3": .object(Self.plainBucket), "gdrive": .object(Self.plainDrive)]
        CloudLibrary.choose(.bucket, in: &lib)
        var root: [String: JSONValue] = ["settings": .object(Self.with(lib))]
        CloudLibrary.applyOptions(.init(backsUp: false, tierOn: false, keepDays: 90), to: &root)

        // Over to Drive: Drive copies (its own switch, never set), the bucket's stays off.
        lib = Self.library(Self.settings(root))
        CloudLibrary.choose(.drive, in: &lib)
        #expect(CloudLibrary.remoteInUse(Self.with(lib)) == .drive)
        #expect(CloudLibrary.options(Self.with(lib)).backsUp == true)
        #expect(await Self.sends(Self.with(lib))?.drive == true)
        #expect(await Self.sends(Self.with(lib))?.copies == true)
        // Drive's copy off, there.
        root = ["settings": .object(Self.with(lib))]
        CloudLibrary.applyOptions(.init(backsUp: false, tierOn: false, keepDays: 90), to: &root)
        #expect(CloudLibrary.remoteInUse(Self.settings(root)) == .drive, "Drive's copy off keeps Drive")

        // And back to the bucket: still off, and Drive's off too.
        lib = Self.library(Self.settings(root))
        CloudLibrary.choose(.bucket, in: &lib)
        #expect(CloudLibrary.remoteInUse(Self.with(lib)) == .bucket)
        #expect(CloudLibrary.options(Self.with(lib)).backsUp == false)
        #expect(await Self.sends(Self.with(lib))?.drive == false)
        #expect(await Self.sends(Self.with(lib))?.copies == false)
        guard case .object(let gd)? = lib["gdrive"] else { Issue.record("no gdrive"); return }
        #expect(!CloudLibrary.driveBacksUp(gd))
        // Copy back on at the bucket: Drive's switch still untouched.
        root = ["settings": .object(Self.with(lib))]
        CloudLibrary.applyOptions(.init(backsUp: true, tierOn: false, keepDays: 90), to: &root)
        guard case .object(let gd2)? = Self.library(Self.settings(root))["gdrive"] else { Issue.record("no gdrive"); return }
        #expect(gd2["backUpNew"] == .bool(false))
        #expect(await Self.sends(Self.settings(root))?.drive == false)
    }

    @Test("a book from before the fix: the bucket's `enabled` is its copy switch until it is chosen away and back")
    func oldBookSwitchSurvivesTheTrip() {
        // Copying, no backUpNew yet: Drive chosen, then the bucket again — still copying.
        var lib: [String: JSONValue] = ["s3": .object(Self.plainBucket), "gdrive": .object(Self.plainDrive)]
        CloudLibrary.choose(.drive, in: &lib)
        #expect(CloudLibrary.remoteInUse(Self.with(lib)) == .drive)
        CloudLibrary.choose(.bucket, in: &lib)
        #expect(CloudLibrary.options(Self.with(lib)).backsUp == true)
        // Switched off, Drive off too (it read as "a bucket, not copying"): chosen, still off.
        var off = Self.plainBucket; off["enabled"] = .bool(false)
        lib = ["s3": .object(off)]
        #expect(CloudLibrary.remoteInUse(Self.with(lib)) == .bucket)
        #expect(CloudLibrary.options(Self.with(lib)).backsUp == false)
        CloudLibrary.choose(.bucket, in: &lib)
        #expect(CloudLibrary.options(Self.with(lib)).backsUp == false)
    }

    @Test("re-saving the bucket (a new key) keeps a backup the shop turned off")
    func resaveKeepsTheSwitch() {
        let form = CloudLibrary.BucketForm(provider: "r2", endpoint: "https://acc.r2.cloudflarestorage.com",
                                           bucket: "lib", region: "auto", prefix: "", accessKeyId: "k2")
        // Turned off in the pane.
        var root: [String: JSONValue] = ["settings": .object(Self.with(["s3": .object(Self.plainBucket)]))]
        CloudLibrary.applyOptions(.init(backsUp: false, tierOn: false, keepDays: 90), to: &root)
        var lib = Self.library(Self.settings(root))
        CloudLibrary.saveBucket(form, sealedSecret: "new", in: &lib)
        #expect(CloudLibrary.options(Self.with(lib)).backsUp == false)
        #expect(CloudLibrary.remoteInUse(Self.with(lib)) == .bucket)

        // Turned off in a book from before the fix: `enabled: false`, no Drive.
        var old = Self.plainBucket; old["enabled"] = .bool(false)
        lib = ["s3": .object(old)]
        #expect(CloudLibrary.options(Self.with(lib)).backsUp == false)
        CloudLibrary.saveBucket(form, sealedSecret: nil, in: &lib)
        #expect(CloudLibrary.options(Self.with(lib)).backsUp == false, "saving turned the backup back on")

        // A first bucket copies.
        lib = [:]
        CloudLibrary.saveBucket(form, sealedSecret: "s", in: &lib)
        #expect(CloudLibrary.options(Self.with(lib)).backsUp == true)
    }

    @Test("a bucket secret sealed on another Mac: the pane agrees with the library that Drive is used")
    func sealedElsewhere() async {
        var s3 = Self.plainBucket; s3["secretAccessKey"] = .string("__enc__not-this-mac")
        let settings = Self.with(["s3": .object(s3), "gdrive": .object(Self.plainDrive)])
        let real = await CloudLibrary.remoteInUse(settings, build: nil)
        #expect(real == .drive)
        #expect(await Self.sends(settings)?.drive == true, "config and remoteInUse must agree")
        #expect(CloudLibrary.options(settings, using: real).backsUp == true)
        // Only the stored-settings reading (the first frame) cannot tell.
        #expect(CloudLibrary.remoteInUse(settings) == .bucket)
        // The pane corrects itself from the async reading.
        let pane = try? QuoteSheetStatusTests.source("CloudLibrarySettings.swift")
        #expect(pane?.contains("CloudLibrary.remoteInUse(shop.settingsDict, build: shop.source.build)") == true)
    }

    @Test("a reload keeps what is typed in the bucket form and follows the book elsewhere")
    func draftRebased() {
        typealias D = CloudLibrarySettings.Draft
        var was = D(); was.bucket = "lib"; was.accessKeyId = "k"; was.driveFolder = "Prints"
        var typed = was; typed.accessKeyId = "k-new"; typed.secret = "half-typed"
        var now = was; now.driveFolder = "Other"
        let out = D.rebased(typed, was: was, now: now)
        #expect(out.accessKeyId == "k-new")
        #expect(out.secret == "half-typed")
        #expect(out.bucket == "lib")
        #expect(out.driveFolder == "Other", "an untouched field follows the book")
        #expect(D.rebased(was, was: was, now: now) == now)
    }
}
