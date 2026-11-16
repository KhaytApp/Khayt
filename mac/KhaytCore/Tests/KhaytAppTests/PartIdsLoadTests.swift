import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Parts without an id get the id they are owed at load, and it is written
/// only to a book this Mac owns (`Shop+PartIds.swift`).
///
/// In the serialised suite of the library timings: these point the app at a
/// temp book through the one global test seam (`PerfBook.install`).
extension LibraryEditPerfTests {

    /// Three jobs: two with a part that has no id (one Arabic), one whose
    /// part has an id and must not move.
    static func partIdsBook() -> [String: JSONValue] {
        var root = PerfBook.synthesize(models: 0)
        func job(_ id: String, rev: Double, _ parts: [JSONValue]) -> JSONValue {
            .object(["id": .string(id), "status": .string("completed"), "rev": .number(rev),
                     "updatedAt": .string("2026-10-01T09:00:00.000Z"),
                     "timestamp": .string("2026-10-01T09:00:00.000Z"), "parts": .array(parts)])
        }
        root["printLog"] = .array([
            job("INV-2026-0001", rev: 7, [.object(["name": .string("Bracket"), "qty": .number(2),
                                                  "printWeight": .number(12.5), "unitCost": .number(3)])]),
            job("INV-2026-0003-3y0z", rev: 6, [.object(["name": .string("حامل جوال"), "qty": .number(1)])]),
            job("INV-2026-0009", rev: 2, [.object(["id": .string("PRT-kept"), "name": .string("Lid")])]),
        ])
        return root
    }

