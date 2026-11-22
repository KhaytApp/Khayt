import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Opening a model in the shop's own slicer.
@MainActor
struct SlicerTests {

    /// This shop's four, as the book actually holds them — vendor forks and a
    /// space in a bundle name included, because those are the shapes that break.
    static let settings: [String: JSONValue] = [
        "defaultSlicerId": .string("SL-mtep9y1hTW6"),
        "slicers": .array([
            .object(["id": .string("SL-mtep9y1hPAL"), "name": .string("PrusaSlicer"),
                     "path": .string("/Applications/PrusaSlicer.app/Contents/MacOS/PrusaSlicer"),
                     "args": .string("")]),
            .object(["id": .string("SL-mtep9y1hLXF"), "name": .string("OrcaSlicer"),
                     "path": .string("/Applications/OrcaSlicer.app/Contents/MacOS/OrcaSlicer"),
                     "args": .string("")]),
            .object(["id": .string("SL-mtep9y1hTW6"), "name": .string("Snapmaker Orca"),
                     "path": .string("/Applications/Snapmaker Orca.app/Contents/MacOS/Snapmaker_Orca"),
                     "args": .string("")]),
            .object(["id": .string("SL-mtep9y1hYCX"), "name": .string("Creality Print"),
                     "path": .string("/Applications/Creality Print.app/Contents/MacOS/CrealityPrint"),
                     "args": .string("")]),
        ]),
    ]

    @Test("the shop's slicers are read the way Khayt reads them")
    func readsTheList() async throws {
        let engine = try KhaytEngine()
        let list = try await engine.slicers(settings: Self.settings)
        #expect(list.count == 4)
        #expect(list.map(\.name) == ["PrusaSlicer", "OrcaSlicer", "Snapmaker Orca", "Creality Print"])

        // The default is the one the shop chose, not the first in the array —
        // and on this book those are different, which is the whole point of the
        // field.
        let first = try await engine.defaultSlicer(settings: Self.settings)
        #expect(first?.name == "Snapmaker Orca")
        #expect(first?.id != list.first?.id)
    }

    /// A book written before the list existed carries one slicer under
    /// `settings.slicer`. It still has to work — this is most of Khayt's
    /// installed base by age.
    @Test("a shop with only the legacy single slicer still gets one")
    func legacyShape() async throws {
        let engine = try KhaytEngine()
        let old: [String: JSONValue] = ["slicer": .object([
            "path": .string("/Applications/PrusaSlicer.app"), "args": .string(""),
        ])]
        let list = try await engine.slicers(settings: old)
        #expect(list.count == 1)
        // The name is guessed from the path, because the legacy shape has none.
        #expect(list.first?.name == "PrusaSlicer")
        #expect(try await engine.defaultSlicer(settings: old)?.path == "/Applications/PrusaSlicer.app")
    }

