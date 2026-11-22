import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Review of #1844, round two: the prints' picture pass, the pictures to
/// check (cloud placeholders, "not now" vs "Not this print"), and the maps
/// that remember pictures, kept bounded.
struct PicturesToCheckTests {

    static func source(_ name: String) throws -> String {
        try String(contentsOf: LooseSortReviewTests.sources.appending(path: name), encoding: .utf8)
    }

    // MARK: - The prints' picture pass

    static func job(_ n: Int, group: String?, only: String? = nil) -> PrintPhotos.Job {
        PrintPhotos.Job(print: "/Drive/P\(n)", group: group,
                        candidates: [URL(fileURLWithPath: "/Drive/P\(n).jpg")], modelPictures: [:], only: only)
    }

    final class Picks: @unchecked Sendable {
        var asked: [URL] = []
        func pick(_ c: [URL]) -> URL? { asked += c; return c.first }
    }

    @Test("a print is settled only when its picture can go on; one whose group nobody is filed in costs no download")
    func settledOnlyWithAPicture() {
        let picks = Picks()
        let jobs = [Self.job(1, group: "Live One"), Self.job(2, group: "Not Filed Yet")]
        let steps = PrintPhotos.pass(jobs, covered: [], live: ["Live One"], photoless: [], indexed: [],
                                     pick: picks.pick)
        let live = steps.first { $0.print == "/Drive/P1" }
        #expect(live?.groupPick != nil)
        #expect(live?.settled == true)
        let waiting = steps.first { $0.print == "/Drive/P2" }
        #expect(waiting == nil, "nothing to do, and not settled")
        #expect(picks.asked.map(\.lastPathComponent) == ["P1.jpg"], "no picture looked up for the group nobody is in")
        #expect(PrintPhotos.settled(steps, notWorn: []) == ["/Drive/P1"])
        // The write found nobody filed there after all: not settled.
        #expect(PrintPhotos.settled(steps, notWorn: ["Live One"]).isEmpty)
    }

    @Test("a print whose pictures are all too big, or whose model is not in the book, is not settled")
    func tooBigOrNotIndexed() {
        let none: ([URL]) -> URL? = { _ in nil }
        let big = PrintPhotos.pass([Self.job(1, group: "G")], covered: [], live: ["G"], photoless: [], indexed: [],
                                   pick: none)
        #expect(PrintPhotos.settled(big, notWorn: []).isEmpty)
        let notIndexed = PrintPhotos.pass([Self.job(2, group: nil, only: "/Drive/m.stl")], covered: [], live: [],
                                          photoless: [], indexed: [])
        #expect(PrintPhotos.settled(notIndexed, notWorn: []).isEmpty)
        // One that already wears a picture is settled without a download.
        let picks = Picks()
        let covered = PrintPhotos.pass([Self.job(3, group: "G")], covered: ["G"], live: ["G"], photoless: [],
                                       indexed: [], pick: picks.pick)
        #expect(PrintPhotos.settled(covered, notWorn: []) == ["/Drive/P3"])
        #expect(picks.asked.isEmpty)
    }

    @Test("the old 160 cap is gone: 200 prints that cannot settle do not hide the one that can, and 40 a pass still holds")
    func noWindow() {
        var jobs = (0..<200).map { Self.job($0, group: "Nobody \($0)") }
        jobs.append(Self.job(999, group: "Live"))
        let first = Picks()
        let steps = PrintPhotos.pass(jobs, covered: [], live: ["Live"], photoless: [], indexed: [], pick: first.pick)
        #expect(steps.map(\.print) == ["/Drive/P999"])
        let many = (0..<100).map { Self.job($0, group: "Live \($0)") }
        let live = Set((0..<100).map { "Live \($0)" })
        let picks = Picks()
        let capped = PrintPhotos.pass(many, covered: [], live: live, photoless: [], indexed: [], pick: picks.pick)
        #expect(capped.count == PrintPhotos.perPass)
        #expect(picks.asked.count == PrintPhotos.perPass)
        let jobsSource = try? Self.source("Shop+LinkedSort.swift")
        #expect(jobsSource?.contains("limit: PrintPhotos.perPass * 4") == false)
    }

