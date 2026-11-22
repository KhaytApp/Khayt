import XCTest
import KhaytCore
@testable import KhaytCompanion

/**
 * Three ways an edit made on the phone was lost without a word, each pinned.
 *
 * - A send recorded the book as it stood AFTER the reply as delivered, so an
 *   edit made while the send was in flight was never sent.
 * - A pull on a locked phone could not read the baseline, took that for a
 *   first pull, and replaced the book.
 * - A save that changed nothing still bumped `rev`, so a phone a sync behind
 *   could outrank a real edit made on the Mac.
 *
 * The send race through the cloud is in `CloudSyncTests`; these are the book's
 * half of it.
 */
final class SyncDataLossTests: XCTestCase {

    private var dir: URL!
    private var book: CompanionBook!
    private var reader: BookReader!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "loss-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        book = CompanionBook(directory: dir)
        reader = BookReader(book: book)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func pulled() -> [String: JSONValue] {
        [
            "settings": .object(["shopName": .string("Ward")]),
            "clients": .array([
                .object(["id": .string("C-1"), "name": .string("Sara"), "rev": .number(1)]),
                .object(["id": .string("C-2"), "name": .string("Nora"), "rev": .number(1)]),
            ]),
            "printLog": .array([]),
        ]
    }

    private func client(_ id: String) throws -> [String: JSONValue]? {
        guard case .array(let rows)? = try book.read()["clients"] else { return nil }
        for case .object(let o) in rows where o["id"] == .string(id) { return o }
        return nil
    }

    // MARK: - An edit made during a send

    func testAnEditMadeWhileTheSendWasInFlightStaysPending() async throws {
        try book.replace(with: pulled(), scope: nil)
        try book.updateRecord(collection: "clients", id: "C-1") { $0["name"] = .string("Sara A.") }

        // The sender measures its outbox…
        let snapshot = try await reader.pendingSnapshot()
        let measured = try XCTUnwrap(snapshot)
        XCTAssertEqual(measured.outbox.count, 1)
        // …and while it waits on the network, another screen saves.
        try book.updateRecord(collection: "clients", id: "C-2") { $0["name"] = .string("Nora K.") }
        // The reply comes back: what was SENT is synced.
        try book.markSynced(measured.book)

        let after = try await reader.pendingChanges()
        let outbox = try XCTUnwrap(after)
        XCTAssertEqual(outbox.count, 1, "the edit made during the send was counted as delivered")
        guard case .object(let delta)? = outbox.deltas.first,
              case .object(let record)? = delta["record"] else { return XCTFail("\(outbox.deltas)") }
        XCTAssertEqual(record["id"], .string("C-2"))
    }

    // MARK: - A locked phone

    func testAPullThatCannotReadTheBaselineDoesNotReplaceTheBook() async throws {
        try book.replace(with: pulled(), scope: nil)
        try book.updateRecord(collection: "clients", id: "C-1") { $0["name"] = .string("Offline edit") }
        let before = try book.read()

        // There, but unreadable — what a `.complete` file is on a locked phone.
        // A directory in its place is the same answer without a lock screen.
        try FileManager.default.removeItem(at: book.baselineURL)
        try FileManager.default.createDirectory(at: book.baselineURL, withIntermediateDirectories: false)
        guard case .unreadable = book.readBaseline() else { return XCTFail("not read as unreadable") }

        var upstream = pulled()
        upstream["clients"] = .array([.object(["id": .string("C-9"), "name": .string("New"), "rev": .number(1)])])
        do {
            try await reader.adopt(upstream, scope: nil)
            XCTFail("the pull went ahead without a baseline")
        } catch CompanionBook.Failure.baselineUnreadable {}
        XCTAssertEqual(try book.read(), before, "the book was replaced and the offline edit went with it")
    }

    func testABookWithNoBaselineKeepsItsEditsThroughAPull() async throws {
        try book.replace(with: pulled(), scope: nil)
        try book.updateRecord(collection: "clients", id: "C-1") { $0["name"] = .string("Offline edit") }
        try FileManager.default.removeItem(at: book.baselineURL)
        guard case .absent = book.readBaseline() else { return XCTFail("not read as absent") }

        var upstream = pulled()
        upstream["clients"] = .array([
            .object(["id": .string("C-1"), "name": .string("Sara"), "rev": .number(1)]),
            .object(["id": .string("C-2"), "name": .string("Nora (Mac)"), "rev": .number(2)]),
        ])
        try await reader.adopt(upstream, scope: nil)

        XCTAssertEqual(try client("C-1")?["name"], .string("Offline edit"), "the phone's edit was thrown away")
        XCTAssertEqual(try client("C-2")?["name"], .string("Nora (Mac)"), "a newer upstream copy still wins")
        let pending = try await reader.pendingChanges()
        XCTAssertEqual(pending?.count, 1, "and the edit is still on its way")
    }

    // MARK: - A save that changed nothing

    func testAnUpdateThatChangesNothingKeepsTheRevision() async throws {
        try book.replace(with: pulled(), scope: nil)
        let before = try Data(contentsOf: book.url)

        try book.updateRecord(collection: "clients", id: "C-1") { $0["name"] = .string("Sara") }

        XCTAssertEqual(try client("C-1")?["rev"], .number(1), "a no-op save bumped the revision")
        XCTAssertEqual(try Data(contentsOf: book.url), before, "and was written")
        let pending = try await reader.pendingChanges()
        XCTAssertEqual(pending?.count, 0)

        // A real change is still stamped.
        try book.updateRecord(collection: "clients", id: "C-1") { $0["name"] = .string("Sara A.") }
        XCTAssertEqual(try client("C-1")?["rev"], .number(2))
    }
}

/// Unpair goes through the client, so the cloud sign-in it holds goes too.
@MainActor
final class UnpairSignsOutTests: XCTestCase {

    func testUnpairDropsTheCloudSessionInMemory() {
        let defaults = UserDefaults.standard
        let keys = ["khayt.host", "khayt.paired", "khayt.sampleShop"]
        let saved = keys.map { defaults.object(forKey: $0) }
        let held = CloudSession.load()
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            CloudSession.forget()
            held?.save()
        }

        CloudSession(url: "https://cloud.test", shopId: "shop_1", token: "tok",
                     dek: Data(repeating: 7, count: 32), role: "owner", seenRev: 3).save()
        let settings = ConnectionSettings()
        let api = KhaytAPIClient(settings: settings, withBook: false)
        XCTAssertNotNil(api.cloud)

        api.unpair()

        XCTAssertNil(api.cloud, "unpaired, and still signed in to the shop's cloud")
        XCTAssertNil(CloudSession.load())
        XCTAssertFalse(settings.isPaired)
    }
}
