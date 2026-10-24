import Foundation
import Testing
@testable import KhaytCore

/// Library Health's groups, from plain facts — the rule the Mac draws and the
/// iPhone can reuse. Nothing here touches a disk.
@Suite struct LibraryHealthTests {

    typealias M = LibraryHealth.Model
    static let u1: JSONValue = .object(["x": .number(270), "y": .number(270), "z": .number(270)])
    static let laserBed: JSONValue = .object(["x": .number(1300), "y": .number(900), "z": .number(200)])
    static let key = "1000:5000.0:100x80x40"

    static func model(_ id: String, _ presence: LibraryHealth.Presence = .here, hash: String? = nil,
                      key: String? = LibraryHealthTests.key, minutes: Double? = nil, grams: Double? = nil,
                      tags: [String] = ["t"], category: String? = nil, archived: Bool = false) -> M {
        M(id: id, title: id, presence: presence, contentHash: hash, geometryKey: key,
          slicedMinutes: minutes, slicedGrams: grams, tags: tags, category: category, archived: archived)
    }

    static func group(_ kind: LibraryHealth.Kind, _ groups: [LibraryHealth.Group]) -> LibraryHealth.Group? {
        groups.first { $0.kind == kind }
    }

    @Test("a healthy library has no groups at all")
    func healthy() {
        let models = [Self.model("a", hash: "h1"), Self.model("b", hash: "h2", key: "2:1:1x1x1")]
        #expect(LibraryHealth.groups(models: models, machines: [.init(id: "u1", bed: Self.u1)]).isEmpty)
    }

    @Test("missing, online-unmeasured and no-figures never overlap")
    func whereTheBytesAre() {
        let models = [
            Self.model("gone", .missing, key: nil),
            Self.model("cloud", .online, key: nil),
            Self.model("cloud-sliced", .online, key: nil, minutes: 60, grams: 20),
            Self.model("here", .here, key: nil),
            Self.model("sample", .unknown, key: nil),
            Self.model("half", .here, key: nil, minutes: 60),
        ]
        let groups = LibraryHealth.groups(models: models)
        #expect(Self.group(.missing, groups)?.modelIds == ["gone"])
        #expect(Self.group(.onlineUnmeasured, groups)?.modelIds == ["cloud"])
        // A time with no weight is not a model that can be priced.
        #expect(Self.group(.noFigures, groups)?.modelIds == ["here", "sample", "half"])
    }

    @Test("a measured mesh counts as figures — the app estimates from it")
    func meshIsFigures() {
        let m = Self.model("m", key: "500:10.0:10x10x10")
        #expect(m.hasFigures)
        // A key with no triangles is a mesh that could not be read.
        #expect(!Self.model("z", key: "0:0:0x0x0").hasFigures)
        #expect(!Self.model("bad", key: "garbage").hasFigures)
    }

    @Test("the same bytes are a certain duplicate")
    func sameFile() {
        let models = [Self.model("a", hash: "H"), Self.model("b", hash: "H"), Self.model("c", hash: "other", key: nil)]
        let groups = LibraryHealth.groups(models: models)
        #expect(Self.group(.sameFile, groups)?.clusters == [["a", "b"]])
        // Same bytes share a key too, and are NOT shown again as "looks the same".
        #expect(Self.group(.looksSame, groups) == nil)
    }

    @Test("the same key with different bytes is a look, not a duplicate — mirrors share it")
    func mirrorCaveat() {
        // A left and a right hand: same triangles, same volume, same box.
        let left = Self.model("left", hash: "L"), right = Self.model("right", hash: "R")
        let groups = LibraryHealth.groups(models: [left, right])
        #expect(Self.group(.looksSame, groups)?.clusters == [["left", "right"]])
        #expect(Self.group(.sameFile, groups) == nil)
    }