    // MARK: - Check pictures: decided before reading

    static let root = URL(fileURLWithPath: "/Drive/Linked")
    static let target = LooseSort.Suggestion.Target.print("#loose/kart racer")
    static var key: String { PictureVerdicts.key(hash: "h1", root: root, target: target) }

    static func skip(_ known: PictureVerdicts.Seen?, size: Int = 100, modified: Double = 5,
                     verdicts: [String: PictureVerdicts.Verdict] = [:],
                     marks: [String: SortFailures.Mark] = [:], byHand: Bool = false) -> Bool {
        PictureVerdicts.skipWithoutReading(known, size: size, modified: modified, verdicts: verdicts, marks: marks,
                                           today: "2026-10-13", byHand: byHand, root: root, target: target)
    }

    @Test("a held pair is skipped before it is read or counted, by the hash its unchanged listing had")
    func heldBeforeReading() {
        let seen = PictureVerdicts.Seen(hash: "h1", size: 100, modified: 5)
        let today: [String: SortFailures.Mark] = ["picture:" + Self.key: .init(count: 1, last: "2026-10-13")]
        let thrice: [String: SortFailures.Mark] = ["picture:" + Self.key: .init(count: 3, last: "2026-10-01")]
        let yesterday: [String: SortFailures.Mark] = ["picture:" + Self.key: .init(count: 1, last: "2026-10-12")]
        #expect(Self.skip(seen, marks: today))
        #expect(Self.skip(seen, marks: thrice))
        #expect(!Self.skip(seen, marks: yesterday), "held for the day only, until the third failure")
        #expect(!Self.skip(seen, marks: today, byHand: true), "pressed by hand: tried again")
        #expect(Self.skip(seen, verdicts: [Self.key: .init(verdict: "unsure", reference: false)]))
    }

    @Test("a picture never read, a bare old hash, or one whose listing changed is read")
    func readWhenUnknownOrChanged() {
        let marks: [String: SortFailures.Mark] = ["picture:" + Self.key: .init(count: 3, last: "2026-10-01")]
        let bare = PictureVerdicts.Seen(hash: "h1", size: -1, modified: -1)
        let was = PictureVerdicts.Seen(hash: "h1", size: 100, modified: 5)
        let never = Self.skip(nil, marks: marks)
        let old = Self.skip(bare, marks: marks)
        let grew = Self.skip(was, size: 101, marks: marks)
        let touched = Self.skip(was, modified: 6, marks: marks)
        #expect(!never)
        #expect(!old)
        #expect(!grew)
        #expect(!touched)
    }

    @Test("checkPictures asks before reading: the skip, then the budget, then the read")
    func orderInTheLoop() throws {
        let text = try Self.source("Shop+Pictures.swift")
        let skip = try #require(text.range(of: "PictureVerdicts.skipWithoutReading("))
        let spend = try #require(text.range(of: "budget -= 1"))
        let read = try #require(text.range(of: "Data(contentsOf: url)"))
        #expect(skip.lowerBound < spend.lowerBound)
        #expect(spend.lowerBound < read.lowerBound)
    }

    @Test("what a picture looked like is kept with its size and time, and read back")
    func seenRoundTrip() {
        var book: [String: JSONValue] = [:]
        let seen = PictureVerdicts.Seen(hash: "h1", size: 100, modified: 5)
        PictureVerdicts.write([:], seen: ["/Drive/Linked|kart.jpg": seen], into: &book)
        guard case .object(let settings)? = book["settings"] else { Issue.record("no settings"); return }
        #expect(PictureVerdicts.seen(settings)["/Drive/Linked|kart.jpg"] == seen)
        #expect(PictureVerdicts.hashes(settings)["/Drive/Linked|kart.jpg"] == "h1")
    }

    // MARK: - Thumbnails never download

