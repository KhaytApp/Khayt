import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The job page's "Keep as proof" card (Mac file, page 25, frame 3): what it
/// says in each of its five states, and what its buttons do.
@MainActor
@Suite(.serialized)
struct TimelapseProofCardTests {
    static let engine = OperatorLockTests.sharedEngine
    static let at = "2026-11-21T14:10:00.000Z"

    static func shop(_ job: JSONValue) async -> Shop {
        let (shop, _, dir) = LanTimelapseTests.shop([job])
        try? FileManager.default.removeItem(at: dir)
        await shop.words.load("en", engine: engine)
        shop.machineRows = [.object(["id": .string("U1"), "name": .string("Workshop U1"),
                                     "printerApi": .object(["type": .string("moonraker"), "host": .string("192.168.68.56")])])]
        return shop
    }

    @Test("the state is the shared rule's: found, kept, stays on the printer, or nothing to show")
    func states() async throws {
        let found = await Self.shop(LanTimelapseTests.job(bytes: .number(42_000_000)))
        guard case .found(let bytes, let machine, let at)? = await found.timelapseProof("J 1/x") else { Issue.record("not found"); return }
        #expect(bytes == 42_000_000 && machine == "U1" && at != nil)
        let kept: JSONValue = .object(["filename": .string("J_1_x-timelapse-a.mp4"), "kind": .string("timelapse"), "size": .number(41_000_000),
                                       "from": .object(["machineId": .string("U1"), "video": .string(LanTimelapseTests.video)])])
        let have = await Self.shop(LanTimelapseTests.job(files: [kept]))
        #expect(await have.timelapseProof("J 1/x") == .kept(bytes: 41_000_000, machineId: "U1", at: NetworkSwitch.date("2026-11-20T10:00:00.000Z"), filename: "J_1_x-timelapse-a.mp4"))
        let big = await Self.shop(LanTimelapseTests.job(bytes: .number(310_000_000)))
        #expect(await big.timelapseProof("J 1/x") == .stays(bytes: 310_000_000, maxBytes: 150 * 1024 * 1024, reason: "over-budget", machineId: "U1"))
        let unsized = await Self.shop(LanTimelapseTests.job(bytes: nil))
        guard case .stays(_, _, let reason, _)? = await unsized.timelapseProof("J 1/x") else { Issue.record("not stays"); return }
        #expect(reason == "size-unknown")
        // No time-lapse, an unusable record, no such job: the card shows nothing.
        let none = await Self.shop(.object(["id": .string("J 1/x")]))
        #expect(await none.timelapseProof("J 1/x") == nil)
        #expect(await none.timelapseProof("nobody") == nil)
        let unsafe = await Self.shop(LanTimelapseTests.job(video: "../x.mp4"))
        #expect(await unsafe.timelapseProof("J 1/x") == nil)
    }

