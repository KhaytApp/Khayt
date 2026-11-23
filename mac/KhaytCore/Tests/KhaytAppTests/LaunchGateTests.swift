import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// "Khayt was updated" (Mac file, page 28, frame B): at the first start after
/// an update, the "Before you update" items this Mac has not read, held until
/// they are.
@MainActor
@Suite(.serialized)
struct LaunchGateTests {
    static let engine = OperatorLockTests.sharedEngine
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    /// A gate file with three Mac releases; beta.42 and beta.43 share one item.
    static let gates = #"""
        {"about":"test","gates":{"9.9.9":["A desktop item the Mac must never show"]},
         "mac":{"4.0.0-beta.41":["Old news"],
                "4.0.0-beta.42":["Update every computer first.","Check Settings › Phones."],
                "4.0.0-beta.43":["Prices now include VAT.","Update every computer first."]}}
        """#

    static func pending(current: String, last: String?, accepted: String? = nil, book: Bool = true,
                        floor: String = "4.0.0-beta.42") async throws -> [KhaytEngine.GatedRelease] {
        try await engine.launchGatePending(current: current, lastRun: last, acceptedFor: accepted, hasBook: book,
                                           floor: floor, gates: gates)
    }

    @Test("what is unread: every gated release after the one last run, newest first, each item once")
    func rule() async throws {
        // From beta.41 to beta.43: both releases, newest first; the shared item is said once, under the newest.
        let both = try await Self.pending(current: "4.0.0-beta.43", last: "4.0.0-beta.41")
        #expect(both.map(\.version) == ["4.0.0-beta.43", "4.0.0-beta.42"])
        #expect(both[0].items == ["Prices now include VAT.", "Update every computer first."])
        #expect(both[1].items == ["Check Settings › Phones."])
        // From beta.42: only what came after it.
        #expect(try await Self.pending(current: "4.0.0-beta.43", last: "4.0.0-beta.42").map(\.version) == ["4.0.0-beta.43"])
        // The same build, an older build over a newer one, and a release with no items: nothing.
        #expect(try await Self.pending(current: "4.0.0-beta.43", last: "4.0.0-beta.43").isEmpty)
        #expect(try await Self.pending(current: "4.0.0-beta.42", last: "4.0.0-beta.43").isEmpty)
        #expect(try await Self.pending(current: "4.0.0-beta.44", last: "4.0.0-beta.43").isEmpty)
        // beta.9 is older than beta.10: numbers, not text.
        #expect(try await Self.pending(current: "4.0.0-beta.43", last: "4.0.0-beta.9").count == 3)
        // The desktop's gates are never the Mac's.
        let all = try await Self.pending(current: "9.9.9", last: "4.0.0-alpha.1")
        #expect(!all.flatMap(\.items).contains { $0.contains("desktop") })
    }

    @Test("no record: a new install is asked nothing; a Mac with a book counts as coming from the floor")
    func noRecord() async throws {
        #expect(try await Self.pending(current: "4.0.0-beta.43", last: nil, book: false).isEmpty)
        // A book and no record: every gated release AFTER the floor. The floor's own items are not shown.
        #expect(try await Self.pending(current: "4.0.0-beta.43", last: nil).map(\.version) == ["4.0.0-beta.43"])
        #expect(try await Self.pending(current: "4.0.0-beta.43", last: nil, floor: "4.0.0-beta.40").map(\.version)
                == ["4.0.0-beta.43", "4.0.0-beta.42", "4.0.0-beta.41"])
        // Already read (in the update window, when that gate exists): not asked again.
        #expect(try await Self.pending(current: "4.0.0-beta.43", last: "4.0.0-beta.41", accepted: "4.0.0-beta.43").isEmpty)
        // A gate file that is not one is an error, never "nothing to read".
        for bad in ["not json", "{}", #"{"mac":[]}"#, #"{"mac":"x"}"#] {
            await #expect(throws: (any Error).self, Comment(rawValue: bad)) {
                _ = try await Self.engine.launchGatePending(current: "4.0.0-beta.43", lastRun: "4.0.0-beta.41", acceptedFor: nil,
                                                            hasBook: true, floor: "4.0.0-beta.42", gates: bad)
            }
        }
    }

    static func shop() async -> Shop {
        let shop = await OperatorLockTests.shop(on: false)
        shop.launchGateDefaults = UserDefaults(suiteName: "khayt.gate.test.\(UUID().uuidString)")!
        shop.launchGateFileForTests = gates
        shop.launchGateHasBookForTests = false
        return shop
    }

    @Test("this Mac's record: held until read, then moved; with nothing to read it is moved at once, down too")
    func record() async throws {
        let shop = await Self.shop()
        let d = shop.launchGateDefaults
        // A Mac with a book and no record (it updated from before the sheet existed) counts as
        // coming from the floor, one release earlier than strictly needed: beta.42's item, which
        // was only ever release notes, is shown once more, and so is beta.43's.
        shop.launchGateHasBookForTests = true
        await shop.checkLaunchGate(current: "4.0.0-beta.43")
        #expect(LaunchGate.floor == "4.0.0-beta.41")
        #expect(shop.launchGatePending.map(\.version) == ["4.0.0-beta.43", "4.0.0-beta.42"] && shop.launchGateFrom == nil)
        #expect(d.string(forKey: LaunchGate.lastRunKey) == nil, "the record moved before anything was read")
        // A new install (no book on this Mac): nothing is asked, and the record is the running version.
        shop.launchGateHasBookForTests = false
        await shop.checkLaunchGate(current: "4.0.0-beta.43")
        #expect(shop.launchGatePending.isEmpty && !shop.showsLaunchGate)
        #expect(d.string(forKey: LaunchGate.lastRunKey) == "4.0.0-beta.43")
        // It ran beta.41; now beta.43: the sheet stands, and the record does NOT move until it is read.
        d.set("4.0.0-beta.41", forKey: LaunchGate.lastRunKey)
        await shop.checkLaunchGate(current: "4.0.0-beta.43")
        #expect(shop.launchGatePending.count == 2 && shop.showsLaunchGate)
        #expect(shop.launchGateFrom == "4.0.0-beta.41" && shop.launchGateCurrent == "4.0.0-beta.43")
        #expect(d.string(forKey: LaunchGate.lastRunKey) == "4.0.0-beta.41", "quitting would have skipped the sheet for good")
        // Quit and start again without reading: it is back.
        await shop.checkLaunchGate(current: "4.0.0-beta.43")
        #expect(shop.showsLaunchGate)
        // Read.
        shop.acceptLaunchGate()
        #expect(!shop.showsLaunchGate && shop.launchGatePending.isEmpty)
        #expect(d.string(forKey: LaunchGate.lastRunKey) == "4.0.0-beta.43" && d.string(forKey: LaunchGate.acceptedForKey) == "4.0.0-beta.43")
        await shop.checkLaunchGate(current: "4.0.0-beta.43")
        #expect(!shop.showsLaunchGate, "asked twice")
        // A downgrade asks nothing and moves the record down, so the next upgrade asks again.
        await shop.checkLaunchGate(current: "4.0.0-beta.41")
        #expect(!shop.showsLaunchGate && d.string(forKey: LaunchGate.lastRunKey) == "4.0.0-beta.41")
        // A build with no version (swift run, a test) does nothing at all.
        d.removeObject(forKey: LaunchGate.lastRunKey)
        await shop.checkLaunchGate(current: nil)
        #expect(d.string(forKey: LaunchGate.lastRunKey) == nil)
        // The book is never written: the record is this Mac's.
        #expect(shop.settingsDict["launchGate"] == nil)
        // A gate file that cannot be read shows nothing AND leaves the record alone, so a later
        // build with a good file still shows what this one could not.
        d.set("4.0.0-beta.41", forKey: LaunchGate.lastRunKey)
        d.removeObject(forKey: LaunchGate.acceptedForKey)
        shop.launchGateFileForTests = "not json"
        await shop.checkLaunchGate(current: "4.0.0-beta.43")
        #expect(!shop.showsLaunchGate && d.string(forKey: LaunchGate.lastRunKey) == "4.0.0-beta.41", "an unreadable file was taken for “read”")
        shop.launchGateFileForTests = Self.gates
        await shop.checkLaunchGate(current: "4.0.0-beta.43")
        #expect(shop.showsLaunchGate)
    }

    @Test("with the staff lock on, the sign-in screen comes first; whoever signs in may read and continue")
    func afterSignIn() async throws {
        let shop = await OperatorLockTests.shop()
        shop.launchGateDefaults = UserDefaults(suiteName: "khayt.gate.test.\(UUID().uuidString)")!
        shop.launchGateFileForTests = Self.gates
        shop.launchGatePending = [.init(version: "4.0.0-beta.43", items: ["x"])]
        shop.launchGateCurrent = "4.0.0-beta.43"
        #expect(shop.needsSignIn && !shop.showsLaunchGate)
        #expect(await shop.signIn("OP-v", pin: "4444") == .ok)       // a viewer
        #expect(shop.showsLaunchGate)
        shop.acceptLaunchGate()
        #expect(!shop.showsLaunchGate)
    }

    @Test("the words are frame B's, and an item says which release it is from")
    func words() async throws {
        let shop = await OperatorLockTests.shop(on: false)
        let w = shop.words
        #expect(w.callIt("mac.gate_title") == "Khayt was updated" && w.callIt("mac.gate_head") == "Before you carry on")
        #expect(w.callIt("mac.gate_read") == "I have read these changes" && w.callIt("mac.gate_continue") == "Continue")
        #expect(LaunchGateSheet.summary(current: "4.0.0-beta.43", from: "4.0.0-beta.41", count: 2, words: w)
                == "This Mac now runs Khayt 4.0.0-beta.43 (it ran beta.41 before). 2 things changed that you should know before you carry on.")
        // Arabic counts two, a few and many each in its own form.
        let ar = Words(); await ar.load("ar", engine: Self.engine)
        #expect(ar.counting(2, "mac.gate_changed") == "تغيّر أمران ينبغي أن تعرفهما قبل المتابعة.")
        #expect(ar.counting(1, "mac.gate_changed") == "تغيّر أمر واحد ينبغي أن تعرفه قبل المتابعة.")
        #expect(ar.counting(5, "mac.gate_changed").contains("أمور") && ar.counting(12, "mac.gate_changed").contains("أمرًا"))
        #expect(LaunchGateSheet.summary(current: "4.0.0-beta.43", from: nil, count: 1, words: w)
                == "This Mac now runs Khayt 4.0.0-beta.43. 1 thing changed that you should know before you carry on.")
        #expect(LaunchGate.short("4.0.0-beta.43") == "beta.43" && LaunchGate.short("4.0.0") == "4.0.0")
        let source = try String(contentsOf: Self.root.appending(path: "mac/KhaytCore/Sources/KhaytApp/LaunchGate.swift"), encoding: .utf8)
        // No Later, Continue off until the tick, and Escape does not close it.
        #expect(source.contains(".disabled(!read)") && source.contains(".interactiveDismissDisabled(true)"))
        #expect(!source.contains("common.cancel") && !source.contains("later"))
    }

    @Test("the bundled gate file is lib's, the floor is a real earlier Mac release, and the cut checks the file")
    func shipped() throws {
        let lib = try Data(contentsOf: Self.root.appending(path: "lib/release-gates.json"))
        let bundled = try Data(contentsOf: Self.root.appending(path: "mac/KhaytCore/Sources/KhaytCore/JS/release-gates.json"))
        #expect(lib == bundled, "run mac/sync-js.sh")
        #expect(KhaytEngine.bundledReleaseGates() != nil, "the app's bundle has no gate file")
        // The floor is below the version this tree builds, or the sheet would hide that version's own items.
        let version = try #require((try JSONSerialization.jsonObject(with: Data(contentsOf: Self.root.appending(path: "mac/version.json")))
                                    as? [String: Any])?["version"] as? String)
        #expect(try Self.engine.compareVersions(LaunchGate.floor, version) < 0, "\(LaunchGate.floor) is not older than \(version)")
        #expect(try Self.engine.compareVersions("4.0.0-beta.9", "4.0.0-beta.10") < 0 && Self.engine.compareVersions("4.0.0", "4.0.0-beta.99") > 0)
        // The cut checks the gate file in the tree it BUILDS (the release worktree), never in the
        // checkout it was started from, which it must not write into.
        let cut = try String(contentsOf: Self.root.appending(path: "mac/release-local.sh"), encoding: .utf8)
        let enters = try #require(cut.range(of: "\ncd \"$WT\"\n"))
        let checks = try #require(cut.range(of: "node scripts/write-release-gates.js --check"))
        let syncs = try #require(cut.range(of: "bash mac/sync-js.sh >/dev/null"))
        #expect(enters.upperBound < checks.lowerBound && enters.upperBound < syncs.lowerBound, "checked or synced before entering the release tree")
        // Started once at launch, never in a snapshot run, and drawn over the shop window.
        let app = try String(contentsOf: Self.root.appending(path: "mac/KhaytCore/Sources/KhaytApp/KhaytApp.swift"), encoding: .utf8)
        #expect(app.contains(#"if ProcessInfo.processInfo.environment["KHAYT_SNAPSHOT_DIR"] == nil { await shop.checkLaunchGate() }"#))
        let window = try String(contentsOf: Self.root.appending(path: "mac/KhaytCore/Sources/KhaytApp/ShopWindow.swift"), encoding: .utf8)
        #expect(window.contains("LaunchGateSheet(shop: shop)"))
    }
}
