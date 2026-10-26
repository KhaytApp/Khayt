import Foundation
import Testing
@testable import KhaytCore

/// `VaultOnlyCopies`: which library models only the vault holds while it is
/// over its plan, what to offer about them, and — after the vault deleted
/// them — how Library Health tells them from a file that simply went missing.
struct VaultLapseOnlyCopiesTests {

    typealias F = VaultOnlyCopies.Found

    @Test("a sidecar's provider is read without the engine; anything unreadable is nil")
    func provider() {
        #expect(VaultOnlyCopies.sidecarProvider(Data(#"{"v":1,"size":10,"sha256":"ab","key":"k","provider":"vault"}"#.utf8)) == "vault")
        #expect(VaultOnlyCopies.sidecarProvider(Data(#"{"v":1,"provider":"gdrive"}"#.utf8)) == "gdrive")
        #expect(VaultOnlyCopies.sidecarProvider(Data(#"{"v":1,"provider":"  "}"#.utf8)) == nil)
        #expect(VaultOnlyCopies.sidecarProvider(Data("not json".utf8)) == nil)
        #expect(VaultOnlyCopies.sidecarProvider(Data()) == nil)
    }

    @Test("only a vault sidecar with no bytes beside it is a model only the vault holds")
    func onlyInVault() {
        #expect(VaultOnlyCopies.onlyInVault([F(name: "a.stl", provider: "vault", bytesHere: false)]))
        // A move interrupted after the sidecar: the bytes are still here.
        #expect(!VaultOnlyCopies.onlyInVault([F(name: "a.stl", provider: "vault", bytesHere: true)]))
        // Moved to a bucket or Drive: the vault's deletion does not touch it.
        #expect(!VaultOnlyCopies.onlyInVault([F(name: "a.stl", provider: "https://s3.example.com", bytesHere: false)]))
        #expect(!VaultOnlyCopies.onlyInVault([F(name: "a.stl", provider: "gdrive", bytesHere: false)]))
        #expect(!VaultOnlyCopies.onlyInVault([F(name: "a.stl", provider: nil, bytesHere: false)]))
        #expect(!VaultOnlyCopies.onlyInVault([]))
        // The record's own file decides; a pack's other file does not.
        let pack = [F(name: "own.3mf", provider: "vault", bytesHere: true),
                    F(name: "extra.stl", provider: "vault", bytesHere: false)]
        #expect(!VaultOnlyCopies.onlyInVault(pack, own: "own.3mf"))
        #expect(VaultOnlyCopies.onlyInVault(pack, own: "named-nothing.stl"), "an unmatched name: any file decides")
    }

    @Test("the offer: a date once the cloud set one, read-only otherwise, nothing when not over or none at risk")
    func offer() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(VaultOnlyCopies.offer(.deleting(overBytes: 5, deleteAfter: end, daysLeft: 12, since: nil), count: 3) == .before(end))
        #expect(VaultOnlyCopies.offer(.readOnly(overBytes: 5, since: nil), count: 3) == .whileReadOnly)
        #expect(VaultOnlyCopies.offer(.readOnly(overBytes: 5, since: nil), count: 0) == nil)
        #expect(VaultOnlyCopies.offer(.notOver, count: 9) == nil)
        // Through the cloud's own fields: deleting false never shows a date.
        let lapse = CloudPlans.Lapse(over: true, overBytes: 1, readOnlySince: nil,
                                     deleteAfter: "2027-01-24T00:00:00Z", deleting: false)
        #expect(VaultOnlyCopies.offer(lapse.display(), count: 1) == .whileReadOnly)
    }

    @Test("batches keep every model once, in order")
    func batches() {
        let ids = (1...23).map(String.init)
        let b = VaultOnlyCopies.batches(ids, size: 10)
        #expect(b.map(\.count) == [10, 10, 3])
        #expect(b.flatMap { $0 } == ids)
        #expect(VaultOnlyCopies.batches([String](), size: 10).isEmpty)
        #expect(VaultOnlyCopies.batches(["a"], size: 0) == [["a"]])
    }

    @Test("deleted by the plan: purged, not linked again, and only the vault's sidecar here")
    func deletedByPlan() {
        let gone = [F(name: "a.stl", provider: "vault", bytesHere: false)]
        #expect(VaultOnlyCopies.deletedByPlan(purgedAt: "2027-01-24T00:00:00Z", vaultFileId: nil, found: gone))
        #expect(!VaultOnlyCopies.deletedByPlan(purgedAt: nil, vaultFileId: nil, found: gone), "never purged: still online")
        #expect(!VaultOnlyCopies.deletedByPlan(purgedAt: "t", vaultFileId: "F1", found: gone), "the vault holds it again")
        #expect(!VaultOnlyCopies.deletedByPlan(purgedAt: "t", vaultFileId: nil,
                                               found: [F(name: "a.stl", provider: "vault", bytesHere: true)]),
                "the bytes are on this Mac: nothing was lost")
    }

    @Test("Library Health puts a model the plan deleted first, on its own, and never as missing or unmeasured")
    func healthGroup() {
        let models = [
            LibraryHealth.Model(id: "a", title: "A", presence: .deletedByPlan, tags: ["x"]),
            LibraryHealth.Model(id: "b", title: "B", presence: .missing, tags: ["x"]),
            LibraryHealth.Model(id: "c", title: "C", presence: .deletedByPlan, tags: ["x"], archived: true),
        ]
        let groups = LibraryHealth.groups(models: models)
        #expect(groups.first?.kind == .deletedByPlan)
        #expect(groups.first?.modelIds == ["a"], "an archived one is put aside, as everywhere")
        #expect(groups.first { $0.kind == .missing }?.modelIds == ["b"])
        #expect(groups.first { $0.kind == .noFigures } == nil, "nothing to measure: there are no bytes")
    }
}