    @Test("a different box is a different shape, whatever the triangles")
    func boxDecides() {
        let a = Self.model("a", hash: "A", key: "1000:5000.0:100x80x40")
        let b = Self.model("b", hash: "B", key: "1000:5000.0:80x100x40")
        #expect(Self.group(.looksSame, LibraryHealth.groups(models: [a, b])) == nil)
    }

    @Test("a cluster with one certain pair and a stranger is shown in both, honestly")
    func mixedCluster() {
        let models = [Self.model("a", hash: "H"), Self.model("b", hash: "H"), Self.model("c", hash: "X")]
        let groups = LibraryHealth.groups(models: models)
        #expect(Self.group(.sameFile, groups)?.clusters == [["a", "b"]])
        #expect(Self.group(.looksSame, groups)?.clusters == [["a", "b", "c"]])
        // Records with no hash prove nothing about their bytes: each is its own.
        let unhashed = LibraryHealth.groups(models: [Self.model("p"), Self.model("q")])
        #expect(Self.group(.looksSame, unhashed)?.modelIds == ["p", "q"])
    }

    @Test("archived models are put aside: not counted, and not duplicates")
    func archivedAside() {
        let models = [Self.model("a", hash: "H"), Self.model("b", hash: "H", archived: true),
                      Self.model("gone", .missing, archived: true)]
        #expect(LibraryHealth.groups(models: models).isEmpty)
    }

    @Test("too big for every 3D printer; lasers and UV beds are not asked")
    func tooBig() {
        let huge = Self.model("huge", key: "10:1.0:1141x757x207")
        let small = Self.model("small", key: "10:1.0:100x100x10")
        let machines: [LibraryHealth.Machine] = [
            .init(id: "u1", kind: "fdm", bed: Self.u1),
            .init(id: "laser", kind: "laser", bed: Self.laserBed),
            .init(id: "uv", kind: "uv", bed: Self.laserBed),
        ]
        let groups = LibraryHealth.groups(models: [huge, small], machines: machines)
        #expect(Self.group(.tooBig, groups)?.modelIds == ["huge"])
        // No 3D printer with a bed: nothing is known, so nothing is too big.
        #expect(Self.group(.tooBig, LibraryHealth.groups(models: [huge], machines: [machines[1]])) == nil)
        #expect(Self.group(.tooBig, LibraryHealth.groups(models: [huge], machines: [.init(id: "x", bed: nil)])) == nil)
        // A machine with no kind reads as FDM.
        #expect(Self.group(.tooBig, LibraryHealth.groups(models: [huge], machines: [.init(id: "x", bed: Self.u1)])) != nil)
    }

    @Test("unorganised means neither a tag nor a category; blanks do not count")
    func unorganised() {
        let models = [Self.model("none", tags: []), Self.model("blank", tags: ["  "], category: " "),
                      Self.model("tagged", tags: ["x"]), Self.model("filed", tags: [], category: "Busts")]
        #expect(Self.group(.unorganised, LibraryHealth.groups(models: models))?.modelIds == ["none", "blank"])
    }

    @Test("a product whose model is gone — an archived model is not gone")
    func orphanProducts() {
        let models = [Self.model("here"), Self.model("aside", archived: true)]
        let products: [LibraryHealth.Product] = [
            .init(id: "P1", name: "ok", printFileIds: ["here"]),
            .init(id: "P2", name: "aside", printFileIds: ["aside"]),
            .init(id: "P3", name: "lost", printFileIds: ["here", "deleted"]),
            .init(id: "P4", name: "no file", printFileIds: []),
        ]
        let g = Self.group(.orphanProducts, LibraryHealth.groups(models: models, products: products))
        #expect(g?.productIds == ["P3"])
        #expect(g?.count == 1)
    }

    @Test("groups come in the order a shop works through them")
    func order() {
        let models = [Self.model("gone", .missing, key: nil, tags: []), Self.model("a", hash: "H"),
                      Self.model("b", hash: "H")]
        let kinds = LibraryHealth.groups(models: models).map(\.kind)
        #expect(kinds == [.missing, .sameFile, .unorganised])
    }
}
