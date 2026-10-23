import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The first code in this app that can lose a shop's data.
///
/// Every case runs against a COPY of a real store — this Mac's if there is one,
/// the sample otherwise — in a temp directory. A write path whose only trial run
/// was on a live book has not been tested, it has been risked.
struct StoreWriterTests {

    // MARK: - a store to work on

    static func freshCopy() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "khayt-writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "khayt-store.json")
        try source().write(to: url)
        return url
    }

    static func source() throws -> Data {
        for build in StoreReader.Build.allCases where build.exists {
            return try Data(contentsOf: build.storeURL)
        }
        return try Data(contentsOf: Bundle.module.url(forResource: "sample-shop", withExtension: "json")!)
    }

    static func read(_ url: URL) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
    }

    static func firstFileId(_ root: [String: JSONValue]) -> String? {
        guard case .array(let rows)? = root["printFiles"], case .object(let first)? = rows.first,
              case .string(let id)? = first["id"] else { return nil }
        return id
    }

    static func owner() -> Bool { true }
    static func nobody() -> String? { nil }

    // MARK: -

    @Test("an edit changes the record it names, and stamps it")
    func editsOneRecord() throws {
        let url = try Self.freshCopy()
        let before = try Self.read(url)
        guard let id = Self.firstFileId(before) else { return }   // no library on this store

        try StoreWriter.updateRecord(storeURL: url, owns: Self.owner, whoHasIt: Self.nobody,
                                     collection: "printFiles", id: id) { record in
            record["favorite"] = .bool(true)
        }

        let after = try Self.read(url)
        guard case .array(let rows)? = after["printFiles"],
              case .object(let record) = rows.first(where: {
                  if case .object(let o) = $0, case .string(let rid)? = o["id"] { return rid == id }
                  return false
              })! else { Issue.record("record vanished"); return }

        #expect(record["favorite"] == .bool(true))
        // Stamped, or the change never reaches the cloud: the renderer's sync
        // baseline is seeded from the store, so an unstamped edit looks like the
        // state it had always been in.
        if case .number(let rev)? = record["rev"] { #expect(rev >= 1) } else { Issue.record("no rev") }
        if case .string(let at)? = record["updatedAt"] {
            #expect(at.hasSuffix("Z") && at.count == 24, "updatedAt must match new Date().toISOString(): \(at)")
        } else { Issue.record("no updatedAt") }
    }

    @Test("nothing else in the book moves")
    func touchesNothingElse() throws {
        let url = try Self.freshCopy()
        let before = try Self.read(url)
        guard let id = Self.firstFileId(before) else { return }

        try StoreWriter.updateRecord(storeURL: url, owns: Self.owner, whoHasIt: Self.nobody,
                                     collection: "printFiles", id: id) { record in
            record["favorite"] = .bool(true)
        }
        let after = try Self.read(url)

        #expect(before.keys.sorted() == after.keys.sorted(), "a collection appeared or vanished")
        for key in before.keys where key != "printFiles" {
            #expect(before[key] == after[key], "\(key) changed and had no business changing")
        }
        // The secrets in particular: this path never decrypts, so they must come
        // through byte for byte. Re-encrypting a working credential into
        // something nothing can open is the failure that matters most here.
        if case .object(let b)? = before["settings"], case .object(let a)? = after["settings"] {
            #expect(b == a, "settings changed — the secrets may have been re-wrapped")
        }
    }

    @Test("the previous book is kept, and no temp file is left behind")
    func keepsOneGeneration() throws {
        let url = try Self.freshCopy()
        let before = try Data(contentsOf: url)
        guard let id = Self.firstFileId(try Self.read(url)) else { return }

        try StoreWriter.updateRecord(storeURL: url, owns: Self.owner, whoHasIt: Self.nobody,
                                     collection: "printFiles", id: id) { record in
            record["favorite"] = .bool(true)
        }

        let prev = url.appendingPathExtension("prev")
        #expect(FileManager.default.fileExists(atPath: prev.path), "no .prev to roll back to")
        #expect(try Data(contentsOf: prev) == before, ".prev is not the book we started with")

        let strays = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { $0.contains(".tmp.") }
        #expect(strays.isEmpty, "left temp files behind: \(strays)")
    }

    @Test("it refuses, and changes nothing, when the book is not ours")
    func refusesWhenNotOwner() throws {
        let url = try Self.freshCopy()
        let before = try Data(contentsOf: url)
        var ran = false
        #expect(throws: StoreWriter.Refusal.self) {
            try StoreWriter.update(storeURL: url,
                                   owns: { false },
                                   whoHasIt: { "Khayt has this book open" }) { _ in ran = true }
        }
        #expect(!ran, "the mutator ran despite the refusal")
        #expect(try Data(contentsOf: url) == before, "the store was modified after a refusal")
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("prev").path),
                "a refusal must not roll the book to .prev")
    }

    @Test("a store that would outgrow every backup is refused")
    func refusesOversizeStore() throws {
        let url = try Self.freshCopy()
        let before = try Data(contentsOf: url)
        #expect(throws: StoreWriter.Refusal.self) {
            try StoreWriter.update(storeURL: url, owns: Self.owner, whoHasIt: Self.nobody) { root in
                // Comfortably past MAX_STORE_BYTES without building it in memory
                // a byte at a time.
                let chunk = String(repeating: "x", count: 1_000_000)
                root["_bloat"] = .array((0..<60).map { _ in .string(chunk) })
            }
        }
        #expect(try Data(contentsOf: url) == before, "an oversize write reached the disk")
    }

    @Test("an edit naming a record that is not there is a no-op, not a wipe")
    func unknownRecordIsHarmless() throws {
        let url = try Self.freshCopy()
        let before = try Self.read(url)
        try StoreWriter.updateRecord(storeURL: url, owns: Self.owner, whoHasIt: Self.nobody,
                                     collection: "printFiles", id: "PF-does-not-exist") { record in
            record["favorite"] = .bool(true)
        }
        #expect(try Self.read(url) == before)
    }

    @Test("the timestamp is the one JavaScript writes")
    func isoMatchesJavaScript() throws {
        // Asked of Node rather than written out here. The first version of this
        // test carried a date I had worked out by hand, and it was wrong by ten
        // days — which would have failed a correct implementation.
        for epochMs in [1_788_000_000_123, 0, 1_000, 1_767_225_599_999] {
            let mine = StoreWriter.iso(Date(timeIntervalSince1970: Double(epochMs) / 1000))
            let theirs = try Self.node("new Date(\(epochMs)).toISOString()")
            #expect(mine == theirs, "epoch \(epochMs): Swift \(mine), JS \(theirs)")
        }
    }

    static func node(_ expression: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "-e", "process.stdout.write(String(\(expression)))"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    @Test("an undo restores the values and moves the revision forward")
    func undoDoesNotRewindTheRevision() {
        let before: [String: JSONValue] = [
            "id": .string("PF-1"), "favorite": .bool(false), "group": .string("Kings"),
            "rev": .number(3), "updatedAt": .string("2026-01-01T00:00:00.000Z"),
        ]
        // The record after an edit: favourite set, group cleared, rev bumped.
        let current: [String: JSONValue] = [
            "id": .string("PF-1"), "favorite": .bool(true), "group": .string(""),
            "rev": .number(4), "updatedAt": .string("2026-02-02T00:00:00.000Z"),
        ]
        let restored = StoreWriter.restoring(before, over: current)

        #expect(restored["favorite"] == .bool(false), "the value must come back")
        #expect(restored["group"] == .string("Kings"))
        // Forward from where the record IS, not back to where it was. A rev
        // that went backwards looks to the next sync exactly like the change
        // never happened, and the other machine's copy wins — the undo undone,
        // by a laptop, quietly.
        #expect(restored["rev"] == .number(5), "got \(String(describing: restored["rev"]))")
        #expect(restored["updatedAt"] != before["updatedAt"], "an undo is an edit and is stamped")
    }

    @Test("a first stamp starts at rev 1, and later ones count on")
    func stampCounts() {
        var fresh: [String: JSONValue] = ["id": .string("X")]
        StoreWriter.stamp(&fresh)
        #expect(fresh["rev"] == .number(1))
        var seen: [String: JSONValue] = ["id": .string("X"), "rev": .number(7)]
        StoreWriter.stamp(&seen)
        #expect(seen["rev"] == .number(8))
    }
}

