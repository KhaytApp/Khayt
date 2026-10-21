import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The beta.1 data-integrity review: a crash on a duplicated id, sheet saves
/// that put back what another writer changed, an undo that counted twice, a
/// lock lost to a hostname change, and tombstones spent on a trimmed log.
///
/// The ones that need the app to OPEN a book live in the serialised suite
/// that owns the test support folder (`extension LibraryEditPerfTests`,
/// below); the rest need no book at all.
@MainActor
@Suite(.serialized)
struct Beta1IntegrityTests {

    // MARK: - The lock, across a hostname change

    static func lockFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "khayt-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: StoreLock.filename)
    }

    @Test("the Mac's own lock is still its own after its hostname changes")
    func lockSurvivesARename() throws {
        let url = try Self.lockFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let taken = try #require(StoreLock.take(at: url, host: "shop-mac.local"))
        #expect(StoreLock.verdict(at: url, host: "shop-mac.local").action == .own)
        // Renamed mid-session: the record names the old host, and is fresh.
        #expect(StoreLock.verdict(at: url, host: "shop-mac-2.local").action == .own,
                "the Mac read its own lock as another machine's and refused every write")
        // The beat keeps it, and re-stamps the host the Mac has now.
        let kept = try #require(StoreLock.beat(taken, at: url, host: "shop-mac-2.local"))
        #expect(kept.host == "shop-mac-2.local")
        #expect(StoreLock.read(at: url)?.host == "shop-mac-2.local")
        #expect(StoreLock.verdict(at: url, host: "shop-mac-2.local").action == .own)
        StoreLock.release(kept, at: url)
        #expect(StoreLock.read(at: url) == nil, "the Mac could not let go of its own lock")
    }

    @Test("a fresh record another process wrote is still held, whatever its pid")
    func anotherRecordIsStillHeld() throws {
        let url = try Self.lockFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let now = Date().timeIntervalSince1970 * 1000
        // Same pid as this process — pids are per host — but not the record
        // this process wrote: another machine's, fresh.
        let theirs = StoreLock.Record(app: "Khayt", pid: Int(ProcessInfo.processInfo.processIdentifier),
                                      host: "other-mac.local", takenAt: now - 5, heartbeat: now)
        try JSONEncoder().encode(theirs).write(to: url)
        #expect(StoreLock.verdict(at: url, host: "shop-mac.local").action == .held)
        #expect(StoreLock.take(at: url, host: "shop-mac.local") == nil)
    }

    // MARK: - Tombstones and the activity log

    static func tempBook(_ root: [String: JSONValue]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "khayt-integrity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "khayt-store.json")
        try JSONEncoder().encode(root).write(to: url)
        return url
    }

    static func read(_ url: URL) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
    }

    static func tombs(_ url: URL) throws -> [String] {
        Shop.rows(try read(url), "tombstones").compactMap {
            guard case .object(let t) = $0, case .string(let c)? = t["collection"],
                  case .string(let i)? = t["id"] else { return nil }
            return c + ":" + i
        }
    }

    @Test("the 2001st activity entry adds no tombstone; a real job delete still does")
    func activityTrimLeavesNoTombstone() async throws {
        let full: [JSONValue] = (0..<2000).map {
            .object(["id": .string("AL\($0)"), "action": .string("status"), "rev": .number(1)])
        }
        let url = try Self.tempBook([
            "auditLog": .array(full),
            "printLog": .array([.object(["id": .string("J1"), "project": .string("a"), "rev": .number(2)])]),
            "settings": .object([:]), "tombstones": .array([]),
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            let snapshot = root
            Shop.appendActivity(&root, text: "moved", ref: "J1", settings: [:], root: snapshot)
        }
        #expect(Shop.rows(try Self.read(url), "auditLog").count == 2000)
        #expect(try Self.tombs(url).isEmpty, "the trimmed activity entry was tombstoned")

        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            let snapshot = root
            root["printLog"] = .array([])
            Shop.appendActivity(&root, text: "deleted", ref: "J1", settings: [:], root: snapshot)
        }
        #expect(try Self.tombs(url) == ["printLog:J1"])
    }

    // MARK: - Numbers no Int holds

    @Test("a count past Int reads saturated, not as a trap")
    func hugeNumbersDoNotTrap() {
        let settings: JSONValue = .object(["storefront": .object(["stockQty": .object(["P1": .number(1e300)])])])
        #expect(Shop.stockCount(of: "P1", in: settings) == Int.saturationLimit)
        #expect(ProductSheet.trim(1e300) == String(1e300))
        #expect(ProductSheet.trim(30) == "30")
        #expect(ProductSheet.PartRow.from(.object(["plate": .number(.infinity)]))?.plate ?? 0 == 0)
    }
}

