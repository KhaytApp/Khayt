import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Models lying loose at the top of a linked folder, sorted into prints by
/// their names (Oct 2026: ~2,150 of them on the shop's Drive, dropped in by a
/// copy job). Every name here is INVENTED, in the shapes that Drive showed:
/// `Kit - part` clusters, `Fig_` figure packs, `.u1` printer variants,
/// Bambu's `obj_N_` export names, hash names, colour-named kit parts and
/// pictures named only by a number.
struct LooseSortTests {

    static let drive = URL(fileURLWithPath: "/Users/x/Library/CloudStorage/GoogleDrive-x/My Drive/Auto_Copied_Shared (1)")

    /// The loose files in the order the copy job created them.
    static let copyOrder = [
        "v9-QQ - holder.stl", "v9-QQ - holder - mirrored.stl", "v9-QQ - cover.stl", "v9-QQ - connector.stl",
        "v9-QQQ - holder.stl", "v9-QQQ - cover.stl", "v9-QQQ - 1 color plate.stl",
        "mochi.3mf", "mochi-medium.3mf", "mochiB_wave.stl", "mochiB_wave.3mf", "mochiA.stl", "mochiA.3mf",
        "Fig_Space Ranger Zed_LegRight_03_Skin.stl", "Fig_Space Ranger Zed_Head_01_White.stl",
        "Fig_Space Ranger Zed_ArmLeft_01_Red.stl",
        "lamp-two-shade-clip3-v11.stl", "lamp-two-shade-v11-c.stl", "lamp-two-shade-door-v11a.stl",
        "teacup_holder_single.u1.3mf", "teacup_holder_single.3mf",
        "Kart Racer 3MF For Bambu Printers.3mf", "Plate 2 - Red.stl", "Plate 1 - Yellow (1).stl",
        "obj_32_Peg.stl", "obj_2_3441afd1cf7ce332dcc8035dae59b005.stl",
        "Left Arm.stl", "Right Arm.stl", "Base.stl", "Fossil Grey 2.stl", "Fossil Grey 1.stl",
        "Charcoal Black Wing Left.stl", "Charcoal Black Wing Right.stl",
        "Gnome Mailbox.stl",
        "KING-Omar-GRAY-120mm-U1.3mf", "KING-Zaid-GRAY-120mm-U1.3mf", "KING-Omar-COLOR-120mm-U1.3mf",
        "KING-Zaid-COLOR-120mm-U1.3mf",
    ]
    static let pictures = ["189.jpg", "190.jpg", "mochi.jpg", "IMG_2041.jpg"]

    /// Births one second apart, in copy order.
    static var births: [String: Double] {
        var out: [String: Double] = [:]
        for (i, n) in (copyOrder + pictures).enumerated() { out[n] = 1_790_000_000 + Double(i) }
        return out
    }

    static func byName(_ clusters: [LooseSort.Cluster]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for c in clusters { out[c.name] = c.members }
        return out
    }

    static func sorted() -> [String: [String]] {
        byName(LooseSort.clusters(models: copyOrder, images: pictures, births: births))
    }

    // MARK: - The local pass

    @Test("v9-QQ and v9-QQQ sit side by side and stay two prints; v9 alone names nothing")
    func neighboursThatShareOnlyAVersion() {
        let s = Self.sorted()
        let qq = s["v9-QQ"] ?? []
        let qqq = s["v9-QQQ"] ?? []
        #expect(qq.count == 4)
        #expect(qqq.count == 3)
        #expect(s["v9"] == nil)
    }

    @Test("a trailing variant letter, a part and a size are the same print: mochi")
    func variantsJoinTheirModel() {
        let members = Self.sorted()["mochi"] ?? []
        #expect(members.count == 6)
        #expect(members.contains("mochiA.3mf"))
        #expect(members.contains("mochi-medium.3mf"))
    }

    @Test("Fig_ figure packs are named for the figure, parts and colours gone")
    func figurePack() {
        let members = Self.sorted()["Space Ranger Zed"] ?? []
        #expect(members.count == 3)
    }

    @Test("a slug's shared words name it, read as words")
    func slug() {
        let members = Self.sorted()["lamp two shade"] ?? []
        #expect(members.count == 3)
    }

    @Test("a .u1 printer variant joins the model it is a variant of")
    func u1Variant() {
        let members = Self.sorted()["teacup holder"] ?? []
        #expect(Set(members) == ["teacup_holder_single.u1.3mf", "teacup_holder_single.3mf"])
    }