    @Test("the words of each state, as the frame has them")
    func words() async throws {
        let shop = await Self.shop(LanTimelapseTests.job())
        let when = NetworkSwitch.date(Self.at)
        func lines(_ proof: Shop.TimelapseProof, copying: TimelapseProgress? = nil, problem: String? = nil) -> (title: String, sub: String) {
            TimelapseProofCard.lines(proof, copying: copying, problem: problem, shop: shop)
        }
        let found = lines(.found(bytes: 42_000_000, machineId: "U1", at: when))
        #expect(found.title == "Time-lapse found on Workshop U1")
        #expect(found.sub.hasPrefix("42 MB · finished ") && found.sub.contains("Nov 21"))
        // Copying: how far, of how much.
        let copying = lines(.found(bytes: 42_000_000, machineId: "U1", at: when), copying: TimelapseProgress(got: 18_000_000, total: 42_000_000))
        #expect(copying.title == "Time-lapse · copying from Workshop U1" && copying.sub == "18 MB of 42 MB")
        // The printer gave no total: the record's own figure is used.
        #expect(lines(.found(bytes: 42_000_000, machineId: "U1", at: when), copying: TimelapseProgress(got: 1_000_000, total: nil)).sub == "1 MB of 42 MB")
        let kept = lines(.kept(bytes: 42_000_000, machineId: "U1", at: when, filename: "x"))
        #expect(kept.title == "Time-lapse · 42 MB · kept as proof" && kept.sub.hasPrefix("From Workshop U1 · ") && kept.sub.contains("Nov 21"))
        let large = lines(.stays(bytes: 310_000_000, maxBytes: 150_000_000, reason: "over-budget", machineId: "U1"))
        #expect(large.title == "Time-lapse · 310 MB · stays on the printer" && large.sub == "Larger than the 150 MB a job keeps. Nothing was copied.")
        let unsized = lines(.stays(bytes: nil, maxBytes: nil, reason: "size-unknown", machineId: "U1"))
        #expect(unsized.sub == "The printer did not say how large it is, so it is not copied.")
        #expect(unsized.title == "Time-lapse · stays on the printer", "a size nobody knows was drawn as a dash between two dots")
        // Could not copy: the same title, the reason, and "Try again" where "Keep as proof" was.
        let failed = lines(.found(bytes: 42_000_000, machineId: "U1", at: when), problem: shop.words.callIt("mac.proof_offline"))
        #expect(failed.title == "Time-lapse found on Workshop U1" && failed.sub == "Couldn't reach the printer. Nothing was copied; the video is still there.")
        #expect(shop.words.callIt("mac.proof_keep") == "Keep as proof" && shop.words.callIt("mac.proof_again") == "Try again")
        #expect(shop.words.callIt("mac.proof_open") == "Open on printer" && shop.words.callIt("mac.proof_show") == "Show" && shop.words.callIt("mac.proof_remove") == "Remove…")
        // Arabic: the frame's sense, with the brand in Arabic where it is named.
        await shop.words.load("ar", engine: Self.engine)
        #expect(lines(.kept(bytes: 42_000_000, machineId: "U1", at: when, filename: "x")).title.contains("محفوظ كإثبات"))
        #expect(shop.words.callIt("mac.proof_gone") == "لا يجد خيط الملف المحفوظ.")
        // A printer's Latin name, then a date that starts with a number: the direction is restated after the
        // name, or the day's number is drawn on the wrong side of the dot (seen in the first photograph).
        let keptAr = lines(.kept(bytes: 42_000_000, machineId: "U1", at: when, filename: "x")).sub
        #expect(keptAr.contains("Workshop U1\u{200F} · "), Comment(rawValue: keptAr))
    }