/// beta.5 review: a value that records something already done outside the
/// book (the portal page went up or down) is stamped even when it is a no-op,
/// so it wins LWW over another Mac's stale value.
struct StoreWriterForceStampTests {
    @Test("forceStamp stamps a write that changed nothing; the default still does not")
    func forceStampStampsANoOp() {
        var root: [String: JSONValue] = ["printLog": .array([
            .object(["id": .string("J1"), "rev": .number(4), "updatedAt": .string("2026-10-01T00:00:00.000Z"),
                     "cloudPublished": .bool(true)]),
        ])]
        let before = root
        _ = StoreWriter.changeRecord(&root, collection: "printLog", id: "J1") { $0["cloudPublished"] = .bool(true) }
        #expect(root == before, "the default no-op rule is unchanged")

        _ = StoreWriter.changeRecord(&root, collection: "printLog", id: "J1", forceStamp: true) {
            $0["cloudPublished"] = .bool(true)
        }
        guard case .array(let rows)? = root["printLog"], case .object(let j)? = rows.first else {
            Issue.record("no row"); return
        }
        #expect(j["rev"] == .number(5))
        #expect(j["updatedAt"] != .string("2026-10-01T00:00:00.000Z"))
        #expect(j["cloudPublished"] == .bool(true))
    }

    @Test("a forced stamp on a missing record writes nothing")
    func forceStampOnMissingRecord() {
        var root: [String: JSONValue] = ["printLog": .array([])]
        let out: Void? = StoreWriter.changeRecord(&root, collection: "printLog", id: "nope", forceStamp: true) { _ in }
        #expect(out == nil)
        #expect(root == ["printLog": .array([])])
    }
}
