import Foundation
import Testing
@testable import KhaytCore

/// Library stage 3b, the pure half: stacks, Find Similar, the viewer's
/// cameras and the model bundle's manifest and listing checks.
struct LibraryStage3bCoreTests {

    typealias M = LibraryStacks.Member

    static let dragons: [M] = [
        M(id: "a", title: "Dragon", group: "Beasts"),
        M(id: "b", title: "Dragon supportless", group: "Beasts"),
        M(id: "c", title: "Dragon_150%", group: "Beasts"),
        M(id: "d", title: "Dragon (pre-supported) v2", group: "Beasts"),
        M(id: "e", title: "Dragon", group: "Other"),
        M(id: "f", title: "Vase", group: "Beasts"),
    ]

    // MARK: Stems

    @Test("variant words, sizes, versions and copy numbers come off a title")
    func stems() {
        #expect(LibraryStacks.stem("Dragon") == "dragon")
        #expect(LibraryStacks.stem("Dragon supportless") == "dragon")
        #expect(LibraryStacks.stem("Dragon_150%") == "dragon")
        #expect(LibraryStacks.stem("Dragon (pre-supported) v2") == "dragon")
        #expect(LibraryStacks.stem("dragon-0.4mm-LEFT.stl") == "dragon")
        #expect(LibraryStacks.stem("Dragon Head") == "dragon head", "a real word is part of the name")
        #expect(LibraryStacks.stem("Benchy 3DBenchy") == "benchy 3dbenchy")
        #expect(LibraryStacks.stem("150%") == "")
    }

    // MARK: Who is in a stack

    @Test("a stack is two or more members; one left alone is a plain model; archived models are out")
    func index() {
        var all = Self.dragons
        all[0].stackId = "S"; all[1].stackId = "S"
        all[2].stackId = "T"                                  // alone
        all[3].stackId = "U"; all[4].stackId = "U"; all[4].archived = true
        let index = LibraryStacks.index(all)
        #expect(index == ["S": ["a", "b"]])
    }

    @Test("a record's stackId is trimmed, empty is none, and a long one is cut")
    func cleanId() {
        #expect(M.clean("  ST-1 ") == "ST-1")
        #expect(M.clean("") == nil && M.clean("   ") == nil && M.clean(nil) == nil)
        #expect(M.clean(String(repeating: "x", count: 500))?.count == LibraryStacks.idLength)
    }

    // MARK: Drawing

    @Test("a stack takes its first shown member's place and wears its cover; the badge counts what is shown")
    func collapse() {
        let members = ["S": ["a", "b", "c"]]
        let stackOf = ["a": "S", "b": "S", "c": "S"]
        // Sorted so b comes first; a is the cover.
        let tiles = LibraryStacks.collapse(["x", "b", "y", "a", "c"], stackOf: stackOf, members: members,
                                           tops: ["a"], expanded: [])
        #expect(tiles.map(\.id) == ["x", "a", "y"])
        #expect(tiles[1].stackId == "S" && tiles[1].shown == ["a", "b", "c"] && tiles[1].total == 3)
        #expect(tiles[1].isStack && !tiles[0].isStack)
        // A filter left only b: the stack still shows, as b, saying 1 of 3.
        let narrowed = LibraryStacks.collapse(["b"], stackOf: stackOf, members: members, tops: ["a"], expanded: [])
        #expect(narrowed.map(\.id) == ["b"] && narrowed[0].shown == ["b"] && narrowed[0].total == 3)
    }

    @Test("an open stack is its tile, then every other shown member inline")
    func expanded() {
        let tiles = LibraryStacks.collapse(["b", "a", "c", "z"], stackOf: ["a": "S", "b": "S", "c": "S"],
                                           members: ["S": ["a", "b", "c"]], tops: [], expanded: ["S"])
        #expect(tiles.map(\.id) == ["b", "a", "c", "z"])
        #expect(tiles[0].open && !tiles[0].inside)
        #expect(tiles[1].inside && tiles[2].inside && tiles[3].stackId == nil)
    }

    @Test("two members marked on top (two machines each chose one) settle on the first, the same everywhere")
    func twoTops() {
        #expect(LibraryStacks.cover(of: ["a", "b", "c"], tops: ["c", "b"]) == "b")
        #expect(LibraryStacks.cover(of: ["a", "b"], tops: []) == "a")
    }

    // MARK: Writing

