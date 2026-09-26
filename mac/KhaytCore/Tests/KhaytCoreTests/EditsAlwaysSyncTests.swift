import Foundation
import Testing
@testable import KhaytCore

/// Every edit the Mac writes carries a higher `rev`, so it syncs and a merge
/// cannot quietly undo it — whether or not the write remembered to stamp.
struct EditsAlwaysSyncTests {

    static func row(_ id: String, rev: Double?, _ extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "name": .string(id)]
        if let rev { o["rev"] = .number(rev) }
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    static func rev(_ root: [String: JSONValue], _ coll: String, _ id: String) -> Double? {
        guard case .array(let rows)? = root[coll] else { return nil }
        for case .object(let o) in rows where o["id"] == .string(id) {
            if case .number(let n)? = o["rev"] { return n }
        }
        return nil
    }

    @Test("an edit that forgot to stamp is stamped")
    func unstampedEdit() {
        let before: [String: JSONValue] = ["printLog": .array([Self.row("Q1", rev: 4, ["status": .string("quote")])])]
        var after = before
        after["printLog"] = .array([Self.row("Q1", rev: 4, ["status": .string("pending")])])
        StoreWriter.stampChanged(before: before, after: &after)
        #expect(Self.rev(after, "printLog", "Q1") == 5)
    }

    @Test("an edit that dropped its rev goes ABOVE the old one, not back to 1")
    func droppedRev() {
        let before: [String: JSONValue] = ["templates": .array([Self.row("T1", rev: 3, ["body": .string("Helo")])])]
        var after = before
        after["templates"] = .array([.object(["id": .string("T1"), "name": .string("T1"), "body": .string("Hello")])])
        StoreWriter.stampChanged(before: before, after: &after)
        #expect(Self.rev(after, "templates", "T1") == 4)
    }

    @Test("a write that already stamped, and a record that did not change, are left alone")
    func leftAlone() {
        let before: [String: JSONValue] = ["spools": .array([Self.row("S1", rev: 2), Self.row("S2", rev: 7)])]
        var after = before
        after["spools"] = .array([Self.row("S1", rev: 3, ["weight": .number(10)]), Self.row("S2", rev: 7)])
        StoreWriter.stampChanged(before: before, after: &after)
        #expect(Self.rev(after, "spools", "S1") == 3)
        #expect(Self.rev(after, "spools", "S2") == 7)
    }

    @Test("a new record is not an edit, and is left as it was written")
    func newRecords() {
        let before: [String: JSONValue] = ["clients": .array([])]
        var after = before
        after["clients"] = .array([Self.row("C1", rev: nil), Self.row("C2", rev: 9)])
        StoreWriter.stampChanged(before: before, after: &after)
        #expect(Self.rev(after, "clients", "C1") == nil)
        #expect(Self.rev(after, "clients", "C2") == 9)
    }

    @Test("through StoreWriter.update, and not for a merge")
    func throughUpdate() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "stamp-\(UUID().uuidString)").appending(path: "khayt-store.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(["purchaseOrders": JSONValue.array([Self.row("PO1", rev: 2, ["status": .string("open")])])]).write(to: url)
        try StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            root["purchaseOrders"] = .array([Self.row("PO1", rev: 2, ["status": .string("received")])])
        }
        var root = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
        #expect(Self.rev(root, "purchaseOrders", "PO1") == 3)

        try StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }, recordingDeletes: false) { root in
            root["purchaseOrders"] = .array([Self.row("PO1", rev: 3, ["status": .string("billed")])])
        }
        root = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
        #expect(Self.rev(root, "purchaseOrders", "PO1") == 3, "a merged record was re-stamped")
    }
}
