import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Every collection this app reads or writes is one the other app's store
/// actually has.
///
/// ── THE BUG THIS EXISTS FOR ───────────────────────────────────────────────
///
/// The service log was written under `hub_maint_log_v1`, with a comment saying
/// `renderer/app-state.js` chose the key. It had — as that app's **localStorage**
/// key, in the legacy fallback path, which `app-state.js` translates into
/// `machMaintLog` before anything reads it. The store file itself has only ever
/// held `machMaintLog`.
///
/// So every repair a shop typed into this app went into a field nothing reads,
/// and the machine P&L charged zero maintenance however much had been spent —
/// the figure that decides whether a printer is worth keeping.
///
/// **And every test passed**, because `sample-shop.json` had been written to
/// match the mistake. A fixture cannot catch this: the fixture is the thing
/// that is wrong. So this reads the other app's SOURCE.
@MainActor
struct StoreKeysAreTheOtherAppsTests {

    /// Keys this app uses that are not in the snapshot, with the reason.
    ///
    /// `printerCompletions` is written by the main process on a timer, not by
    /// the renderer's snapshot, so it is absent from `collectStoreCollections`
    /// and present in every real book. Read here, never written.
    static let allowed: Set<String> = ["printerCompletions", "version"]

    /// The keys the other app's store snapshot is made of — its own source,
    /// read at test time rather than copied into a list here.
    static func snapshotKeys() throws -> Set<String> {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/Tests/KhaytAppTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // …/KhaytCore
            .deletingLastPathComponent()   // …/mac
            .deletingLastPathComponent()   // the repository root
        let text = try String(contentsOf: root.appending(path: "renderer/app-state.js"),
                              encoding: .utf8)
        guard let start = text.range(of: "function collectStoreCollections() {"),
              let close = text.range(of: "};", range: start.upperBound..<text.endIndex),
              let open = text.range(of: "return {", range: start.upperBound..<close.upperBound)
        else {
            Issue.record("could not find collectStoreCollections — the scan has rotted")
            return []
        }
        let body = text[open.upperBound..<close.lowerBound]
        return Set(body.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init).filter { !$0.isEmpty })
    }

    @Test("the other app's snapshot is the list it has always been")
    func snapshotIsReadable() throws {
        let keys = try Self.snapshotKeys()
        #expect(keys.count > 25, Comment(rawValue: "found only \(keys.count): \(keys.sorted())"))
        #expect(keys.contains("printLog"))
        #expect(keys.contains("machMaintLog"))
        #expect(!keys.contains("hub_maint_log_v1"),
                "that is the localStorage key, and reading it as the store key was the bug")
    }

    @Test("the service log key is the other app's store key")
    func serviceLogKeyMatches() throws {
        #expect(try Self.snapshotKeys().contains(ServiceLogEdit.collection),
                Comment(rawValue: "\(ServiceLogEdit.collection) is not a key the store has"))
        #expect(ServiceLogEdit.collection == "machMaintLog")
        // And the one it used to be, which must stay known so the rescue works.
        #expect(ServiceLogEdit.strandedCollection == "hub_maint_log_v1")
    }

    @Test("every top-level key this app touches is one the store has")
    func everyKeyIsReal() throws {
        let known = try Self.snapshotKeys().union(Self.allowed)
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources")
        var offenders: [String] = []
        let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        var scanned = 0
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for match in text.ranges(of: /root\["([A-Za-z_][A-Za-z_0-9]*)"\]/) {
                let key = String(text[match]).dropFirst(6).dropLast(2)
                guard !known.contains(String(key)) else { continue }
                offenders.append("\(url.lastPathComponent) reads root[\"\(key)\"]")
            }
        }
        #expect(scanned > 100, Comment(rawValue: "only \(scanned) files scanned — the walk has rotted"))
        #expect(offenders.isEmpty, Comment(rawValue:
            "a collection this app reads is not one the other app's store has, so the "
            + "read finds nothing on every real book and says nothing about it:\n  "
            + Set(offenders).sorted().joined(separator: "\n  ")))
    }

    @Test("the sample book uses the same key a real book does")
    func sampleUsesTheRealKey() throws {
        // The sample had been written to match the mistake, which is why the
        // suite was green while the feature did nothing.
        let shop = Shop()
        let url = try #require(AppResources.bundle.url(forResource: "sample-shop",
                                                       withExtension: "json"))
        let root = try JSONDecoder().decode([String: JSONValue].self,
                                            from: Data(contentsOf: url))
        #expect(root[ServiceLogEdit.collection] != nil,
                "the sample has no service log under the key a real book uses")
        #expect(root[ServiceLogEdit.strandedCollection] == nil,
                "the sample still carries the key that was never in a store file")
        _ = shop
    }
}

