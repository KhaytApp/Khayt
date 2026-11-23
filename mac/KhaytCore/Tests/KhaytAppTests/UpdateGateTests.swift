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
        #expect(d.stringArray(forKey: UpdateGate.readItemsKey)
                == ["Prices now include VAT.", "Update every computer first.", "Check Settings › Phones."])
        #expect(await shop.updateGateItems(for: "4.0.0-beta.43", running: "4.0.0-beta.41").isEmpty, "asked twice")
        // Nothing held: Continue and an empty hold do nothing.
        shop.continueToUpdate()
        shop.holdUpdate("4.0.0-beta.43", [])
        #expect(!shop.showsUpdateGate)
        // The record is a short list, not a ledger.
        shop.noteGateItemsRead([KhaytEngine.GatedRelease(version: "9.0.0", items: (0..<300).map { "item \($0)" })])
        #expect(d.stringArray(forKey: UpdateGate.readItemsKey)?.count == UpdateGate.keeps)
    }

    @Test("read in Arabic is read: the record is the English text, whatever language it was shown in")
    func arabic() async throws {
        let shop = await Self.shop()
        await shop.words.load("ar", engine: Self.engine)
        let unread = await shop.updateGateItems(for: "4.0.0-beta.43", running: "4.0.0-beta.41")
        #expect(unread[0].items == ["الأسعار تشمل الآن ضريبة القيمة المضافة.", "حدّث كل الأجهزة أولًا."])
        #expect(unread[0].english == ["Prices now include VAT.", "Update every computer first."])
        #expect(unread[1].items == ["Check Settings › Phones."], "no Arabic for beta.42 in the file: English, not nothing")
        shop.holdUpdate("4.0.0-beta.43", unread)
        shop.continueToUpdate()
        await shop.words.load("en", engine: Self.engine)
        #expect(await shop.updateGateItems(for: "4.0.0-beta.43", running: "4.0.0-beta.41").isEmpty)
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
                #expect(!said.isEmpty && !said.contains("{") && !said.contains(where: \.isNumber), Comment(rawValue: "\(lang) \(n): \(said)"))
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
        let hook = try #require(source.range(of: "shouldProceedWithUpdate updateItem"))
        let body = source[hook.upperBound...].prefix(1600)
        #expect(body.contains("Updates.shared.mayProceed(version)") && body.contains("app.khayt.update-gate"))
        // The look that shows nothing is let through; everything else is asked.
        #expect(body.contains("guard updateCheck != .updateInformation else { return }"))
        // The release carries the file the sheet reads.
        let cut = try String(contentsOf: Self.root.appending(path: "mac/release-local.sh"), encoding: .utf8)
        #expect(cut.contains(#"gh release upload "$TAG" lib/release-gates.json -R KhaytApp/khayt-mac --clobber"#))
        // Not started where the app is photographed: the updater is not, and nothing else holds an update.
        #expect(source.contains(#"environment["KHAYT_SNAPSHOT_DIR"] == nil else { return }"#))
    }

    @Test("the updater's own decision: unknown starts the finding out and refuses, clear proceeds")
    func updater() async throws {
        let updates = Updates.shared
        // No window yet: refused, and remembered for when there is one.
        #expect(!updates.mayProceed("9.9.1"))
        let shop = await Self.shop(#"{"mac":{"9.9.1":["Read me."]}}"#)
        // A build with no version of its own holds nothing: clear once looked into.
        updates.attach(shop)
        for _ in 0..<200 where !updates.mayProceed("9.9.1") { try await Task.sleep(for: .milliseconds(10)) }
        #expect(updates.mayProceed("9.9.1"), "an update Khayt cannot find anything about must go on")
        // Ticked: clear.
        updates.wasRead("9.9.3")
        #expect(updates.mayProceed("9.9.3"))
    }
}