    @Test("what a try that kept nothing says, and what needs no sentence")
    func sentences() async throws {
        let shop = await Self.shop(LanTimelapseTests.job())
        for quiet in [Shop.TimelapseKept.kept(filename: "x", bytes: 1), .already, .cancelled, .busy, .none] { #expect(shop.keptSentence(quiet) == nil) }
        #expect(shop.keptSentence(.unreachable) == "Couldn't reach the printer. Nothing was copied; the video is still there.")
        #expect(shop.keptSentence(.noMachine) == shop.keptSentence(.unreachable))
        #expect(shop.keptSentence(.link(reason: "over-budget", bytes: 200_000_000, maxBytes: 150_000_000)) == "The video turned out larger than the 150 MB a job keeps. Nothing was kept.")
        #expect(shop.keptSentence(.link(reason: "size-unknown", bytes: nil, maxBytes: 1)) == nil, "the card's own state says it")
        #expect(shop.keptSentence(.notSaved("Disk full."))?.hasSuffix("Disk full.") == true)
    }

    @Test("Keep as proof from the card: progress while it copies, kept at the end; a printer that is off leaves Try again; Cancel keeps nothing")
    func keeping() async throws {
        CappedDownload.protocolsForTests = [StubPrinter.self]
        defer { CappedDownload.protocolsForTests = nil }
        let (shop, wrote, dir) = LanTimelapseTests.shop([LanTimelapseTests.job(bytes: .number(600_000))])
        defer { try? FileManager.default.removeItem(at: dir) }
        await shop.words.load("en", engine: Self.engine)
        func settle() async throws { for _ in 0..<400 where shop.timelapseTasks["J 1/x"] != nil { try await Task.sleep(for: .milliseconds(10)) } }
        // The card's own path asks orders/edit; with no staff lock on, anyone may.
        StubPrinter.set(.init(chunks: Array(repeating: Data(repeating: 1, count: 200_000), count: 3)))
        shop.startKeepTimelapse("J 1/x")
        shop.startKeepTimelapse("J 1/x")          // a second click while it runs starts nothing
        try await settle()
        #expect(wrote.rows.count == 1 && wrote.rows.first?.1["size"] == .number(600_000))
        #expect(shop.timelapseProblem["J 1/x"] == nil && shop.timelapseProgress["J 1/x"] == nil && shop.timelapseCopying.isEmpty)
        #expect(StubPrinter.requests.count == 1)
        // Off.
        StubPrinter.set(.init(fail: true))
        shop.startKeepTimelapse("J 1/x")
        try await settle()
        #expect(shop.timelapseProblem["J 1/x"] == "Couldn't reach the printer. Nothing was copied; the video is still there.")
        #expect(LanTimelapseTests.listing(dir).count == 1, "the failed try left a file, or took the kept one")
        // Trying again clears what the last try said.
        StubPrinter.set(.init(chunks: [Data(repeating: 2, count: 1000)]))
        shop.startKeepTimelapse("J 1/x")
        #expect(shop.timelapseProblem["J 1/x"] == nil)
        try await settle()
        // Cancel with nothing running does nothing.
        shop.cancelKeepTimelapse("J 1/x")
        #expect(shop.timelapseTasks.isEmpty)
        // A copy that was stopped says nothing and keeps nothing.
        #expect(shop.keptSentence(.cancelled) == nil)
    }

    @Test("Remove… takes only the kept time-lapse off the job; Show opens only a file this app could have written")
    func removing() async throws {
        let hand: JSONValue = .object(["filename": .string("J1-abc.pdf"), "originalName": .string("drawing.pdf"), "size": .number(10)])
        let kept: JSONValue = .object(["filename": .string("J1-timelapse-a.mp4"), "kind": .string("timelapse"),
                                       "from": .object(["machineId": .string("U1"), "video": .string("v.mp4")])])
        var job: [String: JSONValue] = ["id": .string("J1"), "attachedFiles": .array([hand, kept])]
        #expect(Shop.removeKept(from: &job) == ["J1-timelapse-a.mp4"])
        #expect(job["attachedFiles"] == .array([hand]), "a file attached by hand was taken with it")
        #expect(Shop.removeKept(from: &job).isEmpty, "removed twice")
        var bare: [String: JSONValue] = ["id": .string("J1")]
        #expect(Shop.removeKept(from: &bare).isEmpty && bare["attachedFiles"] == nil)
        // Show: a row whose name is not one the rule makes is never opened.
        let evil: JSONValue = .object(["filename": .string("../../Library/x.mp4"), "kind": .string("timelapse"),
                                       "from": .object(["machineId": .string("U1"), "video": .string(LanTimelapseTests.video)])])
        let (shop, _, dir) = LanTimelapseTests.shop([LanTimelapseTests.job(files: [evil])])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(shop.keptTimelapseFile("J 1/x") == nil)
        let (good, _, dir2) = LanTimelapseTests.shop([LanTimelapseTests.job(files: [
            .object(["filename": .string("J_1_x-timelapse-a.mp4"), "kind": .string("timelapse"),
                     "from": .object(["machineId": .string("U1"), "video": .string(LanTimelapseTests.video)])])])])
        defer { try? FileManager.default.removeItem(at: dir2) }
        #expect(good.keptTimelapseFile("J 1/x")?.lastPathComponent == "J_1_x-timelapse-a.mp4")
        // Removing is a person's edit of a job: the sample book has nowhere to write, and says so.
        let sample = await OperatorLockTests.shop(on: false)
        #expect(await sample.removeKeptTimelapse("anything") == false)
        // Under the lock, a viewer may not.
        let locked = await OperatorLockTests.shop()
        #expect(await locked.signIn("OP-v", pin: "4444") == .ok)
        #expect(await locked.removeKeptTimelapse("anything") == false)
    }

    @Test("the card is on the job page, and every button goes through the shop")
    func wiring() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        let page = try String(contentsOf: app.appending(path: "OrderInspector.swift"), encoding: .utf8)
        #expect(page.contains("TimelapseProofCard(shop: shop, jobId: job.id)"))
        let card = try String(contentsOf: app.appending(path: "TimelapseProofCard.swift"), encoding: .utf8)
        for call in ["shop.startKeepTimelapse(jobId)", "shop.cancelKeepTimelapse(jobId)", "shop.removeKeptTimelapse(jobId)", "shop.keptTimelapseFile(jobId)"] {
            #expect(card.contains(call), Comment(rawValue: call))
        }
        // Nothing is copied by looking: the copy is only ever started from the button.
        #expect(card.components(separatedBy: "keepTimelapse(jobId)").count == 2)
        #expect(!card.contains("CappedDownload") && !card.contains("URLSession"))
    }
}