    @Test("one king per print: a shared first word followed by names splits by the name")
    func onePrintPerName() {
        let s = Self.sorted()
        #expect((s["KING-Omar"] ?? []).count == 2)
        #expect((s["KING-Zaid"] ?? []).count == 2)
        #expect(s["KING"] == nil)
    }

    @Test("names of only parts, colours, Bambu's obj_N_ and a hash never make a print here")
    func genericNamesStayLoose() {
        let s = Self.sorted()
        let grouped = Set(s.values.flatMap { $0 })
        for loose in ["Plate 2 - Red.stl", "Plate 1 - Yellow (1).stl", "obj_32_Peg.stl",
                      "obj_2_3441afd1cf7ce332dcc8035dae59b005.stl", "Left Arm.stl", "Right Arm.stl", "Base.stl",
                      "Fossil Grey 2.stl", "Fossil Grey 1.stl", "Charcoal Black Wing Left.stl"] {
            #expect(!grouped.contains(loose), "\(loose)")
        }
        // Each alone, so not a group of one either.
        #expect(!grouped.contains("Gnome Mailbox.stl"))
        #expect(!grouped.contains("Kart Racer 3MF For Bambu Printers.3mf"))
    }

    @Test("generic words alone are never distinctive; a code beside a version is")
    func distinctiveness() {
        #expect(!LooseSort.isDistinctive(["plate", "1"]))
        #expect(!LooseSort.isDistinctive(["v9"]))
        #expect(!LooseSort.isDistinctive(["al"]))
        #expect(!LooseSort.isDistinctive(["front", "frame", "corner", "tr"]))
        #expect(LooseSort.isDistinctive(["v9", "qq"]))
        #expect(LooseSort.isDistinctive(["mochi"]))
        #expect(LooseSort.read("TopPanel_04_p.stl") == nil, "run-together part words are part words")
        #expect(LooseSort.read("Bone White Body.stl") == nil, "a kit part named for its colour")
    }

    @Test("a picture named for the print is its picture; a number or a camera's name is nobody's")
    func pictures() {
        let clusters = LooseSort.clusters(models: Self.copyOrder, images: Self.pictures, births: Self.births)
        let mochi = clusters.first { $0.name == "mochi" }
        #expect(mochi?.pictures == ["mochi.jpg"])
        let all = clusters.flatMap(\.pictures)
        #expect(!all.contains("189.jpg"))
        #expect(!all.contains("IMG_2041.jpg"))
    }

    @Test("copy order is birth order; with no births, the names' own order")
    func order() {
        let o = LooseSort.order(["b.stl", "a.stl", "c.stl"], births: ["c.stl": 1, "b.stl": 2])
        #expect(o == ["c.stl", "b.stl", "a.stl"])
    }

    // MARK: - In the linked folder's plan

    static func plan(_ answers: PrintSort.Answers = PrintSort.Answers(), extra: [String] = []) -> PrintSort.Plan {
        PrintSort.plan(root: drive, models: (copyOrder + extra).map { drive.appending(path: $0) },
                       images: pictures.map { drive.appending(path: $0) }, answers: answers, births: births)
    }

    @Test("a loose print is a group like a folder's, and a folder's models are untouched")
    func inThePlan() {
        let folder = "Monsters/Dragon/body.stl"
        let p = Self.plan(extra: [folder, "Monsters/Dragon/wing.stl"])
        #expect(p.placed["mochiA.stl"]?.group == "mochi")
        #expect(p.placed["Plate 2 - Red.stl"]?.group == nil)
        #expect(p.placed["Gnome Mailbox.stl"]?.group == nil)
        #expect(p.placed[folder]?.group == "Dragon")
        #expect(p.looseModels.count == Self.copyOrder.count)
        let mochiKey = PrintSort.looseKey("mochi")
        #expect(p.prints.contains(mochiKey))
        #expect(p.group(ofPrint: mochiKey) == "mochi")
        #expect(p.pictures(ofPrint: mochiKey) == ["mochi.jpg"])
        let counts = SortPreview.looseCounts([p])
        #expect(counts.total == Self.copyOrder.count)
        #expect(counts.prints == p.loose.count)
    }

    @Test("the print's picture is fetched under the same rules as a folder print's")
    func pictureJob() {
        let jobs = PrintPhotos.jobs([Self.plan()], looked: [])
        let mochi = jobs.first { $0.group == "mochi" }
        #expect(mochi?.candidates.map(\.lastPathComponent) == ["mochi.jpg"])
        #expect(mochi?.only == nil)
        let looked = Set(jobs.map(\.print))
        #expect(PrintPhotos.jobs([Self.plan()], looked: looked).isEmpty, "looked at once, never again")
    }

