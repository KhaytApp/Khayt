import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Review of #1844 (loose sort, "Check pictures"): the bugs it found, pinned.
struct LooseSortReviewTests {

    static var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
    }

    static func source(_ name: String) throws -> String {
        try String(contentsOf: sources.appending(path: name), encoding: .utf8)
    }

    // MARK: - Check pictures: the budget is for pictures still to judge

    @Test("an answer with no verdict is held like a failure, not sent again every scan")
    func noVerdictIsHeld() throws {
        let text = try Self.source("Shop+Pictures.swift")
        let ok = try #require(text.range(of: "if reply.answer.ok {"))
        let rest = text[ok.upperBound...]
        let elseBranch = try #require(rest.range(of: "} else {"))
        let mark = try #require(rest.range(of: "SortFailures.Mark("))
        #expect(elseBranch.lowerBound < mark.lowerBound)
    }

    // MARK: - The two passes share the failure marks

    @Test("the folder sort's marks keep the picture checks' failures as the book holds them")
    func marksAreShared() {
        var book: [String: JSONValue] = [:]
        let picture = SortFailures.Mark(count: 2, last: "2026-10-12")
        SortFailures.write(["picture:abc": picture, "oldfolder": .init(count: 1, last: "2026-10-12")], into: &book)
        guard case .object(let settings)? = book["settings"] else { Issue.record("no settings"); return }
        let sortWould: [String: SortFailures.Mark] = ["loose1": .init(count: 1, last: "2026-10-13")]
        let merged = SortFailures.keepingPictures(sortWould, from: settings)
        #expect(merged["picture:abc"] == picture)
        #expect(merged["loose1"] == .init(count: 1, last: "2026-10-13"))
        #expect(merged["oldfolder"] == nil)
    }

    @Test("both passes merge their marks inside the write")
    func marksMergedInTheWrite() throws {
        let sort = try Self.source("Shop+LinkedSort.swift")
        #expect(sort.contains("SortFailures.keepingPictures(nextMarks, from: Self.settings(root))"))
        let pictures = try Self.source("Shop+Pictures.swift")
        #expect(pictures.contains("var current = SortFailures.read(Self.settings(root))"))
    }

    // MARK: - The preview changes nothing

    @Test("Sort linked folders… asks about pictures but puts none on before Apply")
    func previewPutsNothingOn() throws {
        let sort = try Self.source("Shop+LinkedSort.swift")
        #expect(sort.contains("checkPictures(plans, stop: stop, byHand: true, put: false)"))
        let pictures = try Self.source("Shop+Pictures.swift")
        #expect(pictures.contains("if put, !attach.isEmpty"))
    }

    // MARK: - A group picture the shop took off

    @Test("a print settled once with a picture is not offered one again")
    @MainActor func settledPrintIsNotOffered() throws {
        let drive = LooseSortTests.drive
        let models = LooseSortTests.shoot.filter { !$0.hasSuffix(".jpg") }.map { drive.appending(path: $0) }
        let plan = PrintSort.plan(root: drive, models: models, images: [], births: LooseSortTests.shootBirths)
        let key = try #require(plan.loose.keys.sorted().first)
        let shop = Shop()
        let before = shop.hasPicture(plan, .print(key))
        #expect(!before)
        var book: [String: JSONValue] = [:]
        PrintPhotos.markLooked([drive.appending(path: key).standardizedFileURL.path], into: &book)
        shop.settingsValue = book["settings"] ?? .object([:])
        let after = shop.hasPicture(plan, .print(key))
        #expect(after)
    }

    // MARK: - The launch pass reads the answers back

    @Test("the launch pass reloads the book before laying the assistant's answers over the plan")
    func rescanReloads() throws {
        let text = try Self.source("LinkedFolders.swift")
        let asked = try #require(text.range(of: "if asked.sorted > 0 || asked.loose > 0, !stopped() {"))
        let rest = text[asked.upperBound...]
        let load = try #require(rest.range(of: "await load(source)"))
        let replan = try #require(rest.range(of: "Shop.sortedPlan("))
        #expect(load.lowerBound < replan.lowerBound)
    }

    // MARK: - Sixty UTF-16 units

    @Test("one word longer than the limit is cut to sixty UTF-16 units, never more")
    func fitCountsUTF16() {
        let emoji = String(repeating: "🦖", count: 50)
        let cut = PrintSort.fit(emoji)
        #expect(cut.utf16.count <= 60)
        #expect(cut.utf16.count == 60)
        let arabic = String(repeating: "ب", count: 80)
        #expect(PrintSort.fit(arabic).utf16.count == 60)
        #expect(PrintSort.fit("short name") == "short name")
    }
}