    @Test("stacking writes the same id on each and stackTop on the cover only")
    func stacking() throws {
        let p = try #require(LibraryStacks.stacking(["b", "a", "c"], cover: "a", all: Self.dragons, newId: "ST-new"))
        #expect(Set(p.keys) == ["a", "b", "c"])
        #expect(p.values.allSatisfy { $0.stackId == "ST-new" })
        #expect(p["a"]?.top == true && p["b"]?.top == false && p["c"]?.top == false)
        // One model is nothing to stack.
        #expect(LibraryStacks.stacking(["a"], cover: nil, all: Self.dragons, newId: "x") == nil)
        #expect(LibraryStacks.stacking(["a", "missing"], cover: nil, all: Self.dragons, newId: "x") == nil)
    }

    @Test("stacking onto a stack joins it, keeps its cover, and a lone member left behind is cleared")
    func joining() throws {
        var all = Self.dragons
        all[0].stackId = "S"; all[0].stackTop = true
        all[1].stackId = "S"
        all[2].stackId = "T"; all[3].stackId = "T"
        // d joins S with f; T is left with c alone, which is cleared.
        let p = try #require(LibraryStacks.stacking(["f", "a", "d"], cover: nil, all: all, newId: "new"))
        #expect(p["f"] == .init(stackId: "S", top: false))
        #expect(p["d"] == .init(stackId: "S", top: false))
        #expect(p["a"] == nil, "a is already S's cover: nothing to change")
        #expect(p["b"] == nil, "b stays as it is")
        #expect(p["c"] == .init(stackId: nil, top: false))
    }

    @Test("unstacking clears every member; removing one moves the cover on or dissolves the stack")
    func unstackAndRemove() throws {
        var all = Self.dragons
        for i in 0..<3 { all[i].stackId = "S" }
        all[0].stackTop = true
        let un = try #require(LibraryStacks.unstacking("S", all: all))
        #expect(Set(un.keys) == ["a", "b", "c"] && un.values.allSatisfy { $0.stackId == nil })
        #expect(LibraryStacks.unstacking("nope", all: all) == nil)
        // The cover leaves: b goes on top.
        let r = try #require(LibraryStacks.removing(["a"], all: all))
        #expect(r["a"] == .init(stackId: nil, top: false) && r["b"] == .init(stackId: "S", top: true) && r["c"] == nil)
        // Two leave: c is alone, and cleared.
        let r2 = try #require(LibraryStacks.removing(["a", "b"], all: all))
        #expect(r2["c"] == .init(stackId: nil, top: false))
        #expect(LibraryStacks.removing(["f"], all: all) == nil, "f is in no stack")
    }

    @Test("a new cover moves the mark, and only the records that change are written")
    func cover() throws {
        var all = Self.dragons
        for i in 0..<3 { all[i].stackId = "S" }
        all[0].stackTop = true
        let p = try #require(LibraryStacks.choosingCover("c", all: all))
        #expect(p == ["a": .init(stackId: "S", top: false), "c": .init(stackId: "S", top: true)])
        all[2].stackTop = true; all[0].stackTop = false
        #expect(LibraryStacks.choosingCover("c", all: all) == nil)
    }

    // MARK: Suggestions

    @Test("a suggestion is the same group and name stem; another group is not; a lone name is not")
    func suggestByName() throws {
        let s = LibraryStacks.suggestions(Self.dragons)
        let dragon = try #require(s.first { $0.ids.contains("a") })
        #expect(dragon.reason == .sameName && Set(dragon.ids) == ["a", "b", "c", "d"] && dragon.stem == "dragon")
        #expect(!s.contains { $0.ids.contains("e") }, "the Dragon in another group is not offered")
        #expect(!s.contains { $0.ids.contains("f") })
    }

    @Test("the same bytes come first, the same shape last; models already in one stack are not offered again")
    func suggestionOrder() throws {
        var all = [M(id: "a", title: "Left arm", contentHash: "h1", geometryKey: "12:100:1x2x3"),
                   M(id: "b", title: "Copy of arm", contentHash: "h1", geometryKey: "12:100:1x2x3"),
                   M(id: "c", title: "Right arm", geometryKey: "12:100:1x2x3"),
                   M(id: "d", title: "Mirror", geometryKey: "12:100:1x2x3")]
        let s = LibraryStacks.suggestions(all)
        #expect(s.first?.reason == .sameFile && Set(s.first?.ids ?? []) == ["a", "b"])
        #expect(s.last?.reason == .sameShape && Set(s.last?.ids ?? []) == ["c", "d"])
        for i in all.indices { all[i].stackId = "S" }
        #expect(LibraryStacks.suggestions(all).isEmpty)
        // An unmeasured key is no shape.
        let zero = [M(id: "x", title: "p", geometryKey: "0:0:0x0x0"), M(id: "y", title: "q", geometryKey: "0:0:0x0x0")]
        #expect(LibraryStacks.suggestions(zero).isEmpty)
    }