// MARK: - The ones that open a book

extension LibraryEditPerfTests {

    /// Another writer — sync, the iPhone — changing the book on disk.
    static func elsewhere(_ url: URL, _ change: (inout [String: JSONValue]) -> Void) throws {
        var root = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
        change(&root)
        try JSONEncoder().encode(root).write(to: url, options: .atomic)
    }

    static func diskRecord(_ url: URL, _ collection: String, _ id: String) throws -> [String: JSONValue]? {
        let root = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
        for row in Shop.rows(root, collection) {
            if case .object(let o) = row, o["id"] == .string(id) { return o }
        }
        return nil
    }

    static func setField(_ root: inout [String: JSONValue], _ collection: String, _ id: String,
                         _ change: (inout [String: JSONValue]) -> Void) {
        var rows = Shop.rows(root, collection)
        for i in rows.indices {
            guard case .object(var o) = rows[i], o["id"] == .string(id) else { continue }
            change(&o)
            rows[i] = .object(o)
        }
        root[collection] = .array(rows)
    }

    @Test("a book holding two products with one id opens")
    func duplicateProductIdLoads() async throws {
        var book = PerfBook.synthesize(models: 5)
        book["products"] = .array([
            .object(["id": .string("PDUP"), "nameEn": .string("First"), "category": .string("Vases")]),
            .object(["id": .string("PDUP"), "nameEn": .string("Second"), "category": .string("Toys")]),
        ])
        try await withPerfBook(book) { shop, _ in
            #expect(shop.problem == nil)
            #expect(shop.productCategories["PDUP"] == "Vases", "the first of the two is the one kept")
        }
    }