    static func onDisk() throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self,
                                 from: Data(contentsOf: StoreReader.Build.shipped.storeURL))
    }

    static func job(_ root: [String: JSONValue], _ id: String) -> [String: JSONValue]? {
        for case .object(let o) in Shop.rows(root, "printLog") {
            if case .string(let i)? = o["id"], i == id { return o }
        }
        return nil
    }

    static func firstPartId(_ job: [String: JSONValue]?) -> String? {
        guard case .array(let parts)? = job?["parts"], case .object(let p)? = parts.first,
              case .string(let id)? = p["id"] else { return nil }
        return id
    }

    @Test("an owned book: the ids are written once, stamped, and nothing else moves")
    @MainActor
    func ownedBookIsWritten() async throws {
        let engine = try KhaytEngine()
        let support = try PerfBook.install(Self.partIdsBook())
        defer {
            StoreReader.Build.supportFolderForTests = nil
            try? FileManager.default.removeItem(at: support.deletingLastPathComponent())
        }
        let book = Self.partIdsBook()
        let want1 = try await engine.partIdFor(orderId: "INV-2026-0001", index: 0,
                                         part: .object(["name": .string("Bracket"), "qty": .number(2),
                                                        "printWeight": .number(12.5), "unitCost": .number(3)]))
        let want3 = try await engine.partIdFor(orderId: "INV-2026-0003-3y0z", index: 0,
                                         part: .object(["name": .string("حامل جوال"), "qty": .number(1)]))

        let shop = Shop()
        await shop.load(.store(.shipped))
        #expect(shop.ownership != nil, "the test book was not taken")
        // The ids on screen are the ids the book will hold, from the first load.
        #expect(shop.orders.first { $0.id == "INV-2026-0001" }?.parts.first?.id == want1)
        #expect(shop.orders.first { $0.id == "INV-2026-0003-3y0z" }?.parts.first?.id == want3)

        // The write runs after the load; wait for it to land.
        var disk = try Self.onDisk()
        for _ in 0..<100 where Self.firstPartId(Self.job(disk, "INV-2026-0001")) == nil {
            try await Task.sleep(for: .milliseconds(50))
            disk = try Self.onDisk()
        }
        #expect(Self.firstPartId(Self.job(disk, "INV-2026-0001")) == want1)
        #expect(Self.firstPartId(Self.job(disk, "INV-2026-0003-3y0z")) == want3)
        // Stamped, so it syncs.
        #expect(Self.job(disk, "INV-2026-0001")?["rev"] == .number(8))
        #expect(Self.job(disk, "INV-2026-0003-3y0z")?["rev"] == .number(7))
        // The job with nothing missing is exactly as it was.
        #expect(Self.job(disk, "INV-2026-0009") == Self.job(book, "INV-2026-0009"))
        // Only `id`, `rev` and `updatedAt` moved on the two that changed.
        for id in ["INV-2026-0001", "INV-2026-0003-3y0z"] {
            var was = try #require(Self.job(book, id)), now = try #require(Self.job(disk, id))
            for k in ["rev", "updatedAt"] { was[k] = nil; now[k] = nil }
            if case .array(let parts)? = now["parts"], case .object(var p)? = parts.first {
                p["id"] = nil; now["parts"] = .array([.object(p)])
            }
            #expect(now == was, Comment(rawValue: id))
        }
        // Everything outside the jobs is as it was.
        var restWas = book, restNow = disk
        restWas["printLog"] = nil; restNow["printLog"] = nil
        restWas["tombstones"] = nil; restNow["tombstones"] = nil
        #expect(restNow == restWas)

        // Idempotent: the reload after it finds nothing to give, and a second
        // ask writes nothing.
        try await Task.sleep(for: .milliseconds(200))
        // The jobs, not the whole file: a load of this small book may let
        // other load-time work (standing orders, the library) write too.
        let settled = Shop.rows(try Self.onDisk(), "printLog")
        #expect(await shop.writeMissingPartIds() == false)
        await shop.load(.store(.shipped))
        try await Task.sleep(for: .milliseconds(200))
        #expect(Shop.rows(try Self.onDisk(), "printLog") == settled)
        #expect(shop.orders.first { $0.id == "INV-2026-0001" }?.parts.first?.id == want1)
        await shop.load(.sample)
    }

    @Test("a book another app owns: the same ids in memory, and NO write")
    @MainActor
    func notOwnedIsNeverWritten() async throws {
        let engine = try KhaytEngine()
        let support = try PerfBook.install(Self.partIdsBook())
        defer {
            StoreReader.Build.supportFolderForTests = nil
            try? FileManager.default.removeItem(at: support.deletingLastPathComponent())
        }
        // Another machine's lock, fresh: this Mac must read and never write.
        let now = Date().timeIntervalSince1970 * 1000
        let theirs = StoreLock.Record(app: "Khayt", pid: Int(ProcessInfo.processInfo.processIdentifier),
                                      host: "other-mac.local", takenAt: now - 5, heartbeat: now)
        try JSONEncoder().encode(theirs).write(to: StoreLock.lockURL(for: .shipped))
        let before = try Data(contentsOf: StoreReader.Build.shipped.storeURL)

        let shop = Shop()
        await shop.load(.store(.shipped))
        #expect(shop.ownership == nil, "the test book was taken from its owner")
        let want1 = try await engine.partIdFor(orderId: "INV-2026-0001", index: 0,
                                         part: .object(["name": .string("Bracket"), "qty": .number(2),
                                                        "printWeight": .number(12.5), "unitCost": .number(3)]))
        #expect(shop.orders.first { $0.id == "INV-2026-0001" }?.parts.first?.id == want1)
        // Stable across a reload: the made-up UUID is gone.
        await shop.load(.store(.shipped))
        #expect(shop.orders.first { $0.id == "INV-2026-0001" }?.parts.first?.id == want1)
        #expect(await shop.writeMissingPartIds() == false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try Data(contentsOf: StoreReader.Build.shipped.storeURL) == before,
                "a book this Mac does not own was written")
        await shop.load(.sample)
        try? FileManager.default.removeItem(at: StoreLock.lockURL(for: .shipped))
    }

    /// The proof on a COPY of a real book, run by hand: `KHAYT_PARTIDS_PROOF`
    /// names the copy and `KHAYT_PARTIDS_PROOF_OUT` where the result goes.
    /// Reads the copy, runs the write's own transform (`Shop.givePartIds`)
    /// and writes the result to the out path; the copy itself is not
    /// changed, and nothing here can reach the shop's book. Skipped when the
    /// variables are not set, which is every ordinary run.
    @Test("proof on a copy of a book (only when asked)")
    @MainActor
    func proofOnACopy() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let copy = env["KHAYT_PARTIDS_PROOF"], let out = env["KHAYT_PARTIDS_PROOF_OUT"] else { return }
        #expect(!copy.contains("Application Support/Khayt"), "point this at a copy, never the book")
        let engine = try KhaytEngine()
        var root = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: URL(fileURLWithPath: copy)))
        let first = await Shop.givePartIds(&root, engine: engine)
        let second = await Shop.givePartIds(&root, engine: engine)
        root["__proof"] = .object(["first": .number(Double(first)), "second": .number(Double(second))])
        try JSONEncoder().encode(root).write(to: URL(fileURLWithPath: out))
    }
}