    // MARK: Find similar

    typealias S = LibrarySimilar.Model

    @Test("the same file, then the same shape (with the mirror caveat), then near ones by score")
    func similarOrder() {
        let me = S(id: "me", title: "Dragon", group: "Beasts", tags: ["pla"], contentHash: "h", geometryKey: "1000:5000:40x30x20")
        let all = [me,
                   S(id: "near", title: "Wyvern", group: "Beasts", geometryKey: "1100:5200:41x29x21"),
                   S(id: "twin", title: "Dragon left", geometryKey: "1000:5000:40x30x20"),
                   S(id: "same", title: "Copy", contentHash: "h"),
                   S(id: "far", title: "Bracket", geometryKey: "20:3:300x2x1"),
                   S(id: "old", title: "Dragon", group: "Beasts", geometryKey: "1000:5000:40x30x20", archived: true),
                   S(id: "turned", title: "Lying", geometryKey: "1000:5000:20x40x30")]
        let ranked = LibrarySimilar.ranked(me, among: all)
        #expect(ranked.map(\.id).prefix(2) == ["same", "twin"])
        #expect(ranked.first { $0.id == "twin" }?.mirrorCaveat == true)
        #expect(ranked.first { $0.id == "same" }?.mirrorCaveat == false)
        #expect(ranked.contains { $0.id == "near" } && ranked.contains { $0.id == "turned" })
        #expect(!ranked.contains { $0.id == "far" } && !ranked.contains { $0.id == "old" } && !ranked.contains { $0.id == "me" })
        // A part lying down is the same box as one standing up.
        let turned = ranked.first { $0.id == "turned" }!.score
        let near = ranked.first { $0.id == "near" }!.score
        #expect(turned > 0.7 && near > 0.7)
    }

    @Test("with no mesh, the name, group and tags still find a model; a stranger is not found")
    func similarWithoutMesh() {
        let me = S(id: "me", title: "Lantern small", group: "Ramadan", tags: ["gift", "light"])
        let all = [me, S(id: "big", title: "Lantern large", group: "Ramadan", tags: ["gift", "light"]),
                   S(id: "x", title: "Gear", group: "Parts")]
        #expect(LibrarySimilar.ranked(me, among: all).map(\.id) == ["big"])
        #expect(LibrarySimilar.ranked(me, among: all, limit: 0).isEmpty)
    }

    // MARK: The viewer's cameras