    @Test("a shop with no slicer configured is offered nothing")
    func noSlicers() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.slicers(settings: [:]).isEmpty)
        #expect(try await engine.defaultSlicer(settings: [:]) == nil)
    }

    // MARK: - What may be launched

    /// THE GUARD IS ASKED, not assumed from the entry existing.
    ///
    /// `settings.slicers[]` arrives in a restored backup and through cloud
    /// sync, so the program named there was chosen by whoever wrote that book,
    /// and the `args` beside it too. The Electron app carried this exact rule
    /// for months and called it nowhere — every one of the paths below was
    /// accepted as a slicer.
    @Test("a program that does not look like a slicer is refused")
    func theAllowlistIsAsked() async throws {
        let engine = try KhaytEngine()
        for path in ["/Applications/PrusaSlicer.app/Contents/MacOS/PrusaSlicer",
                     "/Applications/Snapmaker Orca.app/Contents/MacOS/Snapmaker_Orca",
                     "/Applications/Creality Print.app/Contents/MacOS/CrealityPrint",
                     "C:/Program Files/OrcaSlicer/orca-slicer.exe"] {
            #expect(try await engine.mayLaunchAsSlicer(path: path), "should allow \(path)")
        }
        // None of these is a shell, and each runs an arbitrary command from its
        // own arguments. A denylist of interpreters lets them all through.
        for path in ["/usr/bin/awk", "/usr/bin/find", "/usr/bin/xargs", "/usr/bin/gdb",
                     "/usr/bin/make", "/bin/busybox", "/usr/bin/git", "/usr/bin/expect",
                     "/bin/bash", "/usr/bin/python3", "", "/usr/local/bin/totally-legit"] {
            #expect(try await engine.mayLaunchAsSlicer(path: path) == false, "should refuse \(path)")
        }
    }

    /// And the launcher actually calls it. Equality with the rule proves the
    /// rule is right; this proves it is reached — the failure that put this
    /// whole area on the list in the first place.
    @Test("the launcher refuses before it opens anything")
    func theLauncherAsks() {
        var asked: [String] = []
        let refusal = FileActions.openInSlicer(URL(fileURLWithPath: "/tmp/model.3mf"),
                                               slicerPath: "/usr/bin/awk") { path in
            asked.append(path)
            return false
        }
        #expect(asked == ["/usr/bin/awk"])
        #expect(refusal == "notAllowed")
    }

    /// A path that passes the allowlist but is not on this Mac is a different
    /// answer, and the shop gets a different sentence.
    @Test("a slicer that is not installed says so rather than failing silently")
    func missingSlicer() {
        let refusal = FileActions.openInSlicer(
            URL(fileURLWithPath: "/tmp/model.3mf"),
            slicerPath: "/Applications/NotInstalledSlicer.app/Contents/MacOS/NotInstalledSlicer"
        ) { _ in true }
        #expect(refusal == "missing")
    }

    // MARK: - Finding the .app

    /// The stored path points at the executable inside the bundle, because that
    /// is what a slicer wants on a command line. Running it directly on macOS
    /// gives a second, dockless copy of an app the shop may already have open,
    /// so the bundle is what gets opened.
    @Test("the executable's bundle is what gets launched")
    func bundleFromExecutable() {
        let cases = [
            ("/Applications/Snapmaker Orca.app/Contents/MacOS/Snapmaker_Orca",
             "/Applications/Snapmaker Orca.app"),
            ("/Applications/PrusaSlicer.app/Contents/MacOS/PrusaSlicer",
             "/Applications/PrusaSlicer.app"),
            // Already a bundle.
            ("/Applications/OrcaSlicer.app", "/Applications/OrcaSlicer.app"),
            // Not in a bundle at all — a Homebrew or Linux-style install
            // somebody copied over. Handed back unchanged rather than guessed
            // at; NSWorkspace refuses it, which is the honest outcome.
            ("/usr/local/bin/PrusaSlicer", "/usr/local/bin/PrusaSlicer"),
        ]
        for (input, expected) in cases {
            let out = FileActions.appBundle(containing: URL(fileURLWithPath: input))
            #expect(out.path == expected, "\(input) → \(out.path)")
        }
    }

    /// The outer `.app` wins, not an inner one. A helper bundled inside a
    /// slicer would otherwise be launched instead of the slicer.
    @Test("a nested bundle resolves to the outermost one")
    func nestedBundles() {
        let out = FileActions.appBundle(containing: URL(fileURLWithPath:
            "/Applications/OrcaSlicer.app/Contents/Helpers/Updater.app/Contents/MacOS/Updater"))
        #expect(out.path == "/Applications/OrcaSlicer.app")
    }
}

/// Finding the slicers a Mac already has.
///
/// Against bundles built in a temp directory, not against `/Applications`: a
/// test whose answer depends on what somebody installed is a test that passes
/// on the machine it was written on.
@MainActor
struct SlicerFinderTests {