    @Test("a record the shop placed, or took out of its group, is not moved; the app's own is")
    func handPlacedStays() {
        let p = Self.plan()
        func row(_ id: String, _ rel: String, group: String, extra: [String: JSONValue] = [:]) -> JSONValue {
            var o: [String: JSONValue] = ["id": .string(id), "name": .string(LinkedRegroup.stem(Self.drive.appending(path: rel))),
                                          "externalPath": .string(Self.drive.appending(path: rel).standardizedFileURL.path),
                                          "group": .string(group), "folder": .string(group)]
            for (k, v) in extra { o[k] = v }
            return .object(o)
        }
        let rows = [
            row("a", "mochiA.stl", group: ""),
            row("b", "mochiA.3mf", group: "Favourites"),
            row("c", "mochi.3mf", group: "", extra: ["autoGroup": .string("mochi")]),
            row("d", "Gnome Mailbox.stl", group: ""),
        ]
        let changes = LinkedRegroup.changes(rows: rows, plan: p)
        let ids = changes.map(\.id)
        #expect(ids == ["a"])
        #expect(changes.first?.group == "mochi")
        var root: [String: JSONValue] = ["printFiles": .array(rows)]
        LinkedRegroup.apply(changes, to: &root)
        guard case .array(let after)? = root["printFiles"] else { Issue.record("no rows"); return }
        let again = LinkedRegroup.changes(rows: after, plan: p)
        #expect(again.isEmpty, "settled")
    }

    // MARK: - The assistant

    static let on: [String: JSONValue] = ["ai": .object(["provider": .string("anthropic"), "enabled": .bool(true),
                                                         "features": .object(["library": .bool(true)])])]

    @Test("the Mac's batches agree with the shared limits")
    func limitsAgree() async throws {
        let engine = try KhaytEngine()
        let limits = try await engine.aiLibraryLimits()
        #expect(limits["looseNames"] == LooseCache.perRequest)
        #expect(limits["looseNamesPerScan"] == LooseCache.perScan)
    }