    @Test("front shows +X on the right and Z up; top shows +Y up; side looks from +X; nothing is mirrored")
    func cameras() {
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }
        let front = ModelViewAngle.front.camera
        #expect(near(front.project(1, 0, 0).u, 1) && near(front.project(0, 0, 1).v, 1))
        #expect(front.project(0, -1, 0).depth > 0, "the front of the bed is nearest from the front")
        let top = ModelViewAngle.top.camera
        #expect(near(top.project(0, 1, 0).v, 1) && near(top.project(1, 0, 0).u, 1) && top.project(0, 0, 1).depth > 0)
        let side = ModelViewAngle.side.camera
        #expect(side.project(1, 0, 0).depth > 0 && near(side.project(0, 1, 0).u, 1))
        // Right-handed: right × up = towards, for every view.
        for angle in ModelViewAngle.allCases {
            let c = angle.camera
            let (r, u, t) = (c.right, c.up, c.towards)
            let cross = (r.1 * u.2 - r.2 * u.1, r.2 * u.0 - r.0 * u.2, r.0 * u.1 - r.1 * u.0)
            #expect(near(cross.0, t.0) && near(cross.1, t.1) && near(cross.2, t.2), "\(angle) is mirrored")
        }
        // Iso is from the front right, above.
        let iso = ModelViewAngle.iso.camera.towards
        #expect(iso.0 > 0 && iso.1 < 0 && iso.2 > 0)
    }

    @Test("a picker offers the plates a file has, once each, and none for a single plate")
    func plates() {
        #expect(ModelViewAngle.platesToPick([2, 1, 2, 3]) == [1, 2, 3])
        #expect(ModelViewAngle.platesToPick([1, 1]).isEmpty)
        #expect(ModelViewAngle.platesToPick([Int]()).isEmpty)
    }

    // MARK: The bundle

    static let record: [String: JSONValue] = [
        "id": .string("PF-1"), "name": .string("Dragon"), "material": .string("PLA"),
        "printNextFor": .string("Noura's order"), "licenceCode": .string("SECRET-123"),
        "externalPath": .string("/Users/shop/Models/dragon.stl"), "consumables": .array([.object(["unitCost": .number(3)])]),
        "tags": .array([.string("beast")]), "folder": .string("Beasts"), "stackId": .string("ST-1"),
        "timesPrinted": .number(7), "testedNotes": .string("Brim on"), "geometryKey": .string("1:2:3x4x5"),
        "setups": .array([.object(["name": .string("Fast"), "nozzleMm": .number(0.4), "machineName": .string("X1C")])]),
    ]

    @Test("the manifest is an allowlist: no customer, no licence code, no path, no price unless asked")
    func manifest() throws {
        let m = ModelBundle.manifest(record: Self.record, group: "Beasts",
                                     members: [.init(path: "model/dragon.stl", role: .model, size: 10)],
                                     price: nil, exportedAt: "2026-10-26T00:00:00.000Z", app: "Khayt Mac test")
        guard case .object(let top) = m, case .object(let rec)? = top["record"] else { Issue.record("no record"); return }
        for key in ["printNextFor", "licenceCode", "externalPath", "consumables", "timesPrinted", "id", "stackId", "folder"] {
            #expect(rec[key] == nil, "\(key) left the shop")
        }
        #expect(rec["name"] == .string("Dragon") && rec["group"] == .string("Beasts") && rec["setups"] != nil)
        #expect(top["price"] == nil)
        #expect(top["format"] == .string(ModelBundle.format))
        let priced = ModelBundle.manifest(record: Self.record, group: nil, members: [], price: (85, "SAR"),
                                          exportedAt: "", app: "")
        guard case .object(let p) = priced else { return }
        #expect(p["price"] == .object(["amount": .number(85), "currency": .string("SAR")]))
        // The two lists never overlap.
        #expect(Set(ModelBundle.exported).isDisjoint(with: ModelBundle.neverExported))
    }

    @Test("member names: traversal, absolute paths, backslashes, control characters and strange folders are refused")
    func names() {
        for ok in ["manifest.json", "model/dragon.stl", "pictures/thumb.jpg", "settings/profile.ini", "model/ドラゴン.3mf"] {
            #expect(ModelBundle.isSafeName(ok), "\(ok)")
        }
        for bad in ["../evil.stl", "model/../../evil", "/etc/passwd", "model\\evil.stl", "model/a\u{0}b",
                    "model/.hidden", "other/file", "model/sub/deep.stl", "model/", "C:/x", "model/a:b",
                    "model/.", "./manifest.json", ""] {
            #expect(!ModelBundle.isSafeName(bad), "\(bad.debugDescription) was let through")
        }
    }

    static func entry(_ name: String, size: Int = 10, flags: UInt16 = 0, attributes: UInt32 = 0) -> Zip.Entry {
        var e = Zip.Entry(name: name, compressedSize: size, size: size, method: 0, offset: 0)
        e.flags = flags
        e.externalAttributes = attributes
        return e
    }

    @Test("a listing is judged before anything is read: caps, symlinks, encryption, a manifest and a model")
    func verdict() {
        let good = [Self.entry("manifest.json"), Self.entry("model/a.stl"), Self.entry("model/")]
        if case .success(let files) = ModelBundle.verdict(good, bundleBytes: 100) { #expect(files.count == 2) }
        else { Issue.record("a good bundle was refused") }
        func refused(_ entries: [Zip.Entry], bytes: Int = 100) -> ModelBundle.Refusal? {
            if case .failure(let r) = ModelBundle.verdict(entries, bundleBytes: bytes) { return r }
            return nil
        }
        #expect(refused(good, bytes: ModelBundle.maxBundleBytes + 1) == .tooBig)
        #expect(refused([Self.entry("manifest.json"), Self.entry("model/a.stl", size: ModelBundle.maxMemberBytes + 1)]) == .tooBig)
        #expect(refused([Self.entry("manifest.json", size: ModelBundle.maxManifestBytes + 1), Self.entry("model/a.stl")]) == .tooBig)
        #expect(refused([Self.entry("manifest.json"), Self.entry("model/a.stl", attributes: 0o120777 << 16)]) == .badName("model/a.stl"))
        #expect(refused([Self.entry("manifest.json"), Self.entry("model/a.stl", flags: 1)]) == .encrypted("model/a.stl"))
        #expect(refused([Self.entry("model/a.stl")]) == .noManifest)
        #expect(refused([Self.entry("manifest.json"), Self.entry("pictures/a.jpg")]) == .noModel)
        #expect(refused([Self.entry("manifest.json"), Self.entry("model/../x")]) == .badName("model/../x"))
        #expect(refused([Self.entry("manifest.json"), Self.entry("model/A.stl"), Self.entry("model/a.stl")]) == .badName("model/a.stl"))
        let many = [Self.entry("manifest.json")] + (0..<ModelBundle.maxMembers).map { Self.entry("model/\($0).stl") }
        #expect(refused(many) == .tooMany)
    }

    @Test("a manifest read back takes only what an import may set, checked and cut to size")
    func open() throws {
        let crafted: [String: JSONValue] = [
            "format": .string(ModelBundle.format),
            "record": .object([
                "name": .string(String(repeating: "N", count: 500)), "id": .string("PF-evil"),
                "externalPath": .string("/etc"), "contentHash": .string("forged"), "archiveMember": .string("x"),
                "tags": .array([.string("a"), .number(3), .string("  ")]),
                "swapCount": .number(-4), "material": .number(5), "category": .string("Toys"),
                "parsed": .object(["printTimeMins": .number(90), "filamentGrams": .string("lots")]),
                "setups": .array([.object(["name": .string("Fast"), "path": .string("/x"), "nozzleMm": .number(0.4)])]),
            ]),
            "price": .object(["amount": .number(42), "currency": .string("SAR")]),
        ]
        let data = try JSONEncoder().encode(JSONValue.object(crafted))
        let o = try #require(ModelBundle.open(manifest: data))
        #expect(o.title?.count == 200)
        #expect(o.fields["id"] == nil && o.fields["externalPath"] == nil && o.fields["contentHash"] == nil
                && o.fields["archiveMember"] == nil)
        #expect(o.tags == ["a"] && o.fields["swapCount"] == nil && o.fields["material"] == nil)
        #expect(o.fields["category"] == .string("Toys"))
        #expect(o.fields["parsed"] == .object(["printTimeMins": .number(90)]))
        #expect(o.fields["setups"] == .array([.object(["name": .string("Fast"), "nozzleMm": .number(0.4)])]))
        #expect(o.price == 42 && o.currency == "SAR")
        #expect(ModelBundle.open(manifest: Data("{\"format\":\"other\",\"record\":{}}".utf8)) == nil)
        #expect(ModelBundle.open(manifest: Data("not json".utf8)) == nil)
    }

    @Test("the manifest fills only what the import left empty")
    func fill() {
        var record: [String: JSONValue] = ["name": .string("dragon.stl"), "material": .string("PETG"),
                                           "category": .string(""), "parsed": .object(["printTimeMins": .null])]
        let set = ModelBundle.fill(&record, from: ["name": .string("Dragon"), "material": .string("PLA"),
                                                   "category": .string("Toys"),
                                                   "parsed": .object(["printTimeMins": .number(90)]),
                                                   "testedNotes": .string("Brim on")])
        #expect(set == ["category", "parsed", "testedNotes"])
        #expect(record["material"] == .string("PETG"), "what the import read is kept")
        #expect(record["name"] == .string("dragon.stl"), "the name goes in through the import itself")
    }

    @Test("a member's leaf is safe and unique under its folder")
    func memberPaths() {
        var taken: Set<String> = []
        #expect(ModelBundle.memberPath("../../dragon.stl", in: .model, taken: &taken) == "model/dragon.stl")
        #expect(ModelBundle.memberPath("Dragon.STL", in: .model, taken: &taken) == "model/Dragon 2.STL")
        #expect(ModelBundle.memberPath(".hidden", in: .pictures, taken: &taken) == "pictures/hidden")
        #expect(ModelBundle.memberPath("", in: .settings, taken: &taken) == "settings/file")
        for path in taken { #expect(ModelBundle.isSafeName(path), "\(path)") }
    }
}