    /// A `.app` with an Info.plist and an executable, as the scan expects one.
    static func makeBundle(in dir: URL, app: String, executable: String,
                           runnable: Bool = true) throws -> URL {
        let bundle = dir.appending(path: app)
        let macos = bundle.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        let plist = ["CFBundleExecutable": executable]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: bundle.appending(path: "Contents/Info.plist"))
        let binary = macos.appending(path: executable)
        FileManager.default.createFile(atPath: binary.path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: runnable ? [.posixPermissions: 0o755] : [:])
        return bundle
    }

    static func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "khayt-slicers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The binary is read from the bundle, not guessed from its name.
    ///
    /// Snapmaker's app is "Snapmaker Orca.app" and its binary "Snapmaker_Orca";
    /// a dozen vendor forks each differ in their own way. main.js carries a
    /// hand-written table of eighteen for exactly this, and a table goes stale.
    @Test("the executable comes from the bundle's own Info.plist")
    func readsTheBundle() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try Self.makeBundle(in: dir, app: "Snapmaker Orca.app",
                                         executable: "Snapmaker_Orca")
        let found = try #require(SlicerFinder.executable(in: bundle))
        #expect(found.lastPathComponent == "Snapmaker_Orca")
        #expect(found.path.hasSuffix("Snapmaker Orca.app/Contents/MacOS/Snapmaker_Orca"))
    }

    @Test("a bundle with no plist, no executable key, or nothing runnable is skipped")
    func incompleteBundles() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // No Info.plist at all.
        let bare = dir.appending(path: "Bare.app")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        #expect(SlicerFinder.executable(in: bare) == nil)

        // A plist, but the named binary is not executable — a broken install,
        // or a bundle still being copied.
        let notRunnable = try Self.makeBundle(in: dir, app: "Half.app", executable: "Half",
                                              runnable: false)
        #expect(SlicerFinder.executable(in: notRunnable) == nil)
    }

    /// The scan asks the SAME question the launcher asks. Two lists is how a
    /// shop is offered a slicer the guard then refuses to run.
    @Test("only bundles the launcher would accept are offered")
    func scanUsesTheAllowlist() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try Self.makeBundle(in: dir, app: "OrcaSlicer.app", executable: "OrcaSlicer")
        _ = try Self.makeBundle(in: dir, app: "Snapmaker Orca.app", executable: "Snapmaker_Orca")
        // Not a slicer. It has an Info.plist and a runnable binary like the
        // others, so only the allowlist keeps it out.
        _ = try Self.makeBundle(in: dir, app: "Terminal.app", executable: "Terminal")
        _ = try Self.makeBundle(in: dir, app: "Mail.app", executable: "Mail")

        let engine = try KhaytEngine()
        var allowed: [String: Bool] = [:]
        for entry in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            allowed[entry] = try await engine.mayLaunchAsSlicer(path: entry)
        }
        let found = SlicerFinder.installed(in: [dir], allowed: { allowed[$0] ?? false },
                                           name: { $0 })
        #expect(found.count == 2)
        #expect(Set(found.map(\.name)) == ["OrcaSlicer.app", "Snapmaker Orca.app"])
    }

    /// Two directories, one bundle each — and `~/Applications` is the one people
    /// forget: it is where an app dragged out of a DMG without administrator
    /// rights lands.
    @Test("both application folders are searched, and a duplicate path is offered once")
    func bothFolders() throws {
        let a = try Self.tempDir(), b = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        _ = try Self.makeBundle(in: a, app: "PrusaSlicer.app", executable: "PrusaSlicer")
        _ = try Self.makeBundle(in: b, app: "OrcaSlicer.app", executable: "OrcaSlicer")

        let found = SlicerFinder.installed(in: [a, b], allowed: { _ in true }, name: { $0 })
        #expect(found.count == 2)

        // The same directory twice: a path already offered is not offered again.
        let twice = SlicerFinder.installed(in: [a, a], allowed: { _ in true }, name: { $0 })
        #expect(twice.count == 1)
    }

    @Test("a folder that is not there is not an error")
    func missingFolder() {
        let nowhere = URL(fileURLWithPath: "/does/not/exist/\(UUID().uuidString)")
        #expect(SlicerFinder.installed(in: [nowhere], allowed: { _ in true }, name: { $0 }).isEmpty)
    }
}