    @Test("a customer saved from its sheet keeps a schedule another writer moved meanwhile")
    func customerSheetKeepsADiskChange() async throws {
        var book = PerfBook.synthesize(models: 5)
        book["clients"] = .array([.object([
            "id": .string("CL1"), "nameEn": .string("Sara"), "phone": .string("0500"), "rev": .number(1),
            "recurring": .object(["enabled": .bool(true), "interval": .string("monthly"),
                                  "nextDue": .string("2026-11-01"), "lastRun": .string("2026-10-01")]),
        ])])
        try await withPerfBook(book) { shop, url in
            let opened = try #require(shop.clients.first { $0.id == "CL1" })
            // The standing order ran on the iPhone while the sheet was open.
            try Self.elsewhere(url) { root in
                Self.setField(&root, "clients", "CL1") { o in
                    o["recurring"] = .object(["enabled": .bool(true), "interval": .string("monthly"),
                                              "nextDue": .string("2026-12-01"), "lastRun": .string("2026-11-01")])
                }
            }
            await shop.load(shop.source)
            var edit = CustomerSheet.opening(opened)
            edit.draft = edit.draft.with(\.email, "sara@example.com")
            await shop.saveCustomer(CustomerSheet.saving(edit), opened: opened)
            #expect(shop.moveProblem == nil)
            let saved = try #require(try Self.diskRecord(url, "clients", "CL1"))
            #expect(saved["email"] == .string("sara@example.com"))
            guard case .object(let schedule)? = saved["recurring"] else { Issue.record("no schedule"); return }
            #expect(schedule["lastRun"] == .string("2026-11-01"),
                    "the sheet rolled the schedule back — the standing order would run twice")
            #expect(schedule["nextDue"] == .string("2026-12-01"))
        }
    }

    @Test("a product saved from its sheet keeps a field another writer changed meanwhile")
    func productSheetKeepsADiskChange() async throws {
        var book = PerfBook.synthesize(models: 5)
        book["products"] = .array([.object([
            "id": .string("P1"), "nameEn": .string("Dragon"), "category": .string("Toys"), "rev": .number(1),
        ])])
        try await withPerfBook(book) { shop, url in
            let opened = try #require(await shop.productForEditing("P1"))
            try Self.elsewhere(url) { root in
                Self.setField(&root, "products", "P1") { $0["category"] = .string("Gifts") }
            }
            // Any write reloads: by Save, the row on screen is the newer one.
            await shop.load(shop.source)
            var edited = opened
            edited.names["en"] = "Red dragon"
            await shop.saveProduct(edited, opened: opened)
            #expect(shop.moveProblem == nil)
            let saved = try #require(try Self.diskRecord(url, "products", "P1"))
            #expect(saved["nameEn"] == .string("Red dragon"))
            #expect(saved["category"] == .string("Gifts"), "the sheet put the old category back")
        }
    }

    @Test("a supplier saved from its sheet keeps a field another writer changed meanwhile")
    func supplierSheetKeepsADiskChange() async throws {
        var book = PerfBook.synthesize(models: 5)
        book["suppliers"] = .array([.object([
            "id": .string("sup1"), "name": .string("Filament Co"), "phone": .string("0500"),
            "purchases": .array([]), "rev": .number(1),
        ])])
        try await withPerfBook(book) { shop, url in
            let opened = try #require(shop.suppliers.first { $0.id == "sup1" })
            try Self.elsewhere(url) { root in
                Self.setField(&root, "suppliers", "sup1") { $0["phone"] = .string("0555") }
            }
            await shop.load(shop.source)
            var edited = opened
            edited.notes = "Ships Sundays"
            await shop.saveSupplier(SupplierSheet.saving(edited, lead: SupplierSheet.leadText(edited)),
                                    opened: opened)
            #expect(shop.moveProblem == nil)
            let saved = try #require(try Self.diskRecord(url, "suppliers", "sup1"))
            #expect(saved["notes"] == .string("Ships Sundays"))
            #expect(saved["phone"] == .string("0555"), "the sheet put the old phone number back")
        }
    }

    @Test("a spool edit that had to run twice leaves one undo, not two")
    func spoolEditRetriedUndoesOnce() async throws {
        var book = PerfBook.synthesize(models: 5)
        book["inventory"] = .array([
            .object(["id": .string("SP1"), "material": .string("PLA"), "weight": .number(1000),
                     "cost": .number(90), "rev": .number(1)]),
        ])
        try await withPerfBook(book) { shop, url in
            let undo = UndoManager()
            undo.groupsByEvent = false
            shop.undoManager = undo
            // The book moves while the edit is being worked out — once — so
            // the writer works it out again on the newer book.
            var moved = false
            StoreWriter.afterMutateForTests = { at in
                guard at == url, !moved else { return }
                moved = true
                try? Self.elsewhere(url) { root in
                    root["clients"] = .array([.object(["id": .string("CLX"), "nameEn": .string("New")])])
                }
            }
            undo.beginUndoGrouping()
            await shop.saveSpool(["weight": .number(800)], id: "SP1", opened: nil)
            undo.endUndoGrouping()
            StoreWriter.afterMutateForTests = nil
            #expect(moved, "the book never moved, so nothing was retried")
            #expect(shop.spendProblem == nil)
            #expect(try Self.diskRecord(url, "inventory", "SP1")?["weight"] == .number(800))

            undo.undo()
            var weight: JSONValue?
            for _ in 0..<600 {
                weight = try Self.diskRecord(url, "inventory", "SP1")?["weight"]
                if weight != .number(800) { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(weight == .number(1000), "Undo put the stock back more than once")
            shop.undoManager = nil
        }
    }
}
