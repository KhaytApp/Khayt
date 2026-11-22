import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Filament used per head after a U1 print (U1 idea 4): the shared rule's
/// split (`lib/printer-actuals.js perHeadActuals`, `perHeadPatch`), which row
/// of the printer's history is THIS print, and one record per print.
@MainActor
struct HeadActualsTests {

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static func obj(_ v: JSONValue?) -> [String: JSONValue] { if case .object(let o)? = v { return o }; return [:] }
    static func json(_ file: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appending(path: "test/fixtures/\(file)")))
    }
    static let engine = OperatorLockTests.sharedEngine

    @Test("the shared per-head vectors: what the Mac would write is the rule's split, head by head")
    func vectors() async throws {
        guard case .array(let cases)? = Self.obj(try Self.json("per-head-actuals-vectors.json"))["cases"] else { Issue.record("no cases"); return }
        #expect(cases.count >= 7)
        var written = 0
        for value in cases {
            let c = Self.obj(value)
            let why: Comment = { if case .string(let s)? = c["why"] { return Comment(rawValue: s) }; return "?" }()
            let patch = try await Self.engine.perHeadPatch(order: .object(["id": .string("J1")]), historyJob: c["job"] ?? .null)
            guard case .object(let want) = c["want"] ?? .null else {
                #expect(patch == .null, why)   // the rule has nothing to say: nothing is written
                continue
            }
            let p = Self.obj(patch)
            #expect(p["actualHeadsJobId"] == want["jobId"], why)
            #expect(p["actualHeadsBasis"] == want["basis"], why)
            guard case .array(let heads)? = want["heads"], case .array(let got)? = p["actualHeads"] else { Issue.record(why); continue }
            #expect(got.count == heads.count, why)
            for (g, h) in zip(got, heads) {
                let got = Self.obj(g), want = Self.obj(h)
                #expect(got["head"] == want["head"], why)
                #expect(got["grams"] == want["grams"], why)
            }
            #expect(Set(p.keys) == Shop.headActualKeys, why)
            written += 1
        }
        #expect(written >= 3)
    }

    @Test("this print's history row: the newest completed run of the file that ended near when Khayt saw it end")
    func whichRow() throws {
        let history = Self.obj(try Self.json("u1-history-around-timelapse.json"))
        let end = Date(timeIntervalSince1970: 1785823749)
        let job = try #require(HeadActuals.job(in: history, filename: "td-swatch_PLA_17m25s.gcode", endedAt: end.addingTimeInterval(40)))
        #expect(Self.obj(job)["job_id"] == .string("00004F"))
        // The same file's row from long before is not this print.
        #expect(HeadActuals.job(in: history, filename: "td-swatch_PLA_17m25s.gcode", endedAt: end.addingTimeInterval(3 * 3600)) == nil)
        // Another file, or a history that is not one.
        #expect(HeadActuals.job(in: history, filename: "other.gcode", endedAt: end) == nil)
        #expect(HeadActuals.job(in: [:], filename: "td-swatch_PLA_17m25s.gcode", endedAt: end) == nil)
    }

    @Test("the U1's own history: two heads used, split in proportion, and never written twice")
    func realHistory() async throws {
        let history = Self.obj(try Self.json("u1-history-around-timelapse.json"))
        let job = try #require(HeadActuals.job(in: history, filename: "td-swatch_PLA_17m25s.gcode",
                                               endedAt: Date(timeIntervalSince1970: 1785823749)))
        let patch = Self.obj(try await Self.engine.perHeadPatch(order: .object(["id": .string("J1")]), historyJob: job))
        #expect(patch["actualHeadsJobId"] == .string("00004F"))
        #expect(patch["actualHeadsBasis"] == .string("proportional"))
        guard case .array(let heads)? = patch["actualHeads"] else { Issue.record("no heads"); return }
        let numbers: [JSONValue?] = heads.map { Self.obj($0)["head"] }
        #expect(numbers == [JSONValue.number(0), JSONValue.number(1)], "heads 3 and 4 used nothing and are left out")
        let grams = heads.compactMap { v -> Double? in if case .number(let g)? = Self.obj(v)["grams"] { return g }; return nil }
        // The slicer said 4.38 + 2.27 = 6.65 g over 2232.6 mm; the printer measured 2238.6 mm.
        let total: Double = grams.reduce(0, +)
        let expected: Double = 6.65 * (2238.6034 / 2232.6)
        #expect(abs(total - expected) < 0.11, "\(grams)")
        #expect(grams[0] > grams[1])
        // A job that already holds a split, this print's or another's, is left alone.
        let held: JSONValue = .object(["id": .string("J1"), "actualHeadsJobId": .string("00004F")])
        #expect(try await Self.engine.perHeadPatch(order: held, historyJob: job) == .null)
        let other: JSONValue = .object(["id": .string("J1"), "actualHeadsJobId": .string("000001")])
        #expect(try await Self.engine.perHeadPatch(order: other, historyJob: job) == .null)
    }

    @Test("each head keeps the colour and material that were in it: the tag if read, else what the machine is recorded as holding")
    func colourStamp() async throws {
        let history = Self.obj(try Self.json("u1-history-around-timelapse.json"))
        let job = try #require(HeadActuals.job(in: history, filename: "td-swatch_PLA_17m25s.gcode",
                                               endedAt: Date(timeIntervalSince1970: 1785823749)))
        // The shop's own U1 reading: heads 1 and 2 tagged, 3 and 4 empty.
        let detect = try #require(HeadActuals.filamentDetect(in: Self.obj(try Self.json("u1-filament-detect.json"))))
        let loaded: JSONValue = .array([.object(["slot": .number(0), "hex": .string("#FF0000"), "material": .string("PETG")]),
                                        .object(["slot": .number(1), "hex": .string("#00FF00"), "material": .string("PETG")])])
        func heads(_ patch: JSONValue) -> [[String: JSONValue]] {
            guard case .array(let list)? = Self.obj(patch)["actualHeads"] else { return [] }
            return list.map(Self.obj)
        }
        let order: JSONValue = .object(["id": .string("J1")])
        // A tag read wins over the list.
        let tagged = heads(try await Self.engine.perHeadPatch(order: order, historyJob: job,
                                                              filamentDetect: detect, machineLoaded: loaded))
        #expect(tagged.count == 2)
        for head in tagged {
            #expect(head["colourFrom"] == .string("rfid"))
            guard case .string(let hex)? = head["hex"], case .string(let material)? = head["material"] else {
                Issue.record("no colour on a tagged head"); continue
            }
            #expect(hex.count == 7 && hex.hasPrefix("#") && hex != "#FF0000" && hex != "#00FF00")
            #expect(!material.isEmpty && material != "PETG")
        }
        // No reading: what the machine is recorded as holding.
        let listed = heads(try await Self.engine.perHeadPatch(order: order, historyJob: job, machineLoaded: loaded))
        #expect(listed.map { $0["hex"] } == [.string("#FF0000"), .string("#00FF00")])
        #expect(listed.allSatisfy { $0["colourFrom"] == .string("loaded") && $0["material"] == .string("PETG") })
        // Neither: the split as it always was, with no colour fields at all.
        let bare = heads(try await Self.engine.perHeadPatch(order: order, historyJob: job))
        #expect(bare.count == 2)
        #expect(bare.allSatisfy { Set($0.keys) == ["head", "grams", "estimateG"] })
        // The grams are the same whichever way the colour was found.
        #expect(tagged.map { $0["grams"] } == bare.map { $0["grams"] })
        // Not an answer: nothing to read.
        #expect(HeadActuals.filamentDetect(in: ["result": .object(["status": .object([:])])]) == nil)
        #expect(HeadActuals.filamentDetect(in: [:]) == nil)
    }

    @Test("the shared colour vectors, through the bundled rule")
    func colourVectors() async throws {
        let v = Self.obj(try Self.json("per-head-actuals-vectors.json"))
        guard case .array(let cases)? = v["colour"] else { Issue.record("no vectors"); return }
        #expect(cases.count >= 8)
        for c in cases.map(Self.obj) {
            let got = try await Self.engine.headColour(head: c["head"] ?? .null, at: c["at"] ?? .null)
            #expect(got == (c["want"] ?? .null), Comment(rawValue: "\(c["why"] ?? .null)"))
        }
    }

    @Test("on the sample book nothing is written, and a row with no per-head figures writes nothing anywhere")
    func writesNothingWhereItCannot() async throws {
        let shop = await OperatorLockTests.shop(on: false)
        let jobId = shop.orders.first?.id ?? ""
        let history = Self.obj(try Self.json("u1-history-around-timelapse.json"))
        let job = try #require(HeadActuals.job(in: history, filename: "td-swatch_PLA_17m25s.gcode",
                                               endedAt: Date(timeIntervalSince1970: 1785823749)))
        #expect(await shop.writeHeadActuals(historyJob: job, jobId: jobId) == false, "the sample has nowhere to write")
        #expect(try await Self.engine.perHeadPatch(order: .object([:]), historyJob: .object(["job_id": .string("X"), "filament_used": .number(100)])) == .null)
        #expect(Shop.headActualKeys == ["actualHeads", "actualHeadsJobId", "actualHeadsBasis"])
    }
}
