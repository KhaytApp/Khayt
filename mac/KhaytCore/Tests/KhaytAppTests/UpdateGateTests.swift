import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// "An update is ready" (Mac file, page 28, frame C): an update that has
/// "Before you update" items is held until they are read on this Mac, and an
/// update whose items cannot be read is offered as it always was.
@MainActor
@Suite(.serialized)
struct UpdateGateTests {
    static let engine = OperatorLockTests.sharedEngine
    static let root = LaunchGateTests.root

    /// What the beta.43 release carries: its own items and beta.42's, Arabic for beta.43.
    static let asset = LaunchGateTests.translatedGates

    static func shop(_ file: String? = asset) async -> Shop {
        let shop = await LaunchGateTests.shop()
        shop.updateGateFetchForTests = { _ in file }
        return shop
    }

    @Test("the verdict: not looked into is asked about, nothing unread goes on, unread items hold")
    func verdict() {
        #expect(UpdateGate.verdict(nil) == .ask)
        #expect(UpdateGate.verdict([]) == .proceed)
        let one = [KhaytEngine.GatedRelease(version: "4.0.0-beta.43", items: ["x"])]
        #expect(UpdateGate.verdict(one) == .hold(one))
    }

    @Test("what an update holds: every gated release after the one running, up to the one on offer")
    func items() async throws {
        let shop = await Self.shop()
        let both = await shop.updateGateItems(for: "4.0.0-beta.43", running: "4.0.0-beta.41")
        #expect(both.map(\.version) == ["4.0.0-beta.43", "4.0.0-beta.42"])
        #expect(both[0].items == ["Prices now include VAT.", "Update every computer first."])
        #expect(both[1].items == ["Check Settings › Phones."])
        // From beta.42, only beta.43's. On beta.43 already, or newer: nothing.
        #expect(await shop.updateGateItems(for: "4.0.0-beta.43", running: "4.0.0-beta.42").map(\.version) == ["4.0.0-beta.43"])
        #expect(await shop.updateGateItems(for: "4.0.0-beta.43", running: "4.0.0-beta.43").isEmpty)
        #expect(await shop.updateGateItems(for: "4.0.0-beta.43", running: "4.0.0-beta.44").isEmpty)
        // A release after the gated ones, with none of its own, still carries what it skips over...
        #expect(await shop.updateGateItems(for: "4.0.0-beta.44", running: "4.0.0-beta.42").map(\.version) == ["4.0.0-beta.43"])
        // ...and holds nothing for a Mac already past them.
        #expect(await shop.updateGateItems(for: "4.0.0-beta.44", running: "4.0.0-beta.43").isEmpty)
        // A build with no version (swift run) has no "since".
        #expect(await shop.updateGateItems(for: "4.0.0-beta.43", running: nil).isEmpty)
    }

    @Test("it fails open: no file, a file that is not one, or a refused call offers the update as before")
    func failsOpen() async throws {
        for bad in [nil, "", "not json", "{}", #"{"mac":[]}"#, "<html>Not Found</html>"] as [String?] {
            let shop = await Self.shop(bad)
            #expect(await shop.updateGateItems(for: "4.0.0-beta.43", running: "4.0.0-beta.41").isEmpty, Comment(rawValue: bad ?? "nil"))
        }
        // "Make no internet calls": the file is not asked for at all, and that is counted on the updates row.
        let offline = UpdateChecksTests.gate(.object(["network": .object(["offline": .bool(true)])]))
        let text = await OutboundGate.$scoped.withValue(offline) { await UpdateGate.fetch(version: "4.0.0-beta.43") }
        #expect(text == nil && offline.blocked(.updates)?.count == 1)
    }