    @Test("a request holds at most 300 names, only the files' own names, in copy order")
    func requestIsBounded() async throws {
        let many = (0..<450).map { "widget \($0).stl" }
        var births: [String: Double] = [:]
        for (i, n) in many.enumerated() { births[n] = Double(i) }
        let p = PrintSort.plan(root: Self.drive, models: many.map { Self.drive.appending(path: $0) }, images: [],
                               births: births)
        let pending = LooseCache.pending(p, settings: [:])
        #expect(pending.count == 450)
        #expect(pending.first == "widget 0.stl")
        let batches = LooseCache.batches(pending, births: births)
        #expect(batches.count == 2)
        #expect(batches.allSatisfy { $0.count <= 300 })
        let engine = try KhaytEngine()
        let request = try await engine.aiLooseRequest(settings: Self.on, names: batches[0], apiKey: "k")
        let body = String(describing: request.body)
        #expect(body.contains("0 | widget 0.stl"))
        #expect(!body.contains("GoogleDrive"), "nothing above the linked folder")
        #expect(!body.contains("1790000000"), "no dates")
        #expect(body.contains("group_loose_model_files"))
        // Even a list longer than a request is cut to 300 by the shared rule.
        let all = try await engine.aiLooseRequest(settings: Self.on, names: pending, apiKey: "k")
        #expect(!String(describing: all.body).contains("300 | "))
        // And nothing is asked when the shop has not turned it on.
        let off: [String: JSONValue] = ["ai": .object(["provider": .string("anthropic"), "enabled": .bool(true)])]
        await #expect(throws: (any Error).self) {
            _ = try await engine.aiLooseRequest(settings: off, names: batches[0], apiKey: "k")
        }
    }

    @Test("a scan sends at most 3,000 names")
    func scanIsBounded() {
        let many = (0..<3_200).map { "thing \($0).stl" }
        let p = PrintSort.plan(root: Self.drive, models: many.map { Self.drive.appending(path: $0) }, images: [])
        #expect(LooseCache.pending(p, settings: [:]).count == 3_000)
    }

    @Test("a batch is cut where the copy job paused, near the end of a full batch")
    func batchCutsAtAPause() {
        let names = (0..<400).map { "n\($0).stl" }
        var births: [String: Double] = [:]
        for (i, n) in names.enumerated() { births[n] = Double(i) + (i >= 270 ? 500 : 0) }
        let batches = LooseCache.batches(names, births: births)
        #expect(batches.first?.count == 270)
    }

    static func reply(_ prints: [JSONValue]) -> JSONValue {
        .object([
            "stop_reason": .string("tool_use"),
            "usage": .object(["input_tokens": .number(900), "output_tokens": .number(200)]),
            "content": .array([.object([
                "type": .string("tool_use"), "name": .string("group_loose_model_files"),
                "input": .object(["prints": .array(prints)]),
            ])]),
        ])
    }

    static func print(_ name: String, _ members: [Int]) -> JSONValue {
        .object(["name": .string(name), "members": .array(members.map { .number(Double($0)) })])
    }

    @Test("a bad answer is dropped: dots, a slash, a number never sent")
    func badAnswer() async throws {
        let engine = try KhaytEngine()
        let sent = ["Kart Racer 3MF For Bambu Printers.3mf", "Plate 2 - Red.stl", "Plate 1 - Yellow (1).stl"]
        let read = try await engine.aiLooseRead(settings: Self.on, response: Self.reply([
            Self.print("Kart Racer", [0, 1, 2]),
            Self.print("..", [0, 1]),
            Self.print("../../etc", [1, 2]),
            Self.print("a/b", [1, 2]),
            Self.print("Far", [1, 7]),
        ]), count: sent.count)
        #expect(read.ok)
        #expect(read.prints.count == 1)
        #expect(read.dropped == 4)
        let answered = LooseCache.answered(root: Self.drive, sent: sent, prints: read.prints)
        #expect(answered.prints["Kart Racer"] == sent)
        // The cost goes into the shop's AI spend, like the folder sort's.
        let ledger = try await engine.aiUsageRecord(ledger: .object([:]), task: "library", model: "claude-opus-5",
                                                    usage: try #require(read.usage), now: Date())
        #expect(ledger != .object([:]))
    }

    @Test("an answer is kept: never sent twice, read back as groups, generic kit parts joining their kit")
    func cacheAndApply() {
        let first = Self.plan()
        let sent = LooseCache.pending(first, settings: [:])
        #expect(sent.count == Self.copyOrder.count)
        let kart = ["Kart Racer 3MF For Bambu Printers.3mf", "Plate 2 - Red.stl", "Plate 1 - Yellow (1).stl"]
        let answered = LooseCache.Answered(root: Self.drive, sent: sent, prints: ["Kart Racer": kart])
        var root: [String: JSONValue] = [:]
        let present = [Self.drive.standardizedFileURL.path: Set(first.looseModels)]
        LooseCache.store([answered], present: present, into: &root)
        guard case .object(let settings)? = root["settings"] else { Issue.record("no settings"); return }
        #expect(LooseCache.pending(first, settings: settings).isEmpty, "nothing is sent twice")
        // A new file is the only one asked about next time.
        let grown = Self.plan(extra: ["new thing.stl"])
        #expect(LooseCache.pending(grown, settings: settings) == ["new thing.stl"])
        // The answer, laid over the names.
        let p = Shop.sortedPlan(root: Self.drive, models: Self.copyOrder.map { Self.drive.appending(path: $0) },
                                images: [], settings: settings, births: Self.births)
        #expect(p.placed["Plate 2 - Red.stl"]?.group == "Kart Racer")
        #expect(p.placed["Kart Racer 3MF For Bambu Printers.3mf"]?.group == "Kart Racer")
        // The local pass fills everything the assistant did not place.
        #expect(p.placed["mochiA.stl"]?.group == "mochi")
    }

    @Test("a name read back from the book is held to the group rule again")
    func cachedNamesAreSanitised() {
        let settings: [String: JSONValue] = ["printLibrary": .object(["looseSort": .object([
            Self.drive.standardizedFileURL.path: .object(["prints": .object([
                "..": .array([.string("Plate 2 - Red.stl"), .string("Plate 1 - Yellow (1).stl")]),
                "Kart/Racer": .array([.string("Kart Racer 3MF For Bambu Printers.3mf"), .string("Gone.stl")]),
            ])]),
        ])])]
        let present: Set<String> = ["Plate 2 - Red.stl", "Plate 1 - Yellow (1).stl", "Kart Racer 3MF For Bambu Printers.3mf"]
        let read = LooseCache.answers(settings, root: Self.drive, present: present)
        #expect(read["Plate 2 - Red.stl"] == nil, "dots name nothing")
        #expect(read["Kart Racer 3MF For Bambu Printers.3mf"] == "Kart - Racer", "no slash in a group name")
        #expect(read["Gone.stl"] == nil, "only files still there")
    }

    @Test("a loose request's failures are held by its own signature")
    func failureSignature() {
        let a = LooseCache.signature(["x.stl", "y.stl"])
        #expect(a == LooseCache.signature(["x.stl", "y.stl"]))
        #expect(a != LooseCache.signature(["y.stl", "x.stl"]))
    }
}
