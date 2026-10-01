import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Putting a spool on the shelf, and correcting one.
///
/// The RULE is `lib/spool-edit.js`, tested where it lives against the two
/// renderer handlers it was lifted from. What is tested here is that this app
/// asks for it correctly, writes the settings that come back with it, stamps
/// an edit and not a new record, and can undo a deletion.
@MainActor
struct SpoolTests {

    static func shelf() -> [String: JSONValue] {
        [
            "inventory": .array([
                .object(["id": .string("S1"), "material": .string("PLA"), "weight": .number(800),
                         "cost": .number(90), "rev": .number(4)]),
                .object(["id": .string("S2"), "material": .string("PETG"), "weight": .number(500),
                         "cost": .number(120), "rev": .number(1)]),
            ]),
            "settings": .object(["currency": .string("SAR")]),
        ]
    }

    static func rows(_ root: [String: JSONValue]) -> [[String: JSONValue]] {
        Shop.rows(root, "inventory").compactMap { if case .object(let o) = $0 { return o } else { return nil } }
    }
    static func number(_ v: JSONValue?) -> Double? { Shop.plainNumber(v) }
    static func string(_ v: JSONValue?) -> String? { Shop.plainString(v) }

    @Test("a new spool is the record the shared rule builds")
    func newSpool() async throws {
        let engine = try KhaytEngine()
        let made = try await engine.newSpool([
            "material": .string("  PLA+ 2.0 "), "cost": .string("90"),
            "weight": .string("1000"), "color": .string("#112233"),
        ], id: "INV-1", today: "2026-09-04")
        guard case .object(let spool)? = made.spool else { Issue.record("no record"); return }
        #expect(Self.string(spool["material"]) == "PLA+ 2.0", "trimmed")
        #expect(Self.number(spool["weight"]) == 1000)
        #expect(Self.string(spool["purchasedAt"]) == "2026-09-04")
        #expect(Self.string(spool["materialType"]) == "fdm", "the default a shop never has to choose")
    }

    @Test("a spool with no material is refused")
    func refused() async throws {
        let engine = try KhaytEngine()
        let made = try await engine.newSpool(["material": .string("   ")], id: "X", today: "2026-09-04")
        #expect(made.spool == nil)
        #expect(made.refused == "material")
    }

    @Test("an edit carries the fields it was not shown, and remembers a price change")
    func edit() async throws {
        let engine = try KhaytEngine()
        let before: JSONValue = .object([
            "id": .string("S1"), "material": .string("PLA"), "cost": .number(90),
            "weight": .number(800), "printTemp": .number(215), "usageHistory": .array([.number(12)]),
        ])
        let out = try await engine.editSpool(before, input: ["weight": .string("650"), "cost": .string("110")],
                                             settings: [:], today: "2026-09-05")
        guard case .object(let spool) = out.spool else { Issue.record("no record"); return }
        #expect(Self.number(spool["weight"]) == 650)
        #expect(Self.number(spool["printTemp"]) == 215, "a field the form did not show is left alone")
        #expect(spool["usageHistory"] != nil, "and so is the usage the shelf rules wrote")
        if case .array(let history)? = spool["priceHistory"], case .object(let entry)? = history.first {
            #expect(Self.number(entry["cost"]) == 90, "the OLD price is what is remembered")
            #expect(Self.string(entry["date"]) == "2026-09-05")
        } else {
            Issue.record("the price change was not remembered")
        }
    }

    @Test("a colour variant comes back in the settings, not only on the spool")
    func colours() async throws {
        let engine = try KhaytEngine()
        let before: JSONValue = .object(["id": .string("S1"), "material": .string("PLA")])
        let out = try await engine.editSpool(before, input: ["colourVariant": .string(" Matte Black ")],
                                             settings: [:], today: "2026-09-05")
        #expect(out.colourAdded == "Matte Black")
        #expect(try await engine.spoolColours(settings: out.settings, material: "PLA") == ["Matte Black"],
                "the shop's library learned it — the caller must write the settings too")
    }

    // MARK: - On disk

    @Test("an edit is stamped, a new spool is not, and neither touches the other rows")
    func onDisk() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let url = try Self.tempStore(Self.shelf())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            var shelf = Shop.rows(root, "inventory")
            let out = try await engine.editSpool(shelf[0], input: ["weight": .string("650")],
                                                 settings: Shop.settings(root), today: "2026-09-05")
            guard case .object(var record) = out.spool else { return }
            StoreWriter.stamp(&record)
            shelf[0] = .object(record)
            let made = try await engine.newSpool(["material": .string("ASA"), "weight": .string("1000")],
                                                 id: "INV-new", today: "2026-09-05")
            shelf.append(try #require(made.spool))
            root["inventory"] = .array(shelf)
        }
        let back = try Self.read(url)
        let shelf = Self.rows(back)
        #expect(Self.number(shelf[0]["weight"]) == 650)
        // `rev` is what the cloud's sync baseline reads: an unstamped edit
        // never leaves this Mac.
        #expect(Self.number(shelf[0]["rev"]) == 5, "the corrected spool is stamped")
        #expect(Self.number(shelf[1]["rev"]) == 1, "the one nobody touched is not")
        #expect(shelf.count == 3)
        #expect(shelf[2]["rev"] == nil, "a new record is not an edit, so it is not stamped")
    }

    @Test("deleting a spool takes it off the shelf and leaves the rest")
    func delete() async throws {
        let url = try Self.tempStore(Self.shelf())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            var shelf = Shop.rows(root, "inventory")
            shelf.removeAll { Shop.recordId($0) == "S1" }
            root["inventory"] = .array(shelf)
        }
        let shelf = Self.rows(try Self.read(url))
        #expect(shelf.count == 1)
        #expect(Self.string(shelf[0]["id"]) == "S2")
    }

    @Test("the sample shop's shelf cannot be changed, and it says why")
    func sampleRefuses() async throws {
        let shop = Shop()
        await shop.load(.sample)
        await shop.saveSpool(["material": .string("PLA")], id: nil, opened: nil)
        #expect(shop.spendProblem == shop.words.callIt("mac.move_sample"))
        await shop.deleteSpool("anything")
        #expect(shop.spendProblem == shop.words.callIt("mac.move_sample"))
    }

    // MARK: -

    static func tempStore(_ root: [String: JSONValue]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-spool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "khayt-store.json")
        try JSONEncoder().encode(root).write(to: url)
        return url
    }

    static func read(_ url: URL) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
    }
}