/// Moving a log out of the key it should never have been in.
@MainActor
struct ServiceLogRescueTests {

    private func entry(_ id: String, _ date: String, cost: Double = 0) -> JSONValue {
        .object(["id": .string(id), "machineId": .string("M1"), "date": .string(date),
                 "note": .string("belt"), "cost": .number(cost)])
    }

    @Test("rows under the old key are moved, not dropped")
    func rowsMove() {
        var root: [String: JSONValue] = [
            ServiceLogEdit.strandedCollection: .array([entry("A", "2026-09-01", cost: 120)]),
        ]
        #expect(ServiceLogEdit.rescueStranded(&root))
        guard case .array(let log)? = root[ServiceLogEdit.collection] else {
            Issue.record("nothing under the right key"); return
        }
        #expect(log.count == 1)
        #expect(root[ServiceLogEdit.strandedCollection] == nil, "the stray key is gone")
    }

    @Test("a shop that used both apps keeps both halves, newest first")
    func bothHalvesSurvive() {
        var root: [String: JSONValue] = [
            ServiceLogEdit.collection: .array([entry("B", "2026-08-01")]),
            ServiceLogEdit.strandedCollection: .array([entry("A", "2026-09-01")]),
        ]
        #expect(ServiceLogEdit.rescueStranded(&root))
        guard case .array(let log)? = root[ServiceLogEdit.collection] else {
            Issue.record("nothing under the right key"); return
        }
        #expect(log.count == 2)
        // Newest first: two lists concatenated would put August above September.
        guard case .object(let first) = log[0], case .string(let day)? = first["date"] else {
            Issue.record("no date on the first row"); return
        }
        #expect(day == "2026-09-01", "the log is not newest-first")
    }

    @Test("running it twice does not double a shop's repair bill")
    func idempotent() {
        var root: [String: JSONValue] = [
            ServiceLogEdit.strandedCollection: .array([entry("A", "2026-09-01", cost: 120)]),
        ]
        #expect(ServiceLogEdit.rescueStranded(&root))
        #expect(ServiceLogEdit.rescueStranded(&root) == false, "there was nothing left to do")
        guard case .array(let log)? = root[ServiceLogEdit.collection] else {
            Issue.record("nothing under the right key"); return
        }
        #expect(log.count == 1)
        // And again with the old key put back holding the same row, which is
        // what a second device syncing an old copy looks like.
        root[ServiceLogEdit.strandedCollection] = .array([entry("A", "2026-09-01", cost: 120)])
        #expect(ServiceLogEdit.rescueStranded(&root))
        guard case .array(let after)? = root[ServiceLogEdit.collection] else {
            Issue.record("nothing under the right key"); return
        }
        #expect(after.count == 1, "the same repair was counted twice")
    }

    @Test("an empty stray key is still removed, and a book without one is left alone")
    func emptyAndAbsent() {
        var empty: [String: JSONValue] = [ServiceLogEdit.strandedCollection: .array([])]
        #expect(ServiceLogEdit.rescueStranded(&empty))
        #expect(empty[ServiceLogEdit.strandedCollection] == nil)

        var clean: [String: JSONValue] = [ServiceLogEdit.collection: .array([entry("B", "2026-08-01")])]
        #expect(ServiceLogEdit.rescueStranded(&clean) == false, "nothing to do, so nothing written")
        #expect(clean.count == 1)
    }
}