    static func drive() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ptc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in LooseSortTests.shoot { try Data(repeating: 1, count: 64).write(to: dir.appending(path: name)) }
        return dir
    }

    static func plan(_ dir: URL) -> PrintSort.Plan {
        let shoot = LooseSortTests.shoot
        var births: [String: Double] = [:]
        for (k, v) in LooseSortTests.shootBirths { births[k] = v }
        return PrintSort.plan(root: dir, models: shoot.filter { !$0.hasSuffix(".jpg") }.map { dir.appending(path: $0) },
                              images: shoot.filter { $0.hasSuffix(".jpg") }.map { dir.appending(path: $0) },
                              births: births)
    }

    @Test("a picture kept only in the cloud is a placeholder, never a thumbnail; one on this Mac is drawn")
    @MainActor func cloudIsAPlaceholder() throws {
        let dir = try Self.drive()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Self.plan(dir)
        let local = PictureRow.rows([p], settings: [:], hasPicture: { _, _ in false }, outcome: { _ in nil },
                                    isOnline: { _ in false })
        let cloud = PictureRow.rows([p], settings: [:], hasPicture: { _, _ in false }, outcome: { _ in nil },
                                    isOnline: { _ in true })
        #expect(!local.isEmpty)
        #expect(local.allSatisfy { $0.picture != nil && !$0.online })
        #expect(cloud.allSatisfy { $0.picture == nil && $0.online })
    }

    @Test("Show brings one picture down within the 8 MB cap; a bigger one is never read")
    func showIsCapped() {
        let url = URL(fileURLWithPath: "/Drive/Linked/big.jpg")
        var reads = 0
        let big = PictureSend.bringDown(url, size: { _ in PictureSend.maxSourceBytes + 1 },
                                        read: { _ in reads += 1; return Data() })
        #expect(!big)
        #expect(reads == 0)
        let fine = PictureSend.bringDown(url, size: { _ in 1000 }, read: { _ in reads += 1; return Data([1]) })
        #expect(fine)
        #expect(reads == 1)
    }

    @Test("the sheet draws no thumbnail of a cloud picture until Show")
    func sheetUsesThePlaceholder() throws {
        let text = try Self.source("Shop+LinkedSort.swift")
        #expect(text.contains("row.picture ?? (brought ? row.image : nil)"))
        #expect(text.contains("shop.bringDownPicture(row.image)"))
    }

    // MARK: - Untick is "not now"

    @Test("Apply turns down only the rows marked Not this print; an unticked row waits for next time")
    func untickIsNotNow() throws {
        let text = try Self.source("Shop+LinkedSort.swift")
        #expect(text.contains("rejectPictures(preview.pictures.map(\\.id).filter(notThis.contains))"))
        #expect(!text.contains("turned.append(row.id)"))
        #expect(text.contains("ticked.contains(row.id) && !notThis.contains(row.id)"))
    }

    @Test("with only pictures applied, the note says how many went on, not regrouped 0")
    func noteForPicturesOnly() throws {
        let text = try Self.source("Shop+LinkedSort.swift")
        #expect(text.contains("if n > 0 || pictures == 0 { lines.append(words.callIt(\"mac.linked_regrouped\""))
    }

    @Test("the new words are in both languages")
    @MainActor func words() async throws {
        let w = Words()
        await w.load("ar", engine: try KhaytEngine())
        for key in ["mac.sort_picture_not_this", "mac.sort_picture_undo", "mac.sort_picture_cloud",
                    "mac.sort_picture_show", "mac.sort_pictures_check_help"] {
            let ar = w.callIt(key)
            #expect(ar != key)
            #expect(!ar.contains("Not this") && !ar.contains("cloud"))
        }
    }

    // MARK: - Bounded maps

    @Test("entries for pictures, prints and folders gone from a scanned folder go; another folder's stay")
    func pruneGone() throws {
        let dir = try Self.drive()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Self.plan(dir)
        let r = dir.standardizedFileURL.path
        let key = try #require(p.loose.keys.sorted().first)
        let elsewhere = "/Volumes/Unplugged"
        let library: [String: JSONValue] = [
            PictureRejects.settingsKey: .array([
                .string(r + "|Owl Lamp.jpg|print:" + key),
                .string(r + "|gone.jpg|print:" + key),
                .string(r + "|Owl Lamp.jpg|print:#loose/gone"),
                .string(elsewhere + "|a.jpg|model:a.stl"),
            ]),
            PictureVerdicts.hashesKey: .object([
                r + "|Owl Lamp.jpg": .object(["h": .string("h1"), "at": .string("2026-10-13T00:00:00Z")]),
                r + "|gone.jpg": .object(["h": .string("h2"), "at": .string("2026-10-13T00:00:00Z")]),
            ]),
            PictureVerdicts.settingsKey: .object([
                "h1|" + r + "|print:" + key: .object(["v": .string("unsure")]),
                "h2|" + r + "|print:" + key: .object(["v": .string("unsure")]),
                "h1|" + r + "|print:#loose/gone": .object(["v": .string("unsure")]),
                "h9|" + elsewhere + "|model:a.stl": .object(["v": .string("no")]),
            ]),
            SortCache.settingsKey: .object([
                r + "/Gone Folder": .object(["sig": .string("x")]),
                elsewhere + "/Kept": .object(["sig": .string("y")]),
            ]),
        ]
        var root: [String: JSONValue] = ["settings": .object(["printLibrary": .object(library)])]
        #expect(PictureMaps.prune(&root, plans: [p]))
        guard case .object(let s)? = root["settings"], case .object(let lib)? = s["printLibrary"] else {
            Issue.record("no library"); return
        }
        guard case .array(let rejected)? = lib[PictureRejects.settingsKey] else { Issue.record("no rejects"); return }
        #expect(rejected == [.string(r + "|Owl Lamp.jpg|print:" + key), .string(elsewhere + "|a.jpg|model:a.stl")])
        guard case .object(let hashes)? = lib[PictureVerdicts.hashesKey] else { Issue.record("no hashes"); return }
        #expect(Set(hashes.keys) == [r + "|Owl Lamp.jpg"])
        guard case .object(let checks)? = lib[PictureVerdicts.settingsKey] else { Issue.record("no checks"); return }
        #expect(Set(checks.keys) == ["h1|" + r + "|print:" + key, "h9|" + elsewhere + "|model:a.stl"])
        guard case .object(let folders)? = lib[SortCache.settingsKey] else { Issue.record("no folders"); return }
        #expect(Set(folders.keys) == [elsewhere + "/Kept"])
        // Nothing more to let go: no write.
        #expect(!PictureMaps.prune(&root, plans: [p]))
    }

    @Test("each map keeps at most its cap, the oldest dropped first")
    func capped() {
        var checks: [String: JSONValue] = [:]
        for i in 0..<5 { checks["h\(i)|/Elsewhere|model:m\(i)"] = .object(["v": .string("no"), "at": .string("2026-10-0\(i + 1)")]) }
        let rejects: [JSONValue] = (0..<5).map { .string("/Elsewhere|p\($0).jpg|model:m\($0)") }
        var root: [String: JSONValue] = ["settings": .object(["printLibrary": .object([
            PictureVerdicts.settingsKey: .object(checks), PictureRejects.settingsKey: .array(rejects),
        ])])]
        #expect(PictureMaps.prune(&root, plans: [], cap: 2))
        guard case .object(let s)? = root["settings"], case .object(let lib)? = s["printLibrary"],
              case .object(let kept)? = lib[PictureVerdicts.settingsKey],
              case .array(let rows)? = lib[PictureRejects.settingsKey] else { Issue.record("no maps"); return }
        #expect(Set(kept.keys) == ["h3|/Elsewhere|model:m3", "h4|/Elsewhere|model:m4"])
        #expect(rows == Array(rejects.suffix(2)))
        #expect(PictureMaps.cap == 5000)
    }
}