    @Test("the address is built only from a version shaped like one")
    func address() {
        #expect(UpdateGate.asset(for: "4.0.0-beta.43")?.absoluteString
                == "https://github.com/KhaytApp/khayt-mac/releases/download/v4.0.0-beta.43/release-gates.json")
        #expect(UpdateGate.asset(for: "4.1.0") != nil)
        for bad in ["", "4.0", "4.0.0/../../x", "4.0.0-beta.43?x=1", "4.0.0 beta", "4.0.0-", "v4.0.0", "4.0.0-beta..1", "../4.0.0",
                    "4.0.0-" + String(repeating: "a", count: 60), "4.0.0#x", "4.0.0%2f"] {
            #expect(UpdateGate.asset(for: bad) == nil, Comment(rawValue: bad))
        }
    }

    @Test("held, put off, read: Later records nothing; Continue records the items and clears the sheet")
    func sheet() async throws {
        let shop = await Self.shop()
        let d = shop.launchGateDefaults
        let unread = await shop.updateGateItems(for: "4.0.0-beta.43", running: "4.0.0-beta.41")
        shop.holdUpdate("4.0.0-beta.43", unread)
        #expect(shop.showsUpdateGate && shop.updateOffer?.version == "4.0.0-beta.43")
        // Later: gone for now, nothing remembered, so it is unread at the next check.
        shop.putOffUpdate()
        #expect(!shop.showsUpdateGate && d.stringArray(forKey: UpdateGate.readItemsKey) == nil)
        #expect(await shop.updateGateItems(for: "4.0.0-beta.43", running: "4.0.0-beta.41").count == 2)
        // Read.
        shop.holdUpdate("4.0.0-beta.43", unread)
        shop.continueToUpdate()
        #expect(!shop.showsUpdateGate && shop.updateOffer == nil)
        #expect(d.stringArray(forKey: UpdateGate.readItemsKey) == [
            UpdateGate.mark(version: "4.0.0-beta.43", english: "Prices now include VAT.", shown: "Prices now include VAT."),
            UpdateGate.mark(version: "4.0.0-beta.43", english: "Update every computer first.", shown: "Update every computer first."),
            UpdateGate.mark(version: "4.0.0-beta.42", english: "Check Settings › Phones.", shown: "Check Settings › Phones."),
        ])
        #expect(await shop.updateGateItems(for: "4.0.0-beta.43", running: "4.0.0-beta.41").isEmpty, "asked twice")
        // Nothing held: Continue and an empty hold do nothing.
        shop.continueToUpdate()
        shop.holdUpdate("4.0.0-beta.43", [])
        #expect(!shop.showsUpdateGate)
        // The record is a short list, not a ledger.
        shop.noteGateItemsRead([KhaytEngine.GatedRelease(version: "9.0.0", items: (0..<300).map { "item \($0)" })])
        #expect(d.stringArray(forKey: UpdateGate.readItemsKey)?.count == UpdateGate.keeps)
    }

    @Test("a file made to be shown is not believed: too many items, or one too long, and the update is offered as before")
    func notBelieved() async throws {
        func file(_ items: [String]) -> String {
            let list = items.map { "\"\($0)\"" }.joined(separator: ",")
            return #"{"mac":{"4.0.0-beta.43":["# + list + "]}}"
        }
        let most = await Self.shop(file((0..<UpdateGate.mostItems).map { "item \($0)" }))
        #expect(await most.updateGateItems(for: "4.0.0-beta.43", running: "4.0.0-beta.41").first?.items.count == UpdateGate.mostItems)
        let many = await Self.shop(file((0...UpdateGate.mostItems).map { "item \($0)" }))
        #expect(await many.updateGateItems(for: "4.0.0-beta.43", running: "4.0.0-beta.41").isEmpty)
        let long = await Self.shop(file([String(repeating: "x", count: UpdateGate.longestItem + 1)]))
        #expect(await long.updateGateItems(for: "4.0.0-beta.43", running: "4.0.0-beta.41").isEmpty)
    }

    @Test("a translation that is not the signed app's does not count as having read the real item")
    func wrongTranslation() async throws {
        // The release file shows an Arabic shop something soothing for beta.43's first item.
        let forged = Self.asset.replacingOccurrences(of: "الأسعار تشمل الآن ضريبة القيمة المضافة.", with: "لا شيء مهم.")
        let shop = await Self.shop(forged)
        await shop.words.load("ar", engine: Self.engine)
        shop.launchGateDefaults.set("4.0.0-beta.41", forKey: LaunchGate.lastRunKey)
        shop.launchGateFileForTests = Self.asset          // what the installed, signed app holds
        shop.launchGateHasBookForTests = true
        let shown = await shop.updateGateItems(for: "4.0.0-beta.43", running: "4.0.0-beta.41")
        #expect(shown[0].items[0] == "لا شيء مهم.")
        shop.holdUpdate("4.0.0-beta.43", shown)
        shop.continueToUpdate()
        // First start of beta.43: the item whose words were not the app's is shown; the two that matched are not.
        await shop.checkLaunchGate(current: "4.0.0-beta.43")
        #expect(shop.launchGatePending.map(\.version) == ["4.0.0-beta.43"])
        #expect(shop.launchGatePending.first?.items == ["الأسعار تشمل الآن ضريبة القيمة المضافة."])
    }

    @Test("read in Arabic is read in Arabic; in another language the same items are shown again, never hidden")
    func arabic() async throws {
        let shop = await Self.shop()
        await shop.words.load("ar", engine: Self.engine)
        let unread = await shop.updateGateItems(for: "4.0.0-beta.43", running: "4.0.0-beta.41")
        #expect(unread[0].items == ["الأسعار تشمل الآن ضريبة القيمة المضافة.", "حدّث كل الأجهزة أولًا."])
        #expect(unread[0].english == ["Prices now include VAT.", "Update every computer first."])
        #expect(unread[1].items == ["Check Settings › Phones."], "no Arabic for beta.42 in the file: English, not nothing")
        shop.holdUpdate("4.0.0-beta.43", unread)
        shop.continueToUpdate()
        #expect(await shop.updateGateItems(for: "4.0.0-beta.43", running: "4.0.0-beta.41").isEmpty, "asked twice")
        // The record is the words that were shown. The Mac's language changed: the two items read in
        // Arabic are shown in English (the safe way to be wrong); the one read in English is not.
        await shop.words.load("en", engine: Self.engine)
        let again = await shop.updateGateItems(for: "4.0.0-beta.43", running: "4.0.0-beta.41")
        #expect(again.map(\.version) == ["4.0.0-beta.43"] && again.first?.items == ["Prices now include VAT.", "Update every computer first."])
    }

    @Test("the first start after it: what was read before the download is not asked again, and anything else still is")
    func thenFirstLaunch() async throws {
        let shop = await Self.shop()
        let d = shop.launchGateDefaults
        d.set("4.0.0-beta.41", forKey: LaunchGate.lastRunKey)
        // Read before the download, from a release file that held only ONE of beta.43's two items.
        let thin = #"{"mac":{"4.0.0-beta.43":["Prices now include VAT."]}}"#
        shop.updateGateFetchForTests = { _ in thin }
        shop.holdUpdate("4.0.0-beta.43", await shop.updateGateItems(for: "4.0.0-beta.43", running: "4.0.0-beta.41"))
        shop.continueToUpdate()
        // The installed app's own list (`LaunchGateTests.gates`) has more: exactly the rest is shown.
        await shop.checkLaunchGate(current: "4.0.0-beta.43")
        #expect(shop.launchGatePending.map(\.version) == ["4.0.0-beta.43", "4.0.0-beta.42"])
        #expect(shop.launchGatePending[0].items == ["Update every computer first."])
        #expect(shop.launchGatePending[1].items == ["Check Settings › Phones."])
        #expect(d.string(forKey: LaunchGate.lastRunKey) == "4.0.0-beta.41", "the record moved before the rest was read")
        shop.acceptLaunchGate()
        #expect(d.string(forKey: LaunchGate.lastRunKey) == "4.0.0-beta.43" && !shop.showsLaunchGate)
        // Everything read before the download: the first start asks nothing and moves the record on.
        let all = await Self.shop(LaunchGateTests.gates)
        all.launchGateDefaults.set("4.0.0-beta.41", forKey: LaunchGate.lastRunKey)
        all.holdUpdate("4.0.0-beta.43", await all.updateGateItems(for: "4.0.0-beta.43", running: "4.0.0-beta.41"))
        all.continueToUpdate()
        await all.checkLaunchGate(current: "4.0.0-beta.43")
        #expect(all.launchGatePending.isEmpty && !all.showsLaunchGate)
        #expect(all.launchGateDefaults.string(forKey: LaunchGate.lastRunKey) == "4.0.0-beta.43")
        // An older build put back over it forgets what was ticked: the next upgrade asks again, on this sheet too.
        await all.checkLaunchGate(current: "4.0.0-beta.41")
        #expect(all.launchGateDefaults.stringArray(forKey: UpdateGate.readItemsKey) == nil)
        #expect(await all.updateGateItems(for: "4.0.0-beta.43", running: "4.0.0-beta.41").count == 2)
    }

    @Test("the words: the count is a word, and the sentence is the frame's, in English and Arabic")
    func words() async throws {
        let en = Words(); await en.load("en", engine: Self.engine)
        #expect(UpdateGateSheet.summary(version: "4.0.0-beta.43", running: "4.0.0-beta.41", count: 2, words: en)
                == "Khayt 4.0.0-beta.43 is ready to install on this Mac (it runs beta.41 now). Two things change that you should know before you update.")
        #expect(UpdateGate.changes(1, words: en) == "One thing changes that you should know before you update.")
        #expect(UpdateGate.changes(3, words: en) == "Three things change that you should know before you update.")
        let ar = Words(); await ar.load("ar", engine: Self.engine)
        #expect(UpdateGate.changes(2, words: ar) == "يتغيّر أمران ينبغي أن تعرفهما قبل التحديث.")
        #expect(UpdateGate.changes(4, words: ar) == "تتغيّر أربعة أمور ينبغي أن تعرفها قبل التحديث.")
        #expect(ar.callIt("mac.upgate_title") == "يوجد تحديث جاهز" && ar.callIt("mac.upgate_continue") == "المتابعة إلى التحديث")
        for lang in Words.supported {
            let l = Words(); await l.load(lang, engine: Self.engine)
            for n in [1, 2, 3, 7, 11, 25] {
                let said = UpdateGate.changes(n, words: l)
                // A figure, in any script's digits. Not `isNumber`: 二 and 七 are number WORDS and count as numbers there.
                #expect(!said.isEmpty && !said.contains("{") && !said.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains), Comment(rawValue: "\(lang) \(n): \(said)"))
            }
            for key in ["mac.upgate_title", "mac.upgate_head", "mac.upgate_later", "mac.upgate_continue", "mac.upgate_hold"] {
                #expect(l.callIt(key) != key && (lang == "en" || l.callIt(key) != en.callIt(key)), Comment(rawValue: "\(lang) \(key)"))
            }
        }
    }

    @Test("Sparkle's window is opened in one place, and its hook refuses a version that is not clear")
    func wiring() throws {
        let source = try String(contentsOf: Self.root.appending(path: "mac/KhaytCore/Sources/KhaytApp/Updates.swift"), encoding: .utf8)
        #expect(source.components(separatedBy: "updater.checkForUpdates()").count == 2,
                "Sparkle's update window is reachable around the sheet")
        // And nowhere else in the app, by any of Sparkle's other doors.
        let app = Self.root.appending(path: "mac/KhaytCore/Sources/KhaytApp")
        for file in try FileManager.default.contentsOfDirectory(at: app, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("checkForUpdatesInBackground()") && !text.contains(".checkForUpdates(nil") && !text.contains("SPUStandardUserDriver("),
                    Comment(rawValue: file.lastPathComponent))
            if file.lastPathComponent != "Updates.swift" { #expect(!text.contains("updater.checkForUpdates"), Comment(rawValue: file.lastPathComponent)) }
        }
        let cutCI = try String(contentsOf: Self.root.appending(path: ".github/workflows/mac-release.yml"), encoding: .utf8)
        #expect(cutCI.contains(#"gh release create "$TAG" dist/*.zip lib/release-gates.json"#))
        let hook = try #require(source.range(of: "shouldProceedWithUpdate updateItem"))
        let body = source[hook.upperBound...].prefix(1600)
        #expect(body.contains("Updates.shared.mayProceed(version)") && body.contains("app.khayt.update-gate"))
        #expect(body.contains("if let refusal {") && body.contains("throw NSError"))
        // The look that shows nothing is let through; everything else is asked.
        #expect(body.contains("guard updateCheck != .updateInformation else { return }"))
        // The release carries the file the sheet reads.
        let cut = try String(contentsOf: Self.root.appending(path: "mac/release-local.sh"), encoding: .utf8)
        #expect(cut.contains(#"gh release upload "$TAG" lib/release-gates.json -R KhaytApp/khayt-mac --clobber"#))
        // Not started where the app is photographed: the updater is not, and nothing else holds an update.
        #expect(source.contains(#"environment["KHAYT_SNAPSHOT_DIR"] == nil else { return }"#))
    }

    @Test("the updater's own decision: not known is refused and looked into; unread holds the sheet; ticked goes on")
    func updater() async throws {
        let updates = Updates.shared
        var opened = 0
        var busy = false
        updates.busyForTests = { busy }
        updates.openForTests = { opened += 1 }
        defer { updates.busyForTests = nil; updates.openForTests = nil }
        func settle(_ done: () -> Bool) async throws {
            for _ in 0..<300 where !done() { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(Words.upfront("mac.upgate_looking") != Words.upfront("mac.upgate_hold"))
        let shop = await Self.shop(#"{"mac":{"9.9.1":["Read me."]}}"#)
        shop.updateGateRunningForTests = "9.9.0"
        updates.attach(shop)

        // A version with something to read. First sight: refused, said to be looking, and looked into.
        #expect(updates.mayProceed("9.9.1") == Words.upfront("mac.upgate_looking"))
        try await settle { shop.updateOffer != nil }
        #expect(shop.updateOffer == UpdateOffer(version: "9.9.1", releases: [KhaytEngine.GatedRelease(version: "9.9.1", items: ["Read me."])]))
        #expect(opened == 0, "Sparkle's window opened beside the sheet")
        // Known and unread: refused with the other sentence, however often Sparkle asks; Later changes nothing.
        shop.putOffUpdate()
        #expect(updates.mayProceed("9.9.1") == Words.upfront("mac.upgate_hold"))
        #expect(shop.updateOffer?.version == "9.9.1", "the sheet did not come back at the next check")
        #expect(opened == 0)
        // Ticked: Sparkle's window is asked for, and the hook lets the version through.
        shop.continueToUpdate()
        try await settle { opened == 1 }
        #expect(opened == 1 && updates.mayProceed("9.9.1") == nil)

        // A version with nothing to read (the file has no such release): looked into, then offered by Sparkle.
        #expect(updates.mayProceed("9.9.0-beta.1") != nil)
        try await settle { opened == 2 }
        #expect(opened == 2 && updates.mayProceed("9.9.0-beta.1") == nil && shop.updateOffer == nil)

        // A file that cannot be read never holds anything.
        shop.updateGateFetchForTests = { _ in nil }
        #expect(updates.mayProceed("9.9.2") != nil)
        try await settle { opened == 3 }
        #expect(opened == 3 && updates.mayProceed("9.9.2") == nil)

        // Sparkle drops a call made while a check is running: the window is asked for only once it is free.
        busy = true
        updates.showOffer()
        updates.showOffer()
        try await Task.sleep(for: .milliseconds(600))
        #expect(opened == 3, "asked while Sparkle was busy: the call is dropped and nothing is shown")
        busy = false
        try await settle { opened == 4 }
        try await Task.sleep(for: .milliseconds(400))
        #expect(opened == 4, "asked for more than once")
    }
}
